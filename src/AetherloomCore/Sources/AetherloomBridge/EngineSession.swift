import AetherloomCore
import Foundation

public protocol EngineSession: Sendable {
    func bootstrap() async throws -> WorkspaceSnapshot
    var events: AsyncStream<EngineEvent> { get }

    func workspace() async -> WorkspaceSnapshot
    func syncSetStates() async -> [SyncSetState]
    func locationStates() async -> [LocationState]
    func openConflicts(in syncSetID: UUID?) async throws -> [ConflictDecision]
    func resolvedConflicts(in syncSetID: UUID?) async throws -> [ConflictResolutionRecord]
    func advice(for conflictIDs: [UUID]) async -> [ConflictAdvice]
    func suggestionsEnabled() async -> Bool
    func activity(matching query: ActivityQuery) async -> [ActivityEntry]
    func lastPreparation(for syncSetID: UUID) async -> SyncPreparation?

    func prepare(syncSetID: UUID) async throws -> SyncPreparation
    func execute(_ preparation: SyncPreparation, approval: PlanApproval?) async throws -> SyncRunSummary

    func createSyncSet(_ draft: SyncSetDraft) async throws -> SyncSetState
    func setSuggestionsEnabled(_ enabled: Bool) async throws
    func setPaused(_ paused: Bool, syncSetID: UUID) async
    func updateSyncSet(mode: SyncMode, settings: SyncSettings, syncSetID: UUID) async throws
    func deleteSyncSet(_ syncSetID: UUID) async throws
    func resolveConflict(id: UUID, as resolution: Resolution) async throws
}

public struct WorkspaceSnapshot: Sendable, Hashable {
    public var locations: [LocationState]
    public var syncSets: [SyncSetState]
    public var openConflictCount: Int
    public var status: WorkspaceStatus

    public init(
        locations: [LocationState],
        syncSets: [SyncSetState],
        openConflictCount: Int,
        status: WorkspaceStatus
    ) {
        self.locations = locations
        self.syncSets = syncSets
        self.openConflictCount = openConflictCount
        self.status = status
    }
}

public struct LocationState: Sendable, Hashable, Identifiable {
    public var location: SyncLocation
    public var availability: LocationAvailability
    public var lastCheckedAt: Date?
    public var accountLabel: String?

    public var id: LocationID { location.id }

    public init(
        location: SyncLocation,
        availability: LocationAvailability,
        lastCheckedAt: Date? = nil,
        accountLabel: String? = nil
    ) {
        self.location = location
        self.availability = availability
        self.lastCheckedAt = lastCheckedAt
        self.accountLabel = accountLabel
    }
}

public struct SyncSetState: Sendable, Hashable, Identifiable {
    public var syncSet: SyncSet
    public var isPaused: Bool
    public var lastRun: RunDigest?
    public var lastPreparation: PreparationDigest?
    public var trackedItemCount: Int
    public var openConflictCount: Int
    public var phase: SyncSetPhase

    public var id: UUID { syncSet.id }

    public init(
        syncSet: SyncSet,
        isPaused: Bool,
        lastRun: RunDigest? = nil,
        lastPreparation: PreparationDigest? = nil,
        trackedItemCount: Int = 0,
        openConflictCount: Int = 0,
        phase: SyncSetPhase = .idle
    ) {
        self.syncSet = syncSet
        self.isPaused = isPaused
        self.lastRun = lastRun
        self.lastPreparation = lastPreparation
        self.trackedItemCount = trackedItemCount
        self.openConflictCount = openConflictCount
        self.phase = phase
    }
}

public struct SyncSetDraft: Sendable, Hashable {
    public var name: String
    public var locationIDs: [LocationID]
    public var mode: SyncMode
    public var settings: SyncSettings

    public init(
        name: String,
        locationIDs: [LocationID],
        mode: SyncMode = .balancedMirror,
        settings: SyncSettings = SyncSettings()
    ) {
        self.name = name
        self.locationIDs = locationIDs
        self.mode = mode
        self.settings = settings
    }
}

public enum EngineEvent: Sendable, Hashable {
    case activityAppended(ActivityEntry)
    case syncSetChanged(UUID)
    case locationsChanged
    case conflictsChanged
    case runFinished(SyncRunSummary)
    case worldReset
}

public enum EngineSessionError: Error, Hashable, Sendable, LocalizedError {
    case syncSetPaused(UUID)
    case syncSetNotFound(UUID)
    case invalidSyncSetDraft(detail: String)
    case runAlreadyInProgress(UUID)
    case conflictNotFound(UUID)
    case cancelled
    case engineFailure(detail: String)

    public var errorDescription: String? {
        switch self {
        case .syncSetPaused:
            return "This sync set is paused. Resume it before preparing changes."
        case .syncSetNotFound:
            return "This sync set could not be found."
        case let .invalidSyncSetDraft(detail):
            return detail
        case .runAlreadyInProgress:
            return "A sync is already in progress for this sync set."
        case .conflictNotFound:
            return "This conflict is no longer open."
        case .cancelled:
            return "The operation was cancelled."
        case let .engineFailure(detail):
            return detail
        }
    }
}

public enum SyncSetPhase: Sendable, Hashable {
    case idle
    case preparing
    case executing
}

public struct RunDigest: Sendable, Hashable {
    public var runID: UUID
    public var finishedAt: Date
    public var outcome: SyncRunOutcome

    public init(runID: UUID, finishedAt: Date, outcome: SyncRunOutcome) {
        self.runID = runID
        self.finishedAt = finishedAt
        self.outcome = outcome
    }
}

public struct PreparationDigest: Sendable, Hashable {
    public var generatedAt: Date
    public var sectionCounts: [PreviewSectionKind: Int]
    public var holds: [HoldNotice]
    public var refusals: [RefusalNotice]

    public init(
        generatedAt: Date,
        sectionCounts: [PreviewSectionKind: Int],
        holds: [HoldNotice],
        refusals: [RefusalNotice]
    ) {
        self.generatedAt = generatedAt
        self.sectionCounts = sectionCounts
        self.holds = holds
        self.refusals = refusals
    }

    public init(preview: ChangePreview) {
        self.init(
            generatedAt: preview.generatedAt,
            sectionCounts: Dictionary(uniqueKeysWithValues: preview.sections.map { ($0.kind, $0.entries.count) }),
            holds: preview.holds,
            refusals: preview.refusals
        )
    }
}

public enum WorkspaceStatus: Sendable, Hashable {
    case busy(stage: String)
    case needsReview(count: Int)
    case pausedForSafety
    case allInSync
}
