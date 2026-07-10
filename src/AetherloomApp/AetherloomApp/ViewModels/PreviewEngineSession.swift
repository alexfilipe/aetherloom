import AetherloomBridge
import AetherloomCore
import Foundation

actor PreviewEngineSession: EngineSession {
    nonisolated var events: AsyncStream<EngineEvent> {
        AsyncStream { $0.finish() }
    }

    private var snapshot: WorkspaceSnapshot
    private var openConflictValues: [ConflictDecision]
    private var resolvedConflictValues: [ConflictResolutionRecord]
    private var adviceValues: [ConflictAdvice]
    private var suggestionsAreEnabled: Bool

    init(
        snapshot: WorkspaceSnapshot,
        openConflicts: [ConflictDecision] = [],
        resolvedConflicts: [ConflictResolutionRecord] = [],
        advice: [ConflictAdvice] = [],
        suggestionsEnabled: Bool = true
    ) {
        self.snapshot = snapshot
        self.openConflictValues = openConflicts
        self.resolvedConflictValues = resolvedConflicts
        self.adviceValues = advice
        self.suggestionsAreEnabled = suggestionsEnabled
    }

    func bootstrap() async throws -> WorkspaceSnapshot { snapshot }
    func workspace() async -> WorkspaceSnapshot { snapshot }
    func syncSetStates() async -> [SyncSetState] { snapshot.syncSets }
    func locationStates() async -> [LocationState] { snapshot.locations }
    func openConflicts(in syncSetID: UUID?) async throws -> [ConflictDecision] {
        openConflictValues.filter { syncSetID == nil || $0.syncSetID == nil || $0.syncSetID == syncSetID }
    }
    func resolvedConflicts(in syncSetID: UUID?) async throws -> [ConflictResolutionRecord] {
        resolvedConflictValues.filter {
            syncSetID == nil || $0.conflict.syncSetID == nil || $0.conflict.syncSetID == syncSetID
        }
    }
    func advice(for conflictIDs: [UUID]) async -> [ConflictAdvice] {
        let requested = Set(conflictIDs)
        return adviceValues.filter { requested.contains($0.conflictID) }
    }
    func suggestionsEnabled() async -> Bool { suggestionsAreEnabled }
    func activity(matching query: ActivityQuery) async -> [ActivityEntry] { [] }
    func lastPreparation(for syncSetID: UUID) async -> SyncPreparation? { nil }

    func prepare(syncSetID: UUID) async throws -> SyncPreparation {
        throw EngineSessionError.engineFailure(detail: "Preview fixtures do not prepare sync plans.")
    }

    func execute(_ preparation: SyncPreparation, approval: PlanApproval?) async throws -> SyncRunSummary {
        throw EngineSessionError.engineFailure(detail: "Preview fixtures do not execute sync plans.")
    }

    func createSyncSet(_ draft: SyncSetDraft) async throws -> SyncSetState {
        throw EngineSessionError.engineFailure(detail: "Preview fixtures do not create sync sets.")
    }

    func setSuggestionsEnabled(_ enabled: Bool) async throws {
        suggestionsAreEnabled = enabled
        if !enabled {
            adviceValues.removeAll()
        }
    }

    func setPaused(_ paused: Bool, syncSetID: UUID) async {}

    func updateSyncSet(mode: SyncMode, settings: SyncSettings, syncSetID: UUID) async throws {}

    func deleteSyncSet(_ syncSetID: UUID) async throws {}

    func resolveConflict(id: UUID, as resolution: ConflictDecision.Resolution) async throws {
        guard let index = openConflictValues.firstIndex(where: { $0.id == id }) else {
            throw EngineSessionError.conflictNotFound(id)
        }
        let conflict = openConflictValues.remove(at: index)
        resolvedConflictValues.append(
            ConflictResolutionRecord(
                id: id,
                conflict: conflict,
                resolution: resolution,
                resolvedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        adviceValues.removeAll { $0.conflictID == id }
    }
}

extension WorkspaceSnapshot {
    static let previewReady = WorkspaceSnapshot(
        locations: [],
        syncSets: [],
        openConflictCount: 0,
        status: .allInSync
    )
}

struct OverviewPreviewFixture {
    var workspace: WorkspaceSnapshot
    var preparations: [UUID: SyncPreparation] = [:]
    var activity: [ActivityEntry] = []
    var busySyncSets: Set<UUID> = []

    static let populated = makePopulated()
    static let allInSync = makeSimple(status: .allInSync)
    static let busy = makeSimple(status: .busy(stage: "Scan"), phase: .preparing)
    static let empty = OverviewPreviewFixture(workspace: .previewReady)

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makePopulated() -> OverviewPreviewFixture {
        let world = DemoWorld.standard
        let syncSets = Dictionary(uniqueKeysWithValues: world.syncSets.map { ($0.id, $0) })
        let documents = syncSets[DemoWorld.documentsID]!
        let projects = syncSets[DemoWorld.projectsID]!
        let photos = syncSets[DemoWorld.photosArchiveID]!
        let conflicts = HoldReason.conflicts(count: 1)
        let deletions = HoldReason.deletionsNeedReview(count: 1)
        let massDeletion = HoldReason.massDeletion(
            MassChangeEvidence(
                intentCount: 30,
                trackedCount: 60,
                groups: [ChangeGroup(ancestor: "/Projects/Archive", intentCount: 30)]
            )
        )
        let documentsPreview = ChangePreview(
            syncSetID: documents.id,
            planFingerprint: PlanFingerprint(rawValue: "overview-documents-preview"),
            headline: "Changes need review",
            holds: [
                HoldNotice(id: id(1), reason: conflicts, message: conflicts.message),
                HoldNotice(id: id(2), reason: deletions, message: deletions.message),
            ],
            sections: [
                PreviewSection(kind: .additions, entries: [
                    PreviewEntry(
                        decisionID: id(11),
                        path: "/Documents/Notes/From iPhone.txt",
                        summary: "Create this file in the other locations.",
                        destinations: [.googleDrive, .localFolder],
                        byteSize: 1_024
                    ),
                ]),
                PreviewSection(kind: .updates, entries: [
                    PreviewEntry(
                        decisionID: id(12),
                        path: "/Documents/Plans/Roadmap.md",
                        summary: "Update the unchanged copies from iCloud Drive.",
                        destinations: [.googleDrive, .localFolder],
                        byteSize: 2_048
                    ),
                ]),
                PreviewSection(kind: .movesToTrash, entries: [
                    PreviewEntry(
                        decisionID: id(13),
                        path: "/Documents/Archive/Obsolete.txt",
                        summary: "Move matching copies to provider trash.",
                        destinations: [.googleDrive, .localFolder],
                        isTrash: true
                    ),
                ]),
                PreviewSection(kind: .bothVersionsPreserved, entries: [
                    PreviewEntry(
                        decisionID: id(14),
                        path: "/Documents/Budget.xlsx",
                        summary: ActivityMessageCatalog.conflictPreserved,
                        destinations: [.iCloudDrive, .googleDrive]
                    ),
                ]),
            ],
            generatedAt: now
        )
        let projectPreview = ChangePreview(
            syncSetID: projects.id,
            planFingerprint: PlanFingerprint(rawValue: "overview-projects-preview"),
            headline: "Needs review",
            holds: [HoldNotice(id: id(3), reason: massDeletion, message: massDeletion.message)],
            sections: [
                PreviewSection(kind: .movesToTrash, entries: [
                    PreviewEntry(
                        decisionID: id(15),
                        path: "/Projects/Archive",
                        summary: "Move matching copies to provider trash.",
                        destinations: [.iCloudDrive],
                        isTrash: true
                    ),
                ]),
            ],
            generatedAt: now
        )
        let nasReason = LocationUnavailabilityReason.volumeNotMounted(detail: "NAS \"Tank\" is not mounted.")
        let refusalReason = RefusalReason.locationUnavailable(.nasFolder, nasReason)
        let photoPreview = ChangePreview(
            syncSetID: photos.id,
            planFingerprint: nil,
            headline: "Paused for safety",
            refusals: [
                RefusalNotice(
                    id: id(4),
                    reason: refusalReason,
                    locationID: .nasFolder,
                    message: refusalReason.message,
                    detail: "NAS \"Tank\" is not mounted."
                ),
            ],
            generatedAt: now
        )
        let preparations = [
            documents.id: planPreparation(
                syncSet: documents,
                preview: documentsPreview,
                gate: .hold([conflicts, deletions]),
                runID: id(21)
            ),
            projects.id: planPreparation(
                syncSet: projects,
                preview: projectPreview,
                gate: .hold([massDeletion]),
                runID: id(22)
            ),
            photos.id: SyncPreparation(
                outcome: .refusal(SyncRefusal(syncSetID: photos.id, reasons: [refusalReason], occurredAt: now)),
                preview: photoPreview,
                runID: id(23),
                syncSetName: photos.name
            ),
        ]
        let locations = world.locations.map { location in
            let availability: LocationAvailability = switch location.kind {
            case .oneDrive:
                .unavailable(.networkUnreachable(detail: "OneDrive cannot be reached."))
            case .nasFolder:
                .unavailable(nasReason)
            default:
                .available
            }
            return LocationState(
                location: location,
                availability: availability,
                lastCheckedAt: now,
                accountLabel: world.accountLabels[location.id]
            )
        }
        let states = world.syncSets.map { syncSet in
            let tracked = world.seedGroups.first(where: { $0.syncSetID == syncSet.id })?.items.count ?? 0
            return SyncSetState(
                syncSet: syncSet,
                isPaused: world.pausedSyncSetIDs.contains(syncSet.id),
                lastPreparation: preparations[syncSet.id].map { PreparationDigest(preview: $0.preview) },
                trackedItemCount: tracked,
                openConflictCount: syncSet.id == documents.id ? 1 : 0
            )
        }
        let activity = (0 ..< 6).map { offset in
            ActivityEntry(
                id: id(30 + offset),
                occurredAt: now.addingTimeInterval(TimeInterval(-offset * 60)),
                syncSetID: documents.id,
                runID: id(40),
                category: offset == 0 ? .safety : .sync,
                locationID: offset == 0 ? .nasFolder : .iCloudDrive,
                message: offset == 0 ? ActivityMessageCatalog.providerUnavailable : ActivityMessageCatalog.runFinished
            )
        }
        return OverviewPreviewFixture(
            workspace: WorkspaceSnapshot(
                locations: locations,
                syncSets: states,
                openConflictCount: 1,
                status: .needsReview(count: 4)
            ),
            preparations: preparations,
            activity: activity
        )
    }

    private static func makeSimple(
        status: WorkspaceStatus,
        phase: SyncSetPhase = .idle
    ) -> OverviewPreviewFixture {
        let world = DemoWorld.standard
        let syncSet = world.syncSets[0]
        let locations = world.locations.map {
            LocationState(
                location: $0,
                availability: .available,
                lastCheckedAt: now,
                accountLabel: world.accountLabels[$0.id]
            )
        }
        let state = SyncSetState(
            syncSet: syncSet,
            isPaused: false,
            lastRun: RunDigest(runID: id(50), finishedAt: now, outcome: .completed),
            trackedItemCount: world.seedGroups.first(where: { $0.syncSetID == syncSet.id })?.items.count ?? 0,
            phase: phase
        )
        return OverviewPreviewFixture(
            workspace: WorkspaceSnapshot(
                locations: locations,
                syncSets: [state],
                openConflictCount: 0,
                status: status
            ),
            busySyncSets: phase == .idle ? [] : [syncSet.id]
        )
    }

    private static func planPreparation(
        syncSet: AetherloomCore.SyncSet,
        preview: ChangePreview,
        gate: ExecutionGate,
        runID: UUID
    ) -> SyncPreparation {
        let fingerprint = preview.planFingerprint ?? PlanFingerprint(rawValue: "overview-preview")
        let plan = SyncPlan(
            syncSetID: syncSet.id,
            generatedAt: now,
            decisions: [],
            schedule: OperationSchedule(),
            gate: gate,
            fingerprint: fingerprint
        )
        return SyncPreparation(
            outcome: .plan(plan),
            preview: preview,
            runID: runID,
            syncSetName: syncSet.name
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", suffix))!
    }
}
