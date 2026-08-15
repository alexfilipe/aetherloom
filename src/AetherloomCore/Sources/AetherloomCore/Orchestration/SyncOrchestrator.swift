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
    case freshPreparationRequired(UUID)
}

public actor SyncOrchestrator {
    private let locations: LocationDirectory
    private let providers: [LocationID: any StorageProvider]
    private let stores: EngineStores
    private let contentStage: ContentStage
    private let environment: EngineEnvironment
    private let advisor: (any ConflictAdvisor)?
    private let advisoryBudget: AdvisoryBudget
    private let adviceValidator = AdviceValidator()
    private let renderer = ChangePreviewRenderer()
    private var activeSyncSets: Set<UUID> = []
    private var currentPreparationRunIDs: [UUID: UUID] = [:]

    public init(
        locations: LocationDirectory,
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,
        stage: ContentStage,
        environment: EngineEnvironment,
        advisor: (any ConflictAdvisor)? = nil,
        advisoryBudget: AdvisoryBudget = .default
    ) {
        self.locations = locations
        self.providers = providers
        self.stores = stores
        self.contentStage = stage
        self.environment = environment
        self.advisor = advisor
        self.advisoryBudget = advisoryBudget
    }

    public func prepare(_ syncSet: SyncSet) async throws -> SyncPreparation {
        try beginRun(syncSet.id)
        defer { finishRun(syncSet.id) }

        // Starting a new preparation invalidates every older preparation for
        // this sync set without retaining an unbounded history of run IDs.
        currentPreparationRunIDs.removeValue(forKey: syncSet.id)
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
        var snapshots = await scan(syncSet)
        await appendStage("Scan", syncSetID: syncSet.id, runID: runID, started: false)

        try Task.checkCancellation()
        await appendStage("Plan", syncSetID: syncSet.id, runID: runID, started: true)
        let baseRead = await baseRecords(for: syncSet.id)
        let resolvedConflicts = try await stores.conflicts.resolvedConflicts(for: syncSet.id)
        var outcome = plan(
            syncSet,
            snapshots: snapshots,
            baseRead: baseRead,
            resolvedConflicts: resolvedConflicts
        )
        await appendStage("Plan", syncSetID: syncSet.id, runID: runID, started: false)

        if case .plan = outcome {
            try Task.checkCancellation()
            await appendStage("Evidence", syncSetID: syncSet.id, runID: runID, started: true)
            do {
                (snapshots, outcome) = try await refineEvidenceUntilSafe(
                    for: syncSet,
                    snapshots: snapshots,
                    initialOutcome: outcome,
                    baseRead: baseRead,
                    resolvedConflicts: resolvedConflicts
                )
            } catch let failure as EvidenceRefinementFailure {
                outcome = .refusal(
                    SyncRefusal(
                        syncSetID: syncSet.id,
                        reasons: [
                            .evidenceUnavailable(
                                failure.location,
                                path: failure.path,
                                detail: failure.detail
                            )
                        ],
                        occurredAt: environment.now()
                    )
                )
            }
            await appendStage("Evidence", syncSetID: syncSet.id, runID: runID, started: false)
        }

        try Task.checkCancellation()
        return try await finishPreparation(outcome, syncSet: syncSet, runID: runID, baseRecords: baseRead.records)
    }

    public func execute(_ preparation: SyncPreparation, approval: PlanApproval? = nil) async throws -> SyncRunSummary {
        let syncSetID = preparation.outcome.syncSetID
        guard currentPreparationRunIDs[syncSetID] == preparation.runID else {
            throw SyncOrchestratorError.freshPreparationRequired(
                preparation.runID
            )
        }
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
            if !plan.gate.isClear, approval == nil || !plan.gate.permitsApproval {
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
            let summary: SyncRunSummary
            do {
                summary = try await executor.execute(
                    plan,
                    runID: preparation.runID,
                    approval: approval,
                    syncSetName: preparation.syncSetName,
                    logRunBoundaryActivity: false
                )
            } catch let error as ScheduleExecutionError
                where error.requiresFreshPreparation {
                if currentPreparationRunIDs[syncSetID] == preparation.runID {
                    currentPreparationRunIDs.removeValue(forKey: syncSetID)
                }
                throw error
            }
            await appendStage("Execute", syncSetID: syncSetID, runID: preparation.runID, started: false)
            if case .mutationIndeterminate = summary.outcome {
                // The caller-visible execution phase returned, but the run is
                // deliberately unfinished until recovery reconciles the late
                // provider outcome.
            } else {
                await appendActivity(
                    syncSetID: syncSetID,
                    runID: preparation.runID,
                    category: .sync,
                    message: summary.outcome.hasWaitingExclusions
                        ? ActivityMessageCatalog.runFinishedWithExclusions
                        : ActivityMessageCatalog.runFinished,
                    detail: summary.outcome.detail
                )
            }
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
        let annotations = await advisoryAnnotations(for: outcome, syncSetID: syncSet.id, runID: runID)
        let preview = renderer.render(
            outcome: outcome,
            locations: locations,
            base: baseRecords,
            advice: annotations.advice,
            triageNotes: annotations.triageNotes,
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
            await logExclusions(plan.exclusions, syncSetID: syncSet.id, runID: runID)
        } else if case let .refusal(refusal) = outcome {
            await logRefusals(refusal.reasons, syncSetID: syncSet.id, runID: runID)
        }
        await logPreparationSummary(preview, syncSetID: syncSet.id, runID: runID)
        await appendStage("Preview", syncSetID: syncSet.id, runID: runID, started: false)

        let preparation = SyncPreparation(
            outcome: outcome,
            preview: preview,
            advice: annotations.advice,
            runID: runID,
            syncSetName: syncSet.name
        )
        currentPreparationRunIDs[syncSet.id] = runID
        return preparation
    }

    private func recoverIfNeeded(syncSetID: UUID, runID: UUID) async throws {
        await appendStage("Recovery", syncSetID: syncSetID, runID: runID, started: true)
        if let replay = try await stores.journal.unfinishedRun(for: syncSetID) {
            let report = try await RunRecovery(
                providers: providers,
                stores: stores,
                stage: contentStage,
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

    private func plan(
        _ syncSet: SyncSet,
        snapshots: [LocationSnapshot],
        baseRead: (records: [BaseRecord], unreadableDetail: String?),
        resolvedConflicts: [ConflictResolutionRecord]
    ) -> PlanOutcome {
        SyncPlanner().plan(
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
    }

    private func refineEvidenceUntilSafe(
        for syncSet: SyncSet,
        snapshots initialSnapshots: [LocationSnapshot],
        initialOutcome: PlanOutcome,
        baseRead: (records: [BaseRecord], unreadableDetail: String?),
        resolvedConflicts: [ConflictResolutionRecord]
    ) async throws -> ([LocationSnapshot], PlanOutcome) {
        var snapshots = initialSnapshots
        var outcome = initialOutcome
        var refinedKeys: Set<EvidenceTargetKey> = []

        while case let .plan(currentPlan) = outcome {
            let targets = evidenceTargets(
                for: currentPlan,
                snapshots: snapshots
            ).filter { !refinedKeys.contains($0.key) }
            guard !targets.isEmpty else {
                if let unsafe = evidenceTargets(
                    for: currentPlan,
                    snapshots: snapshots
                ).first {
                    throw EvidenceRefinementFailure(
                        location: unsafe.observation.location,
                        path: unsafe.observation.path,
                        detail: "A content-displacing operation still lacks strong version evidence."
                    )
                }
                return (snapshots, outcome)
            }

            for target in targets.sorted(by: evidenceTargetSort) {
                try Task.checkCancellation()
                guard let provider = providers[target.observation.location] else {
                    throw EvidenceRefinementFailure(
                        location: target.observation.location,
                        path: target.observation.path,
                        detail: "The provider is missing."
                    )
                }
                let refined: ItemObservation
                do {
                    refined = try await provider.refineEvidence(
                        for: target.observation
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw EvidenceRefinementFailure(
                        location: target.observation.location,
                        path: target.observation.path,
                        detail: String(describing: error)
                    )
                }
                guard refined.location == target.observation.location,
                      refined.path == target.observation.path,
                      refined.kind == target.observation.kind,
                      refined.version.hasStrongEvidence else {
                    throw EvidenceRefinementFailure(
                        location: target.observation.location,
                        path: target.observation.path,
                        detail: "The provider returned incomplete or mismatched evidence."
                    )
                }
                snapshots = replacingObservation(
                    target.observation,
                    with: refined,
                    in: snapshots
                )
                refinedKeys.insert(target.key)
            }

            outcome = plan(
                syncSet,
                snapshots: snapshots,
                baseRead: baseRead,
                resolvedConflicts: resolvedConflicts
            )
        }
        return (snapshots, outcome)
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

    private func advisoryAnnotations(
        for outcome: PlanOutcome,
        syncSetID: UUID,
        runID: UUID
    ) async -> AdvisoryAnnotations {
        guard let advisor, case let .plan(plan) = outcome, !plan.gate.isClear else {
            return AdvisoryAnnotations()
        }

        let result = await withAdvisoryTimeout(seconds: advisoryBudget.perPreparationSeconds, mode: advisoryBudget.timeoutMode) {
            await self.collectAdvisoryAnnotations(plan: plan, advisor: advisor, syncSetID: syncSetID, runID: runID)
        }
        switch result {
        case let .completed(annotations):
            return annotations
        case .timedOut:
            await logAdviceUnavailable(
                syncSetID: syncSetID,
                runID: runID,
                detail: "preparationBudgetExceeded"
            )
            return AdvisoryAnnotations()
        }
    }

    private func collectAdvisoryAnnotations(
        plan: SyncPlan,
        advisor: any ConflictAdvisor,
        syncSetID: UUID,
        runID: UUID
    ) async -> AdvisoryAnnotations {
        var annotations = AdvisoryAnnotations()
        for conflict in plan.conflicts.sorted(by: conflictSort) {
            if let advice = await conflictAdvice(for: conflict, advisor: advisor, syncSetID: syncSetID, runID: runID) {
                annotations.advice.append(advice)
            }
        }
        for hold in plan.gate.holdReasons {
            if let note = await triageNote(for: hold, plan: plan, advisor: advisor, syncSetID: syncSetID, runID: runID) {
                annotations.triageNotes.append(note)
            }
        }
        return annotations
    }

    private func conflictAdvice(
        for conflict: ConflictDecision,
        advisor: any ConflictAdvisor,
        syncSetID: UUID,
        runID: UUID
    ) async -> ConflictAdvice? {
        let request = ConflictAdvisoryRequest(
            conflict: conflict,
            locationNames: locationNames(),
            contentExcerpts: nil
        )
        let cacheKey = AdviceCacheKey(conflict: conflict, advisor: advisor.descriptor).rawValue
        if let cached = await stores.adviceCache.cachedAdvice(forKey: cacheKey) {
            switch adviceValidator.validate(cached, for: request) {
            case let .accepted(advice):
                await logAdviceShown(advice, syncSetID: syncSetID, runID: runID)
                return advice
            case let .rejected(reason):
                await logAdviceUnavailable(
                    syncSetID: syncSetID,
                    runID: runID,
                    path: conflict.path,
                    relatedConflictID: conflict.id,
                    detail: "cachedValidation.\(reason.rawValue)"
                )
                return nil
            }
        }

        let result = await withAdvisoryTimeout(seconds: advisoryBudget.perConflictSeconds, mode: advisoryBudget.timeoutMode) {
            await advisor.advise(on: request)
        }
        switch result {
        case .timedOut:
            await logAdviceUnavailable(
                syncSetID: syncSetID,
                runID: runID,
                path: conflict.path,
                relatedConflictID: conflict.id,
                detail: "timeout"
            )
            return nil

        case let .completed(rawAdvice?):
            switch adviceValidator.validate(rawAdvice, for: request) {
            case let .accepted(advice):
                await stores.adviceCache.store(advice, forKey: cacheKey)
                await logAdviceShown(advice, syncSetID: syncSetID, runID: runID)
                return advice
            case let .rejected(reason):
                await logAdviceUnavailable(
                    syncSetID: syncSetID,
                    runID: runID,
                    path: conflict.path,
                    relatedConflictID: conflict.id,
                    detail: "validation.\(reason.rawValue)"
                )
                return nil
            }

        case .completed(nil):
            await logAdviceUnavailable(
                syncSetID: syncSetID,
                runID: runID,
                path: conflict.path,
                relatedConflictID: conflict.id,
                detail: "unavailable"
            )
            return nil
        }
    }

    private func triageNote(
        for hold: HoldReason,
        plan: SyncPlan,
        advisor: any ConflictAdvisor,
        syncSetID: UUID,
        runID: UUID
    ) async -> HoldTriageNote? {
        guard let request = HoldTriageRequest(syncSetID: plan.syncSetID, holdReason: hold, locationNames: locationNames()) else {
            return nil
        }

        let result = await withAdvisoryTimeout(seconds: advisoryBudget.perConflictSeconds, mode: advisoryBudget.timeoutMode) {
            await advisor.triage(request)
        }
        switch result {
        case .timedOut:
            await logAdviceUnavailable(syncSetID: syncSetID, runID: runID, detail: "triage.timeout")
            return nil

        case let .completed(rawNote?):
            switch adviceValidator.validate(rawNote, for: request) {
            case let .accepted(note):
                await appendActivity(
                    syncSetID: syncSetID,
                    runID: runID,
                    category: .advisory,
                    message: ActivityMessageCatalog.holdTriageShown,
                    detail: "Generated by \(note.generatedBy.name) via \(note.generatedBy.backend). \(note.summary)"
                )
                return note
            case let .rejected(reason):
                await logAdviceUnavailable(syncSetID: syncSetID, runID: runID, detail: "triage.validation.\(reason.rawValue)")
                return nil
            }

        case .completed(nil):
            await logAdviceUnavailable(syncSetID: syncSetID, runID: runID, detail: "triage.unavailable")
            return nil
        }
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

    private func logExclusions(
        _ exclusions: [LocatedScanExclusion],
        syncSetID: UUID,
        runID: UUID
    ) async {
        for located in exclusions.sorted() {
            await appendActivity(
                syncSetID: syncSetID,
                runID: runID,
                category: .safety,
                locationID: located.location,
                path: located.exclusion.path,
                message: located.exclusion.reason.message,
                detail: "\(located.exclusion.scope.rawValue)|\(located.exclusion.reason.stableKey)"
            )
        }
    }

    private func logAdviceShown(_ advice: ConflictAdvice, syncSetID: UUID, runID: UUID) async {
        await appendActivity(
            syncSetID: syncSetID,
            runID: runID,
            category: .advisory,
            locationID: advice.recommended.locationID,
            message: ActivityMessageCatalog.adviceShown(
                recommendation: advice.recommended,
                locationName: advice.recommended.locationID.map { locationName($0) }
            ),
            detail: "Generated by \(advice.generatedBy.name) via \(advice.generatedBy.backend); confidence \(advice.confidence.rawValue). \(advice.rationale)",
            relatedConflictID: advice.conflictID
        )
    }

    private func logAdviceUnavailable(
        syncSetID: UUID,
        runID: UUID,
        path: SyncPath? = nil,
        relatedConflictID: UUID? = nil,
        detail: String
    ) async {
        await appendActivity(
            syncSetID: syncSetID,
            runID: runID,
            category: .advisory,
            path: path,
            message: ActivityMessageCatalog.adviceUnavailable,
            detail: detail,
            relatedConflictID: relatedConflictID
        )
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

private struct EvidenceTargetKey: Hashable, Sendable {
    var location: LocationID
    var itemID: String?
    var path: SyncPath
}

private struct EvidenceTarget: Hashable, Sendable {
    var key: EvidenceTargetKey
    var observation: ItemObservation

    init(_ observation: ItemObservation) {
        self.key = EvidenceTargetKey(
            location: observation.location,
            itemID: observation.itemID,
            path: observation.path
        )
        self.observation = observation
    }
}

private struct EvidenceRefinementFailure: Error, Sendable {
    var location: LocationID
    var path: SyncPath
    var detail: String
}

private func evidenceTargets(
    for plan: SyncPlan,
    snapshots: [LocationSnapshot]
) -> [EvidenceTarget] {
    var targets: [EvidenceTargetKey: EvidenceTarget] = [:]

    func add(_ observation: ItemObservation) {
        guard observation.kind == .file,
              !observation.version.hasStrongEvidence else {
            return
        }
        let target = EvidenceTarget(observation)
        targets[target.key] = target
    }

    func destinationObservation(
        location: LocationID,
        path: SyncPath
    ) -> ItemObservation? {
        guard let snapshot = snapshots.first(where: { $0.location == location }) else {
            return nil
        }
        return snapshot.observations.byPath[path]
            ?? snapshot.observations.byCaseFoldedPath[path.caseInsensitiveKey]
    }

    for operation in plan.schedule.operations {
        switch operation.kind {
        case let .transfer(content, path, overwrite):
            guard case .ifVersionMatches = overwrite else { continue }
            add(content.observation)
            if let destination = destinationObservation(
                location: operation.location,
                path: path
            ) {
                add(destination)
            }

        case let .relocate(itemRef, _), let .trash(itemRef):
            add(itemRef.observation)

        case .makeFolder:
            break
        }
    }
    return Array(targets.values)
}

private func replacingObservation(
    _ expected: ItemObservation,
    with refined: ItemObservation,
    in snapshots: [LocationSnapshot]
) -> [LocationSnapshot] {
    snapshots.map { snapshot in
        guard snapshot.location == expected.location else { return snapshot }
        let observations = snapshot.observations.all.map { candidate in
            let sameItem = expected.itemID != nil
                && candidate.itemID == expected.itemID
            return sameItem || candidate.path == expected.path
                ? refined
                : candidate
        }
        return LocationSnapshot(
            location: snapshot.location,
            scope: snapshot.scope,
            observations: observations,
            exclusions: snapshot.exclusions,
            status: snapshot.status,
            scannedAt: snapshot.scannedAt
        )
    }
}

private func evidenceTargetSort(
    _ lhs: EvidenceTarget,
    _ rhs: EvidenceTarget
) -> Bool {
    if lhs.observation.location != rhs.observation.location {
        return lhs.observation.location < rhs.observation.location
    }
    return lhs.observation.path < rhs.observation.path
}

private struct AdvisoryAnnotations: Sendable {
    var advice: [ConflictAdvice] = []
    var triageNotes: [HoldTriageNote] = []
}

private enum AdvisoryTimeoutResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

private func withAdvisoryTimeout<Value: Sendable>(
    seconds: TimeInterval,
    mode: AdvisoryTimeoutMode,
    operation: @escaping @Sendable () async -> Value
) async -> AdvisoryTimeoutResult<Value> {
    guard seconds > 0 || mode == .immediateAfterYield else {
        return .timedOut
    }
    return await withTaskGroup(of: AdvisoryTimeoutResult<Value>.self) { group in
        group.addTask {
            .completed(await operation())
        }
        group.addTask {
            if mode == .immediateAfterYield, seconds <= 0 {
                await Task.yield()
            } else {
                let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            return .timedOut
        }

        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
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

private extension ConflictResolutionOption {
    var locationID: LocationID? {
        if case let .makeCanonical(location) = self {
            return location
        }
        return nil
    }
}

private func conflictSort(_ lhs: ConflictDecision, _ rhs: ConflictDecision) -> Bool {
    if lhs.path != rhs.path {
        return lhs.path < rhs.path
    }
    return lhs.id.uuidString < rhs.id.uuidString
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

private extension SyncOrchestrator {
    func locationNames() -> [LocationID: String] {
        Dictionary(uniqueKeysWithValues: locations.map { ($0.key, $0.value.displayName) })
    }

    func locationName(_ locationID: LocationID) -> String {
        locations[locationID]?.displayName ?? locationID.displayName
    }
}

private extension RefusalReason {
    var locationID: LocationID? {
        switch self {
        case let .locationUnavailable(location, _),
             let .scanIncomplete(location, _),
             let .evidenceUnavailable(location, _, _):
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
        case let .evidenceUnavailable(_, path, detail):
            return "\(path.rawValue): \(detail)"
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
        case let .opaqueRelocation(evidence):
            let roots = evidence.exclusions.map { located in
                "\(located.location.rawValue.uuidString):\(located.exclusion.path.rawValue)|\(located.exclusion.scope.rawValue)|\(located.exclusion.reason.stableKey)"
            }.joined(separator: ", ")
            return "\(evidence.trackedPath.rawValue) may be inside \(roots)"
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
