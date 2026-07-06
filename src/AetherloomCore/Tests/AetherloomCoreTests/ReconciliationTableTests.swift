import Foundation
import Testing
@testable import AetherloomCore

@Test func row01_allMatchBase_inSync() {
    let verdict = reconcileTracked([
        .localFolder: .matchesBase,
        .nasFolder: .matchesBase
    ])

    #expect(isInSync(verdict))
}

@Test func row02_oneChanged_propagatesContent() {
    let verdict = reconcileTracked([
        .localFolder: .changed(version("new")),
        .nasFolder: .matchesBase,
        .googleDrive: .matchesBase
    ])

    #expect(hasContent(verdict, from: .localFolder, to: [.nasFolder, .googleDrive]))
}

@Test func row03_convergentEdits_inSync() {
    let converged = version("same")
    let verdict = reconcileTracked([
        .localFolder: .changed(converged),
        .nasFolder: .changed(converged),
        .googleDrive: .matchesBase
    ])

    #expect(isInSync(verdict))
}

@Test func row04_divergentEdits_conflict() {
    let verdict = reconcileTracked([
        .localFolder: .changed(version("local")),
        .nasFolder: .changed(version("nas")),
        .googleDrive: .matchesBase
    ])

    #expect(conflictKind(verdict) == .editEdit)
}

@Test func row05_oneRelocated_propagatesPath() {
    let verdict = reconcileTracked([
        .localFolder: .relocated(to: "/Moved.txt"),
        .nasFolder: .matchesBase,
        .googleDrive: .matchesBase
    ])

    #expect(hasPath(verdict, to: [.nasFolder, .googleDrive], newPath: "/Moved.txt"))
}

@Test func row06_convergentRelocations_inSync() {
    let verdict = reconcileTracked([
        .localFolder: .relocated(to: "/Moved.txt"),
        .nasFolder: .relocated(to: "/Moved.txt"),
        .googleDrive: .matchesBase
    ])

    #expect(isInSync(verdict))
}

@Test func row07_divergentRelocations_conflict() {
    let verdict = reconcileTracked([
        .localFolder: .relocated(to: "/Local.txt"),
        .nasFolder: .relocated(to: "/NAS.txt"),
        .googleDrive: .matchesBase
    ])

    #expect(conflictKind(verdict) == .moveMove)
}

@Test func row08_changedAndRelocated_propagatesContentAndPath() {
    let verdict = reconcileTracked([
        .localFolder: .changedAndRelocated(version("new"), to: "/Moved.txt"),
        .nasFolder: .matchesBase,
        .googleDrive: .matchesBase
    ])

    #expect(hasContent(verdict, from: .localFolder, to: [.nasFolder, .googleDrive]))
    #expect(hasPath(verdict, to: [.nasFolder, .googleDrive], newPath: "/Moved.txt"))
}

@Test func row09_missingWithMatchingPresent_propagatesDeletion() {
    let verdict = reconcileTracked([
        .localFolder: .missing,
        .nasFolder: .matchesBase,
        .googleDrive: .matchesBase
    ])

    #expect(hasDeletion(verdict, to: [.nasFolder, .googleDrive], initiatedBy: .localFolder))
}

@Test func row10_editDelete_preservesEditAndDoesNotDelete() async throws {
    let verdict = reconcileTracked([
        .localFolder: .missing,
        .nasFolder: .changed(version("nas")),
        .googleDrive: .matchesBase
    ])

    #expect(conflictKind(verdict) == .editDelete)

    let syncSet = testSyncSet([.localFolder, .nasFolder, .googleDrive])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oldItems = await seed(path: "/Tracked.txt", contents: "old", providers: [local, nas, google])
    let record = testRecord(syncSetID: syncSet.id, path: "/Tracked.txt", items: oldItems)
    await local.remove(path: "/Tracked.txt")
    await nas.putFile(path: "/Tracked.txt", contents: data("edited"), modifiedAt: testDate.addingTimeInterval(10))

    let plan = await testPlan(syncSet: syncSet, records: [record], providers: [local, nas, google])

    #expect(plan.conflicts.map(\.kind) == [.editDelete])
    #expect(plan.actions.allSatisfy { action in
        if case .trash = action { return false }
        return true
    })
    #expect(plan.actions.contains { action in
        if case .createConflictCopy = action { return true }
        return false
    })
}

@Test func row11_missingWithRelocated_propagatesPathAndCreation() {
    let verdict = reconcileTracked([
        .localFolder: .relocated(to: "/Moved.txt"),
        .nasFolder: .missing,
        .googleDrive: .matchesBase
    ])

    #expect(hasPath(verdict, to: [.googleDrive], newPath: "/Moved.txt"))
    #expect(hasCreation(verdict, from: .localFolder, to: [.nasFolder]))
}

@Test func row12_allMissing_inSync() {
    let verdict = reconcileTracked([
        .localFolder: .missing,
        .nasFolder: .missing
    ])

    #expect(isInSync(verdict))
}

@Test func row13_waitingWithContentDecision_waits() {
    let verdict = reconcileTracked([
        .localFolder: .changed(version("new")),
        .nasFolder: .waiting,
        .googleDrive: .matchesBase
    ])

    #expect(hasWaiting(verdict, locations: [.nasFolder]))
}

@Test func row14_oneAppeared_propagatesCreation() {
    let appeared = item(.localFolder, path: "/New.txt", hash: "new")
    let verdict = reconcileAppeared([
        .localFolder: .appeared(appeared),
        .nasFolder: .missing,
        .googleDrive: .missing
    ])

    #expect(hasCreation(verdict, from: .localFolder, to: [.nasFolder, .googleDrive]))
}

@Test func row15_convergentAppeared_inSync() {
    let verdict = reconcileAppeared([
        .localFolder: .appeared(item(.localFolder, path: "/New.txt", hash: "same")),
        .nasFolder: .appeared(item(.nasFolder, path: "/New.txt", hash: "same")),
        .googleDrive: .missing
    ])

    #expect(isInSync(verdict))
}

@Test func row16_divergentAppeared_conflict() {
    let verdict = reconcileAppeared([
        .localFolder: .appeared(item(.localFolder, path: "/New.txt", hash: "local")),
        .nasFolder: .appeared(item(.nasFolder, path: "/New.txt", hash: "nas")),
        .googleDrive: .missing
    ])

    #expect(conflictKind(verdict) == .createCreate)
}

@Test func row17_caseCollision_conflict() {
    let verdict = reconcileAppeared([
        .localFolder: .appeared(item(.localFolder, path: "/Readme.txt", hash: "local")),
        .nasFolder: .appeared(item(.nasFolder, path: "/README.txt", hash: "nas")),
        .googleDrive: .missing
    ])

    #expect(conflictKind(verdict) == .caseCollision)
}

@Test func row18_typeClash_conflictAndPreservesFileOnly() async throws {
    let verdict = reconcileAppeared([
        .localFolder: .appeared(item(.localFolder, path: "/Thing", hash: "file")),
        .nasFolder: .appeared(item(.nasFolder, path: "/Thing", kind: .folder)),
        .googleDrive: .missing
    ])

    #expect(conflictKind(verdict) == .typeClash)

    let syncSet = testSyncSet([.localFolder, .nasFolder, .googleDrive])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    let google = FakeStorageProvider(locationID: .googleDrive)
    await local.putFile(path: "/Thing", contents: data("file"))
    await nas.putFolder(path: "/Thing")

    let plan = await testPlan(syncSet: syncSet, providers: [local, nas, google])

    #expect(plan.conflicts.map(\.kind) == [.typeClash])
    #expect(plan.actions.contains { action in
        if case let .createConflictCopy(source, _, _, _) = action {
            return source == .localFolder
        }
        return false
    })
    #expect(plan.actions.allSatisfy { action in
        if case .createFolder = action { return false }
        if case .trash = action { return false }
        return true
    })
}

@Test func reconciliationFactProductSweep_isTotalAndPreservesMetaProperties() {
    let factShapes: [LocationFact] = [
        .matchesBase,
        .changed(version("different")),
        .changed(ItemVersion()),
        .relocated(to: "/Moved.txt"),
        .missing,
        .waiting
    ]
    let locationSets: [[LocationID]] = [
        [.localFolder, .nasFolder],
        [.localFolder, .nasFolder, .googleDrive],
        [.localFolder, .nasFolder, .googleDrive, .oneDrive]
    ]

    for locations in locationSets {
        for facts in products(factShapes, count: locations.count) {
            let factsByLocation = Dictionary(uniqueKeysWithValues: zip(locations, facts))
            let verdict = reconcileTracked(factsByLocation, locations: locations)

            #expect(deletionMetaPropertyHolds(verdict: verdict, facts: factsByLocation, hasBase: true))
            #expect(unknownDoesNotPropagateContent(verdict: verdict, facts: factsByLocation))
            #expect(placeholderDeletionPropertyHolds(verdict: verdict, facts: factsByLocation))
        }
    }
}

@Test func hashMoveMatchingPairsMissingAndAppearedWithIdenticalHash() {
    let syncSet = testSyncSet([.localFolder, .nasFolder])
    let record = testRecord(
        syncSetID: syncSet.id,
        path: "/Old.txt",
        items: [.localFolder: item(.localFolder, path: "/Old.txt", hash: "hash")]
    )
    let baseItem = ReconciliationItem(
        base: record,
        facts: [.localFolder: .missing, .nasFolder: .matchesBase],
        observations: [.nasFolder: item(.nasFolder, path: "/Old.txt", hash: "hash")],
        locations: syncSet.locations,
        primaryPath: "/Old.txt"
    )
    let appeared = item(.localFolder, path: "/New.txt", hash: "base")
    let appearedItem = ReconciliationItem(
        base: nil,
        facts: [.localFolder: .appeared(appeared), .nasFolder: .missing],
        observations: [.localFolder: appeared],
        locations: syncSet.locations,
        primaryPath: "/New.txt"
    )

    let matched = applyHashBasedMoveMatching(to: [baseItem, appearedItem])

    #expect(matched.count == 1)
    #expect(matched.first?.facts[.localFolder]?.relocatedPath == "/New.txt")
}

@Test func hashMoveMatchingDoesNotPairWithoutHash() {
    let syncSet = testSyncSet([.localFolder, .nasFolder])
    let record = testRecord(
        syncSetID: syncSet.id,
        path: "/Old.txt",
        items: [.localFolder: item(.localFolder, path: "/Old.txt", hash: nil)]
    )
    let baseItem = ReconciliationItem(
        base: record,
        facts: [.localFolder: .missing, .nasFolder: .matchesBase],
        observations: [.nasFolder: item(.nasFolder, path: "/Old.txt", hash: nil)],
        locations: syncSet.locations,
        primaryPath: "/Old.txt"
    )
    let appeared = item(.localFolder, path: "/New.txt", hash: nil)
    let appearedItem = ReconciliationItem(
        base: nil,
        facts: [.localFolder: .appeared(appeared), .nasFolder: .missing],
        observations: [.localFolder: appeared],
        locations: syncSet.locations,
        primaryPath: "/New.txt"
    )

    let matched = applyHashBasedMoveMatching(to: [baseItem, appearedItem])

    #expect(matched.count == 2)
}

@Test func subtreeMoveFoldingDropsChildMovesWhenFolderHasStableID() {
    let syncSet = testSyncSet([.localFolder, .nasFolder])
    let folderRecord = testRecord(
        syncSetID: syncSet.id,
        path: "/Folder",
        kind: .folder,
        items: [.localFolder: item(.localFolder, path: "/Folder", kind: .folder, itemID: "folder")]
    )
    let childRecord = testRecord(
        syncSetID: syncSet.id,
        path: "/Folder/Child.txt",
        items: [.localFolder: item(.localFolder, path: "/Folder/Child.txt", hash: "child", itemID: "child")]
    )
    let folderItem = ReconciliationItem(
        base: folderRecord,
        facts: [.localFolder: .relocated(to: "/Moved"), .nasFolder: .matchesBase],
        observations: [:],
        locations: syncSet.locations,
        primaryPath: "/Folder"
    )
    let childItem = ReconciliationItem(
        base: childRecord,
        facts: [.localFolder: .relocated(to: "/Moved/Child.txt"), .nasFolder: .matchesBase],
        observations: [:],
        locations: syncSet.locations,
        primaryPath: "/Folder/Child.txt"
    )
    let reconciled = [
        ReconciledItem(item: folderItem, verdict: .propagatePath(to: [.nasFolder], newPath: "/Moved")),
        ReconciledItem(item: childItem, verdict: .propagatePath(to: [.nasFolder], newPath: "/Moved/Child.txt"))
    ]

    let folded = foldSubtreeMoves(reconciled)

    #expect(folded.count == 1)
    #expect(folded.first?.item.primaryPath == "/Folder")
}

private func reconcileTracked(
    _ facts: [LocationID: LocationFact],
    locations: [LocationID]? = nil
) -> ItemVerdict {
    let resolvedLocations = locations ?? facts.keys.sorted()
    let base = testRecord(syncSetID: testSyncSet(resolvedLocations).id, path: "/Tracked.txt", items: [:])
    return testReconciler.reconcile(
        base: base,
        facts: facts,
        observations: observations(from: facts),
        locations: resolvedLocations,
        primaryPath: base.path
    )
}

private func reconcileAppeared(_ facts: [LocationID: LocationFact]) -> ItemVerdict {
    let locations = facts.keys.sorted()
    return testReconciler.reconcile(
        base: nil,
        facts: facts,
        observations: observations(from: facts),
        locations: locations,
        primaryPath: observations(from: facts).values.map(\.path).sorted().first ?? "/New.txt"
    )
}

private func observations(from facts: [LocationID: LocationFact]) -> [LocationID: ItemObservation] {
    Dictionary(uniqueKeysWithValues: facts.compactMap { location, fact in
        switch fact {
        case let .appeared(observation):
            return (location, observation)
        case let .changed(version):
            return (location, item(location, path: "/Tracked.txt", version: version))
        case let .changedAndRelocated(version, path):
            return (location, item(location, path: path, version: version))
        case let .relocated(path):
            return (location, item(location, path: path, hash: "base"))
        case .matchesBase:
            return (location, item(location, path: "/Tracked.txt", hash: "base"))
        case .waiting:
            return (location, item(location, path: "/Tracked.txt", hash: "base", isPlaceholder: true))
        case .missing:
            return nil
        }
    })
}

private func testSyncSet(_ locations: [LocationID]) -> SyncSet {
    SyncSet(name: "Reconcile", locations: locations, createdAt: testDate, updatedAt: testDate)
}

private func item(
    _ location: LocationID,
    path: SyncPath,
    hash: String? = "base",
    kind: ItemKind = .file,
    itemID: String? = nil,
    isPlaceholder: Bool = false
) -> ItemObservation {
    item(location, path: path, version: version(hash), kind: kind, itemID: itemID, isPlaceholder: isPlaceholder)
}

private func item(
    _ location: LocationID,
    path: SyncPath,
    version: ItemVersion,
    kind: ItemKind = .file,
    itemID: String? = nil,
    isPlaceholder: Bool = false
) -> ItemObservation {
    ItemObservation(
        location: location,
        itemID: itemID ?? "\(location.rawValue.uuidString):\(path.rawValue)",
        path: path,
        kind: kind,
        version: kind == .folder ? ItemVersion(modifiedAt: testDate, revisionToken: "folder") : version,
        isPlaceholder: isPlaceholder
    )
}

private func version(_ hash: String?) -> ItemVersion {
    ItemVersion(contentHash: hash, size: hash.map { Int64($0.count) }, modifiedAt: testDate, revisionToken: hash)
}

private func testRecord(
    syncSetID: UUID,
    path: SyncPath,
    kind: ItemKind = .file,
    items: [LocationID: ItemObservation]
) -> BaseRecord {
    BaseRecord(
        syncSetID: syncSetID,
        path: path,
        kind: kind,
        version: version("base"),
        perLocation: Dictionary(uniqueKeysWithValues: items.map { location, observation in
            (location, LocationMemory(itemID: observation.itemID, revisionToken: observation.version.revisionToken, lastSeenAt: testDate))
        }),
        lastConvergedAt: testDate,
        createdAt: testDate,
        updatedAt: testDate
    )
}

private func seed(
    path: SyncPath,
    contents: String,
    providers: [FakeStorageProvider]
) async -> [LocationID: ItemObservation] {
    var items: [LocationID: ItemObservation] = [:]
    for provider in providers {
        items[provider.locationID] = await provider.putFile(path: path, contents: data(contents), modifiedAt: testDate)
    }
    return items
}

private func testPlan(
    syncSet: SyncSet,
    records: [BaseRecord] = [],
    providers: [FakeStorageProvider]
) async -> SyncPlan {
    var snapshots: [LocationSnapshot] = []
    for provider in providers {
        snapshots.append(await provider.scan(.entireDrive))
    }
    return SyncPlanner().plan(
        SyncPlanningInput(syncSet: syncSet, records: records, snapshots: snapshots),
        environment: testEnvironment
    )
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}

private let testDate = Date(timeIntervalSince1970: 1_770_000_000)
private let testEnvironment = PlanningEnvironment(
    now: testDate,
    makeID: { UUID(uuidString: "40000000-0000-0000-0000-000000000001")! },
    locationNames: [
        .localFolder: "Local Folder",
        .nasFolder: "NAS Folder",
        .googleDrive: "Google Drive",
        .oneDrive: "OneDrive"
    ]
)
private let testReconciler = Reconciler(environment: testEnvironment)

private func isInSync(_ verdict: ItemVerdict) -> Bool {
    if case .inSync = verdict { return true }
    return false
}

private func conflictKind(_ verdict: ItemVerdict) -> ConflictKind? {
    switch verdict {
    case let .conflict(conflict):
        return conflict.kind
    case let .compound(children):
        return children.compactMap(conflictKind).first
    case .inSync, .propagateContent, .propagateCreation, .propagatePath, .propagateDeletion, .waiting:
        return nil
    }
}

private func hasContent(_ verdict: ItemVerdict, from source: LocationID, to destinations: Set<LocationID>) -> Bool {
    contains(verdict) {
        if case let .propagateContent(actionSource, actionDestinations) = $0 {
            return actionSource == source && actionDestinations == destinations
        }
        return false
    }
}

private func hasCreation(_ verdict: ItemVerdict, from source: LocationID, to destinations: Set<LocationID>) -> Bool {
    contains(verdict) {
        if case let .propagateCreation(actionSource, actionDestinations) = $0 {
            return actionSource == source && actionDestinations == destinations
        }
        return false
    }
}

private func hasPath(_ verdict: ItemVerdict, to destinations: Set<LocationID>, newPath: SyncPath) -> Bool {
    contains(verdict) {
        if case let .propagatePath(actionDestinations, actionPath) = $0 {
            return actionDestinations == destinations && actionPath == newPath
        }
        return false
    }
}

private func hasDeletion(_ verdict: ItemVerdict, to destinations: Set<LocationID>, initiatedBy: LocationID) -> Bool {
    contains(verdict) {
        if case let .propagateDeletion(actionDestinations, actionInitiator) = $0 {
            return actionDestinations == destinations && actionInitiator == initiatedBy
        }
        return false
    }
}

private func hasWaiting(_ verdict: ItemVerdict, locations: Set<LocationID>) -> Bool {
    contains(verdict) {
        if case let .waiting(_, waitingLocations) = $0 {
            return waitingLocations == locations
        }
        return false
    }
}

private func contains(_ verdict: ItemVerdict, predicate: (ItemVerdict) -> Bool) -> Bool {
    if predicate(verdict) {
        return true
    }
    if case let .compound(children) = verdict {
        return children.contains { contains($0, predicate: predicate) }
    }
    return false
}

private func products(_ facts: [LocationFact], count: Int) -> [[LocationFact]] {
    guard count > 0 else { return [[]] }
    return products(facts, count: count - 1).flatMap { prefix in
        facts.map { prefix + [$0] }
    }
}

private func deletionMetaPropertyHolds(
    verdict: ItemVerdict,
    facts: [LocationID: LocationFact],
    hasBase: Bool
) -> Bool {
    !contains(verdict) {
        if case .propagateDeletion = $0 {
            return !(hasBase && facts.values.allSatisfy { fact in
                switch fact {
                case .matchesBase, .missing, .waiting:
                    return true
                case .changed, .relocated, .changedAndRelocated, .appeared:
                    return false
                }
            })
        }
        return false
    }
}

private func unknownDoesNotPropagateContent(verdict: ItemVerdict, facts: [LocationID: LocationFact]) -> Bool {
    let hasUnknown = facts.values.contains { fact in
        guard let changed = fact.changedVersion else { return false }
        return changed.comparison(to: version("base")) == .unknown
    }
    guard hasUnknown else { return true }
    return !contains(verdict) {
        if case .propagateContent = $0 { return true }
        return false
    }
}

private func placeholderDeletionPropertyHolds(verdict: ItemVerdict, facts: [LocationID: LocationFact]) -> Bool {
    guard facts.values.contains(where: \.isWaiting) else { return true }
    guard contains(verdict, predicate: { if case .propagateDeletion = $0 { return true }; return false }) else { return true }
    var withoutWaiting = facts
    for (location, fact) in facts where fact.isWaiting {
        withoutWaiting[location] = .matchesBase
    }
    let comparisonVerdict = reconcileTracked(withoutWaiting, locations: facts.keys.sorted())
    return contains(comparisonVerdict) {
        if case .propagateDeletion = $0 { return true }
        return false
    }
}
