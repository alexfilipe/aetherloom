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
                    reason: "Sync paused because \(locationName(location, locationsByID: locationsByID, environment: environment)) is unavailable. No files will be deleted while a provider is unreachable.",
                    location: location,
                    detail: reason
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
                locationsByID[$0.location]?.kind == .iCloudDrive && $0.isPlaceholder && !input.settings.isExcluded($0.path)
            }
        if let placeholder = placeholderItems.first {
            return pausedPlan(
                syncSetID: input.syncSet.id,
                reason: "Sync paused because \(placeholder.path.rawValue) in iCloud Drive is a placeholder. No files will be deleted while iCloud files are unavailable.",
                location: placeholder.location,
                path: placeholder.path
            )
        }

        let context = PlanningContext(
            input: input,
            locationIDs: locationIDs,
            snapshotsByLocation: snapshotsByLocation,
            resolver: ConflictResolver(environment: environment)
        )
        var mutableContext = context
        mutableContext.processExistingRecords()
        mutableContext.processNewItems()

        var plan = SyncPlan(
            syncSetID: input.syncSet.id,
            actions: mutableContext.actions,
            warnings: mutableContext.warnings,
            conflicts: mutableContext.conflicts
        )
        plan.riskLevel = SafetyAnalyzer.riskLevel(for: plan)
        plan.isAutoExecutable = SafetyAnalyzer.isAutoExecutable(plan)
        return safetyAnalyzer.analyze(
            plan: plan,
            trackedItemCount: max(input.records.filter { !input.settings.isExcluded($0.path) }.count, 1),
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

private struct PlanningContext {
    let input: SyncPlanningInput
    let locationIDs: [LocationID]
    let snapshotsByLocation: [LocationID: LocationSnapshot]
    let resolver: ConflictResolver
    var actions: [SyncAction] = []
    var warnings: [SyncWarning] = []
    var conflicts: [SyncConflict] = []
    var knownItemKeys: Set<ItemKey> = []

    private var itemsByLocationAndPath: [LocationID: [SyncPath: ItemObservation]]
    private var itemsByLocationAndInsensitivePath: [LocationID: [String: ItemObservation]]
    private var itemsByLocationAndID: [LocationID: [String: ItemObservation]]

    init(
        input: SyncPlanningInput,
        locationIDs: [LocationID],
        snapshotsByLocation: [LocationID: LocationSnapshot],
        resolver: ConflictResolver
    ) {
        self.input = input
        self.locationIDs = locationIDs
        self.snapshotsByLocation = snapshotsByLocation
        self.resolver = resolver
        self.itemsByLocationAndPath = [:]
        self.itemsByLocationAndInsensitivePath = [:]
        self.itemsByLocationAndID = [:]

        for location in locationIDs {
            let items = snapshotsByLocation[location]?.observations.all.filter {
                !$0.isTrashed && !input.settings.isExcluded($0.path)
            } ?? []
            itemsByLocationAndPath[location] = snapshotsByLocation[location]?.observations.byPath.filter {
                !input.settings.isExcluded($0.key) && !$0.value.isTrashed
            } ?? Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
            itemsByLocationAndInsensitivePath[location] = snapshotsByLocation[location]?.observations.byCaseFoldedPath.filter {
                !input.settings.isExcluded($0.value.path) && !$0.value.isTrashed
            } ?? Dictionary(items.map { ($0.path.caseInsensitiveKey, $0) }) { first, _ in first }
            itemsByLocationAndID[location] = snapshotsByLocation[location]?.observations.byItemID.filter {
                !input.settings.isExcluded($0.value.path) && !$0.value.isTrashed
            } ?? Dictionary(
                uniqueKeysWithValues: items.compactMap { item in
                    item.itemID.map { ($0, item) }
                }
            )
        }
    }

    mutating func processExistingRecords() {
        let records = input.records
            .filter { $0.syncSetID == input.syncSet.id }
            .filter { !input.settings.isExcluded($0.path) }
            .sorted { $0.path < $1.path }

        for record in records {
            let findings = locationIDs.map { location in
                RecordFinding(location: location, item: item(for: location, record: record))
            }
            for finding in findings {
                if let item = finding.item {
                    knownItemKeys.insert(ItemKey(location: finding.location, path: item.path))
                }
            }

            if handlePathChange(record: record, findings: findings) {
                continue
            }

            if handleContentChange(record: record, findings: findings) {
                continue
            }

            handleDeletion(record: record, findings: findings)
        }
    }

    mutating func processNewItems() {
        let allNewItems = locationIDs.flatMap { location -> [ItemObservation] in
            (itemsByLocationAndPath[location]?.values.map { $0 } ?? []).filter {
                !knownItemKeys.contains(ItemKey(location: location, path: $0.path))
            }
        }

        let groups = Dictionary(grouping: allNewItems) { $0.path.caseInsensitiveKey }
        for (_, items) in groups.sorted(by: { $0.key < $1.key }) {
            let exactGroups = Dictionary(grouping: items) { $0.path }
            if exactGroups.count > 1 {
                for item in items.sorted(by: itemSort) {
                    createCollisionConflictCopies(sourceItem: item, preferredPath: item.path)
                }
                continue
            }

            guard let path = exactGroups.keys.first,
                  let groupItems = exactGroups[path] else {
                continue
            }

            let fileItems = groupItems.filter { !$0.isFolder }
            if differentContentVersions(fileItems) {
                createIndependentCreationConflicts(path: path, items: fileItems)
                continue
            }

            guard let sourceItem = groupItems.sorted(by: itemSort).first else { continue }
            propagateNewItem(sourceItem)
        }
    }

    private mutating func handlePathChange(record: BaseRecord, findings: [RecordFinding]) -> Bool {
        let movedFindings = findings.compactMap { finding -> RecordFinding? in
            guard let item = finding.item, item.path != record.path else { return nil }
            return finding
        }

        guard movedFindings.count == 1,
              let sourceFinding = movedFindings.first,
              let sourceItem = sourceFinding.item else {
            return false
        }

        for finding in findings where finding.location != sourceFinding.location {
            guard let destinationItem = finding.item, destinationItem.path == record.path else { continue }
            if sourceItem.path.parent == record.path.parent {
                addCaseSafeAction(
                    destination: finding.location,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .rename(destination: finding.location, item: destinationItem, newName: sourceItem.name)
                )
            } else {
                addCaseSafeAction(
                    destination: finding.location,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .move(destination: finding.location, item: destinationItem, newPath: sourceItem.path)
                )
            }
        }
        return true
    }

    private mutating func handleContentChange(record: BaseRecord, findings: [RecordFinding]) -> Bool {
        let presentFindings = findings.filter { $0.item != nil }
        let changedFindings = presentFindings.filter { finding in
            guard let item = finding.item else { return false }
            return !item.isFolder && item.version.itemChanged(vs: record.version)
        }

        guard !changedFindings.isEmpty else { return false }

        let changedItems = changedFindings.compactMap(\.item)
        if changedItems.count > 1 && differentContentVersions(changedItems) {
            createEditConflict(record: record, changedFindings: changedFindings)
            return true
        }

        guard let sourceFinding = changedFindings.first,
              let sourceItem = sourceFinding.item else {
            return false
        }

        for finding in findings where finding.location != sourceFinding.location {
            guard let destinationItem = finding.item else {
                addCaseSafeAction(
                    destination: finding.location,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .upload(
                        source: sourceFinding.location,
                        destination: finding.location,
                        sourceItem: sourceItem,
                        destinationPath: sourceItem.path
                    )
                )
                continue
            }

            if !matchingContent(sourceItem, destinationItem) {
                actions.append(
                    .overwrite(
                        source: sourceFinding.location,
                        destination: finding.location,
                        sourceItem: sourceItem,
                        destinationItem: destinationItem
                    )
                )
            }
        }
        return true
    }

    private mutating func handleDeletion(record: BaseRecord, findings: [RecordFinding]) {
        let present = findings.compactMap(\.item)
        let missingLocations = findings.filter { $0.item == nil }.map(\.location)
        guard !missingLocations.isEmpty, !present.isEmpty else { return }
        guard present.allSatisfy({ !$0.version.itemChanged(vs: record.version) }) else { return }

        switch input.syncSet.mode {
        case .balancedMirror:
            for item in present.sorted(by: itemSort) {
                actions.append(.trash(destination: item.location, item: item))
            }
        case .askBeforeDeleting:
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Aetherloom found deletions for \(record.path.rawValue). Review before moving matching files to trash.",
                    path: record.path
                )
            )
            for item in present.sorted(by: itemSort) {
                actions.append(.trash(destination: item.location, item: item))
            }
        case .noDeletePropagation:
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Delete propagation is disabled for \(record.path.rawValue). No files will be moved to trash.",
                    path: record.path
                )
            )
        }
    }

    private mutating func propagateNewItem(_ sourceItem: ItemObservation) {
        for location in locationIDs where location != sourceItem.location {
            let destinationItems = itemsByLocationAndPath[location] ?? [:]
            if let exact = destinationItems[sourceItem.path] {
                guard !sourceItem.isFolder, !exact.isFolder, !matchingContent(sourceItem, exact) else { continue }
                createConflictCopy(sourceItem: sourceItem, destination: location)
                continue
            }

            addCaseSafeAction(
                destination: location,
                destinationPath: sourceItem.path,
                fallbackSourceItem: sourceItem,
                action: sourceItem.isFolder
                    ? .createFolder(destination: location, path: sourceItem.path)
                    : .upload(source: sourceItem.location, destination: location, sourceItem: sourceItem, destinationPath: sourceItem.path)
            )
        }
    }

    private mutating func createEditConflict(record: BaseRecord, changedFindings: [RecordFinding]) {
        let changedItems = changedFindings.compactMap(\.item).sorted(by: itemSort)
        conflicts.append(
            SyncConflict(
                path: record.path,
                locations: changedFindings.map(\.location).sorted(),
                items: changedItems,
                message: "This file changed in more than one place. Aetherloom preserved both versions."
            )
        )
        warnings.append(
            SyncWarning(
                severity: .needsReview,
                message: "This file changed in more than one place. Aetherloom preserved both versions.",
                path: record.path
            )
        )

        for sourceItem in changedItems {
            for destination in locationIDs where destination != sourceItem.location {
                createConflictCopy(sourceItem: sourceItem, destination: destination)
            }
        }
    }

    private mutating func createIndependentCreationConflicts(path: SyncPath, items: [ItemObservation]) {
        let sortedItems = items.sorted(by: itemSort)
        conflicts.append(
            SyncConflict(
                path: path,
                locations: sortedItems.map(\.location),
                items: sortedItems,
                message: "Different files appeared at the same path before sync. Aetherloom preserved each version."
            )
        )
        warnings.append(
            SyncWarning(
                severity: .needsReview,
                message: "Different files appeared at \(path.rawValue). Aetherloom preserved each version.",
                path: path
            )
        )

        for sourceItem in sortedItems {
            for destination in locationIDs where destination != sourceItem.location {
                createConflictCopy(sourceItem: sourceItem, destination: destination)
            }
        }
    }

    private mutating func createCollisionConflictCopies(sourceItem: ItemObservation, preferredPath: SyncPath) {
        warnings.append(
            SyncWarning(
                severity: .needsReview,
                message: "A filename collision was found near \(preferredPath.rawValue). Aetherloom will preserve both names.",
                location: sourceItem.location,
                path: preferredPath
            )
        )
        for destination in locationIDs where destination != sourceItem.location {
            createConflictCopy(sourceItem: sourceItem, destination: destination)
        }
    }

    private mutating func createConflictCopy(sourceItem: ItemObservation, destination: LocationID) {
        let existingPaths = Set(itemsByLocationAndPath[destination]?.keys.map { $0 } ?? [])
        let conflictPath = resolver.conflictPath(for: sourceItem, existingPaths: existingPaths)
        actions.append(
            .createConflictCopy(
                source: sourceItem.location,
                destination: destination,
                sourceItem: sourceItem,
                conflictPath: conflictPath
            )
        )
    }

    private mutating func addCaseSafeAction(
        destination: LocationID,
        destinationPath: SyncPath,
        fallbackSourceItem: ItemObservation,
        action: SyncAction
    ) {
        if let collision = itemsByLocationAndInsensitivePath[destination]?[destinationPath.caseInsensitiveKey],
           collision.path != destinationPath {
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "A case-insensitive filename collision was found at \(destinationPath.rawValue). Aetherloom will preserve both versions.",
                    location: destination,
                    path: destinationPath
                )
            )
            createConflictCopy(sourceItem: fallbackSourceItem, destination: destination)
            return
        }
        actions.append(action)
    }

    private func item(for location: LocationID, record: BaseRecord) -> ItemObservation? {
        if let itemID = record.itemID(for: location),
           let item = itemsByLocationAndID[location]?[itemID] {
            return item
        }
        return itemsByLocationAndPath[location]?[record.path]
    }

    private func differentContentVersions(_ items: [ItemObservation]) -> Bool {
        let fileItems = items.filter { !$0.isFolder }
        guard fileItems.count > 1 else { return false }
        for lhsIndex in fileItems.indices {
            for rhsIndex in fileItems.index(after: lhsIndex)..<fileItems.endIndex {
                if fileItems[lhsIndex].version.comparison(to: fileItems[rhsIndex].version) != .same {
                    return true
                }
            }
        }
        return false
    }

    private func matchingContent(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.isFolder { return true }
        return lhs.version.isSameVersion(as: rhs.version)
    }

    private func itemSort(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.location < rhs.location
    }
}

private struct RecordFinding {
    var location: LocationID
    var item: ItemObservation?
}

private struct ItemKey: Hashable {
    var location: LocationID
    var path: SyncPath
}
