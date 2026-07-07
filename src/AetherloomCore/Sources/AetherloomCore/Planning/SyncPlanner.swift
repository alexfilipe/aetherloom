import Foundation

public struct SyncPlanningInput: Sendable {
    public var syncSet: SyncSet
    public var locations: [SyncLocation]
    public var records: [BaseRecord]
    public var snapshots: [LocationSnapshot]
    public var settings: SyncSettings
    public var baseStateUnreadableDetail: String?
    public var resolvedConflicts: [ConflictResolutionRecord]

    public init(
        syncSet: SyncSet,
        locations: [SyncLocation] = [],
        records: [BaseRecord] = [],
        snapshots: [LocationSnapshot],
        settings: SyncSettings? = nil,
        baseStateUnreadableDetail: String? = nil,
        resolvedConflicts: [ConflictResolutionRecord] = []
    ) {
        self.syncSet = syncSet
        self.locations = locations
        self.records = records
        self.snapshots = snapshots
        self.settings = settings ?? syncSet.settings
        self.baseStateUnreadableDetail = baseStateUnreadableDetail
        self.resolvedConflicts = resolvedConflicts
    }
}

public struct SyncPlanner: Sendable {
    public init() {}

    public func plan(
        _ input: SyncPlanningInput,
        environment: PlanningEnvironment
    ) -> PlanOutcome {
        let locationIDs = input.syncSet.locations.sorted()
        let snapshotsByLocation = Dictionary(uniqueKeysWithValues: input.snapshots.map { ($0.location, $0) })
        let locationsByID = Dictionary(uniqueKeysWithValues: input.locations.map { ($0.id, $0) })
        let reasons = refusalReasons(
            input: input,
            locationIDs: locationIDs,
            snapshotsByLocation: snapshotsByLocation
        )
        if !reasons.isEmpty {
            return .refusal(SyncRefusal(syncSetID: input.syncSet.id, reasons: reasons, occurredAt: environment.now))
        }

        let syncSet = SyncSet(
            id: input.syncSet.id,
            name: input.syncSet.name,
            locations: input.syncSet.locations,
            mode: input.syncSet.mode,
            settings: input.settings,
            createdAt: input.syncSet.createdAt,
            updatedAt: input.syncSet.updatedAt
        )
        let reconciliationInput = ReconciliationInput(
            syncSet: syncSet,
            base: input.records,
            snapshots: snapshotsByLocation,
            environment: environment
        )
        let reconciler = Reconciler(environment: environment)
        let reconciled = foldSubtreeMoves(
            applyConflictResolutions(
                deriveFacts(reconciliationInput).map { item in
                    ReconciledItem(item: item, verdict: reconciler.reconcile(item))
                },
                resolutions: input.resolvedConflicts,
                locationIDs: locationIDs
            )
        )
        let builder = PlanLowerer(
            syncSet: syncSet,
            settings: input.settings,
            locationIDs: locationIDs,
            locationsByID: locationsByID,
            environment: environment
        )
        let lowered = builder.lower(reconciled)
        let trackedCount = max(input.records.filter { !input.settings.isExcluded(path: $0.path, kind: $0.kind) }.count, 1)
        let gate = ExecutionGate.evaluate(
            decisions: lowered.decisions,
            trackedCount: trackedCount,
            settings: input.settings,
            mode: syncSet.mode
        )
        let fingerprint = PlanFingerprint.compute(
            syncSetID: syncSet.id,
            decisions: lowered.decisions,
            schedule: lowered.schedule,
            gate: gate,
            snapshots: input.snapshots
        )

        return .plan(
            SyncPlan(
                syncSetID: syncSet.id,
                generatedAt: environment.now,
                decisions: lowered.decisions,
                schedule: lowered.schedule,
                conflicts: lowered.conflicts,
                waiting: lowered.waiting,
                gate: gate,
                fingerprint: fingerprint
            )
        )
    }

    private func refusalReasons(
        input: SyncPlanningInput,
        locationIDs: [LocationID],
        snapshotsByLocation: [LocationID: LocationSnapshot]
    ) -> [RefusalReason] {
        var reasons: [RefusalReason] = []

        if let detail = input.baseStateUnreadableDetail {
            reasons.append(.baseStateUnreadable(detail: detail))
        }

        for location in locationIDs {
            guard let snapshot = snapshotsByLocation[location] else {
                reasons.append(.locationUnavailable(location, .unknown(detail: "Missing scan snapshot.")))
                continue
            }
            switch snapshot.status {
            case .complete:
                break
            case let .unavailable(reason):
                reasons.append(.locationUnavailable(location, reason))
            case let .incomplete(reason):
                reasons.append(.scanIncomplete(location, detail: reason))
            }
        }

        return reasons
    }
}

private func applyConflictResolutions(
    _ items: [ReconciledItem],
    resolutions: [ConflictResolutionRecord],
    locationIDs: [LocationID]
) -> [ReconciledItem] {
    guard !resolutions.isEmpty else { return items }
    return items.map { item in
        guard case let .conflict(conflict) = item.verdict,
              let resolution = resolutions.first(where: { matches($0.conflict, conflict: conflict) }) else {
            return item
        }

        switch resolution.resolution {
        case .preserveAll:
            return item
        case let .makeCanonical(source):
            guard item.item.observations[source] != nil else {
                return item
            }
            return ReconciledItem(
                item: item.item,
                verdict: .propagateContent(from: source, to: Set(locationIDs.filter { $0 != source }))
            )
        }
    }
}

private func matches(_ resolved: ConflictDecision, conflict: ConflictDecision) -> Bool {
    resolved.id == conflict.id || (resolved.kind == conflict.kind && resolved.path == conflict.path)
}

private struct LoweredPlan {
    var decisions: [ItemDecision]
    var schedule: OperationSchedule
    var conflicts: [ConflictDecision]
    var waiting: [WaitingItem]
}

private struct PlanLowerer {
    let syncSet: SyncSet
    let settings: SyncSettings
    let locationIDs: [LocationID]
    let locationsByID: [LocationID: SyncLocation]
    let environment: PlanningEnvironment
    let resolver: ConflictResolver

    init(
        syncSet: SyncSet,
        settings: SyncSettings,
        locationIDs: [LocationID],
        locationsByID: [LocationID: SyncLocation],
        environment: PlanningEnvironment
    ) {
        self.syncSet = syncSet
        self.settings = settings
        self.locationIDs = locationIDs
        self.locationsByID = locationsByID
        self.environment = environment
        self.resolver = ConflictResolver(environment: environment)
    }

    func lower(_ reconciled: [ReconciledItem]) -> LoweredPlan {
        var state = LoweringState(existingPathsByLocation: existingPaths(from: reconciled))

        for (index, reconciledItem) in reconciled.sorted(by: reconciledSort).enumerated() {
            guard !reconciledItem.verdict.isInSync else { continue }
            let decisionID = decisionID(for: reconciledItem, index: index)
            let startOperationCount = state.operations.count
            lower(
                reconciledItem.verdict,
                item: reconciledItem.item,
                decisionID: decisionID,
                state: &state
            )
            let operationIDs = Array(state.operations[startOperationCount...].map(\.id))
            state.decisions.append(
                ItemDecision(
                    id: decisionID,
                    path: reconciledItem.item.primaryPath,
                    verdict: reconciledItem.verdict,
                    operations: operationIDs,
                    explanation: explanation(for: reconciledItem.verdict, item: reconciledItem.item)
                )
            )
        }

        let orderedOperations = state.operations.filter { !$0.kind.isTrash } + state.operations.filter { $0.kind.isTrash }
        let schedule = OperationSchedule(operations: orderedOperations)
        assert((try? schedule.validate(decisions: state.decisions)) != nil)
        return LoweredPlan(
            decisions: state.decisions,
            schedule: schedule,
            conflicts: state.conflicts,
            waiting: state.waiting
        )
    }

    private func lower(
        _ verdict: ItemVerdict,
        item: ReconciliationItem,
        decisionID: UUID,
        state: inout LoweringState
    ) {
        switch verdict {
        case .inSync:
            return

        case let .propagateContent(source, destinations):
            guard let sourceItem = item.observations[source] else { return }
            for destination in destinations.sorted() {
                if let destinationItem = item.observations[destination] {
                    if !matchingContent(sourceItem, destinationItem) {
                        appendOperation(
                            location: destination,
                            kind: .transfer(
                                content: ContentRef(sourceItem),
                                to: destinationItem.path,
                                overwrite: .ifVersionMatches(destinationItem.version)
                            ),
                            precondition: .versionMatches(destinationItem.version),
                            decisionID: decisionID,
                            state: &state
                        )
                    }
                } else {
                    appendOperation(
                        location: destination,
                        kind: .transfer(content: ContentRef(sourceItem), to: sourceItem.path, overwrite: .neverOverwrite),
                        precondition: .pathAbsent,
                        decisionID: decisionID,
                        state: &state
                    )
                }
            }

        case let .propagateCreation(source, destinations):
            guard let sourceItem = item.observations[source] else { return }
            for destination in destinations.sorted() {
                if sourceItem.isFolder {
                    appendOperation(
                        location: destination,
                        kind: .makeFolder(at: sourceItem.path),
                        precondition: .pathAbsent,
                        decisionID: decisionID,
                        state: &state
                    )
                } else {
                    appendOperation(
                        location: destination,
                        kind: .transfer(content: ContentRef(sourceItem), to: sourceItem.path, overwrite: .neverOverwrite),
                        precondition: .pathAbsent,
                        decisionID: decisionID,
                        state: &state
                    )
                }
            }

        case let .propagatePath(destinations, newPath):
            for destination in destinations.sorted() {
                guard let destinationItem = item.observations[destination] else { continue }
                appendOperation(
                    location: destination,
                    kind: .relocate(itemRef: ItemRef(destinationItem), to: newPath),
                    precondition: .versionMatches(destinationItem.version),
                    decisionID: decisionID,
                    state: &state
                )
            }

        case let .propagateDeletion(destinations, initiatedBy):
            lowerDeletion(
                destinations: destinations,
                initiatedBy: initiatedBy,
                item: item,
                decisionID: decisionID,
                state: &state
            )

        case let .conflict(conflict):
            state.conflicts.append(conflict)
            lowerConflictCopies(conflict: conflict, decisionID: decisionID, state: &state)

        case let .waiting(reason, locations):
            state.waiting.append(
                WaitingItem(
                    id: DeterministicID.uuid("waiting", item.primaryPath.rawValue, locations.map { $0.rawValue.uuidString }.joined()),
                    path: item.primaryPath,
                    reason: reason,
                    locations: locations.sorted()
                )
            )

        case let .compound(verdicts):
            for child in verdicts {
                lower(child, item: item, decisionID: decisionID, state: &state)
            }
        }
    }

    private func lowerDeletion(
        destinations: Set<LocationID>,
        initiatedBy: LocationID,
        item: ReconciliationItem,
        decisionID: UUID,
        state: inout LoweringState
    ) {
        switch syncSet.mode {
        case .balancedMirror, .askBeforeDeleting:
            for destination in destinations.sorted() {
                guard let destinationItem = item.observations[destination] else { continue }
                appendOperation(
                    location: destination,
                    kind: .trash(itemRef: ItemRef(destinationItem)),
                    precondition: .versionMatches(destinationItem.version),
                    decisionID: decisionID,
                    state: &state
                )
            }

        case .noDeletePropagation:
            break
        }
    }

    private func lowerConflictCopies(
        conflict: ConflictDecision,
        decisionID: UUID,
        state: inout LoweringState
    ) {
        let sourceItems = conflict.versions.map(\.observation).filter { !$0.isFolder }

        for sourceItem in sourceItems.sorted(by: itemSort) {
            for destination in locationIDs where destination != sourceItem.location {
                let conflictPath = resolver.conflictPath(
                    for: sourceItem,
                    existingPaths: state.existingPathsByLocation[destination] ?? []
                )
                state.existingPathsByLocation[destination, default: []].insert(conflictPath)
                appendOperation(
                    location: destination,
                    kind: .transfer(content: ContentRef(sourceItem), to: conflictPath, overwrite: .neverOverwrite),
                    precondition: .pathAbsent,
                    decisionID: decisionID,
                    state: &state
                )
            }
        }
    }

    private func appendOperation(
        location: LocationID,
        kind: OperationKind,
        precondition: Precondition,
        decisionID: UUID,
        state: inout LoweringState
    ) {
        let existingForDecision = state.operations.filter { state.operationDecisionIDs[$0.id] == decisionID }
        let dependencies = existingForDecision.last.map { [$0.id] } ?? []
        let operation = Operation(
            id: operationID(for: kind, location: location, decisionID: decisionID, sequence: existingForDecision.count),
            location: location,
            kind: kind,
            precondition: precondition,
            dependsOn: dependencies
        )
        state.operationDecisionIDs[operation.id] = decisionID
        state.operations.append(operation)
    }

    private func decisionID(for reconciledItem: ReconciledItem, index: Int) -> UUID {
        DeterministicID.uuid(
            "decision",
            syncSet.id.uuidString,
            String(index),
            reconciledItem.item.primaryPath.rawValue,
            String(describing: reconciledItem.verdict)
        )
    }

    private func operationID(
        for kind: OperationKind,
        location: LocationID,
        decisionID: UUID,
        sequence: Int
    ) -> OperationID {
        OperationID(
            DeterministicID.uuid(
                "operation",
                decisionID.uuidString,
                location.rawValue.uuidString,
                String(sequence),
                String(describing: kind)
            )
        )
    }

    private func existingPaths(from reconciled: [ReconciledItem]) -> [LocationID: Set<SyncPath>] {
        var paths: [LocationID: Set<SyncPath>] = [:]
        for item in reconciled {
            for observation in item.item.observations.values where !settings.isExcluded(observation) {
                paths[observation.location, default: []].insert(observation.path)
            }
        }
        return paths
    }

    private func explanation(for verdict: ItemVerdict, item: ReconciliationItem) -> String {
        switch verdict {
        case .inSync:
            return "Already in sync."
        case let .propagateContent(source, _):
            return "Changed at \(locationName(source)) since last sync."
        case let .propagateCreation(source, _):
            return "Appeared at \(locationName(source)) since last sync."
        case .propagatePath:
            return "Moved since last sync."
        case let .propagateDeletion(_, initiatedBy):
            return "Deleted from \(locationName(initiatedBy)) since last sync."
        case let .conflict(conflict):
            return conflict.message
        case .waiting:
            return "Provider unavailable"
        case let .compound(verdicts):
            return verdicts.map { explanation(for: $0, item: item) }.joined(separator: " ")
        }
    }

    private func locationName(_ id: LocationID) -> String {
        environment.locationNames[id] ?? locationsByID[id]?.displayName ?? id.displayName
    }

    private func matchingContent(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.isFolder { return true }
        return lhs.version.isSameVersion(as: rhs.version)
    }

    private func reconciledSort(_ lhs: ReconciledItem, _ rhs: ReconciledItem) -> Bool {
        lhs.item.primaryPath < rhs.item.primaryPath
    }

    private func itemSort(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.location < rhs.location
    }
}

private struct LoweringState {
    var decisions: [ItemDecision] = []
    var operations: [Operation] = []
    var operationDecisionIDs: [OperationID: UUID] = [:]
    var conflicts: [ConflictDecision] = []
    var waiting: [WaitingItem] = []
    var existingPathsByLocation: [LocationID: Set<SyncPath>]
}

private extension ItemVerdict {
    var isInSync: Bool {
        if case .inSync = self {
            return true
        }
        return false
    }
}
