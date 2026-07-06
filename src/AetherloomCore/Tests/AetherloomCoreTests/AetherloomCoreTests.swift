import Foundation
import Testing
@testable import AetherloomCore

@Test func fileCreatedInOneProviderPropagatesToOthers() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let source = await google.putFile(path: "/Documents/Resume.docx", contents: data("resume"))

    let plan = await makePlan(syncSet: syncSet, providers: [iCloud, google, oneDrive])

    #expect(plan.riskLevel == .safe)
    #expect(uploadCount(plan) == 2)
    #expect(containsUpload(plan, source: source.location, destination: .iCloudDrive, path: source.path))
    #expect(containsUpload(plan, source: source.location, destination: .oneDrive, path: source.path))
}

@Test func folderCreatedInOneProviderPropagatesToOthers() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFolder(path: "/Projects/Website")

    let plan = await makePlan(syncSet: syncSet, providers: [iCloud, google, oneDrive])

    #expect(createFolderCount(plan) == 2)
    #expect(containsCreateFolder(plan, destination: .iCloudDrive, path: "/Projects/Website"))
    #expect(containsCreateFolder(plan, destination: .oneDrive, path: "/Projects/Website"))
}

@Test func editedFileOverwritesUnchangedCopies() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Budget.xlsx", contents: "old", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Budget.xlsx", items: oldItems)
    let source = await google.putFile(path: "/Budget.xlsx", contents: data("new"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(overwriteCount(plan) == 2)
    #expect(containsOverwrite(plan, source: source.location, destination: .iCloudDrive, path: "/Budget.xlsx"))
    #expect(containsOverwrite(plan, source: source.location, destination: .oneDrive, path: "/Budget.xlsx"))
    #expect(conflictCopyCount(plan) == 0)
}

@Test func independentEditsCreateConflictCopies() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Budget.xlsx", contents: "old", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Budget.xlsx", items: oldItems)
    await google.putFile(path: "/Budget.xlsx", contents: data("google edit"))
    await oneDrive.putFile(path: "/Budget.xlsx", contents: data("onedrive edit"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(plan.riskLevel == .needsReview)
    #expect(plan.isAutoExecutable == false)
    #expect(plan.conflicts.count == 1)
    #expect(conflictCopyCount(plan) == 4)
    #expect(overwriteCount(plan) == 0)
}

@Test func renamedFilePropagatesRename() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Old Name.txt", contents: "note", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Old Name.txt", items: oldItems)
    _ = try await google.rename(item: oldItems[.googleDrive]!, to: "New Name.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(renameCount(plan) == 2)
    #expect(containsRename(plan, destination: .iCloudDrive, newName: "New Name.txt"))
    #expect(containsRename(plan, destination: .oneDrive, newName: "New Name.txt"))
}

@Test func movedFilePropagatesMove() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Report.txt", contents: "report", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Report.txt", items: oldItems)
    _ = try await google.move(item: oldItems[.googleDrive]!, to: "/Archive/Report.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(moveCount(plan) == 2)
    #expect(containsMove(plan, destination: .iCloudDrive, newPath: "/Archive/Report.txt"))
    #expect(containsMove(plan, destination: .oneDrive, newPath: "/Archive/Report.txt"))
}

@Test func deletedFileMovesMatchingFilesToTrash() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Old Notes.txt", contents: "old", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Old Notes.txt", items: oldItems)
    await google.remove(path: "/Old Notes.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(trashCount(plan) == 2)
    #expect(containsTrash(plan, destination: .iCloudDrive, path: "/Old Notes.txt"))
    #expect(containsTrash(plan, destination: .oneDrive, path: "/Old Notes.txt"))
}

@Test func providerUnavailableDoesNotProduceDeleteActions() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let item = await oneDrive.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.oneDrive: item])
    await google.setUnavailable(reason: "Network unavailable")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])

    #expect(plan.riskLevel == .paused)
    #expect(containsPause(plan))
    #expect(trashCount(plan) == 0)
}

@Test func incompleteScanDoesNotProduceDeleteActions() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let item = await oneDrive.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.oneDrive: item])
    await google.setIncompleteScan(reason: "Pagination stopped early")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])

    #expect(plan.riskLevel == .paused)
    #expect(containsPause(plan))
    #expect(trashCount(plan) == 0)
}

@Test func iCloudPlaceholderDoesNotProduceDeleteActions() async throws {
    let syncSet = makeSyncSet([.iCloudDrive, .googleDrive])
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let icloudObservation = await iCloud.putFile(path: "/Photo.jpg", contents: data("placeholder"), isPlaceholder: true)
    let googleItem = await google.putFile(path: "/Photo.jpg", contents: data("placeholder"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Photo.jpg", items: [.iCloudDrive: icloudObservation, .googleDrive: googleItem])
    await google.remove(path: "/Photo.jpg")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google])

    #expect(plan.riskLevel == .paused)
    #expect(trashCount(plan) == 0)
}

@Test func massDeletePausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    var records: [BaseRecord] = []
    for index in 0..<6 {
        let path = SyncPath("/Deleted-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem]))
        await google.remove(path: path)
    }
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 3, massDeleteRatio: 0.5, massEditAbsolute: 99, massEditRatio: 1))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive], settings: settings)

    #expect(plan.riskLevel == .paused)
    #expect(containsPause(plan))
    #expect(trashCount(plan) == 6)
}

@Test func massEditPausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    var records: [BaseRecord] = []
    for index in 0..<6 {
        let path = SyncPath("/Edited-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem]))
        await google.putFile(path: path, contents: data("new \(index)"))
    }
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 99, massDeleteRatio: 1, massEditAbsolute: 3, massEditRatio: 0.5))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive], settings: settings)

    #expect(plan.riskLevel == .paused)
    #expect(containsPause(plan))
    #expect(overwriteCount(plan) == 6)
}

@Test func destinationChangedAfterPlanningStopsExecutionForReplan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let googleOld = await google.putFile(path: "/Draft.txt", contents: data("old"))
    let oneDriveOld = await oneDrive.putFile(path: "/Draft.txt", contents: data("old"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Draft.txt", items: [.googleDrive: googleOld, .oneDrive: oneDriveOld])
    await google.putFile(path: "/Draft.txt", contents: data("new from google"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])
    await oneDrive.putFile(path: "/Draft.txt", contents: data("surprise edit"))
    let executor = SyncPlanExecutor(providers: [.googleDrive: google, .oneDrive: oneDrive])

    do {
        _ = try await executor.execute(plan)
        #expect(Bool(false))
    } catch let error as SyncExecutionError {
        #expect(error == .destinationChangedRequiresReplan(provider: .oneDrive, path: "/Draft.txt"))
    }
}

@Test func rerunningSameSyncPlanIsIdempotent() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFile(path: "/New.txt", contents: data("hello"))
    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])
    let executor = SyncPlanExecutor(providers: [.googleDrive: google, .oneDrive: oneDrive])

    let firstReport = try await executor.execute(plan)
    let secondReport = try await executor.execute(plan)

    #expect(firstReport.appliedActions.count == 1)
    #expect(secondReport.appliedActions.isEmpty)
    #expect(secondReport.skippedActions.count == 1)
    #expect(await oneDrive.item(at: "/New.txt") != nil)
}

@Test func conflictNamesPreserveFileExtensions() {
    let resolver = ConflictResolver(environment: makeEnvironment())
    let item = ItemObservation(location: .oneDrive, path: "/Money/Budget.final.xlsx", kind: .file)

    let conflictPath = resolver.conflictPath(for: item)

    #expect(conflictPath.rawValue.hasSuffix(".xlsx"))
    #expect(conflictPath.name.contains("Budget.final (conflict from OneDrive"))
}

@Test func caseInsensitiveFilenameCollisionsAreHandledSafely() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFile(path: "/Readme.txt", contents: data("google"))
    await oneDrive.putFile(path: "/README.txt", contents: data("onedrive"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(plan.riskLevel == .needsReview)
    #expect(conflictCopyCount(plan) > 0)
    #expect(overwriteCount(plan) == 0)
    #expect(trashCount(plan) == 0)
}

@Test func unicodeFilenamesAreHandledSafely() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFile(path: "/Résumé.txt", contents: data("unicode"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsUpload(plan, source: .googleDrive, destination: .oneDrive, path: "/Résumé.txt"))
}

@Test func emptyFoldersAreSynchronized() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFolder(path: "/Empty")

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsCreateFolder(plan, destination: .oneDrive, path: "/Empty"))
}

@Test func zeroByteFilesAreSynchronized() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFile(path: "/zero.dat", contents: Data())

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsUpload(plan, source: .googleDrive, destination: .oneDrive, path: "/zero.dat"))
}

@Test func excludedFilesAreIgnored() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    await google.putFile(path: "/.DS_Store", contents: data("metadata"))
    let settings = SyncSettings(exclusions: [
        SyncExclusion(pattern: ".DS_Store", matchStyle: .filename)
    ])

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive], settings: settings)

    #expect(plan.actions.isEmpty)
}

@Test func twoSameKindLocationsPropagateCreates() async throws {
    let first = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    let second = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
    let syncSet = makeSyncSet([first, second])
    let firstFolder = FakeCloudProvider(id: first, displayName: "Local A")
    let secondFolder = FakeCloudProvider(id: second, displayName: "Local B")
    await firstFolder.putFile(path: "/Shared.txt", contents: data("same kind"))

    let plan = await makePlan(syncSet: syncSet, providers: [firstFolder, secondFolder])

    #expect(plan.riskLevel == .safe)
    #expect(containsUpload(plan, source: first, destination: second, path: "/Shared.txt"))
}

@Test func localAndNASLocationsPropagateCreates() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeCloudProvider(id: .localFolder)
    let nas = FakeCloudProvider(id: .nasFolder)
    await local.putFile(path: "/Media.mov", contents: data("movie"))

    let plan = await makePlan(syncSet: syncSet, providers: [local, nas])

    #expect(plan.riskLevel == .safe)
    #expect(containsUpload(plan, source: .localFolder, destination: .nasFolder, path: "/Media.mov"))
}

@Test func localAndNASLocationsPreserveIndependentEditConflicts() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeCloudProvider(id: .localFolder)
    let nas = FakeCloudProvider(id: .nasFolder)
    let oldItems = await seedFile(path: "/Sketch.psd", contents: "base", providers: [local, nas])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Sketch.psd", items: oldItems)
    await local.putFile(path: "/Sketch.psd", contents: data("local"))
    await nas.putFile(path: "/Sketch.psd", contents: data("nas"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [local, nas])

    #expect(plan.riskLevel == .needsReview)
    #expect(plan.conflicts.count == 1)
    #expect(conflictCopyCount(plan) == 2)
    #expect(overwriteCount(plan) == 0)
}

@Test func localAndNASLocationsPropagateDeletesToTrash() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeCloudProvider(id: .localFolder)
    let nas = FakeCloudProvider(id: .nasFolder)
    let oldItems = await seedFile(path: "/Archive.zip", contents: "base", providers: [local, nas])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Archive.zip", items: oldItems)
    await local.remove(path: "/Archive.zip")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [local, nas])

    #expect(trashCount(plan) == 1)
    #expect(containsTrash(plan, destination: .nasFolder, path: "/Archive.zip"))
}

@Test func baseRecordJSONRoundTrips() throws {
    let record = BaseRecord(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        syncSetID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        path: "/RoundTrip.txt",
        kind: .file,
        version: ItemVersion(contentHash: "hash", size: 4, modifiedAt: fixedDate, revisionToken: "rev-1"),
        perLocation: [
            .localFolder: LocationMemory(itemID: "local-1", revisionToken: "rev-1", lastSeenAt: fixedDate),
            .nasFolder: LocationMemory(itemID: "nas-1", revisionToken: "rev-1", lastSeenAt: fixedDate)
        ],
        tombstone: Tombstone(deletedAt: fixedDate, initiatedBy: .localFolder),
        lastConvergedAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )

    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(BaseRecord.self, from: encoded)

    #expect(decoded == record)
}

@Test func versionComparisonMatrixTreatsUnknownAsNotEqual() {
    let baseDate = fixedDate

    #expect(ItemVersion(contentHash: "a", size: 1, modifiedAt: baseDate, revisionToken: "1").comparison(to: ItemVersion(contentHash: "a", size: 2, modifiedAt: baseDate.addingTimeInterval(1), revisionToken: "2")) == .same)
    #expect(ItemVersion(contentHash: "a").comparison(to: ItemVersion(contentHash: "b")) == .different)
    #expect(ItemVersion(size: 1, modifiedAt: baseDate, revisionToken: "1").comparison(to: ItemVersion(size: 1, modifiedAt: baseDate, revisionToken: "2")) == .same)
    #expect(ItemVersion(size: 1, modifiedAt: baseDate).comparison(to: ItemVersion(size: 2, modifiedAt: baseDate)) == .different)
    #expect(ItemVersion(revisionToken: "1").comparison(to: ItemVersion(revisionToken: "1")) == .same)
    #expect(ItemVersion(revisionToken: "1").comparison(to: ItemVersion(revisionToken: "2")) == .different)
    #expect(ItemVersion(contentHash: "a").comparison(to: ItemVersion(revisionToken: "a")) == .unknown)
    #expect(ItemVersion().comparison(to: ItemVersion()) == .unknown)
    #expect(ItemVersion(contentHash: "a").isSameVersion(as: ItemVersion(revisionToken: "a")) == false)
}

private func makeSyncSet(_ locations: [LocationID] = [.iCloudDrive, .googleDrive, .oneDrive]) -> SyncSet {
    SyncSet(
        name: "Documents",
        locations: locations,
        mode: .balancedMirror,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

private func makePlan(
    syncSet: SyncSet,
    records: [BaseRecord] = [],
    providers: [FakeCloudProvider],
    settings: SyncSettings? = nil
) async -> SyncPlan {
    let resolvedSettings = settings ?? syncSet.settings
    let locations = providers.map {
        SyncLocation(
            id: $0.id,
            kind: $0.id.defaultKind,
            displayName: $0.displayName,
            scope: .entireDrive
        )
    }
    var snapshots: [LocationSnapshot] = []
    for provider in providers {
        let scope = locations.first { $0.id == provider.id }?.scope ?? .entireDrive
        snapshots.append(await provider.snapshot(scope: scope))
    }
    return SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            locations: locations,
            records: records,
            snapshots: snapshots,
            settings: resolvedSettings
        ),
        environment: makeEnvironment(locations: locations)
    )
}

private func makeEnvironment(locations: [SyncLocation] = [
    SyncLocation(id: .iCloudDrive, kind: .iCloudDrive, displayName: "iCloud Drive"),
    SyncLocation(id: .googleDrive, kind: .googleDrive, displayName: "Google Drive"),
    SyncLocation(id: .oneDrive, kind: .oneDrive, displayName: "OneDrive"),
    SyncLocation(id: .localFolder, kind: .localFolder, displayName: "Local Folder"),
    SyncLocation(id: .nasFolder, kind: .nasFolder, displayName: "NAS Folder")
]) -> PlanningEnvironment {
    PlanningEnvironment(
        now: fixedDate,
        makeID: { UUID(uuidString: "30000000-0000-0000-0000-000000000001")! },
        locationNames: Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0.displayName) })
    )
}

private func seedFile(
    path: SyncPath,
    contents: String,
    providers: [FakeCloudProvider]
) async -> [LocationID: ItemObservation] {
    var items: [LocationID: ItemObservation] = [:]
    for provider in providers {
        items[provider.id] = await provider.putFile(path: path, contents: data(contents), modifiedAt: fixedDate)
    }
    return items
}

private func makeRecord(
    syncSetID: UUID,
    path: SyncPath,
    kind: ItemKind = .file,
    items: [LocationID: ItemObservation]
) -> BaseRecord {
    let baseline = items.values.sorted { $0.location < $1.location }.first
    return BaseRecord(
        syncSetID: syncSetID,
        path: path,
        kind: kind,
        version: baseline?.version ?? ItemVersion(),
        perLocation: Dictionary(uniqueKeysWithValues: items.map { location, item in
            (
                location,
                LocationMemory(
                    itemID: item.itemID,
                    revisionToken: item.version.revisionToken,
                    lastSeenAt: fixedDate
                )
            )
        }),
        lastConvergedAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}

private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

private func uploadCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .upload = $0 { return true }
        return false
    }
}

private func overwriteCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .overwrite = $0 { return true }
        return false
    }
}

private func createFolderCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .createFolder = $0 { return true }
        return false
    }
}

private func conflictCopyCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .createConflictCopy = $0 { return true }
        return false
    }
}

private func renameCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .rename = $0 { return true }
        return false
    }
}

private func moveCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .move = $0 { return true }
        return false
    }
}

private func trashCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .trash = $0 { return true }
        return false
    }
}

private func containsPause(_ plan: SyncPlan) -> Bool {
    plan.actions.contains {
        if case .pause = $0 { return true }
        return false
    }
}

private func count(_ plan: SyncPlan, where predicate: (SyncAction) -> Bool) -> Int {
    plan.actions.reduce(0) { total, action in
        total + (predicate(action) ? 1 : 0)
    }
}

private func containsUpload(_ plan: SyncPlan, source: LocationID, destination: LocationID, path: SyncPath) -> Bool {
    plan.actions.contains {
        if case let .upload(actionSource, actionDestination, _, destinationPath) = $0 {
            return actionSource == source && actionDestination == destination && destinationPath == path
        }
        return false
    }
}

private func containsOverwrite(_ plan: SyncPlan, source: LocationID, destination: LocationID, path: SyncPath) -> Bool {
    plan.actions.contains {
        if case let .overwrite(actionSource, actionDestination, _, destinationItem) = $0 {
            return actionSource == source && actionDestination == destination && destinationItem.path == path
        }
        return false
    }
}

private func containsCreateFolder(_ plan: SyncPlan, destination: LocationID, path: SyncPath) -> Bool {
    plan.actions.contains {
        if case let .createFolder(actionDestination, actionPath) = $0 {
            return actionDestination == destination && actionPath == path
        }
        return false
    }
}

private func containsRename(_ plan: SyncPlan, destination: LocationID, newName: String) -> Bool {
    plan.actions.contains {
        if case let .rename(actionDestination, _, actionNewName) = $0 {
            return actionDestination == destination && actionNewName == newName
        }
        return false
    }
}

private func containsMove(_ plan: SyncPlan, destination: LocationID, newPath: SyncPath) -> Bool {
    plan.actions.contains {
        if case let .move(actionDestination, _, actionNewPath) = $0 {
            return actionDestination == destination && actionNewPath == newPath
        }
        return false
    }
}

private func containsTrash(_ plan: SyncPlan, destination: LocationID, path: SyncPath) -> Bool {
    plan.actions.contains {
        if case let .trash(actionDestination, item) = $0 {
            return actionDestination == destination && item.path == path
        }
        return false
    }
}
