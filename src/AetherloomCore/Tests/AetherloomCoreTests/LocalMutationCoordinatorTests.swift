import Foundation
import Testing
@testable import AetherloomCore

@Test func mutationCompletesBeforeDeadlineAndIsConfirmed() async {
    let coordinator = LocalMutationCoordinator()
    let clock = ManualMutationDeadlineClock()
    let receipt = mutationReceipt("000000000001", kind: .makeFolder)

    let result = await coordinator.perform(
        receipt: receipt,
        nanoseconds: 1,
        clock: clock,
        startedAt: { receipt.startedAt }
    ) { _ in
        .success(42)
    }

    guard case let .completed(.success(value)) = result else {
        Issue.record("Mutation did not return confirmed success.")
        return
    }
    #expect(value == 42)
    #expect(await coordinator.retainedOperationCount() == 0)
    #expect(await coordinator.barrierReceipt() == nil)
}

@Test func queuedMutationDeadlineExpiresBeforeStartWithoutSideEffect() async {
    let coordinator = LocalMutationCoordinator()
    let firstClock = ManualMutationDeadlineClock()
    let secondClock = ManualMutationDeadlineClock()
    let firstGate = ControlledMutationOperation<Int>()
    let secondCalls = MutationInvocationCounter()
    let firstReceipt = mutationReceipt("000000000002", kind: .store)
    let secondReceipt = mutationReceipt("000000000003", kind: .makeFolder)

    let first = Task {
        await coordinator.perform(
            receipt: firstReceipt,
            nanoseconds: 1,
            clock: firstClock,
            startedAt: { firstReceipt.startedAt }
        ) { _ in
            await firstGate.run(returning: .success(1))
        }
    }
    await firstGate.waitUntilStarted()

    let second = Task {
        await coordinator.perform(
            receipt: secondReceipt,
            nanoseconds: 1,
            clock: secondClock,
            startedAt: { secondReceipt.startedAt }
        ) { _ in
            await secondCalls.record()
            return .success(2)
        }
    }
    await secondClock.waitUntilSleeping()
    await secondClock.fireAll()

    guard case .deadlineExpiredBeforeStart = await second.value else {
        Issue.record("Queued mutation was not classified as pre-start expiry.")
        await firstGate.release()
        _ = await first.value
        return
    }
    #expect(await secondCalls.count() == 0)

    await firstGate.release()
    guard case .completed(.success(1)) = await first.value else {
        Issue.record("First mutation did not complete normally.")
        return
    }
}

@Test func startedMutationDeadlineRetainsLateSuccessUntilReconciliation() async {
    let coordinator = LocalMutationCoordinator()
    let clock = ManualMutationDeadlineClock()
    let gate = ControlledMutationOperation<Int>()
    let receipt = mutationReceipt("000000000004", kind: .store)

    let call = Task {
        await coordinator.perform(
            receipt: receipt,
            nanoseconds: 1,
            clock: clock,
            startedAt: { receipt.startedAt }
        ) { _ in
            await gate.run(returning: .success(7))
        }
    }
    await gate.waitUntilStarted()
    await clock.waitUntilSleeping()
    await clock.fireAll()

    guard case let .indeterminate(returnedReceipt) = await call.value else {
        Issue.record("Post-start deadline was not indeterminate.")
        await gate.release()
        return
    }
    #expect(returnedReceipt == receipt)
    #expect(await coordinator.retainedOperationCount() == 1)
    #expect(await coordinator.barrierReceipt() == receipt)

    await gate.release()
    await waitForQuiescence(coordinator, receipt: receipt)
    #expect(
        await coordinator.state(for: receipt)
            == .quiescent(.succeeded)
    )
    #expect(await coordinator.retainedOperationCount() == 0)
    #expect(await coordinator.barrierReceipt() == receipt)

    await coordinator.finishRecovery(for: receipt)
    #expect(await coordinator.barrierReceipt() == nil)
}

@Test func startedMutationDeadlineRetainsLateFailure() async {
    let coordinator = LocalMutationCoordinator()
    let clock = ManualMutationDeadlineClock()
    let gate = ControlledMutationOperation<Int>()
    let receipt = mutationReceipt("000000000005", kind: .trash)
    let expected = ProviderError.itemUnavailable(
        provider: receipt.provider,
        path: receipt.affectedPaths[0]
    )

    let call = Task {
        await coordinator.perform(
            receipt: receipt,
            nanoseconds: 1,
            clock: clock,
            startedAt: { receipt.startedAt }
        ) { _ in
            await gate.run(returning: .failure(expected))
        }
    }
    await gate.waitUntilStarted()
    await clock.waitUntilSleeping()
    await clock.fireAll()
    guard case .indeterminate = await call.value else {
        Issue.record("Post-start deadline was not indeterminate.")
        await gate.release()
        return
    }

    await gate.release()
    await waitForQuiescence(coordinator, receipt: receipt)
    guard case let .quiescent(.failed(detail)) = await coordinator.state(for: receipt) else {
        Issue.record("Late failure was not retained.")
        return
    }
    #expect(detail.contains("itemUnavailable"))
}

@Test func indeterminateMutationInvalidatesOldQueueAndRequiresFreshCall() async {
    let coordinator = LocalMutationCoordinator()
    let firstClock = ManualMutationDeadlineClock()
    let secondClock = ManualMutationDeadlineClock()
    let firstGate = ControlledMutationOperation<Int>()
    let secondCalls = MutationInvocationCounter()
    let firstReceipt = mutationReceipt("000000000006", kind: .relocate)
    let secondReceipt = mutationReceipt("000000000007", kind: .makeFolder)
    let freshReceipt = mutationReceipt("000000000008", kind: .makeFolder)

    let first = Task {
        await coordinator.perform(
            receipt: firstReceipt,
            nanoseconds: 1,
            clock: firstClock,
            startedAt: { firstReceipt.startedAt }
        ) { _ in
            await firstGate.run(returning: .success(1))
        }
    }
    await firstGate.waitUntilStarted()

    let second = Task {
        await coordinator.perform(
            receipt: secondReceipt,
            nanoseconds: 1,
            clock: secondClock,
            startedAt: { secondReceipt.startedAt }
        ) { _ in
            await secondCalls.record()
            return .success(2)
        }
    }
    await secondClock.waitUntilSleeping()
    await firstClock.waitUntilSleeping()
    await firstClock.fireAll()
    guard case .indeterminate = await first.value else {
        Issue.record("First mutation did not become indeterminate.")
        await firstGate.release()
        return
    }
    guard case .deadlineExpiredBeforeStart = await second.value else {
        Issue.record("Old queued work was not invalidated before it started.")
        await firstGate.release()
        return
    }
    #expect(await secondCalls.count() == 0)

    await firstGate.release()
    await waitForQuiescence(coordinator, receipt: firstReceipt)

    await coordinator.finishRecovery(for: firstReceipt)
    #expect(await secondCalls.count() == 0)

    let freshResult = await coordinator.perform(
        receipt: freshReceipt,
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock(),
        startedAt: { freshReceipt.startedAt }
    ) { _ in
        await secondCalls.record()
        return .success(3)
    }
    guard case .completed(.success(3)) = freshResult else {
        Issue.record("Fresh post-recovery work did not start.")
        return
    }
    #expect(await secondCalls.count() == 1)
}

private actor ManualMutationDeadlineClock: ProviderDeadlineClock {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds _: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                let observers = sleeperWaiters
                sleeperWaiters.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitUntilSleeping() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            sleeperWaiters.append(continuation)
        }
    }

    func fireAll() {
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor ControlledMutationOperation<Value: Sendable> {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        returning result: Result<Value, ProviderError>
    ) async -> Result<Value, ProviderError> {
        started = true
        let observers = startWaiters
        startWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return result
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor MutationInvocationCounter {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private func waitForQuiescence(
    _ coordinator: LocalMutationCoordinator,
    receipt: ProviderMutationReceipt
) async {
    while await coordinator.state(for: receipt) == .inFlight {
        await Task.yield()
    }
}

private func mutationReceipt(
    _ suffix: String,
    kind: ProviderMutationKind
) -> ProviderMutationReceipt {
    ProviderMutationReceipt(
        id: UUID(uuidString: "a1000000-0000-0000-0000-\(suffix)")!,
        provider: .localFolder,
        kind: kind,
        affectedPaths: ["/Owned.txt"],
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}
