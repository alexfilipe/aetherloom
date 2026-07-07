import Foundation
import Testing
@testable import AetherloomCore

@Test func storageProviderContract_fakeProviderFailureNeverMasqueradesAsEmpty() async {
    let provider = FakeStorageProvider(locationID: .localFolder)
    await provider.putFile(path: "/Present.txt", contents: providerContractData("present"), modifiedAt: providerContractDate)

    await provider.setAvailability(.unavailable(.volumeNotMounted(detail: "Disk unplugged.")))
    let unavailable = await provider.scan(.entireDrive)
    #expect(unavailable.status == .unavailable(reason: .volumeNotMounted(detail: "Disk unplugged.")))
    #expect(unavailable.status != .complete)

    await provider.setAvailability(.available)
    await provider.setIncompleteScan(reason: "Enumeration stopped.")
    let incomplete = await provider.scan(.entireDrive)
    #expect(incomplete.status == .incomplete(reason: "Enumeration stopped."))
    #expect(incomplete.observations.all.map(\.path) == ["/Present.txt"])
}

@Test func storageProviderContract_fakeProviderCompleteScanProofAndPlaceholderInclusion() async {
    let provider = FakeStorageProvider(locationID: .iCloudDrive)
    await provider.putFile(path: "/Dataless.pages", contents: providerContractData("stub"), modifiedAt: providerContractDate, isPlaceholder: true)
    await provider.putSymlink(path: "/Linked", target: "/Volumes/NAS")

    let snapshot = await provider.scan(.entireDrive)

    #expect(snapshot.status == .complete)
    #expect(snapshot.observations.byPath["/Dataless.pages"]?.isPlaceholder == true)
    #expect(snapshot.observations.byPath["/Linked"]?.kind == .symlink(target: "/Volumes/NAS"))
}

@Test func storageProviderContract_fakeProviderEnforcesStorePreconditionsAndKeepsTrashRetrievable() async throws {
    let provider = FakeStorageProvider(locationID: .googleDrive)
    let existing = await provider.putFile(path: "/Existing.txt", contents: providerContractData("old"), modifiedAt: providerContractDate)
    let oldURL = try providerContractTemporaryFile("old.txt", contents: providerContractData("old"))
    let newURL = try providerContractTemporaryFile("new.txt", contents: providerContractData("new"))
    defer {
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.removeItem(at: newURL)
    }

    let same = try await provider.store(from: oldURL, at: "/Existing.txt", options: StoreOptions(overwrite: .neverOverwrite))
    #expect(same.itemID == existing.itemID)

    await #expect(throws: ProviderError.itemAlreadyExists(provider: .googleDrive, path: "/Existing.txt")) {
        _ = try await provider.store(from: newURL, at: "/Existing.txt", options: StoreOptions(overwrite: .neverOverwrite))
    }

    await #expect(throws: ProviderError.preconditionFailed(provider: .googleDrive, path: "/Existing.txt")) {
        _ = try await provider.store(
            from: newURL,
            at: "/Existing.txt",
            options: StoreOptions(overwrite: .ifVersionMatches(ItemVersion(contentHash: "wrong")))
        )
    }

    try await provider.trash(existing)
    let trashed = try #require(await provider.item(at: "/Existing.txt", includeTrashed: true))
    let fetchURL = try providerContractTemporaryURL("trash-fetch.txt")
    defer { try? FileManager.default.removeItem(at: fetchURL) }
    try await provider.fetch(trashed, to: fetchURL)
    #expect(try Data(contentsOf: fetchURL) == providerContractData("old"))
}

@Test func storageProviderContract_fakeProviderCallLogRecordsExpectedOrder() async throws {
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let item = await provider.putFile(path: "/Log.txt", contents: providerContractData("log"), modifiedAt: providerContractDate)
    await provider.clearCallLog()

    _ = await provider.checkAvailability()
    _ = await provider.scan(.entireDrive)
    _ = try await provider.changedSubtrees(in: .entireDrive, since: ChangeCursor(rawValue: "cursor"))
    _ = try await provider.currentState(of: item)

    #expect(await provider.callLog().map(\.operation) == [.checkAvailability, .scan, .changedSubtrees, .currentState])
    #expect(await provider.callLog().map(\.order) == [0, 1, 2, 3])
}

@Test func storageProviderContract_quarantinePrefixIsVisibleButExcludedFromPlanning() async {
    let syncSet = SyncSet(name: "Quarantine", locations: [.localFolder, .nasFolder], createdAt: providerContractDate, updatedAt: providerContractDate)
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    await local.putFile(path: "/.aetherloom/trash/run/Quarantined.txt", contents: providerContractData("internal"), modifiedAt: providerContractDate)

    let snapshot = await local.scan(.entireDrive)
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            snapshots: [snapshot, await nas.scan(.entireDrive)]
        ),
        environment: PlanningEnvironment(now: providerContractDate)
    )

    #expect(snapshot.observations.byPath["/.aetherloom/trash/run/Quarantined.txt"] != nil)
    #expect(outcome.planValue?.schedule.operations.isEmpty == true)
}

private func providerContractTemporaryURL(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomProviderContractTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    return url
}

private func providerContractTemporaryFile(_ name: String, contents: Data) throws -> URL {
    let url = try providerContractTemporaryURL(name)
    try contents.write(to: url)
    return url
}

private func providerContractData(_ string: String) -> Data {
    Data(string.utf8)
}

private let providerContractDate = Date(timeIntervalSince1970: 1_770_000_000)
