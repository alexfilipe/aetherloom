import Foundation

public enum RunRecoveryError: Error, Equatable, Sendable {
    case indeterminateMutationStillRunning(
        operationID: OperationID,
        receiptID: UUID
    )
    case indeterminateMutationProviderCannotRecover(operationID: OperationID)
    case providerTruthUnavailable(operationID: OperationID, detail: String)
    case relocateOutcomeUncertain(operationID: OperationID, detail: String)
}

public struct RunRecoveryReport: Codable, Hashable, Sendable {
    public var runID: UUID
    public var reconciledOperations: [OperationID]
    public var restoredRecords: Int

    public init(runID: UUID, reconciledOperations: [OperationID] = [], restoredRecords: Int = 0) {
        self.runID = runID
        self.reconciledOperations = reconciledOperations
        self.restoredRecords = restoredRecords
    }
}

public struct RunRecovery: Sendable {
    private let providers: [LocationID: any StorageProvider]
    private let stores: EngineStores
    private let stage: ContentStage?
    private let environment: ExecutionEnvironment

    public init(
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,
        stage: ContentStage? = nil,
        environment: ExecutionEnvironment = ExecutionEnvironment()
    ) {
        self.providers = providers
        self.stores = stores
        self.stage = stage
        self.environment = environment
    }

    public func recover(_ replay: JournalReplay) async throws -> RunRecoveryReport {
        var restoredRecords = 0
        for event in replay.events {
            guard case let .itemConverged(_, record) = event else { continue }
            try await stores.baseRecords.apply(.upsert(record))
            restoredRecords += 1
        }

        let pendingOperations = replay.events.compactMap { event -> Operation? in
            guard case let .intent(operation) = event, replay.pendingOperationIDs.contains(operation.id) else {
                return nil
            }
            return operation
        }

        let sortedPendingOperations = pendingOperations.sorted { $0.id < $1.id }
        var reconciled: [OperationID] = []
        var receiptsByOperation: [OperationID: ProviderMutationReceipt] = [:]
        var claimsByOperation: [OperationID: ProviderMutationRecoveryClaim] = [:]
        var claimsToFinish: [(
            provider: any IndeterminateMutationRecovering,
            claim: ProviderMutationRecoveryClaim
        )] = []
        do {
            // Discover and durably bind every receipt before claiming or
            // probing any operation. This makes a same-owner WAL prefix
            // independent of operation-ID ordering.
            for operation in sortedPendingOperations {
                var receipt = replay.indeterminateReceiptsByOperation[operation.id]
                if receipt == nil,
                   let discovered = try await discoverIndeterminateReceipt(
                       for: operation,
                       runID: replay.runID
                   ) {
                    // Repair the WAL before inspecting or releasing the owned
                    // mutation. A second persistence failure leaves the intent
                    // unfinished and the provider barrier intact.
                    try await stores.journal.append(
                        .mutationIndeterminate(
                            operationID: operation.id,
                            receipt: discovered,
                            occurredAt: environment.now()
                        ),
                        runID: replay.runID
                    )
                    receipt = discovered
                }
                guard let receipt else { continue }
                guard receiptMatches(
                    receipt,
                    operation: operation,
                    runID: replay.runID
                ) else {
                    throw RunRecoveryError
                        .indeterminateMutationProviderCannotRecover(
                            operationID: operation.id
                        )
                }
                guard (providers[receipt.provider]
                    as? any IndeterminateMutationRecovering) != nil else {
                    throw RunRecoveryError
                        .indeterminateMutationProviderCannotRecover(
                            operationID: operation.id
                        )
                }
                receiptsByOperation[operation.id] = receipt
            }

            // Claim every durable receipt before ordinary confirmation begins.
            // A receipt-less sibling may then read only through an exact claim
            // that its provider proves belongs to the same ownership domain.
            for operation in sortedPendingOperations {
                guard let receipt = receiptsByOperation[operation.id],
                      let provider = providers[receipt.provider]
                        as? any IndeterminateMutationRecovering else {
                    continue
                }
                let claim: ProviderMutationRecoveryClaim
                switch await provider.beginIndeterminateMutationRecovery(
                    for: receipt
                ) {
                case .inFlight:
                    throw RunRecoveryError.indeterminateMutationStillRunning(
                        operationID: operation.id,
                        receiptID: receipt.id
                    )
                case let .claimed(value):
                    claim = value
                }
                claimsByOperation[operation.id] = claim
                claimsToFinish.append((provider, claim))
            }

            for operation in sortedPendingOperations {
                var recoveryProvider: (any IndeterminateMutationRecovering)?
                var recoveryClaim: ProviderMutationRecoveryClaim?
                if let claim = claimsByOperation[operation.id],
                   let provider = providers[operation.location]
                    as? any IndeterminateMutationRecovering {
                    recoveryProvider = provider
                    recoveryClaim = claim
                } else if let provider = providers[operation.location]
                    as? any IndeterminateMutationRecovering {
                    for claimed in claimsToFinish {
                        if await provider.canPerformRecoveryRead(
                            with: claimed.claim
                        ) {
                            recoveryProvider = provider
                            recoveryClaim = claimed.claim
                            break
                        }
                    }
                }

                if let receipt = receiptsByOperation[operation.id] {
                    if receipt.kind == .fetch {
                        // A fetch writes only to the engine's staging area. The
                        // destination mutation could not start until materialize
                        // returned, so quiescence confirms that the journaled
                        // operation itself was never applied.
                        reconciled.append(operation.id)
                        continue
                    }
                    guard receipt.provider == operation.location else {
                        throw RunRecoveryError
                            .indeterminateMutationProviderCannotRecover(
                                operationID: operation.id
                            )
                    }
                    try await confirmPendingOperation(
                        for: operation,
                        recoveryProvider: recoveryProvider,
                        recoveryClaim: recoveryClaim
                    )
                    reconciled.append(operation.id)
                    continue
                }

                try await confirmPendingOperation(
                    for: operation,
                    recoveryProvider: recoveryProvider,
                    recoveryClaim: recoveryClaim
                )
                reconciled.append(operation.id)
            }

            await stores.activity.append(
                ActivityEntry(
                    occurredAt: environment.now(),
                    syncSetID: replay.syncSetID,
                    runID: replay.runID,
                    category: .safety,
                    message: ActivityMessageCatalog.recoveryPerformed,
                    detail: "\(reconciled.count) operations reconciled."
                )
            )
            do {
                try await stores.journal.markReconciled(runID: replay.runID)
            } catch {
                // Atomic replacement may commit and then surface an I/O error.
                // Release the exact barriers only when a separate durable read
                // positively proves that this sync set has no unfinished run.
                let durablyReconciled: Bool
                do {
                    durablyReconciled = try await stores.journal.unfinishedRun(
                        for: replay.syncSetID
                    ) == nil
                } catch {
                    durablyReconciled = false
                }
                guard durablyReconciled else { throw error }
            }
        } catch {
            for claimed in claimsToFinish {
                await claimed.provider.abandonIndeterminateMutationRecovery(
                    claimed.claim
                )
            }
            throw error
        }
        for claimed in claimsToFinish {
            await stage?.releaseDeferredArtifacts(for: claimed.claim.receipt)
            await claimed.provider.finishIndeterminateMutationRecovery(
                claimed.claim
            )
        }
        return RunRecoveryReport(runID: replay.runID, reconciledOperations: reconciled, restoredRecords: restoredRecords)
    }

    private func discoverIndeterminateReceipt(
        for operation: Operation,
        runID: UUID
    ) async throws -> ProviderMutationReceipt? {
        var candidateIDs = [operation.location]
        if case let .transfer(content, _, _) = operation.kind,
           content.sourceLocation != operation.location {
            candidateIDs.append(content.sourceLocation)
        }

        var discovered: ProviderMutationReceipt?
        for id in candidateIDs {
            guard let provider = providers[id]
                as? any IndeterminateMutationRecovering,
                let receipt = await provider.indeterminateMutationReceipt()
            else {
                continue
            }
            guard receipt.correlation == ProviderMutationCorrelation(
                      runID: runID,
                      operationID: operation.id
                  ),
                  receiptMatches(
                      receipt,
                      operation: operation,
                      runID: runID
                  ),
                  discovered == nil || discovered == receipt else {
                throw RunRecoveryError
                    .indeterminateMutationProviderCannotRecover(
                        operationID: operation.id
                    )
            }
            discovered = receipt
        }
        return discovered
    }

    /// Proves whether one pending filesystem operation applied or remained
    /// unapplied. Recovery deliberately does not turn that operation-level
    /// truth into a base record: only an `itemConverged` journal event proves
    /// that every sibling operation for the item succeeded. A fresh scan and
    /// plan incorporates any individually applied operation after the old WAL
    /// has been closed.
    private func confirmPendingOperation(
        for operation: Operation,
        recoveryProvider: (any IndeterminateMutationRecovering)?,
        recoveryClaim: ProviderMutationRecoveryClaim?
    ) async throws {
        guard let provider = providers[operation.location] else {
            throw RunRecoveryError.providerTruthUnavailable(
                operationID: operation.id,
                detail: "The operation's provider is missing."
            )
        }

        switch operation.kind {
        case let .makeFolder(path):
            let expected = ItemObservation(
                location: operation.location,
                path: path,
                kind: .folder
            )
            let current = try await recoveryState(
                of: expected,
                provider: provider,
                recoveryProvider: recoveryProvider,
                recoveryClaim: recoveryClaim,
                operationID: operation.id
            )
            guard let current else { return }
            try requireRecoveryAttribution(
                current,
                expected: expected,
                operationID: operation.id,
                permitsTrashed: false
            )
            return

        case let .transfer(content, path, _):
            let expected = ItemObservation(
                location: operation.location,
                path: path,
                kind: content.kind
            )
            let current = try await recoveryState(
                of: expected,
                provider: provider,
                recoveryProvider: recoveryProvider,
                recoveryClaim: recoveryClaim,
                operationID: operation.id
            )
            guard let current else { return }
            try requireRecoveryAttribution(
                current,
                expected: expected,
                operationID: operation.id,
                permitsTrashed: false
            )
            guard matchingRecoveredContent(
                current.version,
                content.expectedVersion
            ) else {
                return
            }
            return

        case let .relocate(itemRef, newPath):
            var destinationProbe = itemRef.observation
            destinationProbe.path = newPath
            let resolvedDestination = await recoveryStateResult(
                of: destinationProbe,
                provider: provider,
                recoveryProvider: recoveryProvider,
                recoveryClaim: recoveryClaim,
                operationID: operation.id
            )
            let resolvedSource = await recoveryStateResult(
                of: itemRef.observation,
                provider: provider,
                recoveryProvider: recoveryProvider,
                recoveryClaim: recoveryClaim,
                operationID: operation.id
            )
            let destination = try resolvedDestination.get()
            let source = try resolvedSource.get()

            let destinationMatches = destination.map {
                observation(
                    $0,
                    matches: itemRef,
                    at: newPath,
                    mayBeTrashed: false
                )
            } ?? false
            let liveSourceMatches = source.map {
                observation(
                    $0,
                    matches: itemRef,
                    at: itemRef.path,
                    mayBeTrashed: false
                )
            } ?? false
            let trashedSourceMatches = source.map {
                $0.isTrashed && observation(
                    $0,
                    matches: itemRef,
                    at: itemRef.path,
                    mayBeTrashed: true
                )
            } ?? false

            if destination == nil, liveSourceMatches {
                // The old relocate definitely did not apply. Recovery may
                // close the intent only into a fresh scan/replan; it never
                // reissues the old schedule.
                return
            }
            guard destination != nil,
                  destinationMatches,
                  source == nil || trashedSourceMatches else {
                throw RunRecoveryError.relocateOutcomeUncertain(
                    operationID: operation.id,
                    detail: relocateUncertaintyDetail(
                        destination: destination,
                        source: source,
                        destinationMatches: destinationMatches,
                        liveSourceMatches: liveSourceMatches,
                        trashedSourceMatches: trashedSourceMatches
                    )
                )
            }
            return

        case let .trash(itemRef):
            let current = try await recoveryState(
                of: itemRef.observation,
                provider: provider,
                recoveryProvider: recoveryProvider,
                recoveryClaim: recoveryClaim,
                operationID: operation.id
            )
            guard let current else {
                throw RunRecoveryError.providerTruthUnavailable(
                    operationID: operation.id,
                    detail: "Trash absence has no committed recoverable-trash proof."
                )
            }
            try requireRecoveryAttribution(
                current,
                expected: itemRef.observation,
                operationID: operation.id,
                permitsTrashed: true
            )
            guard current.isTrashed else { return }
            guard observation(
                current,
                matches: itemRef,
                at: itemRef.path,
                mayBeTrashed: true
            ) else {
                throw RunRecoveryError.providerTruthUnavailable(
                    operationID: operation.id,
                    detail: "Trash proof does not match the intended item identity or version."
                )
            }
            return
        }
    }

    private func recoveryState(
        of observation: ItemObservation,
        provider: any StorageProvider,
        recoveryProvider: (any IndeterminateMutationRecovering)?,
        recoveryClaim: ProviderMutationRecoveryClaim?,
        operationID: OperationID
    ) async throws -> ItemObservation? {
        do {
            if let recoveryProvider, let recoveryClaim {
                return try await recoveryProvider.currentStateForRecovery(
                    of: observation,
                    claim: recoveryClaim
                )
            }
            return try await provider.currentState(of: observation)
        } catch ProviderError.notFound {
            return nil
        } catch {
            throw RunRecoveryError.providerTruthUnavailable(
                operationID: operationID,
                detail: String(describing: error)
            )
        }
    }

    private func recoveryStateResult(
        of observation: ItemObservation,
        provider: any StorageProvider,
        recoveryProvider: (any IndeterminateMutationRecovering)?,
        recoveryClaim: ProviderMutationRecoveryClaim?,
        operationID: OperationID
    ) async -> Result<ItemObservation?, RunRecoveryError> {
        do {
            return .success(
                try await recoveryState(
                    of: observation,
                    provider: provider,
                    recoveryProvider: recoveryProvider,
                    recoveryClaim: recoveryClaim,
                    operationID: operationID
                )
            )
        } catch let error as RunRecoveryError {
            return .failure(error)
        } catch {
            return .failure(
                .providerTruthUnavailable(
                    operationID: operationID,
                    detail: String(describing: error)
                )
            )
        }
    }

    private func observation(
        _ observation: ItemObservation,
        matches expected: ItemRef,
        at path: SyncPath,
        mayBeTrashed: Bool
    ) -> Bool {
        observation.location == expected.location
            && observation.path == path
            && observation.kind == expected.kind
            && !observation.isPlaceholder
            && (mayBeTrashed || !observation.isTrashed)
            && observation.version.comparison(to: expected.expectedVersion) == .same
            && (expected.itemID == nil || observation.itemID == expected.itemID)
    }

    private func requireRecoveryAttribution(
        _ current: ItemObservation,
        expected: ItemObservation,
        operationID: OperationID,
        permitsTrashed: Bool
    ) throws {
        guard current.location == expected.location,
              current.path == expected.path,
              current.kind == expected.kind,
              !current.isPlaceholder,
              permitsTrashed || !current.isTrashed else {
            throw RunRecoveryError.providerTruthUnavailable(
                operationID: operationID,
                detail: "Provider truth was not bound to the requested location, path, kind, and availability state."
            )
        }
    }

    private func relocateUncertaintyDetail(
        destination: ItemObservation?,
        source: ItemObservation?,
        destinationMatches: Bool,
        liveSourceMatches: Bool,
        trashedSourceMatches: Bool
    ) -> String {
        if destinationMatches, liveSourceMatches {
            return "Both the intended destination and the live source are present."
        }
        if destination != nil, !destinationMatches {
            return "Destination kind, identity, or version does not prove the intended item."
        }
        if source != nil, !liveSourceMatches, !trashedSourceMatches {
            return "Source state does not prove either the original item or a recoverable trash move."
        }
        if destination == nil, source == nil {
            return "Neither endpoint contains enough evidence to establish the relocate outcome."
        }
        if destination == nil, trashedSourceMatches {
            return "The source is recoverably trashed but the intended destination is absent."
        }
        return "The relocate endpoints do not establish a single safe outcome."
    }
}

private func receiptMatches(
    _ receipt: ProviderMutationReceipt,
    operation: Operation,
    runID: UUID
) -> Bool {
    guard receipt.correlation == ProviderMutationCorrelation(
        runID: runID,
        operationID: operation.id
    ) else {
        return false
    }
    switch operation.kind {
    case let .makeFolder(path):
        return receipt.provider == operation.location
            && receipt.kind == .makeFolder
            && receipt.affectedPaths == [path]

    case let .transfer(content, path, _):
        let isFetch = receipt.provider == content.sourceLocation
            && receipt.kind == .fetch
            && receipt.affectedPaths == [content.path]
        let isStore = receipt.provider == operation.location
            && receipt.kind == .store
            && receipt.affectedPaths == [path]
        return isFetch || isStore

    case let .relocate(itemRef, newPath):
        return receipt.provider == operation.location
            && receipt.kind == .relocate
            && receipt.affectedPaths == [itemRef.path, newPath]

    case let .trash(itemRef):
        return receipt.provider == operation.location
            && receipt.kind == .trash
            && receipt.affectedPaths == [itemRef.path]
    }
}

private func matchingRecoveredContent(_ lhs: ItemVersion, _ rhs: ItemVersion) -> Bool {
    if lhs.isSameVersion(as: rhs) {
        return true
    }
    if let lhsSize = lhs.size, let rhsSize = rhs.size, lhsSize == rhsSize, rhs.contentHash == nil {
        return true
    }
    return false
}
