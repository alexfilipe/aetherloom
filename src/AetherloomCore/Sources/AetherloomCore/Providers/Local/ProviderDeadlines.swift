import Foundation

public protocol ProviderDeadlineClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct SystemProviderDeadlineClock: ProviderDeadlineClock {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct ProviderDeadlines: Sendable {
    public var probeNanoseconds: UInt64
    public var scanNanoseconds: UInt64
    public var ioNanoseconds: UInt64
    let clock: any ProviderDeadlineClock
    let now: @Sendable () -> Date

    public init(
        probeNanoseconds: UInt64 = 2_000_000_000,
        scanNanoseconds: UInt64 = 60_000_000_000,
        ioNanoseconds: UInt64 = 60_000_000_000,
        clock: any ProviderDeadlineClock = SystemProviderDeadlineClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probeNanoseconds = probeNanoseconds
        self.scanNanoseconds = scanNanoseconds
        self.ioNanoseconds = ioNanoseconds
        self.clock = clock
        self.now = now
    }
}

enum ProviderDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private actor ProviderDeadlineGate<Value: Sendable> {
    private var result: ProviderDeadlineResult<Value>?
    private var continuation: CheckedContinuation<ProviderDeadlineResult<Value>, Never>?

    func resolve(_ result: ProviderDeadlineResult<Value>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func wait() async -> ProviderDeadlineResult<Value> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

func withProviderDeadline<Value: Sendable>(
    nanoseconds: UInt64,
    clock: any ProviderDeadlineClock,
    operation: @escaping @Sendable () async -> Value
) async -> ProviderDeadlineResult<Value> {
    guard nanoseconds > 0 else {
        return .timedOut
    }

    let gate = ProviderDeadlineGate<Value>()
    let operationTask = Task.detached {
        await gate.resolve(.value(await operation()))
    }
    let deadlineTask = Task.detached {
        do {
            try await clock.sleep(nanoseconds: nanoseconds)
            await gate.resolve(.timedOut)
        } catch {
            // A clock failure must fail closed. The task is cancelled only
            // after the operation has already won.
            if !Task.isCancelled {
                await gate.resolve(.timedOut)
            }
        }
    }

    let result = await gate.wait()
    operationTask.cancel()
    deadlineTask.cancel()
    return result
}
