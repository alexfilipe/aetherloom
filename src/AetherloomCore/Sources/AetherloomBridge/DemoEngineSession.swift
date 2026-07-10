import AetherloomCore
import Foundation

public actor DemoEngineSession: EngineSession {
    private let world: DemoWorld
    private let environment: EngineEnvironment
    private let providerLatencyNanoseconds: UInt64
    private let eventHub = EngineEventHub()

    private var stores: EngineStores
    private var providers: [LocationID: FakeStorageProvider]
    private var orchestrator: SyncOrchestrator
    private var suggestionsAreEnabled: Bool
    private var syncSetsByID: [UUID: SyncSet] = [:]
    private var pausedSyncSetIDs: Set<UUID> = []
    private var preparationsBySyncSetID: [UUID: SyncPreparation] = [:]
    private var adviceByConflictID: [UUID: ConflictAdvice] = [:]
    private var phasesBySyncSetID: [UUID: SyncSetPhase] = [:]
    private var lastRunsBySyncSetID: [UUID: RunDigest] = [:]
    private var availabilityByLocationID: [LocationID: LocationAvailability] = [:]
    private var lastCheckedByLocationID: [LocationID: Date] = [:]
    private var isBootstrapped = false

    public nonisolated var events: AsyncStream<EngineEvent> {
        eventHub.stream()
    }

    public nonisolated var scenarioControls: DemoScenarioControls {
        DemoScenarioControls(session: self)
    }

    public static func standard() -> DemoEngineSession {
        DemoEngineSession(
            world: .standard,
            environment: EngineEnvironment(now: Date.init, makeID: UUID.init),
            providerLatencyNanoseconds: 120_000_000
        )
    }

    public init(
        world: DemoWorld = .standard,
        environment: EngineEnvironment = EngineEnvironment(now: Date.init, makeID: UUID.init),
        providerLatencyNanoseconds: UInt64 = 0,
        stageDirectory: URL? = nil
    ) {
        self.world = world
        self.environment = environment
        self.providerLatencyNanoseconds = providerLatencyNanoseconds
        let composition = Self.makeComposition(
            world: world,
            environment: environment,
            eventHub: eventHub,
            suggestionsEnabled: true,
            stageDirectory: stageDirectory ?? Self.makeStageDirectory()
        )
        self.stores = composition.stores
        self.providers = composition.providers
        self.orchestrator = composition.orchestrator
        self.suggestionsAreEnabled = true
    }

    public func bootstrap() async throws -> WorkspaceSnapshot {
        if isBootstrapped {
            return await workspace()
        }

        try await seedWorld()
        try await convergeSeedGroups()
        await applyConfiguredProviderLatency()
        await applyScriptedDivergences()
        await applyScriptedAvailabilityFaults()
        await clearProviderCallLogs()

        for syncSet in orderedSyncSets() where !pausedSyncSetIDs.contains(syncSet.id) {
            _ = try await prepareUnpaused(syncSet)
        }

        isBootstrapped = true
        return await workspace()
    }

    public func workspace() async -> WorkspaceSnapshot {
        let locations = await locationStates()
        let syncSets = await syncSetStates()
        let openConflictCount = (try? await allOpenConflicts())?.count ?? 0
        let activity = await stores.activity.entries(matching: ActivityQuery(limit: 100))
        return WorkspaceSnapshot(
            locations: locations,
            syncSets: syncSets,
            openConflictCount: openConflictCount,
            status: workspaceStatus(
                for: syncSets,
                openConflictCount: openConflictCount,
                activityEntries: activity
            )
        )
    }

    public func syncSetStates() async -> [SyncSetState] {
        var states: [SyncSetState] = []
        for syncSet in orderedSyncSets() {
            let records = (try? await stores.baseRecords.records(for: syncSet.id)) ?? []
            let openConflictCount = (try? await stores.conflicts.openConflicts(for: syncSet.id).count) ?? 0
            states.append(
                SyncSetState(
                    syncSet: syncSet,
                    isPaused: pausedSyncSetIDs.contains(syncSet.id),
                    lastRun: lastRunsBySyncSetID[syncSet.id],
                    lastPreparation: preparationsBySyncSetID[syncSet.id].map { PreparationDigest(preview: $0.preview) },
                    trackedItemCount: records.count,
                    openConflictCount: openConflictCount,
                    phase: phasesBySyncSetID[syncSet.id] ?? .idle
                )
            )
        }
        return states
    }

    public func locationStates() async -> [LocationState] {
        world.locations.sorted { $0.id < $1.id }.map { location in
            LocationState(
                location: location,
                availability: availabilityByLocationID[location.id] ?? .available,
                lastCheckedAt: lastCheckedByLocationID[location.id],
                accountLabel: world.accountLabels[location.id]
            )
        }
    }

    public func openConflicts(in syncSetID: UUID?) async throws -> [ConflictDecision] {
        if let syncSetID {
            guard syncSetsByID[syncSetID] != nil else {
                throw EngineSessionError.syncSetNotFound(syncSetID)
            }
            return try await stores.conflicts.openConflicts(for: syncSetID)
        }
        return try await allOpenConflicts()
    }

    public func resolvedConflicts(in syncSetID: UUID?) async throws -> [ConflictResolutionRecord] {
        if let syncSetID {
            guard syncSetsByID[syncSetID] != nil else {
                throw EngineSessionError.syncSetNotFound(syncSetID)
            }
            return try await stores.conflicts.resolvedConflicts(for: syncSetID)
        }
        return try await allResolvedConflicts()
    }

    public func advice(for conflictIDs: [UUID]) async -> [ConflictAdvice] {
        conflictIDs.compactMap { adviceByConflictID[$0] }
    }

    public func suggestionsEnabled() async -> Bool {
        suggestionsAreEnabled
    }

    public func activity(matching query: ActivityQuery) async -> [ActivityEntry] {
        await stores.activity.entries(matching: query)
    }

    public func lastPreparation(for syncSetID: UUID) async -> SyncPreparation? {
        preparationsBySyncSetID[syncSetID]
    }

    public func prepare(syncSetID: UUID) async throws -> SyncPreparation {
        guard let syncSet = syncSetsByID[syncSetID] else {
            throw EngineSessionError.syncSetNotFound(syncSetID)
        }
        guard !pausedSyncSetIDs.contains(syncSetID) else {
            throw EngineSessionError.syncSetPaused(syncSetID)
        }
        return try await prepareUnpaused(syncSet)
    }

    public func execute(
        _ preparation: SyncPreparation,
        approval: PlanApproval?
    ) async throws -> SyncRunSummary {
        let syncSetID = preparation.outcome.syncSetID
        guard syncSetsByID[syncSetID] != nil else {
            throw EngineSessionError.syncSetNotFound(syncSetID)
        }
        guard !pausedSyncSetIDs.contains(syncSetID) else {
            throw EngineSessionError.syncSetPaused(syncSetID)
        }

        phasesBySyncSetID[syncSetID] = .executing
        eventHub.emit(.syncSetChanged(syncSetID))
        do {
            let summary = try await orchestrator.execute(preparation, approval: approval)
            lastRunsBySyncSetID[syncSetID] = RunDigest(
                runID: summary.runID,
                finishedAt: environment.now(),
                outcome: summary.outcome
            )
            phasesBySyncSetID[syncSetID] = .idle
            eventHub.emit(.runFinished(summary))
            eventHub.emit(.conflictsChanged)
            eventHub.emit(.syncSetChanged(syncSetID))
            return summary
        } catch {
            phasesBySyncSetID[syncSetID] = .idle
            eventHub.emit(.syncSetChanged(syncSetID))
            throw map(error)
        }
    }

    public func createSyncSet(_ draft: SyncSetDraft) async throws -> SyncSetState {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw EngineSessionError.invalidSyncSetDraft(detail: "Give this sync set a name.")
        }
        let locationIDs = Array(Set(draft.locationIDs)).sorted()
        guard locationIDs.count >= 2 else {
            throw EngineSessionError.invalidSyncSetDraft(detail: "Choose at least two locations.")
        }
        let knownLocationIDs = Set(world.locations.map(\.id))
        guard Set(locationIDs).isSubset(of: knownLocationIDs) else {
            throw EngineSessionError.invalidSyncSetDraft(detail: "One or more locations are unavailable in this workspace.")
        }
        guard !syncSetsByID.values.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            throw EngineSessionError.invalidSyncSetDraft(detail: "A sync set with this name already exists.")
        }

        let now = environment.now()
        let syncSet = SyncSet(
            id: environment.makeID(),
            name: trimmedName,
            locations: locationIDs,
            mode: draft.mode,
            settings: draft.settings,
            createdAt: now,
            updatedAt: now
        )
        syncSetsByID[syncSet.id] = syncSet
        phasesBySyncSetID[syncSet.id] = .idle
        eventHub.emit(.syncSetChanged(syncSet.id))
        return SyncSetState(syncSet: syncSet, isPaused: false)
    }

    public func setSuggestionsEnabled(_ enabled: Bool) async throws {
        guard suggestionsAreEnabled != enabled else { return }
        if let activeSyncSetID = phasesBySyncSetID.first(where: { $0.value != .idle })?.key {
            throw EngineSessionError.runAlreadyInProgress(activeSyncSetID)
        }

        suggestionsAreEnabled = enabled
        orchestrator = Self.makeOrchestrator(
            world: world,
            environment: environment,
            providers: providers,
            stores: stores,
            suggestionsEnabled: enabled,
            stageDirectory: Self.makeStageDirectory()
        )
        preparationsBySyncSetID.removeAll()
        adviceByConflictID.removeAll()
        eventHub.emit(.conflictsChanged)
        for syncSetID in syncSetsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            eventHub.emit(.syncSetChanged(syncSetID))
        }
    }

    public func setPaused(_ paused: Bool, syncSetID: UUID) async {
        guard syncSetsByID[syncSetID] != nil else { return }
        if paused {
            pausedSyncSetIDs.insert(syncSetID)
        } else {
            pausedSyncSetIDs.remove(syncSetID)
        }
        eventHub.emit(.syncSetChanged(syncSetID))
    }

    public func updateSyncSet(
        mode: SyncMode,
        settings: SyncSettings,
        syncSetID: UUID
    ) async throws {
        guard var syncSet = syncSetsByID[syncSetID] else {
            throw EngineSessionError.syncSetNotFound(syncSetID)
        }
        syncSet.mode = mode
        syncSet.settings = settings
        syncSet.updatedAt = environment.now()
        syncSetsByID[syncSetID] = syncSet
        invalidatePreparation(for: syncSetID)
        eventHub.emit(.syncSetChanged(syncSetID))
    }

    public func deleteSyncSet(_ syncSetID: UUID) async throws {
        guard syncSetsByID[syncSetID] != nil else {
            throw EngineSessionError.syncSetNotFound(syncSetID)
        }

        do {
            let records = try await stores.baseRecords.records(for: syncSetID)
            for record in records.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try await stores.baseRecords.apply(.purge(syncSetID: syncSetID, recordID: record.id))
            }
        } catch {
            throw map(error)
        }

        syncSetsByID.removeValue(forKey: syncSetID)
        pausedSyncSetIDs.remove(syncSetID)
        invalidatePreparation(for: syncSetID)
        phasesBySyncSetID.removeValue(forKey: syncSetID)
        lastRunsBySyncSetID.removeValue(forKey: syncSetID)
        eventHub.emit(.syncSetChanged(syncSetID))
        eventHub.emit(.conflictsChanged)
    }

    public func resolveConflict(id: UUID, as resolution: Resolution) async throws {
        do {
            try await stores.conflicts.resolve(id, as: resolution, at: environment.now())
            adviceByConflictID.removeValue(forKey: id)
            eventHub.emit(.conflictsChanged)
        } catch ConflictStoreError.missing {
            throw EngineSessionError.conflictNotFound(id)
        } catch {
            throw map(error)
        }
    }

    func setOneDriveReachable(_ reachable: Bool) async {
        await setAvailability(
            reachable ? .available : .unavailable(.networkUnreachable(detail: "OneDrive cannot be reached.")),
            locationID: .oneDrive
        )
    }

    func setNASMounted(_ mounted: Bool) async {
        await setAvailability(
            mounted ? .available : .unavailable(.volumeNotMounted(detail: "NAS \"Tank\" is not mounted.")),
            locationID: .nasFolder
        )
    }

    func makeConflict() async {
        // Mutate a path that the standard cached Documents preparation already
        // targets so the control deterministically exercises execution drift.
        let path: SyncPath = "/Documents/Notes/Meeting.txt"
        let date = environment.now()
        if let provider = providers[.iCloudDrive] {
            let itemID = await provider.item(at: path)?.itemID
            _ = await provider.putFile(
                path: path,
                contents: Data("Meeting notes edited on iCloud".utf8),
                modifiedAt: date,
                itemID: itemID
            )
        }
        if let provider = providers[.googleDrive] {
            let itemID = await provider.item(at: path)?.itemID
            _ = await provider.putFile(path: path, contents: Data("Google divergent edit".utf8), modifiedAt: date.addingTimeInterval(2), itemID: itemID)
        }
        eventHub.emit(.syncSetChanged(DemoWorld.documentsID))
    }

    func makeMassDeletion() async {
        guard let provider = providers[.googleDrive] else { return }
        for path in world.divergences.projectMassDeletionPaths {
            await provider.remove(path: path)
        }
        eventHub.emit(.syncSetChanged(DemoWorld.projectsID))
    }

    func simulateInterruptedRun() async throws {
        let runID = environment.makeID()
        try await stores.journal.begin(
            runID: runID,
            syncSetID: DemoWorld.documentsID,
            fingerprint: PlanFingerprint(rawValue: "demo-interrupted-\(runID.uuidString)")
        )
        eventHub.emit(.syncSetChanged(DemoWorld.documentsID))
    }

    func reset() async throws {
        let composition = Self.makeComposition(
            world: world,
            environment: environment,
            eventHub: eventHub,
            suggestionsEnabled: suggestionsAreEnabled,
            stageDirectory: Self.makeStageDirectory()
        )
        stores = composition.stores
        providers = composition.providers
        orchestrator = composition.orchestrator
        syncSetsByID.removeAll()
        pausedSyncSetIDs.removeAll()
        preparationsBySyncSetID.removeAll()
        adviceByConflictID.removeAll()
        phasesBySyncSetID.removeAll()
        lastRunsBySyncSetID.removeAll()
        availabilityByLocationID.removeAll()
        lastCheckedByLocationID.removeAll()
        isBootstrapped = false
        _ = try await bootstrap()
        eventHub.emit(.worldReset)
    }

    func providerCallLogs() async -> [LocationID: [FakeProviderCall]] {
        var result: [LocationID: [FakeProviderCall]] = [:]
        for (locationID, provider) in providers {
            result[locationID] = await provider.callLog()
        }
        return result
    }

    func clearProviderCalls() async {
        await clearProviderCallLogs()
    }

    func baseRecordCount(for syncSetID: UUID) async throws -> Int {
        try await stores.baseRecords.records(for: syncSetID).count
    }

    func providerItems(at locationID: LocationID, includeTrashed: Bool = false) async -> [ItemObservation] {
        await providers[locationID]?.allItems(includeTrashed: includeTrashed) ?? []
    }

    func setProviderLatency(_ nanoseconds: UInt64) async {
        for provider in providers.values {
            await provider.setLatency(nanoseconds: nanoseconds)
        }
    }

    private func seedWorld() async throws {
        syncSetsByID = Dictionary(uniqueKeysWithValues: world.syncSets.map { ($0.id, $0) })
        pausedSyncSetIDs = world.pausedSyncSetIDs
        for syncSet in world.syncSets {
            phasesBySyncSetID[syncSet.id] = .idle
        }
        for location in world.locations {
            try await stores.locations.upsert(location)
            availabilityByLocationID[location.id] = .available
            lastCheckedByLocationID[location.id] = environment.now()
        }
        for group in world.seedGroups {
            guard let provider = providers[group.sourceLocationID] else { continue }
            for item in group.items {
                switch item.kind {
                case .folder:
                    _ = await provider.putFolder(
                        path: item.path,
                        modifiedAt: item.modifiedAt,
                        itemID: item.itemID
                    )
                case .file:
                    _ = await provider.putFile(
                        path: item.path,
                        contents: item.contents,
                        modifiedAt: item.modifiedAt,
                        itemID: item.itemID
                    )
                case let .symlink(target):
                    _ = await provider.putSymlink(
                        path: item.path,
                        target: target,
                        modifiedAt: item.modifiedAt,
                        itemID: item.itemID
                    )
                }
            }
        }
    }

    private func convergeSeedGroups() async throws {
        for group in world.seedGroups {
            guard let syncSet = syncSetsByID[group.syncSetID] else { continue }
            let preparation = try await orchestrator.prepare(syncSet)
            let summary = try await orchestrator.execute(preparation, approval: nil)
            lastRunsBySyncSetID[syncSet.id] = RunDigest(
                runID: summary.runID,
                finishedAt: environment.now(),
                outcome: summary.outcome
            )
        }
    }

    private func applyScriptedDivergences() async {
        let divergenceDate = environment.now().addingTimeInterval(60)
        if let iCloud = providers[.iCloudDrive] {
            let path = world.divergences.documentEditPaths[0]
            _ = await iCloud.putFile(
                path: path,
                contents: Data("Meeting notes edited on iCloud".utf8),
                modifiedAt: divergenceDate,
                itemID: await iCloud.item(at: path)?.itemID
            )
            let createPath = world.divergences.documentCreatePaths[0]
            _ = await iCloud.putFile(path: createPath, contents: Data("Created on iPhone".utf8), modifiedAt: divergenceDate)

            let conflictPath = world.divergences.documentConflictPath
            _ = await iCloud.putFile(
                path: conflictPath,
                contents: Data("Budget edited on iCloud".utf8),
                modifiedAt: divergenceDate,
                itemID: await iCloud.item(at: conflictPath)?.itemID
            )
            let placeholderPath = world.divergences.documentPlaceholderPath
            _ = await iCloud.putFile(
                path: placeholderPath,
                contents: Data("Materialized before placeholder".utf8),
                modifiedAt: divergenceDate,
                itemID: await iCloud.item(at: placeholderPath)?.itemID,
                isPlaceholder: true
            )
        }

        if let google = providers[.googleDrive] {
            let path = world.divergences.documentEditPaths[1]
            _ = await google.putFile(
                path: path,
                contents: Data("Roadmap edited on Google Drive".utf8),
                modifiedAt: divergenceDate,
                itemID: await google.item(at: path)?.itemID
            )
            let rename = world.divergences.documentRename
            let renamedItemID = await google.item(at: rename.old)?.itemID
            await google.remove(path: rename.old)
            _ = await google.putFile(
                path: rename.new,
                contents: Data("Reference 1".utf8),
                modifiedAt: divergenceDate,
                itemID: renamedItemID
            )
            await google.remove(path: world.divergences.documentDeletePath)

            let conflictPath = world.divergences.documentConflictPath
            _ = await google.putFile(
                path: conflictPath,
                contents: Data("Budget edited on Google Drive".utf8),
                modifiedAt: divergenceDate.addingTimeInterval(2),
                itemID: await google.item(at: conflictPath)?.itemID
            )
            for path in world.divergences.projectMassDeletionPaths {
                await google.remove(path: path)
            }
        }

        if let local = providers[.localFolder] {
            let path = world.divergences.documentCreatePaths[1]
            _ = await local.putFile(path: path, contents: Data("Local draft".utf8), modifiedAt: divergenceDate)
            // The missing local copy makes content propagation necessary while
            // iCloud exposes only a placeholder, producing the real waiting verdict.
            await local.remove(path: world.divergences.documentPlaceholderPath)
        }
    }

    private func applyScriptedAvailabilityFaults() async {
        await setAvailability(
            .unavailable(.networkUnreachable(detail: "OneDrive cannot be reached.")),
            locationID: .oneDrive,
            emit: false
        )
        await setAvailability(
            .unavailable(.volumeNotMounted(detail: "NAS \"Tank\" is not mounted.")),
            locationID: .nasFolder,
            emit: false
        )
    }

    private func setAvailability(
        _ availability: LocationAvailability,
        locationID: LocationID,
        emit: Bool = true
    ) async {
        await providers[locationID]?.setAvailability(availability)
        availabilityByLocationID[locationID] = availability
        lastCheckedByLocationID[locationID] = environment.now()
        if emit {
            eventHub.emit(.locationsChanged)
        }
    }

    private func prepareUnpaused(_ syncSet: SyncSet) async throws -> SyncPreparation {
        phasesBySyncSetID[syncSet.id] = .preparing
        eventHub.emit(.syncSetChanged(syncSet.id))
        do {
            let preparation = try await orchestrator.prepare(syncSet)
            preparationsBySyncSetID[syncSet.id] = preparation
            for advice in preparation.advice {
                adviceByConflictID[advice.conflictID] = advice
            }
            phasesBySyncSetID[syncSet.id] = .idle
            eventHub.emit(.conflictsChanged)
            eventHub.emit(.syncSetChanged(syncSet.id))
            return preparation
        } catch {
            phasesBySyncSetID[syncSet.id] = .idle
            eventHub.emit(.syncSetChanged(syncSet.id))
            throw map(error)
        }
    }

    private func allOpenConflicts() async throws -> [ConflictDecision] {
        var conflictsByID: [UUID: ConflictDecision] = [:]
        for syncSetID in syncSetsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for conflict in try await stores.conflicts.openConflicts(for: syncSetID) {
                conflictsByID[conflict.id] = conflict
            }
        }
        return conflictsByID.values.sorted {
            $0.path == $1.path ? $0.id.uuidString < $1.id.uuidString : $0.path < $1.path
        }
    }

    private func allResolvedConflicts() async throws -> [ConflictResolutionRecord] {
        var recordsByID: [UUID: ConflictResolutionRecord] = [:]
        for syncSetID in syncSetsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for record in try await stores.conflicts.resolvedConflicts(for: syncSetID) {
                recordsByID[record.id] = record
            }
        }
        return recordsByID.values.sorted {
            $0.resolvedAt == $1.resolvedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.resolvedAt > $1.resolvedAt
        }
    }

    private func orderedSyncSets() -> [SyncSet] {
        syncSetsByID.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
    }

    private func invalidatePreparation(for syncSetID: UUID) {
        let staleAdviceIDs = Set(preparationsBySyncSetID[syncSetID]?.advice.map(\.conflictID) ?? [])
        preparationsBySyncSetID.removeValue(forKey: syncSetID)
        adviceByConflictID = adviceByConflictID.filter { !staleAdviceIDs.contains($0.key) }
    }

    private func clearProviderCallLogs() async {
        for provider in providers.values {
            await provider.clearCallLog()
        }
    }

    private func applyConfiguredProviderLatency() async {
        for provider in providers.values {
            await provider.setLatency(nanoseconds: providerLatencyNanoseconds)
        }
    }

    private func map(_ error: Error) -> EngineSessionError {
        if error is CancellationError {
            return .cancelled
        }
        if case let SyncOrchestratorError.runAlreadyInProgress(syncSetID) = error {
            return .runAlreadyInProgress(syncSetID)
        }
        if let sessionError = error as? EngineSessionError {
            return sessionError
        }
        return .engineFailure(detail: String(describing: error))
    }

    private static func makeComposition(
        world: DemoWorld,
        environment: EngineEnvironment,
        eventHub: EngineEventHub,
        suggestionsEnabled: Bool,
        stageDirectory: URL
    ) -> (
        stores: EngineStores,
        providers: [LocationID: FakeStorageProvider],
        orchestrator: SyncOrchestrator
    ) {
        let baseStores = EngineStores.inMemory()
        let stores = EngineStores(
            baseRecords: baseStores.baseRecords,
            journal: baseStores.journal,
            conflicts: baseStores.conflicts,
            adviceCache: baseStores.adviceCache,
            activity: EventingActivityStore(backing: baseStores.activity, eventHub: eventHub),
            locations: baseStores.locations
        )
        let providers = Dictionary(uniqueKeysWithValues: world.locations.map { location in
            (location.id, FakeStorageProvider(location: location))
        })
        let orchestrator = makeOrchestrator(
            world: world,
            environment: environment,
            providers: providers,
            stores: stores,
            suggestionsEnabled: suggestionsEnabled,
            stageDirectory: stageDirectory
        )
        return (stores, providers, orchestrator)
    }

    private static func makeOrchestrator(
        world: DemoWorld,
        environment: EngineEnvironment,
        providers: [LocationID: FakeStorageProvider],
        stores: EngineStores,
        suggestionsEnabled: Bool,
        stageDirectory: URL
    ) -> SyncOrchestrator {
        SyncOrchestrator(
            locations: Dictionary(uniqueKeysWithValues: world.locations.map { ($0.id, $0) }),
            providers: providers.mapValues { $0 as any StorageProvider },
            stores: stores,
            stage: ContentStage(rootDirectory: stageDirectory, byteLimit: 128 * 1_024 * 1_024),
            environment: environment,
            advisor: suggestionsEnabled ? HeuristicConflictAdvisor() : nil
        )
    }

    private static func makeStageDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherloom-demo-stage-\(UUID().uuidString)", isDirectory: true)
    }
}

private extension PlanOutcome {
    var syncSetID: UUID {
        switch self {
        case let .plan(plan):
            return plan.syncSetID
        case let .refusal(refusal):
            return refusal.syncSetID
        }
    }
}
