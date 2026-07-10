import AetherloomCore
@testable import AetherloomBridge
import Foundation
import Testing

@Suite("Display models")
struct DisplayModelTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("preview display uses a real demo preparation and preserves engine text")
    func previewDisplayFromDemoPreparation() async throws {
        let session = makeDisplaySession()
        let snapshot = try await session.bootstrap()
        let preparation = try #require(await session.lastPreparation(for: DemoWorld.documentsID))
        let display = previewDisplay(for: preparation, locations: snapshot.locations)

        #expect(display.headline == preparation.preview.headline)
        #expect(display.sections.map(\.kind) == PreviewSectionKind.allCases)
        #expect(display.sections.allSatisfy { !$0.entries.isEmpty })
        #expect(display.totals.changeCount == preparation.preview.sections.flatMap(\.entries).count)
        #expect(display.totals.byteTotal == preparation.preview.sections.flatMap(\.entries).compactMap(\.byteSize).reduce(0, +))
        #expect(display.sections.flatMap(\.entries).map(\.summary) == preparation.preview.sections.flatMap(\.entries).map(\.summary))
        #expect(display.sections.flatMap(\.entries).map(\.causality) == preparation.preview.sections.flatMap(\.entries).map(\.causality))
        #expect(display.holds.map(\.message) == preparation.preview.holds.map(\.message))

        let requirement = try #require(display.approvalRequirement)
        let plan = try #require(preparation.outcome.planValue)
        #expect(requirement.fingerprint == plan.fingerprint)
        #expect(requirement.trashCount == plan.approvalTrashCount)
        #expect(requirement.conflictCount == plan.approvalConflictCount)

        let approval = makeApproval(requirement, at: Self.now)
        #expect(approval.planFingerprint == requirement.fingerprint)
        #expect(approval.approvedAt == Self.now)
        #expect(approval.expiresAt == Self.now.addingTimeInterval(15 * 60))
        #expect(approval.acknowledgedTrashCount == requirement.trashCount)
        #expect(approval.acknowledgedConflictCount == requirement.conflictCount)
    }

    @Test("refusal display preserves notice detail and location")
    func refusalDisplay() async throws {
        let session = makeDisplaySession()
        let snapshot = try await session.bootstrap()
        let preparation = try #require(await session.lastPreparation(for: DemoWorld.photosArchiveID))
        let display = previewDisplay(for: preparation, locations: snapshot.locations)
        let raw = try #require(preparation.preview.refusals.first)
        let refusal = try #require(display.refusals.first)

        #expect(refusal.message == raw.message)
        #expect(refusal.detail == raw.detail)
        #expect(refusal.location?.id == raw.locationID)
        #expect(display.approvalRequirement == nil)
    }

    @Test("hold triage display preserves advisor attribution")
    func holdTriageAttribution() async throws {
        let session = makeDisplaySession()
        let snapshot = try await session.bootstrap()
        let preparation = try #require(await session.lastPreparation(for: DemoWorld.projectsID))
        let raw = try #require(preparation.preview.holds.first { $0.advisoryNote != nil })
        let hold = try #require(previewDisplay(for: preparation, locations: snapshot.locations).holds.first {
            $0.id == raw.id
        })
        let note = try #require(raw.advisoryNote)

        #expect(hold.advisoryNote == note.summary)
        #expect(hold.advisoryAttribution == "Suggested on-device by \(note.generatedBy.name)")
    }

    @Test("conflict display maps every conflict and plan-derived preserved name")
    func conflictDisplayFromDemoPlan() async throws {
        let session = makeDisplaySession()
        let snapshot = try await session.bootstrap()
        let preparation = try #require(await session.lastPreparation(for: DemoWorld.documentsID))
        let conflict = try #require(preparation.preview.conflicts.first)
        let advice = preparation.advice.first { $0.conflictID == conflict.id }
        let display = conflictDisplay(
            for: conflict,
            advice: advice,
            locations: snapshot.locations,
            plan: preparation.outcome.planValue
        )

        #expect(display.id == conflict.id)
        #expect(display.path == conflict.path)
        #expect(display.message == conflict.message)
        #expect(display.versions.count == conflict.versions.count)
        #expect(display.preservedCopyName != nil)
        #expect(display.options.count == conflict.versions.count + 1)
        #expect(display.options.first?.resolution == .preserveAll)
        if let advice {
            #expect(display.advice?.rationale == advice.rationale)
            #expect(display.advice?.generatedByName == advice.generatedBy.name)
            #expect(display.advice?.generatedByBackend == advice.generatedBy.backend)
            #expect(display.advice?.attribution == "Suggested on-device by \(advice.generatedBy.name)")
        }

        let unstable = ConflictDecision(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            path: "/Unstable.txt",
            versions: [],
            message: "engine-authored unstable conflict"
        )
        let unstableDisplay = conflictDisplay(for: unstable, advice: nil, locations: snapshot.locations)
        #expect(unstableDisplay.message == unstable.message)
        #expect(unstableDisplay.versions.isEmpty)
        #expect(unstableDisplay.options.map(\.resolution) == [.preserveAll])
    }

    @Test("activity category presentation is total", arguments: ActivityCategory.allCases)
    func activityCategoryPresentation(category: ActivityCategory) {
        let expected: (String, StatusTone) = switch category {
        case .sync: ("arrow.triangle.2.circlepath", .neutral)
        case .safety: ("shield.lefthalf.filled", .paused)
        case .conflict: ("doc.on.doc", .attention)
        case .advisory: ("sparkles", .neutral)
        case .provider: ("externaldrive", .neutral)
        case .error: ("exclamationmark.triangle", .attention)
        }
        #expect(category.presentation.symbolName == expected.0)
        #expect(category.presentation.tone == expected.1)
    }

    @Test("activity rows preserve engine values and group runs newest first")
    func activityRowsAndGroups() {
        let oldRun = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let newRun = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let entries = [
            activityEntry(id: "30000000-0000-0000-0000-000000000011", offset: -180, runID: oldRun, message: "old start"),
            activityEntry(id: "30000000-0000-0000-0000-000000000012", offset: -120, runID: oldRun, message: "old finish"),
            activityEntry(id: "30000000-0000-0000-0000-000000000013", offset: -60, runID: nil, message: "standalone"),
            activityEntry(id: "30000000-0000-0000-0000-000000000014", offset: -30, runID: newRun, message: "new run"),
        ]
        let locations = [LocationState(location: SyncLocation(id: .iCloudDrive, kind: .iCloudDrive), availability: .available)]
        let rows = activityRows(entries, locations: locations, now: Self.now)

        #expect(rows.map(\.message) == ["new run", "standalone", "old finish", "old start"])
        #expect(rows.first?.detail == entries.last?.detail)
        #expect(rows.first?.path == entries.last?.path)
        #expect(rows.first?.location?.id == .iCloudDrive)
        #expect(rows.first?.relatedConflictID == entries.last?.relatedConflictID)
        let groups = runGroups(rows)
        #expect(groups.map(\.runID) == [newRun, nil, oldRun])
        #expect(groups.last?.rows.map(\.message) == ["old finish", "old start"])
    }

    @Test("en-US formatting is pinned", arguments: formattingCases)
    private func formatting(testCase: FormattingCase) {
        #expect(testCase.actual() == testCase.expected)
    }
}

private struct FormattingCase: CustomTestStringConvertible, Sendable {
    var name: String
    var expected: String
    var actual: @Sendable () -> String
    var testDescription: String { name }
}

private let formattingCases: [FormattingCase] = [
    .init(name: "relative past", expected: "2 minutes ago", actual: { DisplayFormatting.relativeDate(DisplayModelTests.now.addingTimeInterval(-120), now: DisplayModelTests.now) }),
    .init(name: "relative future", expected: "in 2 hours", actual: { DisplayFormatting.relativeDate(DisplayModelTests.now.addingTimeInterval(7_200), now: DisplayModelTests.now) }),
    .init(name: "absolute", expected: "Jan 15, 2027 at 8:00 AM", actual: {
        DisplayFormatting.absoluteDate(DisplayModelTests.now, timeZone: TimeZone(secondsFromGMT: 0)!)
    }),
    .init(name: "bytes", expected: "1 kB", actual: { DisplayFormatting.byteCount(1_000) }),
    .init(name: "one file", expected: "1 file", actual: { DisplayFormatting.fileCount(1) }),
    .init(name: "many files", expected: "3 files", actual: { DisplayFormatting.fileCount(3) }),
    .init(name: "one change", expected: "1 change", actual: { DisplayFormatting.itemCount(1) }),
    .init(name: "many changes", expected: "3 changes", actual: { DisplayFormatting.itemCount(3) }),
    .init(name: "preparation summary", expected: "3 updates, 1 addition, 2 items waiting", actual: {
        DisplayFormatting.preparationSummary(
            PreparationDigest(
                generatedAt: DisplayModelTests.now,
                sectionCounts: [.updates: 3, .additions: 1, .waiting: 2],
                holds: [],
                refusals: []
            )
        )
    }),
    .init(name: "path", expected: "/Docu…e.txt", actual: { DisplayFormatting.middleTruncatedPath("/Documents/Archive.txt", maxLength: 11) }),
]

private func makeDisplaySession() -> DemoEngineSession {
    DemoEngineSession(
        environment: EngineEnvironment(now: { DisplayModelTests.now }, makeID: UUID.init),
        providerLatencyNanoseconds: 0
    )
}

private func activityEntry(id: String, offset: TimeInterval, runID: UUID?, message: String) -> ActivityEntry {
    ActivityEntry(
        id: UUID(uuidString: id)!,
        occurredAt: DisplayModelTests.now.addingTimeInterval(offset),
        syncSetID: DemoWorld.documentsID,
        runID: runID,
        category: .conflict,
        locationID: .iCloudDrive,
        path: "/Documents/Budget.xlsx",
        message: message,
        detail: "verbatim detail",
        relatedConflictID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!
    )
}
