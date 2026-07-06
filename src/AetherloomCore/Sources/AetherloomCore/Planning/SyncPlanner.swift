import Foundation

public struct SyncPlanningInput: Sendable {
    public var syncSet: SyncSet
    public var locations: [SyncLocation]
    public var records: [BaseRecord]
    public var snapshots: [LocationSnapshot]
    public var settings: SyncSettings

    public init(
        syncSet: SyncSet,
        locations: [SyncLocation] = [],
        records: [BaseRecord] = [],
        snapshots: [LocationSnapshot],
        settings: SyncSettings? = nil
    ) {
        self.syncSet = syncSet
        self.locations = locations
        self.records = records
        self.snapshots = snapshots
        self.settings = settings ?? syncSet.settings
    }
}

public struct SyncPlanner: Sendable {
    private let safetyAnalyzer: SafetyAnalyzer

    public init(safetyAnalyzer: SafetyAnalyzer = SafetyAnalyzer()) {
        self.safetyAnalyzer = safetyAnalyzer
    }

    public func plan(
        _ input: SyncPlanningInput,
        environment: PlanningEnvironment
    ) -> SyncPlan {
        let locationIDs = input.syncSet.locations.sorted()
        let snapshotsByLocation = Dictionary(uniqueKeysWithValues: input.snapshots.map { ($0.location, $0) })
        let locationsByID = Dictionary(uniqueKeysWithValues: input.locations.map { ($0.id, $0) })
        let missingSnapshots = locationIDs.filter { snapshotsByLocation[$0] == nil }
        if let missingLocation = missingSnapshots.first {
            return pausedPlan(
                syncSetID: input.syncSet.id,
                reason: "Sync paused because \(locationName(missingLocation, locationsByID: locationsByID, environment: environment)) has no scan snapshot. No files will be deleted while provider state is unknown.",
                location: missingLocation
            )
        }

        for location in locationIDs {
            guard let snapshot = snapshotsByLocation[location] else { continue }
            switch snapshot.status {
            case .complete:
                break
            case let .unavailable(reason):
                return pausedPlan(
                    syncSetID: input.syncSet.id,
                    reason: "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.",
                    location: location,
                    detail: reason.detail
                )
            case let .incomplete(reason):
                return pausedPlan(
                    syncSetID: input.syncSet.id,
                    reason: "Sync paused because \(locationName(location, locationsByID: locationsByID, environment: environment)) returned an incomplete scan. No files will be deleted from an incomplete scan.",
                    location: location,
                    detail: reason
                )
            }
        }

        let placeholderItems = input.snapshots
            .flatMap(\.observations.all)
            .filter {
                locationsByID[$0.location]?.kind == .iCloudDrive && $0.isPlaceholder && !input.settings.isExcluded($0)
            }
        if let placeholder = placeholderItems.first {
            return pausedPlan(
                syncSetID: input.syncSet.id,
                reason: "Sync paused because \(placeholder.path.rawValue) in iCloud Drive is a placeholder. No files will be deleted while iCloud files are unavailable.",
                location: placeholder.location,
                path: placeholder.path
            )
        }

        let reconciliationInput = ReconciliationInput(
            syncSet: SyncSet(
                id: input.syncSet.id,
                name: input.syncSet.name,
                locations: input.syncSet.locations,
                mode: input.syncSet.mode,
                settings: input.settings,
                createdAt: input.syncSet.createdAt,
                updatedAt: input.syncSet.updatedAt
            ),
            base: input.records,
            snapshots: snapshotsByLocation,
            environment: environment
        )
        let reconciler = Reconciler(environment: environment)
        let reconciled = foldSubtreeMoves(
            deriveFacts(reconciliationInput).map { item in
                ReconciledItem(item: item, verdict: reconciler.reconcile(item))
            }
        )
        let renderer = LegacyPlanRenderer(
            syncSet: input.syncSet,
            settings: input.settings,
            locationIDs: locationIDs,
            environment: environment
        )
        let rendered = renderer.render(reconciled)

        var plan = SyncPlan(
            syncSetID: input.syncSet.id,
            actions: rendered.actions,
            warnings: rendered.warnings,
            conflicts: rendered.conflicts
        )
        plan.riskLevel = SafetyAnalyzer.riskLevel(for: plan)
        plan.isAutoExecutable = SafetyAnalyzer.isAutoExecutable(plan)
        return safetyAnalyzer.analyze(
            plan: plan,
            trackedItemCount: max(input.records.filter { !input.settings.isExcluded(path: $0.path, kind: $0.kind) }.count, 1),
            settings: input.settings
        )
    }

    private func pausedPlan(
        syncSetID: UUID,
        reason: String,
        location: LocationID,
        detail: String? = nil,
        path: SyncPath? = nil
    ) -> SyncPlan {
        let message = detail.map { "\(reason) \($0)" } ?? reason
        return SyncPlan(
            syncSetID: syncSetID,
            actions: [.pause(reason: reason)],
            warnings: [
                SyncWarning(severity: .pause, message: message, location: location, path: path)
            ],
            riskLevel: .paused,
            isAutoExecutable: false
        )
    }

    private func locationName(
        _ id: LocationID,
        locationsByID: [LocationID: SyncLocation],
        environment: PlanningEnvironment
    ) -> String {
        environment.locationNames[id] ?? locationsByID[id]?.displayName ?? id.displayName
    }
}

private struct LegacyPlanRenderResult {
    var actions: [SyncAction] = []
    var warnings: [SyncWarning] = []
    var conflicts: [SyncConflict] = []
}

private struct LegacyPlanRenderer {
    let syncSet: SyncSet
    let settings: SyncSettings
    let locationIDs: [LocationID]
    let resolver: ConflictResolver

    init(
        syncSet: SyncSet,
        settings: SyncSettings,
        locationIDs: [LocationID],
        environment: PlanningEnvironment
    ) {
        self.syncSet = syncSet
        self.settings = settings
        self.locationIDs = locationIDs
        self.resolver = ConflictResolver(environment: environment)
    }

    func render(_ reconciled: [ReconciledItem]) -> LegacyPlanRenderResult {
        var result = LegacyPlanRenderResult()
        var existingPathsByLocation = existingPaths(from: reconciled)

        for reconciledItem in reconciled.sorted(by: reconciledSort) {
            render(
                reconciledItem.verdict,
                item: reconciledItem.item,
                result: &result,
                existingPathsByLocation: &existingPathsByLocation
            )
        }

        return result
    }

    private func render(
        _ verdict: ItemVerdict,
        item: ReconciliationItem,
        result: inout LegacyPlanRenderResult,
        existingPathsByLocation: inout [LocationID: Set<SyncPath>]
    ) {
        switch verdict {
        case .inSync:
            return

        case let .propagateContent(source, destinations):
            guard let sourceItem = item.observations[source] else { return }
            for destination in destinations.sorted() {
                if let destinationItem = item.observations[destination] {
                    if !matchingContent(sourceItem, destinationItem) {
                        result.actions.append(
                            .overwrite(
                                source: source,
                                destination: destination,
                                sourceItem: sourceItem,
                                destinationItem: destinationItem
                            )
                        )
                    }
                } else {
                    result.actions.append(
                        .upload(
                            source: source,
                            destination: destination,
                            sourceItem: sourceItem,
                            destinationPath: sourceItem.path
                        )
                    )
                }
            }

        case let .propagateCreation(source, destinations):
            guard let sourceItem = item.observations[source] else { return }
            for destination in destinations.sorted() {
                if sourceItem.isFolder {
                    result.actions.append(.createFolder(destination: destination, path: sourceItem.path))
                } else {
                    result.actions.append(
                        .upload(
                            source: source,
                            destination: destination,
                            sourceItem: sourceItem,
                            destinationPath: sourceItem.path
                        )
                    )
                }
            }

        case let .propagatePath(destinations, newPath):
            for destination in destinations.sorted() {
                guard let destinationItem = item.observations[destination] else { continue }
                if destinationItem.path.parent == newPath.parent {
                    result.actions.append(.rename(destination: destination, item: destinationItem, newName: newPath.name))
                } else {
                    result.actions.append(.move(destination: destination, item: destinationItem, newPath: newPath))
                }
            }

        case let .propagateDeletion(destinations, initiatedBy):
            renderDeletion(
                destinations: destinations,
                initiatedBy: initiatedBy,
                item: item,
                result: &result
            )

        case let .conflict(conflict):
            result.conflicts.append(conflict)
            result.warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: conflict.message,
                    path: conflict.path
                )
            )
            renderConflictCopies(
                conflict: conflict,
                result: &result,
                existingPathsByLocation: &existingPathsByLocation
            )

        case let .waiting(_, locations):
            result.warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Provider unavailable",
                    location: locations.sorted().first,
                    path: item.primaryPath
                )
            )

        case let .compound(verdicts):
            for child in verdicts {
                render(
                    child,
                    item: item,
                    result: &result,
                    existingPathsByLocation: &existingPathsByLocation
                )
            }
        }
    }

    private func renderDeletion(
        destinations: Set<LocationID>,
        initiatedBy: LocationID,
        item: ReconciliationItem,
        result: inout LegacyPlanRenderResult
    ) {
        switch syncSet.mode {
        case .balancedMirror:
            for destination in destinations.sorted() {
                if let destinationItem = item.observations[destination] {
                    result.actions.append(.trash(destination: destination, item: destinationItem))
                }
            }
        case .askBeforeDeleting:
            result.warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Aetherloom found deletions for \(item.primaryPath.rawValue). Review before moving matching files to trash.",
                    location: initiatedBy,
                    path: item.primaryPath
                )
            )
            for destination in destinations.sorted() {
                if let destinationItem = item.observations[destination] {
                    result.actions.append(.trash(destination: destination, item: destinationItem))
                }
            }
        case .noDeletePropagation:
            result.warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Delete propagation is disabled for \(item.primaryPath.rawValue). No files will be moved to trash.",
                    location: initiatedBy,
                    path: item.primaryPath
                )
            )
        }
    }

    private func renderConflictCopies(
        conflict: ConflictDecision,
        result: inout LegacyPlanRenderResult,
        existingPathsByLocation: inout [LocationID: Set<SyncPath>]
    ) {
        let sourceItems = conflict.versions.map(\.observation).filter { observation in
            if conflict.kind == .typeClash {
                return !observation.isFolder
            }
            return !observation.isFolder
        }

        for sourceItem in sourceItems.sorted(by: itemSort) {
            for destination in locationIDs where destination != sourceItem.location {
                let conflictPath = resolver.conflictPath(
                    for: sourceItem,
                    existingPaths: existingPathsByLocation[destination] ?? []
                )
                existingPathsByLocation[destination, default: []].insert(conflictPath)
                result.actions.append(
                    .createConflictCopy(
                        source: sourceItem.location,
                        destination: destination,
                        sourceItem: sourceItem,
                        conflictPath: conflictPath
                    )
                )
            }
        }
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
