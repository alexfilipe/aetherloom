import Foundation

public enum ScheduleExecutionError: Error, Equatable, Sendable {
    case missingProvider(LocationID)
    case planNeedsReview
    case invalidSchedule(String)
}

public enum SyncRunOutcome: Codable, Hashable, Sendable {
    case completed
    case stoppedForReplan(location: LocationID, path: SyncPath)
    case cancelled
    case failed(message: String)
}

public enum OperationExecutionStatus: String, Codable, Hashable, Sendable {
    case applied
    case skipped
    case failed
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
    public var perItemResults: [ItemExecutionResult]

    public init(
        runID: UUID,
        syncSetID: UUID,
        outcome: SyncRunOutcome,
        appliedOperations: [OperationExecutionRecord] = [],
        skippedOperations: [OperationExecutionRecord] = [],
        failedOperations: [OperationExecutionRecord] = [],
        perItemResults: [ItemExecutionResult] = []
    ) {
        self.runID = runID
        self.syncSetID = syncSetID
        self.outcome = outcome
        self.appliedOperations = appliedOperations
        self.skippedOperations = skippedOperations
        self.failedOperations = failedOperations
        self.perItemResults = perItemResults
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

    public func execute(_ plan: SyncPlan, runID requestedRunID: UUID? = nil) async throws -> SyncRunSummary {
        guard plan.gate.isClear else {
            throw ScheduleExecutionError.planNeedsReview
        }
        do {
            try plan.schedule.validate(decisions: plan.decisions)
        } catch {
            throw ScheduleExecutionError.invalidSchedule(String(describing: error))
        }

        let runID = requestedRunID ?? environment.makeID()
        try await stores.journal.begin(runID: runID, syncSetID: plan.syncSetID, fingerprint: plan.fingerprint)
        await appendActivity(
            syncSetID: plan.syncSetID,
            runID: runID,
            category: .sync,
            message: ActivityMessageCatalog.runStarted(locationCount: providers.count)
        )

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
                if case let .stoppedForReplan(location, path) = result.stop {
                    summaryOutcome = .stoppedForReplan(location: location, path: path)
                }
            }

            if case .stoppedForReplan = summaryOutcome {
                break
            }
        }

        if case .completed = summaryOutcome, let firstFailure = state.failedOperations.first {
            summaryOutcome = .failed(message: firstFailure.detail ?? "One or more operations failed.")
        }

        let journalOutcome: JournalRunOutcome
        switch summaryOutcome {
        case .completed:
            journalOutcome = .succeeded
        case .stoppedForReplan:
            journalOutcome = .stoppedForReplan
        case .cancelled:
            journalOutcome = .cancelled
        case .failed:
            journalOutcome = .failed
        }
        try await stores.journal.append(
            .runFinished(outcome: journalOutcome, occurredAt: environment.now(), detail: summaryOutcome.detail),
            runID: runID
        )
        await appendActivity(
            syncSetID: plan.syncSetID,
            runID: runID,
            category: .sync,
            message: ActivityMessageCatalog.runFinished,
            detail: summaryOutcome.detail
        )

        return SyncRunSummary(
            runID: runID,
            syncSetID: plan.syncSetID,
            outcome: summaryOutcome,
            appliedOperations: state.appliedOperations,
            skippedOperations: state.skippedOperations,
            failedOperations: state.failedOperations,
            perItemResults: state.itemResults.sorted { $0.path == $1.path ? $0.id.uuidString < $1.id.uuidString : $0.path < $1.path }
        )
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
                try await stores.journal.append(
                    .result(operationID: operation.id, outcome: .skippedAlreadySatisfied, occurredAt: environment.now(), detail: record.detail),
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

            let applied = try await apply(operation, provider: provider)
            switch applied {
            case let .applied(observation, staged):
                let record = OperationExecutionRecord(
                    operationID: operation.id,
                    location: operation.location,
                    path: operation.kind.targetPath,
                    status: .applied,
                    observation: observation
                )
                try await stores.journal.append(
                    .result(operationID: operation.id, outcome: .applied, occurredAt: environment.now(), detail: nil),
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
                try await stores.journal.append(
                    .result(operationID: operation.id, outcome: .failed, occurredAt: environment.now(), detail: message),
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
        } catch {
            let message = String(describing: error)
            let record = OperationExecutionRecord(
                operationID: operation.id,
                location: operation.location,
                path: operation.kind.targetPath,
                status: .failed,
                detail: message
            )
            try await stores.journal.append(
                .result(operationID: operation.id, outcome: .failed, occurredAt: environment.now(), detail: message),
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
            } catch {
                return .failed(String(describing: error))
            }

        case let .transfer(content, path, overwrite):
            do {
                let source = try self.provider(for: content.sourceLocation)
                let staged = try await stage.materialize(content, from: source)
                defer {
                    Task { await stage.release(staged) }
                }
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
    case stoppedForReplan(SyncPath)
}

private extension OperationExecutionStatus {
    var isSuccessful: Bool {
        self == .applied || self == .skipped
    }
}

private extension SyncRunOutcome {
    var detail: String? {
        switch self {
        case .completed:
            return nil
        case let .stoppedForReplan(location, path):
            return "\(location.rawValue.uuidString) \(path.rawValue)"
        case .cancelled:
            return "Cancelled."
        case let .failed(message):
            return message
        }
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
