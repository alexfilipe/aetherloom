import Foundation
import Testing
@testable import AetherloomCore

@Test func runJournalFinishedRunsAreHiddenAndFinishIsIdempotent() async throws {
    let store = InMemoryRunJournalStore()
    let syncSetID = journalUUID("000000000101")
    let runID = journalUUID("000000000102")

    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "journal"))
    try await store.append(.runFinished(outcome: .succeeded, occurredAt: journalDate, detail: nil), runID: runID)
    try await store.append(.runFinished(outcome: .succeeded, occurredAt: journalDate, detail: nil), runID: runID)

    #expect(try await store.unfinishedRun(for: syncSetID) == nil)
}

@Test func recoveryMarksPendingTrashIntentOnlyAfterProviderTruthConfirmsTrash() async throws {
    let baseRecords = InMemoryBaseRecordStore()
    let journal = InMemoryRunJournalStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let item = await provider.putFile(path: "/PendingTrash.txt", contents: Data("trash".utf8), modifiedAt: journalDate)
    try await provider.trash(item)
    let trash = Operation(
        id: OperationID(journalUUID("000000000103")),
        location: .oneDrive,
        kind: .trash(itemRef: ItemRef(item)),
        precondition: .versionMatches(item.version)
    )
    let runID = journalUUID("000000000104")
    let syncSetID = journalUUID("000000000105")
    try await journal.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "trash"))
    try await journal.append(.intent(trash), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    let report = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: ExecutionEnvironment(now: { journalDate }, makeID: { journalUUID("000000000106") })
    ).recover(replay)
    let record = try #require(try await baseRecords.records(for: syncSetID).first)

    #expect(report.reconciledOperations == [trash.id])
    #expect(record.tombstone?.deletedAt == journalDate)
}

private func journalUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "93000000-0000-0000-0000-\(suffix)")!
}

private let journalDate = Date(timeIntervalSince1970: 1_770_000_000)
