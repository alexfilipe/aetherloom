import AetherloomCore
@testable import AetherloomBridge
import Foundation
import Testing

@Suite("Display status")
struct DisplayStatusTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("provider presentation is total", arguments: ProviderKind.allCases)
    func providerPresentation(kind: ProviderKind) {
        let presentation = kind.presentation
        #expect(presentation.kind == kind)
        #expect(presentation.displayName == kind.displayName)
        #expect(!presentation.symbolName.isEmpty)
    }

    @Test("availability tone matrix", arguments: availabilityToneCases)
    private func availabilityTone(testCase: AvailabilityToneCase) {
        #expect(tone(for: testCase.availability) == testCase.expected)
    }

    @Test("sync-set tone matrix", arguments: syncSetToneCases)
    private func syncSetTone(testCase: SyncSetToneCase) {
        #expect(tone(for: testCase.state) == testCase.expected)
    }

    @Test("sync-set status-line priority and verbatim notices", arguments: statusLineCases)
    private func syncSetStatusLine(testCase: StatusLineCase) {
        let result = statusLine(for: testCase.state, now: Self.now)
        #expect(result == testCase.expected)
    }

    @Test("location status lines", arguments: locationLineCases)
    private func locationStatusLine(testCase: LocationLineCase) {
        #expect(statusLine(for: testCase.state, now: Self.now) == testCase.expected)
    }

    @Test("workspace priority", arguments: workspaceCases)
    private func workspaceStatusPriority(testCase: WorkspaceCase) {
        #expect(
            workspaceStatus(
                for: testCase.states,
                openConflictCount: testCase.openConflicts,
                activityEntries: testCase.activity
            ) == testCase.expected
        )
    }
}

private struct AvailabilityToneCase: CustomTestStringConvertible, Sendable {
    var name: String
    var availability: LocationAvailability
    var expected: StatusTone
    var testDescription: String { name }
}

private let availabilityToneCases: [AvailabilityToneCase] = [
    .init(name: "available", availability: .available, expected: .healthy),
    .init(name: "not authenticated", availability: .unavailable(.notAuthenticated(detail: "auth")), expected: .paused),
    .init(name: "network unreachable", availability: .unavailable(.networkUnreachable(detail: "network")), expected: .paused),
    .init(name: "volume not mounted", availability: .unavailable(.volumeNotMounted(detail: "mount")), expected: .neutral),
    .init(name: "volume unreachable", availability: .unavailable(.volumeUnreachable(detail: "volume")), expected: .paused),
    .init(name: "scope missing", availability: .unavailable(.scopeMissing(detail: "scope")), expected: .paused),
    .init(name: "rate limited", availability: .unavailable(.rateLimited(retryAfter: nil)), expected: .paused),
    .init(name: "unknown", availability: .unavailable(.unknown(detail: "unknown")), expected: .paused),
]

private struct SyncSetToneCase: CustomTestStringConvertible, Sendable {
    var name: String
    var state: SyncSetState
    var expected: StatusTone
    var testDescription: String { name }
}

private let syncSetToneCases: [SyncSetToneCase] = [
    .init(name: "paused by user", state: makeState(paused: true, holds: [holdNotice], refusals: [refusalNotice], openConflicts: 1), expected: .paused),
    .init(name: "refusal", state: makeState(refusals: [refusalNotice]), expected: .paused),
    .init(name: "hold", state: makeState(holds: [holdNotice]), expected: .attention),
    .init(name: "open conflict", state: makeState(openConflicts: 1), expected: .attention),
    .init(name: "preparing", state: makeState(phase: .preparing), expected: .neutral),
    .init(name: "executing", state: makeState(phase: .executing), expected: .neutral),
    .init(name: "never run", state: makeState(), expected: .neutral),
    .init(name: "healthy", state: makeState(lastRun: completedRun), expected: .healthy),
]

private struct StatusLineCase: CustomTestStringConvertible, Sendable {
    var name: String
    var state: SyncSetState
    var expected: StatusLine
    var testDescription: String { name }
}

private let statusLineCases: [StatusLineCase] = [
    .init(name: "user pause wins", state: makeState(paused: true, holds: [holdNotice], refusals: [refusalNotice]), expected: StatusLine(text: "Paused by you", tone: .paused)),
    .init(name: "refusal wins over hold", state: makeState(holds: [holdNotice], refusals: [refusalNotice]), expected: StatusLine(text: "Paused for safety", tone: .paused, safetyNote: refusalNotice.message)),
    .init(name: "hold wins over phase", state: makeState(holds: [holdNotice], phase: .executing), expected: StatusLine(text: "Needs review", tone: .attention, safetyNote: holdNotice.message)),
    .init(name: "open conflict", state: makeState(openConflicts: 1), expected: StatusLine(text: "Needs review", tone: .attention, safetyNote: ActivityMessageCatalog.conflictPreserved)),
    .init(name: "preparing", state: makeState(phase: .preparing), expected: StatusLine(text: "Preparing", tone: .neutral)),
    .init(name: "executing", state: makeState(phase: .executing), expected: StatusLine(text: "Syncing", tone: .neutral)),
    .init(name: "never synced", state: makeState(), expected: StatusLine(text: "Never synced", tone: .neutral)),
    .init(name: "up to date", state: makeState(lastRun: completedRun), expected: StatusLine(text: "Up to date", tone: .healthy)),
]

private struct LocationLineCase: CustomTestStringConvertible, Sendable {
    var name: String
    var state: LocationState
    var expected: StatusLine
    var testDescription: String { name }
}

private let locationLineCases: [LocationLineCase] = [
    .init(name: "available", state: makeLocation(.available), expected: StatusLine(text: "Up to date", tone: .healthy)),
    .init(name: "waiting volume", state: makeLocation(.unavailable(.volumeNotMounted(detail: "sleeping"))), expected: StatusLine(text: "Waiting for volume", tone: .neutral, safetyNote: ActivityMessageCatalog.providerUnavailable)),
    .init(name: "provider unavailable", state: makeLocation(.unavailable(.scopeMissing(detail: "missing"))), expected: StatusLine(text: "Provider unavailable", tone: .paused, safetyNote: ActivityMessageCatalog.providerUnavailable)),
]

private struct WorkspaceCase: CustomTestStringConvertible, Sendable {
    var name: String
    var states: [SyncSetState]
    var openConflicts: Int
    var activity: [ActivityEntry]
    var expected: WorkspaceStatus
    var testDescription: String { name }
}

private let workspaceCases: [WorkspaceCase] = [
    .init(
        name: "busy wins and uses activity stage",
        states: [makeState(holds: [holdNotice], refusals: [refusalNotice], phase: .preparing)],
        openConflicts: 2,
        activity: [ActivityEntry(occurredAt: DisplayStatusTests.now, syncSetID: testSyncSet.id, category: .sync, message: "Scan started.")],
        expected: .busy(stage: "Scan")
    ),
    .init(name: "review wins over refusal", states: [makeState(holds: [holdNotice], refusals: [refusalNotice])], openConflicts: 2, activity: [], expected: .needsReview(count: 3)),
    .init(name: "refusal", states: [makeState(refusals: [refusalNotice])], openConflicts: 0, activity: [], expected: .pausedForSafety),
    .init(name: "in sync", states: [makeState(lastRun: completedRun)], openConflicts: 0, activity: [], expected: .allInSync),
]

private let testSyncSet = SyncSet(
    id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
    name: "Test",
    locations: [.iCloudDrive, .googleDrive]
)

private let completedRun = RunDigest(
    runID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
    finishedAt: DisplayStatusTests.now,
    outcome: .completed
)

private let refusalNotice = RefusalNotice(
    id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
    reason: .locationUnavailable(.oneDrive, .networkUnreachable(detail: "offline")),
    message: "verbatim refusal"
)

private let holdNotice = HoldNotice(
    id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
    reason: .conflicts(count: 1),
    message: "verbatim hold"
)

private func makeState(
    paused: Bool = false,
    holds: [HoldNotice] = [],
    refusals: [RefusalNotice] = [],
    openConflicts: Int = 0,
    phase: SyncSetPhase = .idle,
    lastRun: RunDigest? = nil
) -> SyncSetState {
    let preparation: PreparationDigest? = (holds.isEmpty && refusals.isEmpty) ? nil : PreparationDigest(
        generatedAt: DisplayStatusTests.now,
        sectionCounts: [:],
        holds: holds,
        refusals: refusals
    )
    return SyncSetState(
        syncSet: testSyncSet,
        isPaused: paused,
        lastRun: lastRun,
        lastPreparation: preparation,
        openConflictCount: openConflicts,
        phase: phase
    )
}

private func makeLocation(_ availability: LocationAvailability) -> LocationState {
    LocationState(location: SyncLocation(id: .nasFolder, kind: .nasFolder), availability: availability)
}
