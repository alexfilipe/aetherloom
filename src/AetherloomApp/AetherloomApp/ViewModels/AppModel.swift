import AetherloomBridge
import AetherloomCore
import Foundation
import Observation
import SwiftUI

enum BootstrapPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case syncSets
    case activity
    case conflicts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .syncSets: "Sync Sets"
        case .activity: "Activity"
        case .conflicts: "Conflicts"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "circle.hexagongrid.fill"
        case .syncSets: "folder.badge.gearshape"
        case .activity: "clock.arrow.circlepath"
        case .conflicts: "doc.on.doc"
        case .settings: "gearshape"
        }
    }
}

enum AppSheet: Identifiable, Hashable {
    case previewChanges(SyncPreparation)
    case newSyncSet
    case syncSetDetail(UUID)
    case connectProvider(ProviderKind)

    var id: String {
        switch self {
        case let .previewChanges(preparation):
            "preview-\(preparation.runID.uuidString)"
        case .newSyncSet:
            "new-sync-set"
        case let .syncSetDetail(id):
            "sync-set-\(id.uuidString)"
        case let .connectProvider(kind):
            "connect-\(kind.rawValue)"
        }
    }
}

enum DemoAction {
    case toggleOneDrive
    case toggleNAS
    case makeConflict
    case makeMassDeletion
    case simulateInterruptedRun
    case reset
}

@MainActor
@Observable
final class AppModel {
    static let suggestionsPreferenceKey = "aetherloom.suggestions.enabled"

    var selectedDestination: SidebarDestination = .overview
    var activeSheet: AppSheet?
    var pendingToast: RunResultToast.Model?
    var presentedError: String?
    var bootstrapPhase: BootstrapPhase
    var activityFilterRunID: UUID?
    var syncSetsLocationFilter: LocationID?
    private(set) var focusedConflictID: UUID?

    private(set) var workspace: WorkspaceSnapshot?
    private(set) var recentActivity: [ActivityEntry]
    private(set) var activityEntries: [ActivityEntry]
    private(set) var activityIsLoading = false
    private(set) var activityCanLoadMore = false
    private(set) var preparations: [UUID: SyncPreparation]
    private(set) var busySyncSets: Set<UUID>
    private(set) var openConflicts: [ConflictDecision]
    private(set) var resolvedConflicts: [ConflictResolutionRecord]
    private(set) var conflictAdviceByID: [UUID: ConflictAdvice]
    private(set) var defaultSafetyThresholds: SafetyThresholds
    private(set) var suggestionsEnabled: Bool

    private let session: any EngineSession
    private let preferences: BridgePreferences
    private let demoControls: DemoScenarioControls?
    @ObservationIgnored private var activeActivityQuery: ActivityQuery?
    @ObservationIgnored private var activityRequestID = UUID()
    @ObservationIgnored private var eventLoopTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    init(
        session: any EngineSession,
        preferences: BridgePreferences = BridgePreferences(),
        initialSuggestionsEnabled: Bool = UserDefaults.standard.object(
            forKey: AppModel.suggestionsPreferenceKey
        ) as? Bool ?? true,
        bootstrapImmediately: Bool = true,
        initialWorkspace: WorkspaceSnapshot? = nil,
        initialPhase: BootstrapPhase = .loading,
        initialActivity: [ActivityEntry] = [],
        initialPreparations: [UUID: SyncPreparation] = [:],
        initialBusySyncSets: Set<UUID> = [],
        initialOpenConflicts: [ConflictDecision] = [],
        initialResolvedConflicts: [ConflictResolutionRecord] = [],
        initialConflictAdvice: [ConflictAdvice] = []
    ) {
        self.session = session
        self.preferences = preferences
        self.demoControls = (session as? DemoEngineSession)?.scenarioControls
        self.workspace = initialWorkspace
        self.recentActivity = initialActivity
        self.activityEntries = initialActivity
        self.preparations = initialPreparations
        self.busySyncSets = initialBusySyncSets
        self.openConflicts = initialOpenConflicts
        self.resolvedConflicts = initialResolvedConflicts
        self.conflictAdviceByID = Dictionary(
            uniqueKeysWithValues: initialConflictAdvice.map { ($0.conflictID, $0) }
        )
        self.defaultSafetyThresholds = SafetyThresholds()
        self.suggestionsEnabled = initialSuggestionsEnabled
        self.bootstrapPhase = initialPhase

        startEventLoop()
        if bootstrapImmediately {
            bootstrapTask = Task { [weak self] in
                await self?.bootstrap()
            }
        }
    }

    var isDemoSession: Bool { demoControls != nil }

    var pendingPreparations: [SyncPreparation] {
        preparations.values
            .filter(Self.hasPendingContent)
            .sorted { $0.syncSetName.localizedStandardCompare($1.syncSetName) == .orderedAscending }
    }

    var isScanning: Bool { !busySyncSets.isEmpty }

    var oneDriveIsReachable: Bool {
        workspace?.locations.first(where: { $0.location.kind == .oneDrive })?.availability == .available
    }

    var nasIsMounted: Bool {
        workspace?.locations.first(where: { $0.location.kind == .nasFolder })?.availability == .available
    }

    func refreshWorkspace() async {
        workspace = await session.workspace()
    }

    func scanAll() async {
        guard let states = workspace?.syncSets else { return }
        for state in states where !state.isPaused {
            guard !Task.isCancelled else { return }
            _ = await prepare(syncSetID: state.id, presenting: false)
        }
        await refreshWorkspace()
    }

    func syncAll() async {
        guard let states = workspace?.syncSets else { return }
        for state in states where !state.isPaused {
            guard activeSheet == nil, !Task.isCancelled else { return }
            await syncNow(state.id)
        }
    }

    func syncNow(_ syncSetID: UUID) async {
        let requiresFirstPreview = workspace?.syncSets.first(where: { $0.id == syncSetID })?.lastRun == nil
        guard let preparation = await prepare(syncSetID: syncSetID, presenting: false) else { return }
        if requiresFirstPreview {
            guard activeSheet == nil else { return }
            activeSheet = .previewChanges(preparation)
        } else if preparation.outcome.planValue?.isAutoExecutable == true {
            await execute(preparation, approval: nil)
        } else if activeSheet == nil {
            activeSheet = .previewChanges(preparation)
        }
    }

    func preview(_ syncSetID: UUID) async {
        guard let preparation = await prepare(syncSetID: syncSetID, presenting: false) else { return }
        guard activeSheet == nil else { return }
        activeSheet = .previewChanges(preparation)
    }

    func showCachedPreview(_ preparation: SyncPreparation) {
        guard activeSheet == nil else { return }
        activeSheet = .previewChanges(preparation)
    }

    func showCachedPreview(for syncSetID: UUID) {
        guard let preparation = preparations[syncSetID] else { return }
        showCachedPreview(preparation)
    }

    func approveAndExecute(_ preparation: SyncPreparation, approval: PlanApproval) async {
        await execute(preparation, approval: approval)
    }

    func isBusy(syncSetID: UUID) -> Bool {
        busySyncSets.contains(syncSetID)
    }

    func refreshPreview(syncSetID: UUID) async -> SyncPreparation? {
        await prepare(syncSetID: syncSetID, presenting: false)
    }

    func executePreview(
        _ preparation: SyncPreparation,
        approval: PlanApproval?
    ) async -> SyncRunSummary? {
        let syncSetID = preparation.preview.syncSetID
        guard busySyncSets.insert(syncSetID).inserted else { return nil }
        defer { busySyncSets.remove(syncSetID) }
        do {
            let summary = try await session.execute(preparation, approval: approval)
            preparations.removeValue(forKey: syncSetID)
            await refreshWorkspace()
            return summary
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func finishPreview(with summary: SyncRunSummary) {
        pendingToast = RunResultToast.Model(summary: summary)
        activeSheet = nil
    }

    func setPaused(_ paused: Bool, syncSetID: UUID) async {
        guard !busySyncSets.contains(syncSetID) else { return }
        await session.setPaused(paused, syncSetID: syncSetID)
        await refreshWorkspace()
    }

    @discardableResult
    func createSyncSet(_ draft: SyncSetDraft) async -> Bool {
        do {
            let state = try await session.createSyncSet(draft)
            preparations.removeValue(forKey: state.id)
            await refreshWorkspace()
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func createSyncSet(
        name: String,
        locationIDs: [LocationID],
        mode: SyncMode
    ) async -> Bool {
        let draft = await preferences.makeSyncSetDraft(
            name: name,
            locationIDs: locationIDs,
            mode: mode
        )
        return await createSyncSet(draft)
    }

    func saveDefaultSafetyThresholds(_ thresholds: SafetyThresholds) async {
        do {
            try await preferences.setDefaultSafetyThresholds(thresholds)
            defaultSafetyThresholds = thresholds
        } catch {
            present(error)
        }
    }

    func setSuggestionsEnabled(_ enabled: Bool) async {
        guard enabled != suggestionsEnabled, !isScanning else { return }
        do {
            try await session.setSuggestionsEnabled(enabled)
            suggestionsEnabled = enabled
            preparations.removeAll()
            conflictAdviceByID.removeAll()
            await refreshWorkspace()
            await refreshConflicts()
        } catch {
            present(error)
        }
    }

    @discardableResult
    func updateSyncSet(
        mode: SyncMode,
        settings: SyncSettings,
        syncSetID: UUID
    ) async -> Bool {
        guard !busySyncSets.contains(syncSetID) else { return false }
        do {
            try await session.updateSyncSet(mode: mode, settings: settings, syncSetID: syncSetID)
            preparations.removeValue(forKey: syncSetID)
            await refreshWorkspace()
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func deleteSyncSet(_ syncSetID: UUID) async -> Bool {
        guard !busySyncSets.contains(syncSetID) else { return false }
        do {
            try await session.deleteSyncSet(syncSetID)
            preparations.removeValue(forKey: syncSetID)
            if case let .syncSetDetail(presentedID) = activeSheet, presentedID == syncSetID {
                activeSheet = nil
            }
            await refreshWorkspace()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func resolveConflict(_ id: UUID, as resolution: ConflictDecision.Resolution) async {
        do {
            try await session.resolveConflict(id: id, as: resolution)
            await refreshWorkspace()
            await refreshConflicts()
        } catch {
            present(error)
        }
    }

    func show(
        _ destination: SidebarDestination,
        filteredToRun runID: UUID? = nil,
        focusing conflictID: UUID? = nil
    ) {
        selectedDestination = destination
        activityFilterRunID = destination == .activity ? runID : nil
        if destination == .conflicts {
            focusedConflictID = conflictID
        }
    }

    func consumeActivityRunFilter() -> UUID? {
        defer { activityFilterRunID = nil }
        return activityFilterRunID
    }

    func loadActivity(
        categories: Set<ActivityCategory>?,
        syncSetID: UUID?,
        runID: UUID?
    ) async {
        activityEntries.removeAll()
        activityCanLoadMore = false
        let query = ActivityQuery(
            syncSetID: syncSetID,
            runID: runID,
            categories: categories,
            limit: 200
        )
        await replaceActivity(with: query, showsLoading: true)
    }

    func loadMoreActivity() async {
        guard var query = activeActivityQuery, !activityIsLoading, activityCanLoadMore else { return }
        query.limit += 200
        await replaceActivity(with: query, showsLoading: true)
    }

    func deactivateActivityFeed() {
        activeActivityQuery = nil
        activityRequestID = UUID()
        activityIsLoading = false
    }

    func clearConflictFocus(_ id: UUID) {
        if focusedConflictID == id {
            focusedConflictID = nil
        }
    }

    func showSyncSets(using locationID: LocationID) {
        syncSetsLocationFilter = locationID
        show(.syncSets)
    }

    func wakeAndMountNAS() async {
        guard let demoControls else { return }
        await demoControls.setNASMounted(true)
    }

    func performDemoAction(_ action: DemoAction) async {
        guard let demoControls else { return }
        do {
            switch action {
            case .toggleOneDrive:
                await demoControls.setOneDriveReachable(!oneDriveIsReachable)
            case .toggleNAS:
                await demoControls.setNASMounted(!nasIsMounted)
            case .makeConflict:
                await demoControls.makeConflict()
            case .makeMassDeletion:
                await demoControls.makeMassDeletion()
            case .simulateInterruptedRun:
                try await demoControls.simulateInterruptedRun()
            case .reset:
                try await demoControls.reset()
            }
            await refreshWorkspace()
        } catch {
            present(error)
        }
    }

    private func bootstrap() async {
        do {
            defaultSafetyThresholds = await preferences.defaultSafetyThresholds()
            try await session.setSuggestionsEnabled(suggestionsEnabled)
            let snapshot = try await session.bootstrap()
            guard !Task.isCancelled else { return }
            workspace = snapshot
            recentActivity = await session.activity(matching: ActivityQuery(limit: 100))
            activityEntries = recentActivity
            await refreshConflicts()
            for state in snapshot.syncSets {
                if let preparation = await session.lastPreparation(for: state.id) {
                    preparations[state.id] = preparation
                }
            }
            bootstrapPhase = .ready
        } catch is CancellationError {
            return
        } catch {
            bootstrapPhase = .failed(error.localizedDescription)
        }
    }

    private func startEventLoop() {
        let events = session.events
        eventLoopTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
    }

    private func receive(_ event: EngineEvent) async {
        switch event {
        case let .activityAppended(entry):
            recentActivity.removeAll { $0.id == entry.id }
            recentActivity.insert(entry, at: 0)
            if recentActivity.count > 100 {
                recentActivity.removeLast(recentActivity.count - 100)
            }
            if let query = activeActivityQuery {
                await replaceActivity(with: query, showsLoading: false)
            }
        case let .syncSetChanged(syncSetID):
            await refreshWorkspace()
            if let preparation = await session.lastPreparation(for: syncSetID) {
                preparations[syncSetID] = preparation
            } else {
                preparations.removeValue(forKey: syncSetID)
            }
        case .locationsChanged:
            await refreshWorkspace()
        case .conflictsChanged:
            await refreshWorkspace()
            await refreshConflicts()
        case let .runFinished(summary):
            let announcement = RunResultToast.Model(summary: summary)
            AccessibilityNotification.Announcement(
                "\(announcement.title). \(announcement.detail)"
            ).post()
            let previewOwnsResult: Bool
            if case let .previewChanges(preparation) = activeSheet {
                previewOwnsResult = preparation.preview.syncSetID == summary.syncSetID
            } else {
                previewOwnsResult = false
            }
            if !previewOwnsResult {
                pendingToast = RunResultToast.Model(summary: summary)
            }
            preparations.removeValue(forKey: summary.syncSetID)
            await refreshWorkspace()
        case .worldReset:
            workspace = await session.workspace()
            recentActivity = await session.activity(matching: ActivityQuery(limit: 100))
            if let query = activeActivityQuery {
                await replaceActivity(with: query, showsLoading: false)
            } else {
                activityEntries = recentActivity
            }
            await refreshConflicts()
            preparations.removeAll()
            if let states = workspace?.syncSets {
                for state in states {
                    if let preparation = await session.lastPreparation(for: state.id) {
                        preparations[state.id] = preparation
                    }
                }
            }
        }
    }

    private func prepare(syncSetID: UUID, presenting: Bool) async -> SyncPreparation? {
        guard busySyncSets.insert(syncSetID).inserted else { return nil }
        defer { busySyncSets.remove(syncSetID) }
        do {
            let knownHoldIDs = Set(preparations[syncSetID]?.preview.holds.map(\.id) ?? [])
            let preparation = try await session.prepare(syncSetID: syncSetID)
            preparations[syncSetID] = preparation
            if let newHold = preparation.preview.holds.first(where: { !knownHoldIDs.contains($0.id) }) {
                AccessibilityNotification.Announcement(newHold.message).post()
            }
            await refreshWorkspace()
            if presenting, activeSheet == nil {
                activeSheet = .previewChanges(preparation)
            }
            return preparation
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    private func replaceActivity(with query: ActivityQuery, showsLoading: Bool) async {
        activeActivityQuery = query
        let requestID = UUID()
        activityRequestID = requestID
        if showsLoading {
            activityIsLoading = true
        }
        let entries = await session.activity(matching: query)
        guard activityRequestID == requestID else { return }
        activityEntries = entries
        activityCanLoadMore = entries.count == query.limit
        activityIsLoading = false
    }

    private func refreshConflicts() async {
        do {
            let open = try await session.openConflicts(in: nil)
            let resolved = try await session.resolvedConflicts(in: nil)
            let advice = await session.advice(for: open.map(\.id))
            openConflicts = open
            resolvedConflicts = resolved
            conflictAdviceByID = Dictionary(uniqueKeysWithValues: advice.map { ($0.conflictID, $0) })
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    private func execute(_ preparation: SyncPreparation, approval: PlanApproval?) async {
        let syncSetID = preparation.preview.syncSetID
        guard busySyncSets.insert(syncSetID).inserted else { return }
        defer { busySyncSets.remove(syncSetID) }
        do {
            let summary = try await session.execute(preparation, approval: approval)
            preparations.removeValue(forKey: syncSetID)
            pendingToast = RunResultToast.Model(summary: summary)
            activeSheet = nil
            await refreshWorkspace()
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        presentedError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func hasPendingContent(_ preparation: SyncPreparation) -> Bool {
        !preparation.preview.sections.allSatisfy(\.entries.isEmpty)
            || !preparation.preview.holds.isEmpty
            || !preparation.preview.refusals.isEmpty
    }
}
