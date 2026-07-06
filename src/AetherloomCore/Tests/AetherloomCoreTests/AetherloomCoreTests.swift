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
    #expect(containsUpload(plan, source: source.provider, destination: .iCloudDrive, path: source.path))
    #expect(containsUpload(plan, source: source.provider, destination: .oneDrive, path: source.path))
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Budget.xlsx", iCloud: oldItems[.iCloudDrive], google: oldItems[.googleDrive], oneDrive: oldItems[.oneDrive])
    let source = await google.putFile(path: "/Budget.xlsx", contents: data("new"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(overwriteCount(plan) == 2)
    #expect(containsOverwrite(plan, source: source.provider, destination: .iCloudDrive, path: "/Budget.xlsx"))
    #expect(containsOverwrite(plan, source: source.provider, destination: .oneDrive, path: "/Budget.xlsx"))
    #expect(conflictCopyCount(plan) == 0)
}

@Test func independentEditsCreateConflictCopies() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeCloudProvider(id: .iCloudDrive)
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    let oldItems = await seedFile(path: "/Budget.xlsx", contents: "old", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Budget.xlsx", iCloud: oldItems[.iCloudDrive], google: oldItems[.googleDrive], oneDrive: oldItems[.oneDrive])
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Old Name.txt", iCloud: oldItems[.iCloudDrive], google: oldItems[.googleDrive], oneDrive: oldItems[.oneDrive])
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Report.txt", iCloud: oldItems[.iCloudDrive], google: oldItems[.googleDrive], oneDrive: oldItems[.oneDrive])
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Old Notes.txt", iCloud: oldItems[.iCloudDrive], google: oldItems[.googleDrive], oneDrive: oldItems[.oneDrive])
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", oneDrive: item)
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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", oneDrive: item)
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
    let iCloudItem = await iCloud.putFile(path: "/Photo.jpg", contents: data("placeholder"), isPlaceholder: true)
    let googleItem = await google.putFile(path: "/Photo.jpg", contents: data("placeholder"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Photo.jpg", iCloud: iCloudItem, google: googleItem)
    await google.remove(path: "/Photo.jpg")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google])

    #expect(plan.riskLevel == .paused)
    #expect(trashCount(plan) == 0)
}

@Test func massDeletePausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    var records: [SyncRecord] = []
    for index in 0..<6 {
        let path = CloudPath("/Deleted-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, google: googleItem, oneDrive: oneDriveItem))
        await google.remove(path: path)
    }
    let settings = SyncPlannerSettings(safetyThresholds: SafetyThresholds(massDeleteAbsolute: 3, massDeleteRatio: 0.5, massEditAbsolute: 99, massEditRatio: 1))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive], settings: settings)

    #expect(plan.riskLevel == .paused)
    #expect(containsPause(plan))
    #expect(trashCount(plan) == 6)
}

@Test func massEditPausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeCloudProvider(id: .googleDrive)
    let oneDrive = FakeCloudProvider(id: .oneDrive)
    var records: [SyncRecord] = []
    for index in 0..<6 {
        let path = CloudPath("/Edited-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, google: googleItem, oneDrive: oneDriveItem))
        await google.putFile(path: path, contents: data("new \(index)"))
    }
    let settings = SyncPlannerSettings(safetyThresholds: SafetyThresholds(massDeleteAbsolute: 99, massDeleteRatio: 1, massEditAbsolute: 3, massEditRatio: 0.5))

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
    let record = makeRecord(syncSetID: syncSet.id, path: "/Draft.txt", google: googleOld, oneDrive: oneDriveOld)
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
    let resolver = ConflictResolver(generatedAt: Date(timeIntervalSince1970: 1_770_000_000))
    let item = CloudItem(provider: .oneDrive, path: "/Money/Budget.final.xlsx", isFolder: false)

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
    let settings = SyncPlannerSettings(exclusions: [
        SyncExclusion(pattern: ".DS_Store", matchStyle: .filename)
    ])

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive], settings: settings)

    #expect(plan.actions.isEmpty)
}

private func makeSyncSet(_ providers: [ProviderID] = [.iCloudDrive, .googleDrive, .oneDrive]) -> SyncSet {
    SyncSet(
        name: "Documents",
        providers: Dictionary(uniqueKeysWithValues: providers.map { ($0, SyncScope.entireDrive) }),
        mode: .balancedMirror,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

private func makePlan(
    syncSet: SyncSet,
    records: [SyncRecord] = [],
    providers: [FakeCloudProvider],
    settings: SyncPlannerSettings = SyncPlannerSettings()
) async -> SyncPlan {
    var snapshots: [ProviderSnapshot] = []
    for provider in providers {
        snapshots.append(await provider.snapshot(scope: syncSet.providers[provider.id] ?? .entireDrive))
    }
    return SyncPlanner().plan(
        SyncPlanningInput(syncSet: syncSet, records: records, snapshots: snapshots, settings: settings),
        generatedAt: fixedDate
    )
}

private func seedFile(
    path: CloudPath,
    contents: String,
    providers: [FakeCloudProvider]
) async -> [ProviderID: CloudItem] {
    var items: [ProviderID: CloudItem] = [:]
    for provider in providers {
        items[provider.id] = await provider.putFile(path: path, contents: data(contents), modifiedAt: fixedDate)
    }
    return items
}

private func makeRecord(
    syncSetID: UUID,
    path: CloudPath,
    isFolder: Bool = false,
    iCloud: CloudItem? = nil,
    google: CloudItem? = nil,
    oneDrive: CloudItem? = nil
) -> SyncRecord {
    let baseline = google ?? oneDrive ?? iCloud
    return SyncRecord(
        syncSetID: syncSetID,
        canonicalPath: path,
        isFolder: isFolder,
        googleDriveItemID: google?.providerItemID,
        oneDriveItemID: oneDrive?.providerItemID,
        lastKnownHash: baseline?.contentHash,
        lastKnownSize: baseline?.size,
        lastKnownModifiedAt: baseline?.modifiedAt,
        googleRevisionID: google?.revisionID,
        oneDriveETag: oneDrive?.eTag,
        oneDriveCTag: oneDrive?.cTag,
        iCloudFileResourceIdentifier: iCloud?.providerItemID,
        lastSyncedAt: fixedDate,
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

private func containsUpload(_ plan: SyncPlan, source: ProviderID, destination: ProviderID, path: CloudPath) -> Bool {
    plan.actions.contains {
        if case let .upload(actionSource, actionDestination, _, destinationPath) = $0 {
            return actionSource == source && actionDestination == destination && destinationPath == path
        }
        return false
    }
}

private func containsOverwrite(_ plan: SyncPlan, source: ProviderID, destination: ProviderID, path: CloudPath) -> Bool {
    plan.actions.contains {
        if case let .overwrite(actionSource, actionDestination, _, destinationItem) = $0 {
            return actionSource == source && actionDestination == destination && destinationItem.path == path
        }
        return false
    }
}

private func containsCreateFolder(_ plan: SyncPlan, destination: ProviderID, path: CloudPath) -> Bool {
    plan.actions.contains {
        if case let .createFolder(actionDestination, actionPath) = $0 {
            return actionDestination == destination && actionPath == path
        }
        return false
    }
}

private func containsRename(_ plan: SyncPlan, destination: ProviderID, newName: String) -> Bool {
    plan.actions.contains {
        if case let .rename(actionDestination, _, actionNewName) = $0 {
            return actionDestination == destination && actionNewName == newName
        }
        return false
    }
}

private func containsMove(_ plan: SyncPlan, destination: ProviderID, newPath: CloudPath) -> Bool {
    plan.actions.contains {
        if case let .move(actionDestination, _, actionNewPath) = $0 {
            return actionDestination == destination && actionNewPath == newPath
        }
        return false
    }
}

private func containsTrash(_ plan: SyncPlan, destination: ProviderID, path: CloudPath) -> Bool {
    plan.actions.contains {
        if case let .trash(actionDestination, item) = $0 {
            return actionDestination == destination && item.path == path
        }
        return false
    }
}
