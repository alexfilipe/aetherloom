import Foundation
import Testing
@testable import AetherloomCore

@Test func activityCatalogLocksOperationSentences() {
    let catalog = ActivityMessageCatalog()
    let source = observation(.googleDrive, path: "/Budget.xlsx", hash: "source")
    let destination = observation(.oneDrive, path: "/Budget.xlsx", hash: "old")

    #expect(catalog.message(for: .upload(source: .googleDrive, destination: .oneDrive, sourceItem: source, destinationPath: "/Budget.xlsx")) == "Created \"/Budget.xlsx\" in OneDrive from Google Drive.")
    #expect(catalog.message(for: .overwrite(source: .googleDrive, destination: .oneDrive, sourceItem: source, destinationItem: destination)) == "Updated \"/Budget.xlsx\" in OneDrive from Google Drive.")
    #expect(catalog.message(for: .createFolder(destination: .oneDrive, path: "/Projects")) == "Created folder \"/Projects\" in OneDrive.")
    #expect(catalog.message(for: .move(destination: .oneDrive, item: destination, newPath: "/Archive/Budget.xlsx")) == "Moved \"/Archive/Budget.xlsx\" in OneDrive.")
    #expect(catalog.message(for: .rename(destination: .oneDrive, item: destination, newName: "Budget Final.xlsx")) == "Renamed \"/Budget.xlsx\" to \"/Budget Final.xlsx\" in OneDrive.")
    #expect(catalog.message(for: .trash(destination: .oneDrive, item: destination)) == "Moved \"/Budget.xlsx\" to OneDrive trash.")
    #expect(catalog.message(for: .createConflictCopy(source: .googleDrive, destination: .oneDrive, sourceItem: source, conflictPath: "/Budget (conflict).xlsx")) == "Created conflict copy \"/Budget (conflict).xlsx\" in OneDrive from Google Drive.")
}

@Test func activityCatalogLocksSafetyApprovalAndAdvisorySentences() {
    #expect(ActivityMessageCatalog.providerUnavailable == "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.")
    #expect(ActivityMessageCatalog.scanIncomplete == "Sync paused because this provider returned an incomplete scan. No files will be deleted from an incomplete scan.")
    #expect(ActivityMessageCatalog.baseStateUnreadable == "Sync paused because the base state is unreadable. No files will be deleted while sync memory is unreadable.")
    #expect(ActivityMessageCatalog.manyDeletions == "Aetherloom found many deletions. This may be intentional, but sync is paused until you review it.")
    #expect(ActivityMessageCatalog.manyEdits == "Aetherloom found many edits. This may be intentional, but sync is paused until you review it.")
    #expect(ActivityMessageCatalog.deletionsNeedReview == "Aetherloom found deletions. Review before moving matching files to trash.")
    #expect(ActivityMessageCatalog.conflictPreserved == "This file changed in more than one place. Aetherloom preserved both versions.")
    #expect(ActivityMessageCatalog.approvalAccepted == "Plan approval accepted. Aetherloom will apply the reviewed changes.")
    #expect(ActivityMessageCatalog.adviceShown == "Aetherloom showed conflict advice.")
    #expect(ActivityMessageCatalog.adviceUnavailable == "Aetherloom could not generate advice.")
    #expect(ActivityMessageCatalog.recoveryPerformed == "Aetherloom checked an unfinished sync run and preserved the safest state.")
    #expect(ActivityMessageCatalog.stoppedForReplan == "Sync stopped because a file changed after planning. Preview changes again before continuing.")
    #expect(ActivityMessageCatalog.verificationFailed == "Sync could not verify a completed write.")
    #expect(ActivityMessageCatalog.runFinished == "Sync finished.")
    #expect(ActivityMessageCatalog.runStarted(locationCount: 3) == "Sync started for 3 locations.")
    #expect(ActivityMessageCatalog.preparationSummary(additions: 1, updates: 2, moves: 3, trash: 4, conflicts: 5, waiting: 6, gate: .clear) == "Prepared 1 additions, 2 updates, 3 moves, 4 trash moves, 5 conflicts, and 6 waiting items; gate is clear.")
}

@Test func canonicalEncoderUsesFractionalSecondsAndRoundTrips() throws {
    let entry = ActivityEntry(
        id: uuid("000000000101"),
        occurredAt: Date(timeIntervalSince1970: 1_770_000_000.789),
        category: .sync,
        message: "Sync finished."
    )

    let data = try CanonicalCoding.encoder().encode(entry)
    let text = String(decoding: data, as: UTF8.self)
    let decoded = try CanonicalCoding.decoder().decode(ActivityEntry.self, from: data)

    #expect(text.contains(".789Z"))
    #expect(decoded == entry)
}

@Test func inMemoryBaseRecordStoreRoundTripsTombstonesAndPurges() async throws {
    let syncSetID = uuid("000000000201")
    let record = baseRecord(syncSetID: syncSetID, path: "/Tracked.txt")
    let store = InMemoryBaseRecordStore()

    try await store.apply(.upsert(record))
    try await store.apply(.tombstone(syncSetID: syncSetID, recordID: record.id, deletedAt: phaseDate.addingTimeInterval(10), initiatedBy: .googleDrive))
    var records = try await store.records(for: syncSetID)

    #expect(records.count == 1)
    #expect(records.first?.tombstone == Tombstone(deletedAt: phaseDate.addingTimeInterval(10), initiatedBy: .googleDrive))

    try await store.apply(.purge(syncSetID: syncSetID, recordID: record.id))
    records = try await store.records(for: syncSetID)

    #expect(records.isEmpty)
}

@Test func fileBaseRecordStoreRoundTripsAndWritesCanonicalJSON() async throws {
    let root = try temporaryDirectory("file-base-roundtrip")
    defer { try? FileManager.default.removeItem(at: root) }
    let syncSetID = uuid("000000000301")
    let store = try FileBaseRecordStore(rootURL: root)
    let record = baseRecord(
        syncSetID: syncSetID,
        path: "/RoundTrip.txt",
        modifiedAt: Date(timeIntervalSince1970: 1_770_000_000.789)
    )

    try await store.apply(.upsert(record))
    let records = try await store.records(for: syncSetID)
    let fileText = try String(contentsOf: root.appendingPathComponent("records-\(syncSetID.uuidString).json"))

    #expect(records == [record])
    #expect(fileText.contains("\"schemaVersion\":1"))
    #expect(fileText.contains(".789Z"))
}

@Test func fileBaseRecordStoreCorruptFileIsQuarantinedAndThrowsTypedError() async throws {
    let root = try temporaryDirectory("file-base-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let syncSetID = uuid("000000000401")
    let fileURL = root.appendingPathComponent("records-\(syncSetID.uuidString).json")
    try Data("{not-json".utf8).write(to: fileURL)
    let store = try FileBaseRecordStore(rootURL: root)

    do {
        _ = try await store.records(for: syncSetID)
        #expect(Bool(false))
    } catch let error as BaseRecordStoreError {
        #expect(error == .corrupt(syncSetID: syncSetID))
    }

    let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(remaining.contains { $0.lastPathComponent.hasPrefix("records-\(syncSetID.uuidString).json.corrupt-") })
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func corruptBaseRecordStoreFeedsPlannerBaseUnreadableRefusal() async throws {
    let root = try temporaryDirectory("planner-corrupt-base")
    defer { try? FileManager.default.removeItem(at: root) }
    let syncSet = SyncSet(
        id: uuid("000000000501"),
        name: "Planner",
        locations: [.googleDrive, .oneDrive],
        createdAt: phaseDate,
        updatedAt: phaseDate
    )
    let fileURL = root.appendingPathComponent("records-\(syncSet.id.uuidString).json")
    try Data("{bad".utf8).write(to: fileURL)
    let store = try FileBaseRecordStore(rootURL: root)
    let snapshots = [
        LocationSnapshot(location: .googleDrive, scope: .entireDrive, observations: [], scannedAt: phaseDate),
        LocationSnapshot(location: .oneDrive, scope: .entireDrive, observations: [], scannedAt: phaseDate)
    ]

    let outcome = await SyncPlanner().plan(
        syncSet: syncSet,
        snapshots: snapshots,
        baseRecordStore: store,
        environment: PlanningEnvironment(now: phaseDate)
    )
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.reasons.contains { reason in
        if case .baseStateUnreadable = reason { return true }
        return false
    })
    #expect(outcome.planValue?.legacyActions.isEmpty != false)
}

@Test func inMemoryRunJournalReplaysUnfinishedRunAndMarkReconciledClearsIt() async throws {
    let store = InMemoryRunJournalStore()
    let syncSetID = uuid("000000000601")
    let runID = uuid("000000000602")
    let operation = transferOperation(id: "000000000603")

    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "fingerprint"))
    try await store.append(.intent(operation), runID: runID)
    try await store.append(.result(operationID: operation.id, outcome: .applied, occurredAt: phaseDate, detail: nil), runID: runID)

    let replay = try #require(try await store.unfinishedRun(for: syncSetID))
    #expect(replay.runID == runID)
    #expect(replay.events.count == 2)
    #expect(replay.pendingOperationIDs.isEmpty)

    try await store.markReconciled(runID: runID)
    #expect(try await store.unfinishedRun(for: syncSetID) == nil)
}

@Test func runJournalRejectsResultBeforeIntent() async throws {
    let store = InMemoryRunJournalStore()
    let syncSetID = uuid("000000000701")
    let runID = uuid("000000000702")
    let operationID = OperationID(uuid("000000000703"))
    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "fingerprint"))

    do {
        try await store.append(.result(operationID: operationID, outcome: .applied, occurredAt: phaseDate, detail: nil), runID: runID)
        #expect(Bool(false))
    } catch let error as RunJournalStoreError {
        #expect(error == .resultWithoutIntent(runID: runID, operationID: operationID))
    }
}

@Test func fileRunJournalReplaysTornFinalLineAndDetectsUnfinishedRun() async throws {
    let root = try temporaryDirectory("file-journal-torn")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileRunJournalStore(rootURL: root)
    let syncSetID = uuid("000000000801")
    let runID = uuid("000000000802")
    let operation = transferOperation(id: "000000000803")

    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "fingerprint"))
    try await store.append(.intent(operation), runID: runID)
    try appendRaw("{torn", to: root.appendingPathComponent("journal-\(runID.uuidString).jsonl"))

    let replay = try #require(try await store.unfinishedRun(for: syncSetID))
    #expect(replay.runID == runID)
    #expect(replay.events == [.intent(operation)])
}

@Test func fileRunJournalMarkReconciledCompactsAndHidesRun() async throws {
    let root = try temporaryDirectory("file-journal-compact")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileRunJournalStore(rootURL: root)
    let syncSetID = uuid("000000000901")
    let runID = uuid("000000000902")
    let operation = transferOperation(id: "000000000903")

    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "fingerprint"))
    try await store.append(.intent(operation), runID: runID)
    try await store.append(.runFinished(outcome: .succeeded, occurredAt: phaseDate, detail: nil), runID: runID)
    try await store.markReconciled(runID: runID)

    let fileText = try String(contentsOf: root.appendingPathComponent("journal-\(runID.uuidString).jsonl"))
    #expect(fileText.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
    #expect(fileText.contains("reconciled"))
    #expect(try await store.unfinishedRun(for: syncSetID) == nil)
}

@Test func conflictStoreUpsertsAndResolvesOpenConflicts() async throws {
    let store = InMemoryConflictStore()
    let syncSetID = uuid("000000001002")
    let otherSyncSetID = uuid("000000001003")
    let conflict = ConflictDecision(
        id: uuid("000000001001"),
        syncSetID: syncSetID,
        path: "/Conflict.txt",
        message: ActivityMessageCatalog.conflictPreserved
    )

    try await store.upsert([conflict])
    #expect(try await store.openConflicts(for: syncSetID) == [conflict])
    #expect(try await store.openConflicts(for: otherSyncSetID).isEmpty)

    try await store.resolve(conflict.id, as: .preserveAll, at: phaseDate)
    #expect(try await store.openConflicts(for: syncSetID).isEmpty)
}

@Test func adviceCacheRoundTripsAdviceWithoutPromptsOrCredentials() async {
    let store = InMemoryAdviceCacheStore()
    let advice = ConflictAdvice(
        id: uuid("000000001101"),
        conflictID: uuid("000000001102"),
        createdAt: phaseDate,
        summary: "Preserve both versions.",
        attribution: "local heuristic"
    )

    await store.store(advice, forKey: "conflict-key")

    #expect(await store.cachedAdvice(forKey: "conflict-key") == advice)
    #expect(await store.cachedAdvice(forKey: "missing") == nil)
}

@Test func locationRegistryRoundTripsAndRefusesReferencedRemoval() async throws {
    let registry = InMemoryLocationRegistry()
    let location = SyncLocation(id: .localFolder, kind: .localFolder, displayName: "Local")
    try await registry.upsert(location)

    #expect(try await registry.allLocations() == [location])

    do {
        try await registry.remove(.localFolder, referencedBy: [uuid("000000001201")])
        #expect(Bool(false))
    } catch let error as LocationRegistryError {
        #expect(error == .referenced(locationID: .localFolder, syncSetIDs: [uuid("000000001201")]))
    }

    try await registry.remove(.localFolder, referencedBy: [])
    #expect(try await registry.allLocations().isEmpty)
}

@Test func inMemoryActivityStoreAppliesEveryQueryFilterNewestFirst() async {
    let store = InMemoryActivityStore()
    let syncSetA = uuid("000000001301")
    let syncSetB = uuid("000000001302")
    let runA = uuid("000000001303")
    let runB = uuid("000000001304")
    let entries = [
        activity(id: "000000001305", at: phaseDate.addingTimeInterval(1), syncSetID: syncSetA, runID: runA, category: .sync, path: "/Docs/A.txt"),
        activity(id: "000000001306", at: phaseDate.addingTimeInterval(3), syncSetID: syncSetA, runID: runA, category: .safety, path: "/Docs/B.txt"),
        activity(id: "000000001307", at: phaseDate.addingTimeInterval(2), syncSetID: syncSetB, runID: runB, category: .sync, path: "/Other/C.txt")
    ]
    for entry in entries {
        await store.append(entry)
    }

    #expect(await store.entries(matching: ActivityQuery()).map(\.id) == [entries[1].id, entries[2].id, entries[0].id])
    #expect(await store.entries(matching: ActivityQuery(syncSetID: syncSetA)).map(\.id) == [entries[1].id, entries[0].id])
    #expect(await store.entries(matching: ActivityQuery(runID: runB)).map(\.id) == [entries[2].id])
    #expect(await store.entries(matching: ActivityQuery(categories: [.safety])).map(\.id) == [entries[1].id])
    #expect(await store.entries(matching: ActivityQuery(pathPrefix: "/Docs")).map(\.id) == [entries[1].id, entries[0].id])
    #expect(await store.entries(matching: ActivityQuery(dateRange: phaseDate.addingTimeInterval(2)...phaseDate.addingTimeInterval(3))).map(\.id) == [entries[1].id, entries[2].id])
    #expect(await store.entries(matching: ActivityQuery(limit: 1)).map(\.id) == [entries[1].id])
}

@Test func fileActivityStoreWritesMonthlyJSONLRoundTripsAndPrunes() async throws {
    let root = try temporaryDirectory("file-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileActivityStore(rootURL: root)
    let oldSync = activity(id: "000000001401", at: phaseDate, category: .sync, path: "/Old.txt")
    let oldSafety = activity(id: "000000001402", at: phaseDate, category: .safety, path: "/Safety.txt")
    let newSync = activity(id: "000000001403", at: phaseDate.addingTimeInterval(10), category: .sync, path: "/New.txt")

    await store.append(oldSync)
    await store.append(oldSafety)
    await store.append(newSync)
    await store.prune(olderThan: phaseDate.addingTimeInterval(5), keepingCategories: [.safety])

    let entries = await store.entries(matching: ActivityQuery())
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

    #expect(entries.map(\.id) == [newSync.id, oldSafety.id])
    #expect(files.contains { $0.lastPathComponent.hasPrefix("activity-") && $0.pathExtension == "jsonl" })
}

@Test func activityRetentionPolicyKeepsSafetyConflictAndErrorsLonger() async {
    let store = InMemoryActivityStore()
    let now = phaseDate.addingTimeInterval(400 * 24 * 60 * 60)
    let oldSync = activity(id: "000000001501", at: now.addingTimeInterval(-100 * 24 * 60 * 60), category: .sync, path: "/Sync.txt")
    let oldSafety = activity(id: "000000001502", at: now.addingTimeInterval(-100 * 24 * 60 * 60), category: .safety, path: "/Safety.txt")
    let tooOldError = activity(id: "000000001503", at: now.addingTimeInterval(-400 * 24 * 60 * 60), category: .error, path: "/Error.txt")
    await store.append(oldSync)
    await store.append(oldSafety)
    await store.append(tooOldError)

    await store.prune(using: .default, now: now)
    let entries = await store.entries(matching: ActivityQuery())

    #expect(entries.map(\.id) == [oldSafety.id])
}

@Test func inMemoryActivityStoreHandlesOneHundredConcurrentAppends() async {
    let store = InMemoryActivityStore()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                await store.append(
                    ActivityEntry(
                        id: uuid(String(format: "%012d", 1_600 + index)),
                        occurredAt: phaseDate.addingTimeInterval(Double(index)),
                        category: .sync,
                        message: "Sync finished."
                    )
                )
            }
        }
    }

    #expect(await store.entries(matching: ActivityQuery(limit: 200)).count == 100)
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomPhase05Tests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func appendRaw(_ text: String, to fileURL: URL) throws {
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { handle.closeFile() }
    handle.seekToEndOfFile()
    handle.write(Data(text.utf8))
    handle.synchronizeFile()
}

private func activity(
    id suffix: String,
    at date: Date,
    syncSetID: UUID? = nil,
    runID: UUID? = nil,
    category: ActivityCategory,
    path: SyncPath
) -> ActivityEntry {
    ActivityEntry(
        id: uuid(suffix),
        occurredAt: date,
        syncSetID: syncSetID,
        runID: runID,
        category: category,
        path: path,
        message: "Sync finished."
    )
}

private func baseRecord(
    syncSetID: UUID,
    path: SyncPath,
    modifiedAt: Date = phaseDate
) -> BaseRecord {
    let version = ItemVersion(contentHash: "hash-\(path.name)", size: 4, modifiedAt: modifiedAt, revisionToken: "rev-\(path.name)")
    return BaseRecord(
        id: uuid("000000009001"),
        syncSetID: syncSetID,
        path: path,
        kind: .file,
        version: version,
        perLocation: [
            .googleDrive: LocationMemory(itemID: "google-\(path.name)", revisionToken: version.revisionToken, lastSeenAt: modifiedAt),
            .oneDrive: LocationMemory(itemID: "one-\(path.name)", revisionToken: version.revisionToken, lastSeenAt: modifiedAt)
        ],
        lastConvergedAt: modifiedAt,
        createdAt: modifiedAt,
        updatedAt: modifiedAt
    )
}

private func transferOperation(id suffix: String) -> AetherloomCore.Operation {
    let source = observation(.googleDrive, path: "/Journal.txt", hash: "journal")
    return AetherloomCore.Operation(
        id: OperationID(uuid(suffix)),
        location: .oneDrive,
        kind: .transfer(content: ContentRef(source), to: source.path, overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
}

private func observation(_ location: LocationID, path: SyncPath, hash: String) -> ItemObservation {
    ItemObservation(
        location: location,
        itemID: "\(location.rawValue.uuidString):\(path.rawValue)",
        path: path,
        kind: .file,
        version: ItemVersion(contentHash: hash, size: Int64(hash.count), modifiedAt: phaseDate, revisionToken: hash)
    )
}

private func uuid(_ suffix: String) -> UUID {
    UUID(uuidString: "50000000-0000-0000-0000-\(suffix)")!
}

private let phaseDate = Date(timeIntervalSince1970: 1_770_000_000)
