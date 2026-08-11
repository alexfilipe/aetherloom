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

    var misboundReceipt = receipt
    misboundReceipt.correlation = ProviderMutationCorrelation(
        runID: receipt.correlation!.runID,
        operationID: OperationID(
            UUID(uuidString: "a1000000-0000-0000-0000-000000000102")!
        )
    )
    #expect(
        await coordinator.beginRecovery(for: misboundReceipt) == .inFlight
    )
    #expect(await coordinator.barrierReceipt() == receipt)

    guard case let .claimed(claim) = await coordinator.beginRecovery(
        for: receipt
    ) else {
        Issue.record("Quiescent mutation could not be claimed for recovery.")
        return
    }
    await coordinator.finishRecovery(claim)
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

    guard case let .claimed(claim) = await coordinator.beginRecovery(
        for: firstReceipt
    ) else {
        Issue.record("Quiescent mutation could not be claimed for recovery.")
        return
    }
    await coordinator.finishRecovery(claim)
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

@Test func admittedReadLeasePreventsMutationInterleavingUntilPhysicalCompletion() async {
    let coordinator = LocalMutationCoordinator()
    let readClock = ManualMutationDeadlineClock()
    let mutationClock = ManualMutationDeadlineClock()
    let readGate = ControlledReadOperation(value: 41)
    let mutationCalls = MutationInvocationCounter()
    let receipt = mutationReceipt("000000000009", kind: .store)

    let read = Task {
        await coordinator.performRead(
            nanoseconds: 1,
            clock: readClock
        ) {
            await readGate.run()
        }
    }
    await readGate.waitUntilStarted()

    let mutation = Task {
        await coordinator.perform(
            receipt: receipt,
            nanoseconds: 1,
            clock: mutationClock,
            startedAt: { receipt.startedAt }
        ) { _ in
            await mutationCalls.record()
            return .success(42)
        }
    }
    await mutationClock.waitUntilSleeping()
    #expect(await mutationCalls.count() == 0)
    #expect(await coordinator.barrierReceipt() == receipt)

    await readGate.release()
    guard case .completed(41) = await read.value else {
        Issue.record("Read did not complete through its owned lease.")
        return
    }
    guard case .completed(.success(42)) = await mutation.value else {
        Issue.record("Mutation did not start after the read lease drained.")
        return
    }
    #expect(await mutationCalls.count() == 1)
}

@Test func readTimeoutRetainsLeaseAndQueuedWriterBlocksLaterReads() async {
    let coordinator = LocalMutationCoordinator()
    let readClock = ManualMutationDeadlineClock()
    let mutationClock = ManualMutationDeadlineClock()
    let readGate = ControlledReadOperation(value: 7)
    let laterReadCalls = MutationInvocationCounter()
    let mutationCalls = MutationInvocationCounter()
    let receipt = mutationReceipt("000000000010", kind: .makeFolder)

    let read = Task {
        await coordinator.performRead(
            nanoseconds: 1,
            clock: readClock
        ) {
            await readGate.run()
        }
    }
    await readGate.waitUntilStarted()
    await readClock.waitUntilSleeping()
    await readClock.fireAll()
    guard case .timedOut = await read.value else {
        Issue.record("Read deadline did not return to its caller.")
        return
    }
    #expect(await coordinator.retainedReadCount() == 1)

    let mutation = Task {
        await coordinator.perform(
            receipt: receipt,
            nanoseconds: 1,
            clock: mutationClock,
            startedAt: { receipt.startedAt }
        ) { _ in
            await mutationCalls.record()
            return .success(8)
        }
    }
    await mutationClock.waitUntilSleeping()
    let laterRead = await coordinator.performRead(
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock()
    ) {
        await laterReadCalls.record()
        return 9
    }
    guard case let .blocked(blockingReceipt) = laterRead else {
        Issue.record("Writer-preferred admission allowed a later read.")
        await readGate.release()
        _ = await mutation.value
        return
    }
    #expect(blockingReceipt == receipt)
    #expect(await laterReadCalls.count() == 0)
    #expect(await mutationCalls.count() == 0)

    await readGate.release()
    guard case .completed(.success(8)) = await mutation.value else {
        Issue.record("Writer did not resume after the late read completed.")
        return
    }
    #expect(await coordinator.retainedReadCount() == 0)
}

@Test func cancelledReadRetainsLeaseUntilPhysicalCompletion() async {
    let coordinator = LocalMutationCoordinator()
    let clock = ManualMutationDeadlineClock()
    let gate = ControlledReadOperation(value: 11)

    let read = Task {
        await coordinator.performRead(
            nanoseconds: 1,
            clock: clock
        ) {
            await gate.run()
        }
    }
    await gate.waitUntilStarted()
    read.cancel()
    guard case .cancelled = await read.value else {
        Issue.record("Read cancellation was not caller-visible.")
        return
    }
    #expect(await coordinator.retainedReadCount() == 1)
    await gate.release()
    while await coordinator.retainedReadCount() != 0 {
        await Task.yield()
    }
}

@Test func recoveryClaimIsReceiptMatchedAndExclusive() async {
    let coordinator = LocalMutationCoordinator()
    let receipt = mutationReceipt("000000000011", kind: .relocate)
    let wrongReceipt = mutationReceipt("000000000012", kind: .relocate)
    let recoveryCalls = MutationInvocationCounter()

    guard case let .claimed(claim) = await coordinator.beginRecovery(
        for: receipt
    ) else {
        Issue.record("Restart receipt was not claimed.")
        return
    }
    #expect(await coordinator.beginRecovery(for: receipt) == .inFlight)
    #expect(await coordinator.beginRecovery(for: wrongReceipt) == .inFlight)

    let wrongRead = await coordinator.performRecoveryRead(
        claim: ProviderMutationRecoveryClaim(receipt: wrongReceipt),
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock()
    ) {
        await recoveryCalls.record()
        return 1
    }
    guard case let .blocked(blockingReceipt) = wrongRead else {
        Issue.record("A wrong receipt entered the recovery read bypass.")
        return
    }
    #expect(blockingReceipt == receipt)
    #expect(await recoveryCalls.count() == 0)

    let rightRead = await coordinator.performRecoveryRead(
        claim: claim,
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock()
    ) {
        await recoveryCalls.record()
        return 2
    }
    guard case .completed(2) = rightRead else {
        Issue.record("The matching recovery receipt was not admitted.")
        return
    }
    #expect(await recoveryCalls.count() == 1)
    await coordinator.abandonRecovery(claim)
    #expect(await coordinator.barrierReceipt() == receipt)
    guard case let .claimed(retryClaim) = await coordinator.beginRecovery(
        for: receipt
    ) else {
        Issue.record("Abandoned recovery could not be reclaimed safely.")
        return
    }
    await coordinator.finishRecovery(retryClaim)
    #expect(await coordinator.barrierReceipt() == nil)
}

@Test func recoveryClaimRejectsReceiptWithoutCorrelation() async {
    let coordinator = LocalMutationCoordinator()
    var receipt = mutationReceipt("000000000016", kind: .store)
    receipt.correlation = nil

    #expect(await coordinator.beginRecovery(for: receipt) == .inFlight)
    #expect(await coordinator.barrierReceipt() == nil)
}

@Test func recoveryCannotBypassUnrelatedReadOrMutationOwner() async {
    let coordinator = LocalMutationCoordinator()
    let recoveryReceipt = mutationReceipt("000000000013", kind: .relocate)
    let recoveryCalls = MutationInvocationCounter()
    let readGate = ControlledReadOperation(value: 1)

    let read = Task {
        await coordinator.performRead(
            nanoseconds: 1,
            clock: ManualMutationDeadlineClock()
        ) {
            await readGate.run()
        }
    }
    await readGate.waitUntilStarted()
    #expect(await coordinator.beginRecovery(for: recoveryReceipt) == .inFlight)
    let readBlocked = await coordinator.performRecoveryRead(
        claim: ProviderMutationRecoveryClaim(receipt: recoveryReceipt),
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock()
    ) {
        await recoveryCalls.record()
        return 2
    }
    guard case .blocked = readBlocked else {
        Issue.record("Recovery bypassed an unrelated ordinary read.")
        await readGate.release()
        return
    }
    #expect(await recoveryCalls.count() == 0)
    await readGate.release()
    _ = await read.value

    let mutationReceipt = mutationReceipt("000000000014", kind: .store)
    let mutationGate = ControlledMutationOperation<Int>()
    let mutation = Task {
        await coordinator.perform(
            receipt: mutationReceipt,
            nanoseconds: 1,
            clock: ManualMutationDeadlineClock(),
            startedAt: { mutationReceipt.startedAt }
        ) { _ in
            await mutationGate.run(returning: .success(3))
        }
    }
    await mutationGate.waitUntilStarted()
    #expect(await coordinator.beginRecovery(for: recoveryReceipt) == .inFlight)
    let mutationBlocked = await coordinator.performRecoveryRead(
        claim: ProviderMutationRecoveryClaim(receipt: recoveryReceipt),
        nanoseconds: 1,
        clock: ManualMutationDeadlineClock()
    ) {
        await recoveryCalls.record()
        return 4
    }
    guard case .blocked = mutationBlocked else {
        Issue.record("Recovery bypassed an unrelated live mutation.")
        await mutationGate.release()
        _ = await mutation.value
        return
    }
    #expect(await recoveryCalls.count() == 0)
    await mutationGate.release()
    _ = await mutation.value

    guard case let .claimed(claim) = await coordinator.beginRecovery(
        for: recoveryReceipt
    ) else {
        Issue.record("Recovery did not become claimable after owners drained.")
        return
    }
    await coordinator.finishRecovery(claim)
}

@Test func recoveryTimeoutRetainsClaimUntilPhysicalReadReturns() async {
    let coordinator = LocalMutationCoordinator()
    let receipt = mutationReceipt("000000000015", kind: .relocate)
    let clock = ManualMutationDeadlineClock()
    let readGate = ControlledReadOperation(value: 1)
    guard case let .claimed(claim) = await coordinator.beginRecovery(
        for: receipt
    ) else {
        Issue.record("Restart receipt was not claimed.")
        return
    }

    let read = Task {
        await coordinator.performRecoveryRead(
            claim: claim,
            nanoseconds: 1,
            clock: clock
        ) {
            await readGate.run()
        }
    }
    await readGate.waitUntilStarted()
    await clock.waitUntilSleeping()
    await clock.fireAll()
    guard case .timedOut = await read.value else {
        Issue.record("Recovery read did not return its caller deadline.")
        await readGate.release()
        return
    }

    await coordinator.abandonRecovery(claim)
    #expect(await coordinator.beginRecovery(for: receipt) == .inFlight)
    #expect(await coordinator.retainedReadCount() == 1)

    await readGate.release()
    while await coordinator.retainedReadCount() != 0 {
        await Task.yield()
    }
    #expect(await coordinator.barrierReceipt() == receipt)
    guard case let .claimed(retryClaim) = await coordinator.beginRecovery(
        for: receipt
    ) else {
        Issue.record("Completed late recovery read did not restore retry ownership.")
        return
    }
    await coordinator.finishRecovery(retryClaim)
    #expect(await coordinator.barrierReceipt() == nil)
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

private actor ControlledReadOperation<Value: Sendable> {
    private let value: Value
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(value: Value) {
        self.value = value
    }

    func run() async -> Value {
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
        return value
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
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        correlation: ProviderMutationCorrelation(
            runID: UUID(
                uuidString: "a1000000-0000-0000-0000-000000000100"
            )!,
            operationID: OperationID(
                UUID(
                    uuidString: "a1000000-0000-0000-0000-000000000101"
                )!
            )
        )
    )
}
