import Foundation

enum LocalMutationDeadlineResult<Value: Sendable>: Sendable {
    case completed(Result<Value, ProviderError>)
    case deadlineExpiredBeforeStart
    case indeterminate(ProviderMutationReceipt)
}

enum LocalOwnedReadResult<Value: Sendable>: Sendable {
    case completed(Value)
    case blocked(ProviderMutationReceipt?)
    case timedOut
    case cancelled
}

private actor LocalMutationResultGate<Value: Sendable> {
    private var result: LocalMutationDeadlineResult<Value>?
    private var continuation: CheckedContinuation<LocalMutationDeadlineResult<Value>, Never>?

    func resolve(_ result: LocalMutationDeadlineResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func wait() async -> LocalMutationDeadlineResult<Value> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private actor LocalReadResultGate<Value: Sendable> {
    private var result: LocalOwnedReadResult<Value>?
    private var continuation: CheckedContinuation<LocalOwnedReadResult<Value>, Never>?

    func resolve(_ result: LocalOwnedReadResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func wait() async -> LocalOwnedReadResult<Value> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

struct LocalRootOwnership: Sendable {
    let mutations: LocalMutationCoordinator
    let artifacts: LocalMutationArtifacts
    /// The physical root this owner was admitted for. Providers must keep
    /// resolving their configured path to this exact root for the lifetime of
    /// the owner; a live symlink retarget never transfers ownership.
    let canonicalRootPath: String?
    let admissionIssue: String?

    init(
        mutations: LocalMutationCoordinator,
        artifacts: LocalMutationArtifacts,
        canonicalRootPath: String?,
        admissionIssue: String? = nil
    ) {
        self.mutations = mutations
        self.artifacts = artifacts
        self.canonicalRootPath = canonicalRootPath
        self.admissionIssue = admissionIssue
    }
}

/// Process-wide ownership registry. Entries are intentionally retained for the
/// process lifetime: dropping a root owner is safe only after proving that no
/// blocking syscall, late result, recovery receipt, or read lease remains.
/// Canonical roots are indexed together with their stable configured-path
/// aliases and enrolled volume identity. A broken enrolled symlink therefore
/// keeps its owner, while an unknown unresolved alias fails closed instead of
/// creating a possibly duplicate owner.
actor LocalRootIORegistry {
    static let shared = LocalRootIORegistry()

    private struct AliasKey: Hashable, Sendable {
        var configuredRootPath: String
        var expectedVolumeIdentity: String?
    }

    private struct CanonicalKey: Hashable, Sendable {
        var canonicalRootPath: String
        var expectedVolumeIdentity: String?
    }

    private struct AliasEntry: Sendable {
        var canonicalRootPath: String?
        var ownership: LocalRootOwnership
    }

    private var entriesByAlias: [AliasKey: AliasEntry] = [:]
    private var entriesByCanonical: [CanonicalKey: LocalRootOwnership] = [:]

    func ownership(
        configuredRootPath: String,
        resolvedCanonicalRootPath: String?,
        expectedVolumeIdentity: String?
    ) -> LocalRootOwnership {
        let aliasKey = AliasKey(
            configuredRootPath: configuredRootPath,
            expectedVolumeIdentity: expectedVolumeIdentity
        )
        if var existing = entriesByAlias[aliasKey] {
            if let resolvedCanonicalRootPath {
                if let previous = existing.canonicalRootPath,
                   previous != resolvedCanonicalRootPath {
                    return rejectedOwnership(
                        "The configured local root now resolves to a different directory."
                    )
                }
                let canonicalKey = CanonicalKey(
                    canonicalRootPath: resolvedCanonicalRootPath,
                    expectedVolumeIdentity: expectedVolumeIdentity
                )
                if let canonicalOwner = entriesByCanonical[canonicalKey],
                   canonicalOwner.mutations !== existing.ownership.mutations {
                    return rejectedOwnership(
                        "The configured local root conflicts with another in-process root owner."
                    )
                }
                existing.canonicalRootPath = resolvedCanonicalRootPath
                entriesByAlias[aliasKey] = existing
                entriesByCanonical[canonicalKey] = existing.ownership
            }
            return existing.ownership
        }

        if let resolvedCanonicalRootPath {
            let canonicalKey = CanonicalKey(
                canonicalRootPath: resolvedCanonicalRootPath,
                expectedVolumeIdentity: expectedVolumeIdentity
            )
            if let existing = entriesByCanonical[canonicalKey] {
                entriesByAlias[aliasKey] = AliasEntry(
                    canonicalRootPath: resolvedCanonicalRootPath,
                    ownership: existing
                )
                return existing
            }
            guard !hasUnresolvedAlias(for: expectedVolumeIdentity) else {
                return rejectedOwnership(
                    "This local root cannot be distinguished from an unavailable in-process root."
                )
            }
            let created = makeOwnership(
                canonicalRootPath: resolvedCanonicalRootPath
            )
            entriesByAlias[aliasKey] = AliasEntry(
                canonicalRootPath: resolvedCanonicalRootPath,
                ownership: created
            )
            entriesByCanonical[canonicalKey] = created
            return created
        }

        // An already-seen configured alias keeps its owner while unavailable.
        // A new unresolved alias is safe only when no root from the same
        // enrolled volume exists in this process; otherwise its identity is
        // ambiguous and all admission must fail closed until reconstruction
        // can resolve the canonical target.
        guard !hasEntry(for: expectedVolumeIdentity) else {
            return rejectedOwnership(
                "The unavailable local root cannot be matched to its in-process owner."
            )
        }
        let created = makeOwnership(canonicalRootPath: nil)
        entriesByAlias[aliasKey] = AliasEntry(
            canonicalRootPath: nil,
            ownership: created
        )
        return created
    }

    func ownership(
        canonicalRootPath: String,
        expectedVolumeIdentity: String?
    ) -> LocalRootOwnership {
        ownership(
            configuredRootPath: canonicalRootPath,
            resolvedCanonicalRootPath: canonicalRootPath,
            expectedVolumeIdentity: expectedVolumeIdentity
        )
    }

    private func makeOwnership(
        canonicalRootPath: String?
    ) -> LocalRootOwnership {
        LocalRootOwnership(
            mutations: LocalMutationCoordinator(),
            artifacts: LocalMutationArtifacts(),
            canonicalRootPath: canonicalRootPath
        )
    }

    private func rejectedOwnership(_ issue: String) -> LocalRootOwnership {
        LocalRootOwnership(
            mutations: LocalMutationCoordinator(),
            artifacts: LocalMutationArtifacts(),
            canonicalRootPath: nil,
            admissionIssue: issue
        )
    }

    private func hasEntry(for expectedVolumeIdentity: String?) -> Bool {
        entriesByAlias.keys.contains {
            $0.expectedVolumeIdentity == expectedVolumeIdentity
        }
    }

    private func hasUnresolvedAlias(
        for expectedVolumeIdentity: String?
    ) -> Bool {
        entriesByAlias.contains { key, entry in
            key.expectedVolumeIdentity == expectedVolumeIdentity
                && entry.canonicalRootPath == nil
        }
    }
}

/// Owns every local filesystem read and mutation until the blocking work
/// actually returns. Ownership is root-wide on purpose: ancestor/descendant
/// overlap, relocate's two paths, and quarantine metadata make narrower
/// locking easy to get wrong.
///
/// Fairness is writer-preferred. Already-admitted ordinary reads may overlap,
/// but the first queued mutation closes read admission. That mutation starts
/// only after all physical read work returns. Caller-visible read deadlines
/// and cancellation never release a lease early.
actor LocalMutationCoordinator {
    private enum RecoveryOrigin: Sendable {
        case quiescent(ProviderLateMutationOutcome)
        case unknownAfterRestart
    }

    private enum Lifecycle: Sendable {
        case pending(ProviderMutationReceipt)
        case started(ProviderMutationReceipt)
        case indeterminate(ProviderMutationReceipt)
        case quiescent(ProviderMutationReceipt, ProviderLateMutationOutcome)
        case awaitingRecovery(ProviderMutationReceipt)
        case recovering(
            ProviderMutationReceipt,
            claimToken: UUID,
            origin: RecoveryOrigin
        )

        var receipt: ProviderMutationReceipt {
            switch self {
            case let .pending(receipt),
                 let .started(receipt),
                 let .indeterminate(receipt),
                 let .quiescent(receipt, _),
                 let .awaitingRecovery(receipt),
                 let .recovering(receipt, _, _):
                return receipt
            }
        }
    }

    private var lifecycleByID: [UUID: Lifecycle] = [:]
    private var pendingIDs: [UUID] = []
    private var startContinuations: [
        UUID: CheckedContinuation<ProviderMutationReceipt?, Never>
    ] = [:]
    private var startedAtProviders: [UUID: @Sendable () -> Date] = [:]
    private var activeID: UUID?
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var preStartResolvers: [UUID: @Sendable () async -> Void] = [:]

    private var activeReadIDs: Set<UUID> = []
    private var activeRecoveryRead: (id: UUID, receiptID: UUID)?
    private var pendingRecoveryAbandonmentTokens: Set<UUID> = []
    private var readTasks: [UUID: Task<Void, Never>] = [:]
    private var readDeadlineTasks: [UUID: Task<Void, Never>] = [:]

    func perform<Value: Sendable>(
        receipt: ProviderMutationReceipt,
        nanoseconds: UInt64,
        clock: any ProviderDeadlineClock,
        startedAt: @escaping @Sendable () -> Date,
        operation: @escaping @Sendable (
            ProviderMutationReceipt
        ) async -> Result<Value, ProviderError>
    ) async -> LocalMutationDeadlineResult<Value> {
        guard nanoseconds > 0, !hasRecoveryBarrier,
              activeRecoveryRead == nil else {
            return .deadlineExpiredBeforeStart
        }

        let gate = LocalMutationResultGate<Value>()
        lifecycleByID[receipt.id] = .pending(receipt)
        pendingIDs.append(receipt.id)
        startedAtProviders[receipt.id] = startedAt
        preStartResolvers[receipt.id] = {
            await gate.resolve(.deadlineExpiredBeforeStart)
        }

        let operationTask = Task.detached { [self] in
            guard let startedReceipt = await waitForStart(receipt.id) else {
                await abandonTaskThatNeverStarted(receipt.id)
                return
            }
            let result = await operation(startedReceipt)
            await finish(receipt.id, result: result, gate: gate)
        }
        operationTasks[receipt.id] = operationTask

        let deadlineTask = Task.detached { [weak self] in
            do {
                try await clock.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
            }
            await self?.expire(receipt.id, gate: gate)
        }
        deadlineTasks[receipt.id] = deadlineTask

        grantNextStartIfPossible()
        return await gate.wait()
    }

    func performRead<Value: Sendable>(
        nanoseconds: UInt64,
        clock: any ProviderDeadlineClock,
        operation: @escaping @Sendable () async -> Value
    ) async -> LocalOwnedReadResult<Value> {
        guard !Task.isCancelled else { return .cancelled }
        guard nanoseconds > 0 else { return .timedOut }
        guard lifecycleByID.isEmpty, activeRecoveryRead == nil else {
            return .blocked(barrierReceipt())
        }
        return await startRead(
            recoveryReceipt: nil,
            nanoseconds: nanoseconds,
            clock: clock,
            operation: operation
        )
    }

    func performRecoveryRead<Value: Sendable>(
        claim: ProviderMutationRecoveryClaim,
        nanoseconds: UInt64,
        clock: any ProviderDeadlineClock,
        operation: @escaping @Sendable () async -> Value
    ) async -> LocalOwnedReadResult<Value> {
        guard !Task.isCancelled else { return .cancelled }
        guard nanoseconds > 0 else { return .timedOut }
        guard activeReadIDs.isEmpty, activeRecoveryRead == nil,
              lifecycleByID.count == 1,
              case let .recovering(receipt, claimToken, _) = lifecycleByID[
                  claim.receipt.id
              ],
              receipt == claim.receipt,
              claimToken == claim.token else {
            return .blocked(barrierReceipt())
        }
        return await startRead(
            recoveryReceipt: claim.receipt,
            nanoseconds: nanoseconds,
            clock: clock,
            operation: operation
        )
    }

    func beginRecovery(
        for receipt: ProviderMutationReceipt
    ) -> ProviderMutationRecoveryClaimResult {
        if let lifecycle = lifecycleByID[receipt.id] {
            guard lifecycle.receipt == receipt else {
                return .inFlight
            }
            switch lifecycle {
            case .pending, .started, .indeterminate:
                return .inFlight
            case let .quiescent(_, outcome):
                return claimRecovery(
                    receipt,
                    origin: .quiescent(outcome)
                )
            case .awaitingRecovery:
                return claimRecovery(
                    receipt,
                    origin: .unknownAfterRestart
                )
            case .recovering:
                return .inFlight
            }
        }

        guard lifecycleByID.isEmpty, pendingIDs.isEmpty, activeID == nil,
              activeReadIDs.isEmpty, activeRecoveryRead == nil else {
            return .inFlight
        }
        return claimRecovery(receipt, origin: .unknownAfterRestart)
    }

    func barrierReceipt() -> ProviderMutationReceipt? {
        if let activeID,
           let lifecycle = lifecycleByID[activeID] {
            return lifecycle.receipt
        }
        return lifecycleByID.values.first?.receipt
    }

    func state(
        for receipt: ProviderMutationReceipt
    ) -> ProviderIndeterminateMutationState {
        guard let lifecycle = lifecycleByID[receipt.id] else {
            // A requested receipt is not a process-restart candidate while an
            // unrelated same-root owner or read still exists.
            return lifecycleByID.isEmpty
                && activeReadIDs.isEmpty
                && activeRecoveryRead == nil
                ? .unknownAfterRestart
                : .inFlight
        }
        guard lifecycle.receipt == receipt else {
            return .inFlight
        }
        switch lifecycle {
        case .started, .indeterminate, .pending:
            return .inFlight
        case let .quiescent(_, outcome):
            return .quiescent(outcome)
        case .awaitingRecovery:
            return .unknownAfterRestart
        case .recovering:
            return .inFlight
        }
    }

    /// Returns only a receipt that has already crossed its deadline after
    /// starting. Recovery uses this when persisting the caller-visible
    /// indeterminate event failed but the in-process owner still exists.
    func indeterminateReceipt() -> ProviderMutationReceipt? {
        lifecycleByID.values.compactMap { lifecycle in
            switch lifecycle {
            case let .indeterminate(receipt), let .quiescent(receipt, _):
                return receipt
            case .pending, .started, .awaitingRecovery, .recovering:
                return nil
            }
        }.first
    }

    func finishRecovery(_ claim: ProviderMutationRecoveryClaim) {
        guard activeRecoveryRead == nil,
              case let .recovering(receipt, claimToken, _) = lifecycleByID[
                  claim.receipt.id
              ],
              receipt == claim.receipt,
              claimToken == claim.token else {
            return
        }
        lifecycleByID[claim.receipt.id] = nil
        grantNextStartIfPossible()
    }

    func abandonRecovery(_ claim: ProviderMutationRecoveryClaim) {
        guard case let .recovering(receipt, claimToken, origin) = lifecycleByID[
                  claim.receipt.id
              ],
              receipt == claim.receipt,
              claimToken == claim.token else {
            return
        }
        if let activeRecoveryRead {
            guard activeRecoveryRead.receiptID == receipt.id else { return }
            // The caller may time out before the blocking recovery probe
            // returns. Retain both the read lease and claim until physical
            // completion, then restore the receipt barrier for retry.
            pendingRecoveryAbandonmentTokens.insert(claimToken)
            return
        }
        restoreRecoveryBarrier(receipt, origin: origin)
    }

    private func restoreRecoveryBarrier(
        _ receipt: ProviderMutationReceipt,
        origin: RecoveryOrigin
    ) {
        switch origin {
        case let .quiescent(outcome):
            lifecycleByID[receipt.id] = .quiescent(receipt, outcome)
        case .unknownAfterRestart:
            lifecycleByID[receipt.id] = .awaitingRecovery(receipt)
        }
    }

    func retainedOperationCount() -> Int {
        operationTasks.count
    }

    func retainedReadCount() -> Int {
        readTasks.count
    }

    private func startRead<Value: Sendable>(
        recoveryReceipt: ProviderMutationReceipt?,
        nanoseconds: UInt64,
        clock: any ProviderDeadlineClock,
        operation: @escaping @Sendable () async -> Value
    ) async -> LocalOwnedReadResult<Value> {
        let id = UUID()
        let gate = LocalReadResultGate<Value>()
        if let recoveryReceipt {
            activeRecoveryRead = (id, recoveryReceipt.id)
        } else {
            activeReadIDs.insert(id)
        }

        let readTask = Task.detached { [self] in
            let value = await operation()
            await finishRead(id, value: value, gate: gate)
        }
        readTasks[id] = readTask
        let deadlineTask = Task.detached { [weak self] in
            do {
                try await clock.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
            }
            await self?.expireRead(id, gate: gate)
        }
        readDeadlineTasks[id] = deadlineTask

        return await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            Task { await self.cancelReadCaller(id, gate: gate) }
        }
    }

    private func finishRead<Value: Sendable>(
        _ id: UUID,
        value: Value,
        gate: LocalReadResultGate<Value>
    ) async {
        readTasks[id] = nil
        readDeadlineTasks.removeValue(forKey: id)?.cancel()
        activeReadIDs.remove(id)
        if activeRecoveryRead?.id == id {
            let receiptID = activeRecoveryRead?.receiptID
            activeRecoveryRead = nil
            if let receiptID,
               case let .recovering(receipt, claimToken, origin) = lifecycleByID[
                   receiptID
               ],
               pendingRecoveryAbandonmentTokens.remove(claimToken) != nil {
                restoreRecoveryBarrier(receipt, origin: origin)
            }
        }
        await gate.resolve(.completed(value))
        grantNextStartIfPossible()
    }

    private func expireRead<Value: Sendable>(
        _ id: UUID,
        gate: LocalReadResultGate<Value>
    ) async {
        guard readTasks[id] != nil else { return }
        readDeadlineTasks[id] = nil
        await gate.resolve(.timedOut)
    }

    private func cancelReadCaller<Value: Sendable>(
        _ id: UUID,
        gate: LocalReadResultGate<Value>
    ) async {
        guard readTasks[id] != nil else { return }
        readDeadlineTasks.removeValue(forKey: id)?.cancel()
        await gate.resolve(.cancelled)
    }

    private func waitForStart(_ id: UUID) async -> ProviderMutationReceipt? {
        guard case .pending = lifecycleByID[id] else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            startContinuations[id] = continuation
            grantNextStartIfPossible()
        }
    }

    private func grantNextStartIfPossible() {
        guard activeID == nil,
              activeReadIDs.isEmpty,
              activeRecoveryRead == nil,
              !hasRecoveryBarrier,
              let nextID = pendingIDs.first,
              let continuation = startContinuations[nextID],
              case var .pending(receipt) = lifecycleByID[nextID] else {
            return
        }
        pendingIDs.removeFirst()
        startContinuations[nextID] = nil
        preStartResolvers[nextID] = nil
        receipt.startedAt = startedAtProviders.removeValue(forKey: nextID)?() ?? receipt.startedAt
        activeID = nextID
        lifecycleByID[nextID] = .started(receipt)
        continuation.resume(returning: receipt)
    }

    private var hasRecoveryBarrier: Bool {
        lifecycleByID.values.contains { lifecycle in
            switch lifecycle {
            case .indeterminate, .quiescent, .awaitingRecovery, .recovering:
                return true
            case .pending, .started:
                return false
            }
        }
    }

    private func expire<Value: Sendable>(
        _ id: UUID,
        gate: LocalMutationResultGate<Value>
    ) async {
        guard let lifecycle = lifecycleByID[id] else { return }
        switch lifecycle {
        case .pending:
            lifecycleByID[id] = nil
            pendingIDs.removeAll { $0 == id }
            let continuation = startContinuations.removeValue(forKey: id)
            startedAtProviders[id] = nil
            preStartResolvers[id] = nil
            operationTasks[id]?.cancel()
            deadlineTasks[id] = nil
            continuation?.resume(returning: nil)
            await gate.resolve(.deadlineExpiredBeforeStart)
            grantNextStartIfPossible()

        case let .started(receipt):
            lifecycleByID[id] = .indeterminate(receipt)
            deadlineTasks[id] = nil
            await invalidatePendingMutations()
            await gate.resolve(.indeterminate(receipt))

        case .indeterminate, .quiescent, .awaitingRecovery, .recovering:
            break
        }
    }

    private func finish<Value: Sendable>(
        _ id: UUID,
        result: Result<Value, ProviderError>,
        gate: LocalMutationResultGate<Value>
    ) async {
        guard let lifecycle = lifecycleByID[id] else {
            operationTasks[id] = nil
            return
        }
        operationTasks[id] = nil
        deadlineTasks.removeValue(forKey: id)?.cancel()
        activeID = nil

        switch lifecycle {
        case .started:
            lifecycleByID[id] = nil
            await gate.resolve(.completed(result))
            grantNextStartIfPossible()

        case let .indeterminate(receipt):
            let lateOutcome: ProviderLateMutationOutcome
            switch result {
            case .success:
                lateOutcome = .succeeded
            case let .failure(error):
                lateOutcome = .failed(detail: String(describing: error))
            }
            lifecycleByID[id] = .quiescent(receipt, lateOutcome)

        case .pending, .quiescent, .awaitingRecovery, .recovering:
            break
        }
    }

    private func claimRecovery(
        _ receipt: ProviderMutationReceipt,
        origin: RecoveryOrigin
    ) -> ProviderMutationRecoveryClaimResult {
        let claim = ProviderMutationRecoveryClaim(receipt: receipt)
        lifecycleByID[receipt.id] = .recovering(
            receipt,
            claimToken: claim.token,
            origin: origin
        )
        return .claimed(claim)
    }

    private func abandonTaskThatNeverStarted(_ id: UUID) {
        operationTasks[id] = nil
    }

    /// Work authorized behind an operation that became indeterminate belongs
    /// to the old schedule. It must never resume after reconciliation; only a
    /// newly probed and replanned call may enter the queue.
    private func invalidatePendingMutations() async {
        let invalidated = pendingIDs
        pendingIDs.removeAll()
        for id in invalidated {
            guard case .pending = lifecycleByID[id] else { continue }
            lifecycleByID[id] = nil
            startedAtProviders[id] = nil
            deadlineTasks.removeValue(forKey: id)?.cancel()
            operationTasks[id]?.cancel()
            startContinuations.removeValue(forKey: id)?.resume(returning: nil)
            let resolve = preStartResolvers.removeValue(forKey: id)
            await resolve?()
        }
    }
}
