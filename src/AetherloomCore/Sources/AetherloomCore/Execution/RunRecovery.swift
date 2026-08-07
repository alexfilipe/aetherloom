import Foundation

public enum RunRecoveryError: Error, Equatable, Sendable {
    case indeterminateMutationStillRunning(
        operationID: OperationID,
        receiptID: UUID
    )
    case indeterminateMutationProviderCannotRecover(operationID: OperationID)
    case providerTruthUnavailable(operationID: OperationID, detail: String)
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

        var reconciled: [OperationID] = []
        var receiptsToFinish: [(any IndeterminateMutationRecovering, ProviderMutationReceipt)] = []
        for operation in pendingOperations.sorted(by: { $0.id < $1.id }) {
            var receipt = replay.indeterminateReceiptsByOperation[operation.id]
            if receipt == nil,
               let discovered = try await discoverIndeterminateReceipt(
                   for: operation
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
            if let receipt {
                guard receiptMatches(receipt, operation: operation) else {
                    throw RunRecoveryError
                        .indeterminateMutationProviderCannotRecover(
                            operationID: operation.id
                        )
                }
                guard let provider = providers[receipt.provider]
                    as? any IndeterminateMutationRecovering else {
                    throw RunRecoveryError.indeterminateMutationProviderCannotRecover(
                        operationID: operation.id
                    )
                }
                switch await provider.indeterminateMutationState(for: receipt) {
                case .inFlight:
                    throw RunRecoveryError.indeterminateMutationStillRunning(
                        operationID: operation.id,
                        receiptID: receipt.id
                    )
                case .quiescent, .unknownAfterRestart:
                    break
                }
                if receipt.kind == .fetch {
                    // A fetch writes only to the engine's staging area. The
                    // destination mutation could not start until materialize
                    // returned, so quiescence confirms that the journaled
                    // operation itself was never applied.
                    reconciled.append(operation.id)
                    receiptsToFinish.append((provider, receipt))
                    continue
                }
                guard receipt.provider == operation.location else {
                    throw RunRecoveryError
                        .indeterminateMutationProviderCannotRecover(
                            operationID: operation.id
                        )
                }
                if let record = try await confirmedRecord(
                    for: operation,
                    syncSetID: replay.syncSetID,
                    recoveryProvider: provider,
                    receipt: receipt
                ) {
                    try await stores.baseRecords.apply(.upsert(record))
                    restoredRecords += 1
                }
                reconciled.append(operation.id)
                receiptsToFinish.append((provider, receipt))
                continue
            }

            if let record = try await confirmedRecord(
                for: operation,
                syncSetID: replay.syncSetID
            ) {
                try await stores.baseRecords.apply(.upsert(record))
                restoredRecords += 1
                reconciled.append(operation.id)
            }
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
        try await stores.journal.markReconciled(runID: replay.runID)
        for (provider, receipt) in receiptsToFinish {
            await stage?.releaseDeferredArtifacts(for: receipt)
            await provider.finishIndeterminateMutationRecovery(for: receipt)
        }
        return RunRecoveryReport(runID: replay.runID, reconciledOperations: reconciled, restoredRecords: restoredRecords)
    }

    private func discoverIndeterminateReceipt(
        for operation: Operation
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
            guard receiptMatches(receipt, operation: operation),
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

    private func confirmedRecord(
        for operation: Operation,
        syncSetID: UUID,
        recoveryProvider: (any IndeterminateMutationRecovering)? = nil,
        receipt: ProviderMutationReceipt? = nil
    ) async throws -> BaseRecord? {
        guard let provider = providers[operation.location] else {
            throw RunRecoveryError.providerTruthUnavailable(
                operationID: operation.id,
                detail: "The operation's provider is missing."
            )
        }
        let now = environment.now()

        switch operation.kind {
        case let .makeFolder(path):
            let current = try await recoveryState(
                of: ItemObservation(location: operation.location, path: path, kind: .folder),
                provider: provider,
                recoveryProvider: recoveryProvider,
                receipt: receipt,
                operationID: operation.id
            )
            guard let current, current.isFolder, !current.isTrashed else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [operation.location: LocationMemory(itemID: current.itemID, revisionToken: current.version.revisionToken, lastSeenAt: now)],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .transfer(content, path, _):
            let current = try await recoveryState(
                of: ItemObservation(location: operation.location, path: path, kind: content.kind),
                provider: provider,
                recoveryProvider: recoveryProvider,
                receipt: receipt,
                operationID: operation.id
            )
            guard let current, matchingRecoveredContent(current.version, content.expectedVersion) else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [
                    content.sourceLocation: LocationMemory(
                        itemID: content.itemID,
                        revisionToken: content.expectedVersion.revisionToken,
                        lastSeenAt: now
                    ),
                    operation.location: LocationMemory(
                        itemID: current.itemID,
                        revisionToken: current.version.revisionToken,
                        lastSeenAt: now
                    )
                ],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .relocate(itemRef, newPath):
            var destinationProbe = itemRef.observation
            destinationProbe.path = newPath
            let current = try await recoveryState(
                of: destinationProbe,
                provider: provider,
                recoveryProvider: recoveryProvider,
                receipt: receipt,
                operationID: operation.id
            )
            guard let current, current.path == newPath, !current.isTrashed else {
                if receipt != nil {
                    _ = try await recoveryState(
                        of: itemRef.observation,
                        provider: provider,
                        recoveryProvider: recoveryProvider,
                        receipt: receipt,
                        operationID: operation.id
                    )
                }
                return nil
            }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [operation.location: LocationMemory(itemID: current.itemID, revisionToken: current.version.revisionToken, lastSeenAt: now)],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .trash(itemRef):
            let current = try await recoveryState(
                of: itemRef.observation,
                provider: provider,
                recoveryProvider: recoveryProvider,
                receipt: receipt,
                operationID: operation.id
            )
            guard current?.isTrashed == true else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: itemRef.path,
                kind: itemRef.kind,
                version: itemRef.expectedVersion,
                perLocation: [operation.location: LocationMemory(itemID: itemRef.itemID, revisionToken: itemRef.expectedVersion.revisionToken, lastSeenAt: now)],
                tombstone: Tombstone(deletedAt: now),
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private func recoveryState(
        of observation: ItemObservation,
        provider: any StorageProvider,
        recoveryProvider: (any IndeterminateMutationRecovering)?,
        receipt: ProviderMutationReceipt?,
        operationID: OperationID
    ) async throws -> ItemObservation? {
        do {
            if let recoveryProvider, let receipt {
                return try await recoveryProvider.currentStateForRecovery(
                    of: observation,
                    receipt: receipt
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
}

private func receiptMatches(
    _ receipt: ProviderMutationReceipt,
    operation: Operation
) -> Bool {
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
