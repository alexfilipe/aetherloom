import Foundation

public enum ScheduleExecutionError: Error, Equatable, Sendable {
    case missingProvider(LocationID)
    case planNeedsReview
    case invalidApproval(ApprovalRejectionReason)
    case invalidSchedule(String)
    case journalWriteFailed(operationID: OperationID, detail: String)
}

public enum SyncRunOutcome: Codable, Hashable, Sendable {
    case refused
    case held
    case completed
    case stoppedForReplan(location: LocationID, path: SyncPath)
    case mutationIndeterminate(
        location: LocationID,
        path: SyncPath,
        receiptID: UUID
    )
    case cancelled
    case failed(message: String)
}

public enum OperationExecutionStatus: String, Codable, Hashable, Sendable {
    case applied
    case skipped
    case failed
    case indeterminate
}

public struct OperationExecutionRecord: Codable, Hashable, Sendable {
    public var operationID: OperationID
    public var location: LocationID
    public var path: SyncPath
    public var status: OperationExecutionStatus
    public var observation: ItemObservation?
    public var detail: String?

    public init(
        operationID: OperationID,
        location: LocationID,
        path: SyncPath,
        status: OperationExecutionStatus,
        observation: ItemObservation? = nil,
        detail: String? = nil
    ) {
        self.operationID = operationID
        self.location = location
        self.path = path
        self.status = status
        self.observation = observation
        self.detail = detail
    }
}

public enum ItemExecutionStatus: String, Codable, Hashable, Sendable {
    case converged
    case failed
    case pending
}

public struct ItemExecutionResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: SyncPath
    public var status: ItemExecutionStatus
    public var record: BaseRecord?

    public init(id: UUID, path: SyncPath, status: ItemExecutionStatus, record: BaseRecord? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.record = record
    }
}

public struct SyncRunSummary: Codable, Hashable, Sendable {
    public var runID: UUID
    public var syncSetID: UUID
    public var outcome: SyncRunOutcome
    public var appliedOperations: [OperationExecutionRecord]
    public var skippedOperations: [OperationExecutionRecord]
    public var failedOperations: [OperationExecutionRecord]
    public var indeterminateOperations: [OperationExecutionRecord]
    public var perItemResults: [ItemExecutionResult]

    public init(
        runID: UUID,
        syncSetID: UUID,
        outcome: SyncRunOutcome,
        appliedOperations: [OperationExecutionRecord] = [],
        skippedOperations: [OperationExecutionRecord] = [],
        failedOperations: [OperationExecutionRecord] = [],
        indeterminateOperations: [OperationExecutionRecord] = [],
        perItemResults: [ItemExecutionResult] = []
    ) {
        self.runID = runID
        self.syncSetID = syncSetID
        self.outcome = outcome
        self.appliedOperations = appliedOperations
        self.skippedOperations = skippedOperations
        self.failedOperations = failedOperations
        self.indeterminateOperations = indeterminateOperations
        self.perItemResults = perItemResults
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case syncSetID
        case outcome
        case appliedOperations
        case skippedOperations
        case failedOperations
        case indeterminateOperations
        case perItemResults
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(UUID.self, forKey: .runID)
        syncSetID = try container.decode(UUID.self, forKey: .syncSetID)
        outcome = try container.decode(SyncRunOutcome.self, forKey: .outcome)
        appliedOperations = try container.decode(
            [OperationExecutionRecord].self,
            forKey: .appliedOperations
        )
        skippedOperations = try container.decode(
            [OperationExecutionRecord].self,
            forKey: .skippedOperations
        )
        failedOperations = try container.decode(
            [OperationExecutionRecord].self,
            forKey: .failedOperations
        )
        indeterminateOperations = try container.decodeIfPresent(
            [OperationExecutionRecord].self,
            forKey: .indeterminateOperations
        ) ?? []
        perItemResults = try container.decode(
            [ItemExecutionResult].self,
            forKey: .perItemResults
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(syncSetID, forKey: .syncSetID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(appliedOperations, forKey: .appliedOperations)
        try container.encode(skippedOperations, forKey: .skippedOperations)
        try container.encode(failedOperations, forKey: .failedOperations)
        try container.encode(indeterminateOperations, forKey: .indeterminateOperations)
        try container.encode(perItemResults, forKey: .perItemResults)
    }
}

public struct ExecutionEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var makeID: @Sendable () -> UUID
    public var maxConcurrentLocationOperations: Int

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        maxConcurrentLocationOperations: Int = 3
    ) {
        self.now = now
        self.makeID = makeID
        self.maxConcurrentLocationOperations = max(1, maxConcurrentLocationOperations)
    }
}

public struct ScheduleExecutor: Sendable {
    private let providers: [LocationID: any StorageProvider]
    private let stores: EngineStores
    private let stage: ContentStage
    private let environment: ExecutionEnvironment
    private let catalog = ActivityMessageCatalog()

    public init(
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,
        stage: ContentStage,
        environment: ExecutionEnvironment = ExecutionEnvironment()
    ) {
        self.providers = providers
        self.stores = stores
        self.stage = stage
        self.environment = environment
    }

    public func execute(
        _ plan: SyncPlan,
        runID requestedRunID: UUID? = nil,
        approval: PlanApproval? = nil,
        syncSetName: String? = nil,
        logRunBoundaryActivity: Bool = true
    ) async throws -> SyncRunSummary {
        let acceptedApproval = try authorize(plan, approval: approval)
        do {
            try plan.schedule.validate(decisions: plan.decisions)
        } catch {
            throw ScheduleExecutionError.invalidSchedule(String(describing: error))
        }

        let runID = requestedRunID ?? environment.makeID()
        try await stores.journal.begin(runID: runID, syncSetID: plan.syncSetID, fingerprint: plan.fingerprint)
        if logRunBoundaryActivity {
            await appendActivity(
                syncSetID: plan.syncSetID,
                runID: runID,
                category: .sync,
                message: ActivityMessageCatalog.runStarted(locationCount: providers.count)
            )
        }
        if acceptedApproval {
            await appendActivity(
                syncSetID: plan.syncSetID,
                runID: runID,
                category: .safety,
                message: ActivityMessageCatalog.approvalAccepted(
                    trashCount: plan.approvalTrashCount,
                    syncSetName: syncSetName ?? "this sync set"
                ),
                detail: plan.fingerprint.rawValue
            )
        }

        var state = ExecutionState(plan: plan)
        var baseRecords = try await stores.baseRecords.records(for: plan.syncSetID)
        var summaryOutcome: SyncRunOutcome = .completed

        while !state.isComplete {
            if Task.isCancelled {
                summaryOutcome = .cancelled
                break
            }

            let dependencyFailures = state.operationsBlockedByFailedDependencies()
            if !dependencyFailures.isEmpty {
                for operation in dependencyFailures {
                    let detail = "A dependency failed."
                    try await stores.journal.append(.intent(operation), runID: runID)
                    try await stores.journal.append(
                        .result(operationID: operation.id, outcome: .failed, occurredAt: environment.now(), detail: detail),
                        runID: runID
                    )
                    await appendActivity(
                        syncSetID: plan.syncSetID,
                        runID: runID,
                        category: .error,
                        locationID: operation.location,
                        path: operation.kind.targetPath,
                        message: ActivityMessageCatalog.verificationFailed,
                        detail: detail
                    )
                    let result = OperationRunResult(
                        record: OperationExecutionRecord(
                            operationID: operation.id,
                            location: operation.location,
                            path: operation.kind.targetPath,
                            status: .failed,
                            detail: detail
                        )
                    )
                    try await record(result, for: operation, plan: plan, state: &state, baseRecords: &baseRecords, runID: runID)
                }
                continue
            }

            let batch = state.nextBatch(limit: environment.maxConcurrentLocationOperations)
            guard !batch.isEmpty else {
                summaryOutcome = .failed(message: "No executable operations remained.")
                break
            }

            let batchResults = try await execute(batch, plan: plan, runID: runID)
            for (operation, result) in batchResults.sorted(by: { state.index(of: $0.operation.id) < state.index(of: $1.operation.id) }) {
                try await record(result, for: operation, plan: plan, state: &state, baseRecords: &baseRecords, runID: runID)
                if let stop = result.stop {
                    summaryOutcome = summaryOutcome.merging(stop: stop)
                }
            }

            if summaryOutcome.stopsSchedule {
                break
            }
        }

        if case .completed = summaryOutcome, let firstFailure = state.failedOperations.first {
            summaryOutcome = .failed(message: firstFailure.detail ?? "One or more operations failed.")
        }

        let journalOutcome: JournalRunOutcome?
        switch summaryOutcome {
        case .refused:
            journalOutcome = .failed
        case .held:
            journalOutcome = .cancelled
        case .completed:
            journalOutcome = .succeeded
        case .stoppedForReplan:
            journalOutcome = .stoppedForReplan
        case .mutationIndeterminate:
            // Leave the WAL unfinished. The operation has an intent and an
            // indeterminate receipt but no confirmed result; recovery must
            // establish truth before any fresh scan or plan.
            journalOutcome = nil
        case .cancelled:
            journalOutcome = .cancelled
        case .failed:
            journalOutcome = .failed
        }
        if let journalOutcome {
            try await stores.journal.append(
                .runFinished(outcome: journalOutcome, occurredAt: environment.now(), detail: summaryOutcome.detail),
                runID: runID
            )
        }
        if logRunBoundaryActivity, journalOutcome != nil {
            await appendActivity(
                syncSetID: plan.syncSetID,
                runID: runID,
                category: .sync,
                message: ActivityMessageCatalog.runFinished,
                detail: summaryOutcome.detail
            )
        }

        return SyncRunSummary(
            runID: runID,
            syncSetID: plan.syncSetID,
            outcome: summaryOutcome,
            appliedOperations: state.appliedOperations,
            skippedOperations: state.skippedOperations,
            failedOperations: state.failedOperations,
            indeterminateOperations: state.indeterminateOperations,
            perItemResults: state.itemResults.sorted { $0.path == $1.path ? $0.id.uuidString < $1.id.uuidString : $0.path < $1.path }
        )
    }

    private func authorize(_ plan: SyncPlan, approval: PlanApproval?) throws -> Bool {
        guard !plan.gate.isClear else {
            return false
        }
        guard let approval else {
            throw ScheduleExecutionError.planNeedsReview
        }
        switch approval.validate(against: plan, at: environment.now()) {
        case .accepted:
            return true
        case let .rejected(reason):
            throw ScheduleExecutionError.invalidApproval(reason)
        }
    }

    private func execute(
        _ operations: [Operation],
        plan: SyncPlan,
        runID: UUID
    ) async throws -> [(operation: Operation, result: OperationRunResult)] {
        try await withThrowingTaskGroup(of: (Operation, OperationRunResult).self) { group in
            for operation in operations {
                group.addTask {
                    let result = try await executeOperation(operation, plan: plan, runID: runID)
                    return (operation, result)
                }
            }

            var results: [(Operation, OperationRunResult)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func executeOperation(_ operation: Operation, plan: SyncPlan, runID: UUID) async throws -> OperationRunResult {
        let provider = try provider(for: operation.location)
        try await stores.journal.append(.intent(operation), runID: runID)

        do {
            let probe = try await probe(operation, provider: provider)
            switch probe {
            case let .alreadySatisfied(observation):
                let record = OperationExecutionRecord(
                    operationID: operation.id,
                    location: operation.location,
                    path: operation.kind.targetPath,
                    status: .skipped,
                    observation: observation,
                    detail: "Already satisfied."
                )
                try await appendJournal(
                    .result(operationID: operation.id, outcome: .skippedAlreadySatisfied, occurredAt: environment.now(), detail: record.detail),
                    for: operation,
                    runID: runID
                )
                return OperationRunResult(record: record, sourceObservation: sourceObservation(for: operation, staged: nil))

            case .needsApply:
                break

            case let .preconditionMismatch(path):
                await appendActivity(
                    syncSetID: plan.syncSetID,
                    runID: runID,
                    category: .safety,
                    locationID: operation.location,
                    path: path,
                    message: ActivityMessageCatalog.stoppedForReplan
                )
                return OperationRunResult(
                    record: OperationExecutionRecord(
                        operationID: operation.id,
                        location: operation.location,
                        path: path,
                        status: .failed,
                        detail: ActivityMessageCatalog.stoppedForReplan
                    ),
                    stop: .stoppedForReplan(location: operation.location, path: path)
                )
            }

            let applied = try await ProviderMutationExecutionContext.$correlation
                .withValue(
                    ProviderMutationCorrelation(
                        runID: runID,
                        operationID: operation.id
                    )
                ) {
                    try await apply(operation, provider: provider)
                }
            switch applied {
            case let .applied(observation, staged):
                let record = OperationExecutionRecord(
                    operationID: operation.id,
                    location: operation.location,
                    path: operation.kind.targetPath,
                    status: .applied,
                    observation: observation
                )
                try await appendJournal(
                    .result(operationID: operation.id, outcome: .applied, occurredAt: environment.now(), detail: nil),
                    for: operation,
                    runID: runID
                )
                await stores.activity.append(catalog.entry(for: operation, syncSetID: plan.syncSetID, runID: runID, occurredAt: environment.now()))
                return OperationRunResult(record: record, sourceObservation: sourceObservation(for: operation, staged: staged))

            case let .failed(message):
                let record = OperationExecutionRecord(
                    operationID: operation.id,
                    location: operation.location,
                    path: operation.kind.targetPath,
                    status: .failed,
                    detail: message
                )
                try await appendJournal(
                    .result(operationID: operation.id, outcome: .failed, occurredAt: environment.now(), detail: message),
                    for: operation,
                    runID: runID
                )
                await appendActivity(
                    syncSetID: plan.syncSetID,
                    runID: runID,
                    category: .error,
                    locationID: operation.location,
                    path: operation.kind.targetPath,
                    message: ActivityMessageCatalog.verificationFailed,
                    detail: message
                )
                return OperationRunResult(record: record)

            case let .deadlineExpiredBeforeStart(path):
                let detail = "Mutation deadline expired before filesystem work started."
                let record = OperationExecutionRecord(
                    operationID: operation.id,
                    location: operation.location,
                    path: path,
                    status: .failed,
                    detail: detail
                )
                try await appendJournal(
                    .result(
                        operationID: operation.id,
                        outcome: .deadlineExpiredBeforeStart,
                        occurredAt: environment.now(),
                        detail: detail
                    ),
                    for: operation,
                    runID: runID
                )
                await appendActivity(
                    syncSetID: plan.syncSetID,
                    runID: runID,
                    category: .safety,
                    locationID: operation.location,
                    path: path,
                    message: ActivityMessageCatalog.mutationDeadlineExpiredBeforeStart,
                    detail: detail
                )
                return OperationRunResult(record: record)

            case let .indeterminate(receipt):
                // Receipt paths are ordered with the provider-owned primary
                // path first (relocate is source, then destination). A legacy
                // malformed empty list falls back conservatively to operation
                // context, while recovery will still reject that receipt.
                let location = receipt.provider
                let path = receipt.affectedPaths.first ?? operation.kind.targetPath
                let destinationContext = operation.location == location
                    && operation.kind.targetPath == path
                    ? ""
                    : " Destination operation: \(operation.location.rawValue.uuidString) \(operation.kind.targetPath.rawValue)."
                let detail = "Filesystem mutation exceeded its deadline after starting; recovery must reconcile receipt \(receipt.id.uuidString).\(destinationContext)"
                try await appendJournal(
                    .mutationIndeterminate(
                        operationID: operation.id,
                        receipt: receipt,
                        occurredAt: environment.now()
                    ),
                    for: operation,
                    runID: runID
                )
                await appendActivity(
                    syncSetID: plan.syncSetID,
                    runID: runID,
                    category: .safety,
                    locationID: location,
                    path: path,
                    message: ActivityMessageCatalog.mutationIndeterminate,
                    detail: detail
                )
                return OperationRunResult(
                    record: OperationExecutionRecord(
                        operationID: operation.id,
                        location: location,
                        path: path,
                        status: .indeterminate,
                        detail: detail
                    ),
                    stop: .mutationIndeterminate(
                        location: location,
                        path: path,
                        receiptID: receipt.id
                    )
                )

            case let .stoppedForReplan(path):
                await appendActivity(
                    syncSetID: plan.syncSetID,
                    runID: runID,
                    category: .safety,
                    locationID: operation.location,
                    path: path,
                    message: ActivityMessageCatalog.stoppedForReplan
                )
                return OperationRunResult(
                    record: OperationExecutionRecord(
                        operationID: operation.id,
                        location: operation.location,
                        path: path,
                        status: .failed,
                        detail: ActivityMessageCatalog.stoppedForReplan
                    ),
                    stop: .stoppedForReplan(location: operation.location, path: path)
                )
            }
        } catch let error as ScheduleExecutionError {
            if case .journalWriteFailed = error {
                // The intent remains the only durable fact. Never convert a
                // WAL failure into a terminal provider failure after apply
                // may have started or completed.
                throw error
            }
            return try await recordProviderFailure(
                error,
                operation: operation,
                plan: plan,
                runID: runID
            )
        } catch {
            return try await recordProviderFailure(
                error,
                operation: operation,
                plan: plan,
                runID: runID
            )
        }
    }

    private func recordProviderFailure(
        _ error: any Error,
        operation: Operation,
        plan: SyncPlan,
        runID: UUID
    ) async throws -> OperationRunResult {
        let message = String(describing: error)
        let record = OperationExecutionRecord(
            operationID: operation.id,
            location: operation.location,
            path: operation.kind.targetPath,
            status: .failed,
            detail: message
        )
        try await appendJournal(
            .result(operationID: operation.id, outcome: .failed, occurredAt: environment.now(), detail: message),
            for: operation,
            runID: runID
        )
        await appendActivity(
            syncSetID: plan.syncSetID,
            runID: runID,
            category: .error,
            locationID: operation.location,
            path: operation.kind.targetPath,
            message: ActivityMessageCatalog.verificationFailed,
            detail: message
        )
        return OperationRunResult(record: record)
    }

    private func appendJournal(
        _ event: JournalEvent,
        for operation: Operation,
        runID: UUID
    ) async throws {
        do {
            try await stores.journal.append(event, runID: runID)
        } catch {
            throw ScheduleExecutionError.journalWriteFailed(
                operationID: operation.id,
                detail: String(describing: error)
            )
        }
    }

    private func record(
        _ result: OperationRunResult,
        for operation: Operation,
        plan: SyncPlan,
        state: inout ExecutionState,
        baseRecords: inout [BaseRecord],
        runID: UUID
    ) async throws {
        state.record(result, for: operation)
        guard result.stop == nil else { return }
        try await convergeReadyItems(plan: plan, state: &state, baseRecords: &baseRecords, runID: runID)
    }

    private func convergeReadyItems(
        plan: SyncPlan,
        state: inout ExecutionState,
        baseRecords: inout [BaseRecord],
        runID: UUID
    ) async throws {
        for decision in plan.decisions.sorted(by: { $0.path == $1.path ? $0.id.uuidString < $1.id.uuidString : $0.path < $1.path }) {
            guard !state.convergedDecisions.contains(decision.id), !decision.operations.isEmpty else { continue }
            let records = decision.operations.compactMap { state.resultsByOperation[$0] }
            guard records.count == decision.operations.count else { continue }
            guard records.allSatisfy({ $0.record.status == .applied || $0.record.status == .skipped }) else {
                if records.contains(where: { $0.record.status == .failed }) {
                    state.convergedDecisions.insert(decision.id)
                    state.itemResults.append(ItemExecutionResult(id: decision.id, path: decision.path, status: .failed))
                }
                continue
            }

            // Conflict-copy transfers preserve divergent user data, but they do
            // not establish a new canonical path or version. Keep the last
            // genuinely converged base record until the user chooses a
            // resolution; otherwise conflict-copy observations can overwrite
            // canonical bookkeeping and make the resolution plan self-conflict.
            if decision.verdict.containsConflictPreservation {
                state.convergedDecisions.insert(decision.id)
                state.itemResults.append(
                    ItemExecutionResult(
                        id: decision.id,
                        path: decision.path,
                        status: .converged
                    )
                )
                continue
            }

            let record = makeBaseRecord(for: decision, plan: plan, state: state, baseRecords: baseRecords)
            try await stores.journal.append(.itemConverged(decisionID: decision.id, record: record), runID: runID)
            if decision.isFullyTrashed {
                if baseRecords.contains(where: { $0.id == record.id || $0.path == decision.path }) {
                    try await stores.baseRecords.apply(
                        .tombstone(
                            syncSetID: plan.syncSetID,
                            recordID: record.id,
                            deletedAt: environment.now(),
                            initiatedBy: decision.deletionInitiator
                        )
                    )
                } else {
                    try await stores.baseRecords.apply(.upsert(record))
                }
            } else {
                try await stores.baseRecords.apply(.upsert(record))
            }
            baseRecords = try await stores.baseRecords.records(for: plan.syncSetID)
            state.convergedDecisions.insert(decision.id)
            state.itemResults.append(ItemExecutionResult(id: decision.id, path: record.path, status: .converged, record: record))
        }
    }

    private func makeBaseRecord(
        for decision: ItemDecision,
        plan: SyncPlan,
        state: ExecutionState,
        baseRecords: [BaseRecord]
    ) -> BaseRecord {
        let operations = state.operations(for: decision)
        let observations = observationsForRecord(decision: decision, operations: operations, state: state)
        let existing = matchingBaseRecord(decision: decision, observations: observations, baseRecords: baseRecords)
        let now = environment.now()
        let kind = observations.sorted { $0.location < $1.location }.first?.kind ?? existing?.kind ?? .file
        let version = observations.first(where: { !$0.isTrashed && !$0.isFolder })?.version
            ?? observations.first(where: { !$0.isTrashed })?.version
            ?? existing?.version
            ?? ItemVersion()
        let path = observations.first(where: { !$0.isTrashed })?.path
            ?? existing?.path
            ?? decision.path
        let perLocation = Dictionary(uniqueKeysWithValues: observations.map { observation in
            (
                observation.location,
                LocationMemory(
                    itemID: observation.itemID,
                    revisionToken: observation.version.revisionToken,
                    lastSeenAt: now
                )
            )
        })

        return BaseRecord(
            id: existing?.id ?? environment.makeID(),
            syncSetID: plan.syncSetID,
            path: path,
            kind: kind,
            version: version,
            perLocation: perLocation,
            tombstone: decision.isFullyTrashed ? Tombstone(deletedAt: now, initiatedBy: decision.deletionInitiator) : nil,
            lastConvergedAt: now,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func observationsForRecord(
        decision: ItemDecision,
        operations: [Operation],
        state: ExecutionState
    ) -> [ItemObservation] {
        var observationsByLocation: [LocationID: ItemObservation] = [:]
        for operation in operations {
            if let source = state.resultsByOperation[operation.id]?.sourceObservation {
                observationsByLocation[source.location] = source
            }
            if let observation = state.resultsByOperation[operation.id]?.record.observation {
                observationsByLocation[observation.location] = observation
            }
        }
        return observationsByLocation.values.sorted { $0.location < $1.location }
    }

    private func matchingBaseRecord(
        decision: ItemDecision,
        observations: [ItemObservation],
        baseRecords: [BaseRecord]
    ) -> BaseRecord? {
        if let byPath = baseRecords.first(where: { $0.path == decision.path }) {
            return byPath
        }
        let itemIDs = Set(observations.compactMap(\.itemID))
        return baseRecords.first { record in
            record.perLocation.values.contains { memory in
                memory.itemID.map { itemIDs.contains($0) } ?? false
            }
        }
    }

    private func probe(_ operation: Operation, provider: any StorageProvider) async throws -> ProbeResult {
        switch operation.kind {
        case let .makeFolder(path):
            do {
                let current = try await provider.currentState(of: ItemObservation(location: operation.location, path: path, kind: .folder))
                if current.isFolder && !current.isTrashed {
                    return .alreadySatisfied(current)
                }
                return .preconditionMismatch(path)
            } catch ProviderError.notFound {
                return .needsApply
            }

        case let .transfer(content, path, _):
            do {
                let current = try await provider.currentState(of: ItemObservation(location: operation.location, path: path, kind: content.kind))
                if matchingContent(current.version, content.expectedVersion) {
                    return .alreadySatisfied(current)
                }
                switch operation.precondition {
                case .pathAbsent:
                    return .preconditionMismatch(path)
                case let .versionMatches(expected):
                    return current.version.isSameVersion(as: expected) ? .needsApply : .preconditionMismatch(path)
                case .folderPresent:
                    return current.isFolder ? .needsApply : .preconditionMismatch(path)
                }
            } catch ProviderError.notFound {
                return operation.precondition == .pathAbsent ? .needsApply : .preconditionMismatch(path)
            }

        case let .relocate(itemRef, newPath):
            do {
                let current = try await provider.currentState(of: itemRef.observation)
                if current.path == newPath {
                    return .alreadySatisfied(current)
                }
                return matchingObservationVersion(current, itemRef.observation) ? .needsApply : .preconditionMismatch(itemRef.path)
            } catch ProviderError.notFound {
                return .preconditionMismatch(itemRef.path)
            }

        case let .trash(itemRef):
            do {
                let current = try await provider.currentState(of: itemRef.observation)
                if current.isTrashed {
                    return .alreadySatisfied(current)
                }
                return matchingObservationVersion(current, itemRef.observation) ? .needsApply : .preconditionMismatch(itemRef.path)
            } catch ProviderError.notFound {
                return .alreadySatisfied(nil)
            }
        }
    }

    private func apply(_ operation: Operation, provider: any StorageProvider) async throws -> ApplyResult {
        switch operation.kind {
        case let .makeFolder(path):
            do {
                let made = try await provider.makeFolder(at: path)
                let verified = try await provider.currentState(of: made)
                guard verified.isFolder, !verified.isTrashed else {
                    return .failed("Folder verification failed at \(path.rawValue).")
                }
                return .applied(verified, staged: nil)
            } catch ProviderError.mutationDeadlineExpiredBeforeStart {
                return .deadlineExpiredBeforeStart(path)
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return .indeterminate(receipt)
            } catch {
                return .failed(String(describing: error))
            }

        case let .transfer(content, path, overwrite):
            var materialized: StagedContent?
            var releaseMaterialized = true
            defer {
                if releaseMaterialized, let materialized {
                    Task { await stage.release(materialized) }
                }
            }
            do {
                let source = try self.provider(for: content.sourceLocation)
                let staged = try await stage.materialize(content, from: source)
                materialized = staged
                let stored = try await provider.store(from: staged.url, at: path, options: StoreOptions(overwrite: overwrite))
                let verified = try await provider.currentState(of: stored)
                guard verified.kind == content.kind, !verified.isTrashed else {
                    return .failed("Stored item kind could not be verified at \(path.rawValue).")
                }
                if let size = verified.version.size, size != staged.size {
                    return .failed("Stored item size was \(size), expected \(staged.size).")
                }
                if let providerHash = verified.version.contentHash, let stagedHash = staged.verifiedHash, providerHash != stagedHash {
                    return .failed("Stored item hash was \(providerHash), expected \(stagedHash).")
                }
                return .applied(verified.upgraded(with: staged), staged: staged)
            } catch ProviderError.mutationDeadlineExpiredBeforeStart {
                return .deadlineExpiredBeforeStart(path)
            } catch let ProviderError.mutationIndeterminate(receipt) {
                // The local provider may still be reading the staged file.
                // Tie its pin to the durable receipt so recovery releases it
                // only after the late task is quiescent and reconciled.
                if let materialized {
                    await stage.deferRelease(materialized, for: receipt)
                    releaseMaterialized = false
                }
                return .indeterminate(receipt)
            } catch ProviderError.preconditionFailed {
                return .stoppedForReplan(path)
            } catch ProviderError.itemAlreadyExists {
                return .stoppedForReplan(path)
            } catch {
                return .failed(String(describing: error))
            }

        case let .relocate(itemRef, newPath):
            do {
                let current = try await provider.currentState(of: itemRef.observation)
                let relocated = try await provider.relocate(current, to: newPath)
                let verified = try await provider.currentState(of: relocated)
                guard verified.path == newPath, !verified.isTrashed else {
                    return .failed("Relocate verification failed at \(newPath.rawValue).")
                }
                return .applied(verified, staged: nil)
            } catch ProviderError.mutationDeadlineExpiredBeforeStart {
                return .deadlineExpiredBeforeStart(newPath)
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return .indeterminate(receipt)
            } catch ProviderError.preconditionFailed {
                return .stoppedForReplan(itemRef.path)
            } catch ProviderError.itemAlreadyExists {
                return .stoppedForReplan(newPath)
            } catch {
                return .failed(String(describing: error))
            }

        case let .trash(itemRef):
            do {
                let current = try await provider.currentState(of: itemRef.observation)
                try await provider.trash(current)
                let verified = try await provider.currentState(of: current)
                guard verified.isTrashed else {
                    return .failed("Trash verification failed at \(itemRef.path.rawValue).")
                }
                return .applied(verified, staged: nil)
            } catch ProviderError.mutationDeadlineExpiredBeforeStart {
                return .deadlineExpiredBeforeStart(itemRef.path)
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return .indeterminate(receipt)
            } catch ProviderError.notFound {
                return .applied(itemRef.observation.trashed(), staged: nil)
            } catch ProviderError.preconditionFailed {
                return .stoppedForReplan(itemRef.path)
            } catch {
                return .failed(String(describing: error))
            }
        }
    }

    private func provider(for id: LocationID) throws -> any StorageProvider {
        guard let provider = providers[id] else {
            throw ScheduleExecutionError.missingProvider(id)
        }
        return provider
    }

    private func appendActivity(
        syncSetID: UUID,
        runID: UUID,
        category: ActivityCategory,
        locationID: LocationID? = nil,
        path: SyncPath? = nil,
        message: String,
        detail: String? = nil
    ) async {
        await stores.activity.append(
            ActivityEntry(
                occurredAt: environment.now(),
                syncSetID: syncSetID,
                runID: runID,
                category: category,
                locationID: locationID,
                path: path,
                message: message,
                detail: detail
            )
        )
    }
}

private extension ItemVerdict {
    var containsConflictPreservation: Bool {
        switch self {
        case .conflict:
            return true
        case let .compound(verdicts):
            return verdicts.contains { $0.containsConflictPreservation }
        case .inSync, .propagateContent, .propagateCreation, .propagatePath,
             .propagateDeletion, .waiting:
            return false
        }
    }
}

private struct ExecutionState {
    let operations: [Operation]
    let indexes: [OperationID: Int]
    let decisionsByOperation: [OperationID: ItemDecision]
    var resultsByOperation: [OperationID: OperationRunResult] = [:]
    var convergedDecisions: Set<UUID> = []
    var itemResults: [ItemExecutionResult] = []

    init(plan: SyncPlan) {
        self.operations = plan.schedule.operations
        self.indexes = Dictionary(uniqueKeysWithValues: plan.schedule.operations.enumerated().map { ($0.element.id, $0.offset) })
        var decisionMap: [OperationID: ItemDecision] = [:]
        for decision in plan.decisions {
            for operationID in decision.operations {
                decisionMap[operationID] = decision
            }
        }
        self.decisionsByOperation = decisionMap
    }

    var isComplete: Bool {
        resultsByOperation.count == operations.count
    }

    var appliedOperations: [OperationExecutionRecord] {
        records(with: .applied)
    }

    var skippedOperations: [OperationExecutionRecord] {
        records(with: .skipped)
    }

    var failedOperations: [OperationExecutionRecord] {
        records(with: .failed)
    }

    var indeterminateOperations: [OperationExecutionRecord] {
        records(with: .indeterminate)
    }

    func index(of operationID: OperationID) -> Int {
        indexes[operationID] ?? Int.max
    }

    func operations(for decision: ItemDecision) -> [Operation] {
        decision.operations.compactMap { operationID in
            operations.first { $0.id == operationID }
        }
    }

    mutating func record(_ result: OperationRunResult, for operation: Operation) {
        resultsByOperation[operation.id] = result
    }

    func nextBatch(limit: Int) -> [Operation] {
        let remaining = operations.filter { resultsByOperation[$0.id] == nil }
        let hasPendingNonTrash = remaining.contains { !$0.kind.isTrash }
        var seenLocations: Set<LocationID> = []
        var batch: [Operation] = []

        for operation in remaining {
            guard operation.dependsOn.allSatisfy({ dependency in
                resultsByOperation[dependency]?.record.status.isSuccessful == true
            }) else {
                continue
            }
            if hasPendingNonTrash, operation.kind.isTrash {
                continue
            }
            guard !seenLocations.contains(operation.location) else {
                continue
            }
            seenLocations.insert(operation.location)
            batch.append(operation)
            if batch.count >= limit {
                break
            }
        }

        return batch
    }

    func operationsBlockedByFailedDependencies() -> [Operation] {
        operations.filter { operation in
            guard resultsByOperation[operation.id] == nil else { return false }
            return operation.dependsOn.contains { dependency in
                resultsByOperation[dependency]?.record.status == .failed
            }
        }
    }

    private func records(with status: OperationExecutionStatus) -> [OperationExecutionRecord] {
        operations.compactMap { operation in
            guard let result = resultsByOperation[operation.id]?.record, result.status == status else { return nil }
            return result
        }
    }
}

private struct OperationRunResult: Sendable {
    var record: OperationExecutionRecord
    var sourceObservation: ItemObservation?
    var stop: SyncRunOutcome?

    init(record: OperationExecutionRecord, sourceObservation: ItemObservation? = nil, stop: SyncRunOutcome? = nil) {
        self.record = record
        self.sourceObservation = sourceObservation
        self.stop = stop
    }
}

private enum ProbeResult: Sendable {
    case needsApply
    case alreadySatisfied(ItemObservation?)
    case preconditionMismatch(SyncPath)
}

private enum ApplyResult: Sendable {
    case applied(ItemObservation, staged: StagedContent?)
    case failed(String)
    case deadlineExpiredBeforeStart(SyncPath)
    case indeterminate(ProviderMutationReceipt)
    case stoppedForReplan(SyncPath)
}

private extension OperationExecutionStatus {
    var isSuccessful: Bool {
        self == .applied || self == .skipped
    }
}

extension SyncRunOutcome {
    var detail: String? {
        switch self {
        case .refused:
            return "Refused."
        case .held:
            return "Held for review."
        case .completed:
            return nil
        case let .stoppedForReplan(location, path):
            return "\(location.rawValue.uuidString) \(path.rawValue)"
        case let .mutationIndeterminate(location, path, receiptID):
            return "\(location.rawValue.uuidString) \(path.rawValue) receipt \(receiptID.uuidString)"
        case .cancelled:
            return "Cancelled."
        case let .failed(message):
            return message
        }
    }

    fileprivate var stopsSchedule: Bool {
        switch self {
        case .stoppedForReplan, .mutationIndeterminate:
            return true
        case .refused, .held, .completed, .cancelled, .failed:
            return false
        }
    }

    fileprivate func merging(stop candidate: SyncRunOutcome) -> SyncRunOutcome {
        if case .mutationIndeterminate = self {
            return self
        }
        if case .mutationIndeterminate = candidate {
            return candidate
        }
        return candidate
    }
}

private extension ItemDecision {
    var isFullyTrashed: Bool {
        !operations.isEmpty && verdict.containsDeletionIntent
    }

    var deletionInitiator: LocationID? {
        verdict.deletionInitiator
    }
}

private extension ItemVerdict {
    var deletionInitiator: LocationID? {
        switch self {
        case let .propagateDeletion(_, initiatedBy):
            return initiatedBy
        case let .compound(verdicts):
            return verdicts.compactMap(\.deletionInitiator).first
        case .inSync, .propagateContent, .propagateCreation, .propagatePath, .conflict, .waiting:
            return nil
        }
    }
}

private extension ItemObservation {
    func upgraded(with staged: StagedContent) -> ItemObservation {
        var copy = self
        copy.version.contentHash = copy.version.contentHash ?? staged.verifiedHash
        copy.version.size = copy.version.size ?? staged.size
        return copy
    }

    func trashed() -> ItemObservation {
        var copy = self
        copy.isTrashed = true
        return copy
    }
}

private func sourceObservation(for operation: Operation, staged: StagedContent?) -> ItemObservation? {
    guard case let .transfer(content, _, _) = operation.kind else { return nil }
    var observation = content.observation
    if let staged {
        observation.version.contentHash = observation.version.contentHash ?? staged.verifiedHash
        observation.version.size = observation.version.size ?? staged.size
    }
    return observation
}

private func matchingObservationVersion(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
    if lhs.itemID != nil && rhs.itemID != nil && lhs.itemID != rhs.itemID {
        return false
    }
    return lhs.version.isSameVersion(as: rhs.version)
}

private func matchingContent(_ lhs: ItemVersion, _ rhs: ItemVersion) -> Bool {
    lhs.isSameVersion(as: rhs)
}
