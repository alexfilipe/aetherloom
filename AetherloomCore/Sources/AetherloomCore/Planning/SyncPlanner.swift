import Foundation

public struct SyncPlanningInput: Sendable {
    public var syncSet: SyncSet
    public var records: [SyncRecord]
    public var snapshots: [ProviderSnapshot]
    public var settings: SyncPlannerSettings

    public init(
        syncSet: SyncSet,
        records: [SyncRecord] = [],
        snapshots: [ProviderSnapshot],
        settings: SyncPlannerSettings = SyncPlannerSettings()
    ) {
        self.syncSet = syncSet
        self.records = records
        self.snapshots = snapshots
        self.settings = settings
    }
}

public struct SyncPlanner: Sendable {
    private let safetyAnalyzer: SafetyAnalyzer

    public init(safetyAnalyzer: SafetyAnalyzer = SafetyAnalyzer()) {
        self.safetyAnalyzer = safetyAnalyzer
    }

    public func plan(_ input: SyncPlanningInput, generatedAt: Date = Date()) -> SyncPlan {
        let providers = input.syncSet.providers.keys.sorted { $0.rawValue < $1.rawValue }
        let snapshotsByProvider = Dictionary(uniqueKeysWithValues: input.snapshots.map { ($0.provider, $0) })
        let missingSnapshots = providers.filter { snapshotsByProvider[$0] == nil }
        if let missingProvider = missingSnapshots.first {
            return pausedPlan(
                syncSetID: input.syncSet.id,
                reason: "Sync paused because \(missingProvider.displayName) has no scan snapshot. No files will be deleted while provider state is unknown.",
                provider: missingProvider
            )
        }

        for provider in providers {
            guard let snapshot = snapshotsByProvider[provider] else { continue }
            switch snapshot.status {
            case .complete:
                break
            case let .unavailable(reason):
                return pausedPlan(
                    syncSetID: input.syncSet.id,
                    reason: "Sync paused because \(provider.displayName) is unavailable. No files will be deleted while a provider is unreachable.",
                    provider: provider,
                    detail: reason
                )
            case let .incomplete(reason):
                return pausedPlan(
                    syncSetID: input.syncSet.id,
                    reason: "Sync paused because \(provider.displayName) returned an incomplete scan. No files will be deleted from an incomplete scan.",
                    provider: provider,
                    detail: reason
                )
            }
        }

        let placeholderItems = input.snapshots.flatMap(\.items).filter {
            $0.provider == .iCloudDrive && $0.isPlaceholder && !input.settings.isExcluded($0.path)
        }
        if let placeholder = placeholderItems.first {
            return pausedPlan(
                syncSetID: input.syncSet.id,
                reason: "Sync paused because \(placeholder.path.rawValue) in iCloud Drive is a placeholder. No files will be deleted while iCloud files are unavailable.",
                provider: .iCloudDrive,
                path: placeholder.path
            )
        }

        let context = PlanningContext(
            input: input,
            providers: providers,
            snapshotsByProvider: snapshotsByProvider,
            resolver: ConflictResolver(generatedAt: generatedAt)
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
            trackedItemCount: max(input.records.filter { !input.settings.isExcluded($0.canonicalPath) }.count, 1),
            settings: input.settings
        )
    }

    private func pausedPlan(
        syncSetID: UUID,
        reason: String,
        provider: ProviderID,
        detail: String? = nil,
        path: CloudPath? = nil
    ) -> SyncPlan {
        let message = detail.map { "\(reason) \($0)" } ?? reason
        return SyncPlan(
            syncSetID: syncSetID,
            actions: [.pause(reason: reason)],
            warnings: [
                SyncWarning(severity: .pause, message: message, provider: provider, path: path)
            ],
            riskLevel: .paused,
            isAutoExecutable: false
        )
    }
}

private struct PlanningContext {
    let input: SyncPlanningInput
    let providers: [ProviderID]
    let snapshotsByProvider: [ProviderID: ProviderSnapshot]
    let resolver: ConflictResolver
    var actions: [SyncAction] = []
    var warnings: [SyncWarning] = []
    var conflicts: [SyncConflict] = []
    var knownItemKeys: Set<ItemKey> = []

    private var itemsByProviderAndPath: [ProviderID: [CloudPath: CloudItem]]
    private var itemsByProviderAndInsensitivePath: [ProviderID: [String: CloudItem]]
    private var itemsByProviderAndID: [ProviderID: [String: CloudItem]]

    init(
        input: SyncPlanningInput,
        providers: [ProviderID],
        snapshotsByProvider: [ProviderID: ProviderSnapshot],
        resolver: ConflictResolver
    ) {
        self.input = input
        self.providers = providers
        self.snapshotsByProvider = snapshotsByProvider
        self.resolver = resolver
        self.itemsByProviderAndPath = [:]
        self.itemsByProviderAndInsensitivePath = [:]
        self.itemsByProviderAndID = [:]

        for provider in providers {
            let items = snapshotsByProvider[provider]?.items.filter {
                !$0.isTrashed && !input.settings.isExcluded($0.path)
            } ?? []
            itemsByProviderAndPath[provider] = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
            itemsByProviderAndInsensitivePath[provider] = Dictionary(items.map { ($0.path.caseInsensitiveKey, $0) }) { first, _ in first }
            itemsByProviderAndID[provider] = Dictionary(
                uniqueKeysWithValues: items.compactMap { item in
                    item.providerItemID.map { ($0, item) }
                }
            )
        }
    }

    mutating func processExistingRecords() {
        let records = input.records
            .filter { $0.syncSetID == input.syncSet.id }
            .filter { !input.settings.isExcluded($0.canonicalPath) }
            .sorted { $0.canonicalPath < $1.canonicalPath }

        for record in records {
            let findings = providers.map { provider in
                RecordFinding(provider: provider, item: item(for: provider, record: record))
            }
            for finding in findings {
                if let item = finding.item {
                    knownItemKeys.insert(ItemKey(provider: finding.provider, path: item.path))
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
        let allNewItems = providers.flatMap { provider -> [CloudItem] in
            (itemsByProviderAndPath[provider]?.values.map { $0 } ?? []).filter {
                !knownItemKeys.contains(ItemKey(provider: provider, path: $0.path))
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

    private mutating func handlePathChange(record: SyncRecord, findings: [RecordFinding]) -> Bool {
        let movedFindings = findings.compactMap { finding -> RecordFinding? in
            guard let item = finding.item, item.path != record.canonicalPath else { return nil }
            return finding
        }

        guard movedFindings.count == 1,
              let sourceFinding = movedFindings.first,
              let sourceItem = sourceFinding.item else {
            return false
        }

        for finding in findings where finding.provider != sourceFinding.provider {
            guard let destinationItem = finding.item, destinationItem.path == record.canonicalPath else { continue }
            if sourceItem.path.parent == record.canonicalPath.parent {
                addCaseSafeAction(
                    destination: finding.provider,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .rename(destination: finding.provider, item: destinationItem, newName: sourceItem.name)
                )
            } else {
                addCaseSafeAction(
                    destination: finding.provider,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .move(destination: finding.provider, item: destinationItem, newPath: sourceItem.path)
                )
            }
        }
        return true
    }

    private mutating func handleContentChange(record: SyncRecord, findings: [RecordFinding]) -> Bool {
        let presentFindings = findings.filter { $0.item != nil }
        let changedFindings = presentFindings.filter { finding in
            guard let item = finding.item else { return false }
            return !item.isFolder && itemChanged(item, comparedTo: record)
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

        for finding in findings where finding.provider != sourceFinding.provider {
            guard let destinationItem = finding.item else {
                addCaseSafeAction(
                    destination: finding.provider,
                    destinationPath: sourceItem.path,
                    fallbackSourceItem: sourceItem,
                    action: .upload(
                        source: sourceFinding.provider,
                        destination: finding.provider,
                        sourceItem: sourceItem,
                        destinationPath: sourceItem.path
                    )
                )
                continue
            }

            if !sameContent(sourceItem, destinationItem) {
                actions.append(
                    .overwrite(
                        source: sourceFinding.provider,
                        destination: finding.provider,
                        sourceItem: sourceItem,
                        destinationItem: destinationItem
                    )
                )
            }
        }
        return true
    }

    private mutating func handleDeletion(record: SyncRecord, findings: [RecordFinding]) {
        let present = findings.compactMap(\.item)
        let missingProviders = findings.filter { $0.item == nil }.map(\.provider)
        guard !missingProviders.isEmpty, !present.isEmpty else { return }
        guard present.allSatisfy({ !itemChanged($0, comparedTo: record) }) else { return }

        switch input.syncSet.mode {
        case .balancedMirror:
            for item in present.sorted(by: itemSort) {
                actions.append(.trash(destination: item.provider, item: item))
            }
        case .askBeforeDeleting:
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Aetherloom found deletions for \(record.canonicalPath.rawValue). Review before moving matching files to trash.",
                    path: record.canonicalPath
                )
            )
            for item in present.sorted(by: itemSort) {
                actions.append(.trash(destination: item.provider, item: item))
            }
        case .noDeletePropagation:
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "Delete propagation is disabled for \(record.canonicalPath.rawValue). No files will be moved to trash.",
                    path: record.canonicalPath
                )
            )
        }
    }

    private mutating func propagateNewItem(_ sourceItem: CloudItem) {
        for provider in providers where provider != sourceItem.provider {
            let destinationItems = itemsByProviderAndPath[provider] ?? [:]
            if let exact = destinationItems[sourceItem.path] {
                guard !sourceItem.isFolder, !exact.isFolder, !sameContent(sourceItem, exact) else { continue }
                createConflictCopy(sourceItem: sourceItem, destination: provider)
                continue
            }

            addCaseSafeAction(
                destination: provider,
                destinationPath: sourceItem.path,
                fallbackSourceItem: sourceItem,
                action: sourceItem.isFolder
                    ? .createFolder(destination: provider, path: sourceItem.path)
                    : .upload(source: sourceItem.provider, destination: provider, sourceItem: sourceItem, destinationPath: sourceItem.path)
            )
        }
    }

    private mutating func createEditConflict(record: SyncRecord, changedFindings: [RecordFinding]) {
        let changedItems = changedFindings.compactMap(\.item).sorted(by: itemSort)
        conflicts.append(
            SyncConflict(
                path: record.canonicalPath,
                providers: changedFindings.map(\.provider).sorted { $0.rawValue < $1.rawValue },
                items: changedItems,
                message: "This file changed in more than one place. Aetherloom preserved both versions."
            )
        )
        warnings.append(
            SyncWarning(
                severity: .needsReview,
                message: "This file changed in more than one place. Aetherloom preserved both versions.",
                path: record.canonicalPath
            )
        )

        for sourceItem in changedItems {
            for destination in providers where destination != sourceItem.provider {
                createConflictCopy(sourceItem: sourceItem, destination: destination)
            }
        }
    }

    private mutating func createIndependentCreationConflicts(path: CloudPath, items: [CloudItem]) {
        let sortedItems = items.sorted(by: itemSort)
        conflicts.append(
            SyncConflict(
                path: path,
                providers: sortedItems.map(\.provider),
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
            for destination in providers where destination != sourceItem.provider {
                createConflictCopy(sourceItem: sourceItem, destination: destination)
            }
        }
    }

    private mutating func createCollisionConflictCopies(sourceItem: CloudItem, preferredPath: CloudPath) {
        warnings.append(
            SyncWarning(
                severity: .needsReview,
                message: "A filename collision was found near \(preferredPath.rawValue). Aetherloom will preserve both names.",
                provider: sourceItem.provider,
                path: preferredPath
            )
        )
        for destination in providers where destination != sourceItem.provider {
            createConflictCopy(sourceItem: sourceItem, destination: destination)
        }
    }

    private mutating func createConflictCopy(sourceItem: CloudItem, destination: ProviderID) {
        let existingPaths = Set(itemsByProviderAndPath[destination]?.keys.map { $0 } ?? [])
        let conflictPath = resolver.conflictPath(for: sourceItem, existingPaths: existingPaths)
        actions.append(
            .createConflictCopy(
                source: sourceItem.provider,
                destination: destination,
                sourceItem: sourceItem,
                conflictPath: conflictPath
            )
        )
    }

    private mutating func addCaseSafeAction(
        destination: ProviderID,
        destinationPath: CloudPath,
        fallbackSourceItem: CloudItem,
        action: SyncAction
    ) {
        if let collision = itemsByProviderAndInsensitivePath[destination]?[destinationPath.caseInsensitiveKey],
           collision.path != destinationPath {
            warnings.append(
                SyncWarning(
                    severity: .needsReview,
                    message: "A case-insensitive filename collision was found at \(destinationPath.rawValue). Aetherloom will preserve both versions.",
                    provider: destination,
                    path: destinationPath
                )
            )
            createConflictCopy(sourceItem: fallbackSourceItem, destination: destination)
            return
        }
        actions.append(action)
    }

    private func item(for provider: ProviderID, record: SyncRecord) -> CloudItem? {
        if let itemID = record.itemID(for: provider),
           let item = itemsByProviderAndID[provider]?[itemID] {
            return item
        }
        return itemsByProviderAndPath[provider]?[record.canonicalPath]
    }

    private func itemChanged(_ item: CloudItem, comparedTo record: SyncRecord) -> Bool {
        if item.isPlaceholder || item.isFolder {
            return false
        }
        if let lastKnownHash = record.lastKnownHash, let contentHash = item.contentHash {
            return lastKnownHash != contentHash
        }
        if let providerRevision = record.providerRevision(for: item.provider), let itemRevision = item.revisionID ?? item.eTag ?? item.cTag {
            return providerRevision != itemRevision
        }
        if let lastKnownSize = record.lastKnownSize, let size = item.size, lastKnownSize != size {
            return true
        }
        if let lastKnownModifiedAt = record.lastKnownModifiedAt, let modifiedAt = item.modifiedAt {
            return modifiedAt != lastKnownModifiedAt
        }
        return false
    }

    private func differentContentVersions(_ items: [CloudItem]) -> Bool {
        let fileItems = items.filter { !$0.isFolder }
        guard fileItems.count > 1 else { return false }
        let signatures = Set(fileItems.map(contentSignature))
        return signatures.count > 1
    }

    private func sameContent(_ lhs: CloudItem, _ rhs: CloudItem) -> Bool {
        guard lhs.isFolder == rhs.isFolder else { return false }
        if lhs.isFolder && rhs.isFolder {
            return true
        }
        return contentSignature(lhs) == contentSignature(rhs)
    }

    private func contentSignature(_ item: CloudItem) -> String {
        if let contentHash = item.contentHash {
            return "hash:\(contentHash)"
        }
        if let size = item.size, let modifiedAt = item.modifiedAt {
            return "size:\(size):modified:\(modifiedAt.timeIntervalSince1970)"
        }
        if let versionToken = item.versionToken {
            return "version:\(versionToken)"
        }
        return "unknown:\(item.path.rawValue):\(item.provider.rawValue)"
    }

    private func itemSort(_ lhs: CloudItem, _ rhs: CloudItem) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.provider.rawValue < rhs.provider.rawValue
    }
}

private struct RecordFinding {
    var provider: ProviderID
    var item: CloudItem?
}

private struct ItemKey: Hashable {
    var provider: ProviderID
    var path: CloudPath
}
