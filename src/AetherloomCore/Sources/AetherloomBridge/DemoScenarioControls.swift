import Foundation

public struct DemoScenarioControls: Sendable {
    private let session: DemoEngineSession

    init(session: DemoEngineSession) {
        self.session = session
    }

    public func setOneDriveReachable(_ reachable: Bool) async {
        await session.setOneDriveReachable(reachable)
    }

    public func setNASMounted(_ mounted: Bool) async {
        await session.setNASMounted(mounted)
    }

    public func makeConflict() async {
        await session.makeConflict()
    }

    public func makeMassDeletion() async {
        await session.makeMassDeletion()
    }

    public func simulateInterruptedRun() async throws {
        try await session.simulateInterruptedRun()
    }

    public func reset() async throws {
        try await session.reset()
    }
}
