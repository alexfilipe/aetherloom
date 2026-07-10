import AetherloomCore
@testable import AetherloomBridge
import Foundation
import Testing

@Suite("Overview display")
struct OverviewDisplayTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("standard demo overview is entirely engine-backed")
    func standardDemoOverview() async throws {
        let session = DemoEngineSession(
            environment: EngineEnvironment(now: { Self.now }, makeID: UUID.init),
            providerLatencyNanoseconds: 0
        )
        let workspace = try await session.bootstrap()
        var preparations: [UUID: SyncPreparation] = [:]
        for state in workspace.syncSets {
            preparations[state.id] = await session.lastPreparation(for: state.id)
        }
        let activity = await session.activity(matching: ActivityQuery(limit: 100))
        let display = overviewDisplay(
            workspace: workspace,
            preparations: preparations.compactMapValues { $0 },
            activity: activity,
            now: Self.now
        )

        #expect(display.metrics.map(\.label) == ["Tracked items", "Connected locations", "Pending changes", "Open conflicts"])
        #expect(display.metrics[0].value == String(workspace.syncSets.reduce(0) { $0 + $1.trackedItemCount }))
        #expect(display.metrics[1].value == String(workspace.locations.count))
        #expect(display.metrics[3].value == String(workspace.openConflictCount))
        #expect(display.holdBanners.count == preparations.values.flatMap(\.preview.holds).count)
        let projectMessage = preparations[DemoWorld.projectsID]?.preview.holds.first?.message
        #expect(display.holdBanners.contains { $0.syncSetID == DemoWorld.projectsID && $0.message == projectMessage })
        #expect(display.refusalBanners.count == 1)
        #expect(display.refusalBanners.first?.message == preparations[DemoWorld.photosArchiveID]?.preview.refusals.first?.message)
        #expect(display.pending?.syncSetID == DemoWorld.documentsID)
        #expect(display.recentActivity.count == 6)
        #expect(display.locations.first(where: { $0.provider.kind == .oneDrive })?.status.text == "Provider unavailable")
        #expect(display.locations.first(where: { $0.provider.kind == .nasFolder })?.action == .wakeAndMount)
    }

    @Test("workspace state decides hero presentation")
    func heroStates() {
        let location = LocationState(
            location: SyncLocation(id: .localFolder, kind: .localFolder),
            availability: .available,
            lastCheckedAt: Self.now
        )
        let empty = overviewDisplay(
            workspace: WorkspaceSnapshot(locations: [], syncSets: [], openConflictCount: 0, status: .allInSync),
            preparations: [:],
            activity: [],
            now: Self.now
        )
        let inSync = overviewDisplay(
            workspace: WorkspaceSnapshot(locations: [location], syncSets: [state()], openConflictCount: 0, status: .allInSync),
            preparations: [:],
            activity: [],
            now: Self.now
        )
        let busy = overviewDisplay(
            workspace: WorkspaceSnapshot(locations: [location], syncSets: [state(phase: .preparing)], openConflictCount: 0, status: .busy(stage: "Scan")),
            preparations: [:],
            activity: [],
            now: Self.now
        )

        #expect(empty.isEmpty)
        #expect(empty.headline == "Create your first sync set")
        #expect(inSync.statusTone == .healthy)
        #expect(inSync.headline == "Everything in sync")
        #expect(busy.isBusy)
        #expect(busy.statusText == "Scanning…")
        #expect(busy.locations.first?.isBusy == true)
    }

    @Test("cloud connection and NAS demo actions are explicit display values")
    func locationActions() {
        let cloud = LocationState(
            location: SyncLocation(id: .dropbox, kind: .dropbox),
            availability: .unavailable(.notAuthenticated(detail: "not connected"))
        )
        let nas = LocationState(
            location: SyncLocation(id: .nasFolder, kind: .nasFolder),
            availability: .available,
            accountLabel: "smb://nas.local"
        )
        let display = overviewDisplay(
            workspace: WorkspaceSnapshot(locations: [cloud, nas], syncSets: [], openConflictCount: 0, status: .allInSync),
            preparations: [:],
            activity: [],
            now: Self.now
        )

        #expect(display.locations.first(where: { $0.id == .dropbox })?.action == .connectProvider(.dropbox))
        #expect(display.locations.first(where: { $0.id == .nasFolder })?.action == OverviewLocationAction.none)
    }
}

private func state(phase: SyncSetPhase = .idle) -> SyncSetState {
    SyncSetState(
        syncSet: SyncSet(name: "Preview", locations: [.localFolder, .iCloudDrive]),
        isPaused: false,
        lastRun: RunDigest(runID: UUID(), finishedAt: OverviewDisplayTests.now, outcome: .completed),
        trackedItemCount: 4,
        phase: phase
    )
}
