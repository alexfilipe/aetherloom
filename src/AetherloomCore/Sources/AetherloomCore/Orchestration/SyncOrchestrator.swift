import Foundation

public typealias LocationDirectory = [LocationID: SyncLocation]

public struct SyncPreparation: Codable, Hashable, Sendable {
    public var outcome: PlanOutcome
    public var preview: ChangePreview
    public var advice: [ConflictAdvice]
    public var runID: UUID
    public var syncSetName: String

    public init(
        outcome: PlanOutcome,
        preview: ChangePreview,
        advice: [ConflictAdvice] = [],
        runID: UUID,
        syncSetName: String
    ) {
        self.outcome = outcome
        self.preview = preview
        self.advice = advice
        self.runID = runID
        self.syncSetName = syncSetName
    }
}

public struct EngineEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var makeID: @Sendable () -> UUID
    public var scanTimeoutSeconds: TimeInterval
    public var maxConcurrentLocationOperations: Int

    public init(
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID,
        scanTimeoutSeconds: TimeInterval = 120,
        maxConcurrentLocationOperations: Int = 3
    ) {
        self.now = now
        self.makeID = makeID
        self.scanTimeoutSeconds = scanTimeoutSeconds
        self.maxConcurrentLocationOperations = max(1, maxConcurrentLocationOperations)
    }
}

public enum SyncOrchestratorError: Error, Equatable, Sendable {
    case runAlreadyInProgress(UUID)
}

public actor SyncOrchestrator {
    private let locations: LocationDirectory
    private let providers: [LocationID: any StorageProvider]
    private let stores: EngineStores
    private let contentStage: ContentStage
    private let environment: EngineEnvironment
    private let renderer = ChangePreviewRenderer()
    private var activeSyncSets: Set<UUID> = []

    public init(
        locations: LocationDirectory,
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,
        stage: ContentStage,
        environment: EngineEnvironment
    ) {
        self.locations = locations
        self.providers = providers
        self.stores = stores
        self.contentStage = stage
        self.environment = environment
    }

    public func prepare(_ syncSet: SyncSet) async throws -> SyncPreparation {
        try beginRun(syncSet.id)
        defer { finishRun(syncSet.id) }

        let runID = environment.makeID()
        await appendActivity(
            syncSetID: syncSet.id,
            runID: runID,
            category: .sync,
            message: ActivityMessageCatalog.runStarted(locationCount: syncSet.locations.count)
        )

        try Task.checkCancellation()
        try await recoverIfNeeded(syncSetID: syncSet.id, runID: runID)

        try Task.checkCancellation()
        await appendStage("Availability", syncSetID: syncSet.id, runID: runID, started: true)
        let availabilityReasons = await availabilityRefusals(for: syncSet)
        await appendStage("Availability", syncSetID: syncSet.id, runID: runID, started: false)
        if !availabilityReasons.isEmpty {
            let refusal = SyncRefusal(syncSetID: syncSet.id, reasons: availabilityReasons, occurredAt: environment.now())
            return try await finishPreparation(.refusal(refusal), syncSet: syncSet, runID: runID, baseRecords: [])
        }

        try Task.checkCancellation()
        await appendStage("Scan", syncSetID: syncSet.id, runID: runID, started: true)
        let snapshots = await scan(syncSet)
        await appendStage("Scan", syncSetID: syncSet.id, runID: runID, started: false)

        try Task.checkCancellation()
        await appendStage("Plan", syncSetID: syncSet.id, runID: runID, started: true)
        let baseRead = await baseRecords(for: syncSet.id)
        let resolvedConflicts = try await stores.conflicts.resolvedConflicts(for: syncSet.id)
        let outcome = SyncPlanner().plan(
            SyncPlanningInput(
                syncSet: syncSet,
                locations: locationsFor(syncSet),
                records: baseRead.records,
                snapshots: snapshots,
                settings: syncSet.settings,
                baseStateUnreadableDetail: baseRead.unreadableDetail,
                resolvedConflicts: resolvedConflicts
            ),
            environment: planningEnvironment()
        )
        await appendStage("Plan", syncSetID: syncSet.id, runID: runID, started: false)

        try Task.checkCancellation()
        return try await finishPreparation(outcome, syncSet: syncSet, runID: runID, baseRecords: baseRead.records)
    }

    public func execute(_ preparation: SyncPreparation, approval: PlanApproval? = nil) async throws -> SyncRunSummary {
        let syncSetID = preparation.outcome.syncSetID
        try beginRun(syncSetID)
        defer { finishRun(syncSetID) }

        switch preparation.outcome {
        case .refusal:
            await appendActivity(
                syncSetID: syncSetID,
                runID: preparation.runID,
                category: .sync,
                message: ActivityMessageCatalog.runFinished,
                detail: SyncRunOutcome.refused.detail
            )
            return SyncRunSummary(runID: preparation.runID, syncSetID: syncSetID, outcome: .refused)

        case let .plan(plan):
            if !plan.gate.isClear, approval == nil {
                await logHolds(plan.gate.holdReasons, syncSetID: syncSetID, runID: preparation.runID)
                await appendActivity(
                    syncSetID: syncSetID,
                    runID: preparation.runID,
                    category: .sync,
                    message: ActivityMessageCatalog.runFinished,
                    detail: SyncRunOutcome.held.detail
                )
                return SyncRunSummary(runID: preparation.runID, syncSetID: syncSetID, outcome: .held)
            }

            await appendStage("Execute", syncSetID: syncSetID, runID: preparation.runID, started: true)
            let executor = ScheduleExecutor(
                providers: providers,
                stores: stores,
                stage: contentStage,
                environment: executionEnvironment()
            )
            let summary = try await executor.execute(
                plan,
                runID: preparation.runID,
                approval: approval,
                syncSetName: preparation.syncSetName,
                logRunBoundaryActivity: false
            )
            await appendStage("Execute", syncSetID: syncSetID, runID: preparation.runID, started: false)
            await appendActivity(
                syncSetID: syncSetID,
                runID: preparation.runID,
                category: .sync,
                message: ActivityMessageCatalog.runFinished,
                detail: summary.outcome.detail
            )
            return summary
        }
    }

    private func finishPreparation(
        _ outcome: PlanOutcome,
        syncSet: SyncSet,
        runID: UUID,
        baseRecords: [BaseRecord]
    ) async throws -> SyncPreparation {
        await appendStage("Preview", syncSetID: syncSet.id, runID: runID, started: true)
        let advice = await conflictAdvice(for: outcome)
        let preview = renderer.render(
            outcome: outcome,
            locations: locations,
            base: baseRecords,
            advice: advice,
            generatedAt: environment.now()
        )
        if case let .plan(plan) = outcome {
            try await stores.conflicts.upsert(plan.conflicts.map { conflict in
                var scoped = conflict
                scoped.syncSetID = syncSet.id
                return scoped
            })
            await logHolds(plan.gate.holdReasons, syncSetID: syncSet.id, runID: runID)
            await logConflicts(plan.conflicts, syncSetID: syncSet.id, runID: runID)
        } else if case let .refusal(refusal) = outcome {
            await logRefusals(refusal.reasons, syncSetID: syncSet.id, runID: runID)
        }
        await logPreparationSummary(preview, syncSetID: syncSet.id, runID: runID)
        await appendStage("Preview", syncSetID: syncSet.id, runID: runID, started: false)

        return SyncPreparation(
            outcome: outcome,
            preview: preview,
            advice: advice,
            runID: runID,
            syncSetName: syncSet.name
        )
    }

    private func recoverIfNeeded(syncSetID: UUID, runID: UUID) async throws {
        await appendStage("Recovery", syncSetID: syncSetID, runID: runID, started: true)
        if let replay = try await stores.journal.unfinishedRun(for: syncSetID) {
            let report = try await RunRecovery(
                providers: providers,
                stores: stores,
                environment: executionEnvironment()
            ).recover(replay)
            await appendActivity(
                syncSetID: syncSetID,
                runID: runID,
                category: .safety,
                message: ActivityMessageCatalog.recoveryPerformed,
                detail: "\(report.reconciledOperations.count) operations reconciled for unfinished run \(report.runID.uuidString)."
            )
        }
        await appendStage("Recovery", syncSetID: syncSetID, runID: runID, started: false)
    }

    private func availabilityRefusals(for syncSet: SyncSet) async -> [RefusalReason] {
        let providerMap = providers
        var missingReasons: [RefusalReason] = []
        var checks: [(LocationID, any StorageProvider)] = []
        for locationID in syncSet.locations.sorted() {
            guard let provider = providerMap[locationID] else {
                missingReasons.append(.locationUnavailable(locationID, .unknown(detail: "Missing provider.")))
                continue
            }
            checks.append((locationID, provider))
        }

        let availability = await withTaskGroup(of: (LocationID, LocationAvailability).self) { group in
            for (locationID, provider) in checks {
                group.addTask {
                    (locationID, await provider.checkAvailability())
                }
            }

            var results: [(LocationID, LocationAvailability)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let unavailable = availability.compactMap { locationID, result -> RefusalReason? in
            if case let .unavailable(reason) = result {
                return .locationUnavailable(locationID, reason)
            }
            return nil
        }
        return (missingReasons + unavailable).sorted(by: refusalSort)
    }

    private func scan(_ syncSet: SyncSet) async -> [LocationSnapshot] {
        let providerMap = providers
        let locationMap = locations
        let timeoutSeconds = environment.scanTimeoutSeconds
        return await withTaskGroup(of: LocationSnapshot.self) { group in
            for locationID in syncSet.locations.sorted() {
                guard let provider = providerMap[locationID] else { continue }
                let scope = locationMap[locationID]?.scope ?? .entireDrive
                group.addTask {
                    await scanWithTimeout(
                        provider: provider,
                        scope: scope,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            }

            var snapshots: [LocationSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.location < $1.location }
        }
    }

    private func baseRecords(for syncSetID: UUID) async -> (records: [BaseRecord], unreadableDetail: String?) {
        do {
            return (try await stores.baseRecords.records(for: syncSetID), nil)
        } catch {
            return ([], baseStateUnreadableDetail(syncSetID: syncSetID, error: error))
        }
    }

    private func locationsFor(_ syncSet: SyncSet) -> [SyncLocation] {
        syncSet.locations.sorted().map { locationID in
            locations[locationID] ?? SyncLocation(id: locationID, kind: locationID.defaultKind, displayName: locationID.displayName)
        }
    }

    private func planningEnvironment() -> PlanningEnvironment {
        PlanningEnvironment(
            now: environment.now(),
            makeID: environment.makeID,
            locationNames: Dictionary(uniqueKeysWithValues: locations.map { ($0.key, $0.value.displayName) })
        )
    }

    private func executionEnvironment() -> ExecutionEnvironment {
        ExecutionEnvironment(
            now: environment.now,
            makeID: environment.makeID,
            maxConcurrentLocationOperations: environment.maxConcurrentLocationOperations
        )
    }

    // Task 08 seam: advisory integration will request conflict advice here.
    private func conflictAdvice(for _: PlanOutcome) async -> [ConflictAdvice] {
        []
    }

    private func logPreparationSummary(_ preview: ChangePreview, syncSetID: UUID, runID: UUID) async {
        let counts = Dictionary(uniqueKeysWithValues: preview.sections.map { ($0.kind, $0.entries.count) })
        let gate = preview.planFingerprint == nil ? ExecutionGate.hold([]) : preview.holds.isEmpty ? .clear : .hold(preview.holds.map(\.reason))
        await appendActivity(
            syncSetID: syncSetID,
            runID: runID,
            category: .sync,
            message: ActivityMessageCatalog.preparationSummary(
                additions: counts[.additions, default: 0],
                updates: counts[.updates, default: 0],
                moves: counts[.movesAndRenames, default: 0],
                trash: counts[.movesToTrash, default: 0],
                conflicts: preview.conflicts.count,
                waiting: counts[.waiting, default: 0],
                gate: gate
            )
        )
    }

    private func logRefusals(_ reasons: [RefusalReason], syncSetID: UUID, runID: UUID) async {
        for reason in reasons {
            await appendActivity(
                syncSetID: syncSetID,
                runID: runID,
                category: .safety,
                locationID: reason.locationID,
                message: reason.message,
                detail: reason.detail
            )
        }
    }

    private func logHolds(_ holds: [HoldReason], syncSetID: UUID, runID: UUID) async {
        for hold in holds {
            await appendActivity(
                syncSetID: syncSetID,
                runID: runID,
                category: .safety,
                message: hold.message,
                detail: hold.detail
            )
        }
    }

    private func logConflicts(_ conflicts: [ConflictDecision], syncSetID: UUID, runID: UUID) async {
        for conflict in conflicts {
            await appendActivity(
                syncSetID: syncSetID,
                runID: runID,
                category: .conflict,
                path: conflict.path,
                message: conflict.message,
                relatedConflictID: conflict.id
            )
        }
    }

    private func appendStage(_ name: String, syncSetID: UUID, runID: UUID, started: Bool) async {
        await appendActivity(
            syncSetID: syncSetID,
            runID: runID,
            category: .sync,
            message: started ? ActivityMessageCatalog.stageStarted(name) : ActivityMessageCatalog.stageFinished(name)
        )
    }

    private func appendActivity(
        syncSetID: UUID,
        runID: UUID,
        category: ActivityCategory,
        locationID: LocationID? = nil,
        path: SyncPath? = nil,
        message: String,
        detail: String? = nil,
        relatedConflictID: UUID? = nil
    ) async {
        await stores.activity.append(
            ActivityEntry(
                id: environment.makeID(),
                occurredAt: environment.now(),
                syncSetID: syncSetID,
                runID: runID,
                category: category,
                locationID: locationID,
                path: path,
                message: message,
                detail: detail,
                relatedConflictID: relatedConflictID
            )
        )
    }

    private func beginRun(_ syncSetID: UUID) throws {
        guard !activeSyncSets.contains(syncSetID) else {
            throw SyncOrchestratorError.runAlreadyInProgress(syncSetID)
        }
        activeSyncSets.insert(syncSetID)
    }

    private func finishRun(_ syncSetID: UUID) {
        activeSyncSets.remove(syncSetID)
    }
}

private func scanWithTimeout(
    provider: any StorageProvider,
    scope: SyncScope,
    timeoutSeconds: TimeInterval
) async -> LocationSnapshot {
    guard timeoutSeconds > 0 else {
        return timeoutSnapshot(provider: provider, scope: scope, timeoutSeconds: timeoutSeconds)
    }

    return await withTaskGroup(of: LocationSnapshot.self) { group in
        group.addTask {
            await provider.scan(scope)
        }
        group.addTask {
            let nanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            return timeoutSnapshot(provider: provider, scope: scope, timeoutSeconds: timeoutSeconds)
        }

        let first = await group.next() ?? timeoutSnapshot(provider: provider, scope: scope, timeoutSeconds: timeoutSeconds)
        group.cancelAll()
        return first
    }
}

private func timeoutSnapshot(
    provider: any StorageProvider,
    scope: SyncScope,
    timeoutSeconds: TimeInterval
) -> LocationSnapshot {
    LocationSnapshot(
        location: provider.locationID,
        scope: scope,
        observations: [],
        status: .unavailable(reason: .unknown(detail: "Scan timed out after \(timeoutSeconds) seconds."))
    )
}

private extension PlanOutcome {
    var syncSetID: UUID {
        switch self {
        case let .refusal(refusal):
            return refusal.syncSetID
        case let .plan(plan):
            return plan.syncSetID
        }
    }
}

private extension RefusalReason {
    var locationID: LocationID? {
        switch self {
        case let .locationUnavailable(location, _), let .scanIncomplete(location, _):
            return location
        case .baseStateUnreadable:
            return nil
        }
    }

    var detail: String? {
        switch self {
        case let .locationUnavailable(_, reason):
            return reason.detail
        case let .scanIncomplete(_, detail):
            return detail
        case let .baseStateUnreadable(detail):
            return detail
        }
    }
}

private extension HoldReason {
    var detail: String? {
        switch self {
        case let .conflicts(count), let .deletionsNeedReview(count):
            return "\(count) items."
        case let .massDeletion(evidence), let .massEdit(evidence):
            return evidence.groups.map { group in
                "all \(group.intentCount) under \(group.ancestor.rawValue)"
            }.joined(separator: ", ")
        }
    }
}

private func refusalSort(_ lhs: RefusalReason, _ rhs: RefusalReason) -> Bool {
    switch (lhs.locationID, rhs.locationID) {
    case let (lhs?, rhs?):
        return lhs < rhs
    case (nil, _?):
        return true
    case (_?, nil):
        return false
    case (nil, nil):
        return lhs.message < rhs.message
    }
}

private func baseStateUnreadableDetail(syncSetID: UUID, error: Error) -> String {
    if case let BaseRecordStoreError.corrupt(corruptSyncSetID) = error {
        return "Base records for \(corruptSyncSetID.uuidString) are unreadable."
    }
    return "Base records for \(syncSetID.uuidString) could not be read: \(error)."
}
