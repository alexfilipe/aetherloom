import Foundation

enum LocalMutationDeadlineResult<Value: Sendable>: Sendable {
    case completed(Result<Value, ProviderError>)
    case deadlineExpiredBeforeStart
    case indeterminate(ProviderMutationReceipt)
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

/// Owns every local filesystem mutation until the blocking work actually
/// returns. The queue is root-wide on purpose: ancestor/descendant overlap,
/// relocate's two paths, and quarantine metadata make narrower locking easy to
/// get wrong. A task that crosses its caller deadline remains retained and
/// blocks the queue until recovery reconciles its receipt.
actor LocalMutationCoordinator {
    private enum Lifecycle: Sendable {
        case pending(ProviderMutationReceipt)
        case started(ProviderMutationReceipt)
        case indeterminate(ProviderMutationReceipt)
        case quiescent(ProviderMutationReceipt, ProviderLateMutationOutcome)

        var receipt: ProviderMutationReceipt {
            switch self {
            case let .pending(receipt),
                 let .started(receipt),
                 let .indeterminate(receipt),
                 let .quiescent(receipt, _):
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

    func perform<Value: Sendable>(
        receipt: ProviderMutationReceipt,
        nanoseconds: UInt64,
        clock: any ProviderDeadlineClock,
        startedAt: @escaping @Sendable () -> Date,
        operation: @escaping @Sendable (
            ProviderMutationReceipt
        ) async -> Result<Value, ProviderError>
    ) async -> LocalMutationDeadlineResult<Value> {
        guard nanoseconds > 0, !hasRecoveryBarrier else {
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

    func barrierReceipt() -> ProviderMutationReceipt? {
        if let activeID,
           let lifecycle = lifecycleByID[activeID] {
            return lifecycle.receipt
        }
        // Pending work also bars reads. Its detached owner may not have
        // reached `waitForStart` yet, and allowing a scan in that scheduling
        // window would let it overlap the mutation as soon as the claim is
        // granted.
        return lifecycleByID.values.first?.receipt
    }

    func state(
        for receipt: ProviderMutationReceipt
    ) -> ProviderIndeterminateMutationState {
        guard let lifecycle = lifecycleByID[receipt.id] else {
            return .unknownAfterRestart
        }
        switch lifecycle {
        case .started, .indeterminate:
            return .inFlight
        case let .quiescent(_, outcome):
            return .quiescent(outcome)
        case .pending:
            // A receipt is not exposed until work has started. Treat a
            // mismatched pending lookup conservatively as in flight.
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
            case .pending, .started:
                return nil
            }
        }.first
    }

    func finishRecovery(for receipt: ProviderMutationReceipt) {
        if case .quiescent = lifecycleByID[receipt.id] {
            lifecycleByID[receipt.id] = nil
            grantNextStartIfPossible()
        }
    }

    func retainedOperationCount() -> Int {
        operationTasks.count
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
            case .indeterminate, .quiescent:
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

        case .indeterminate, .quiescent:
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

        case .pending, .quiescent:
            break
        }
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
