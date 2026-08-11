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

@Test func recoveryClosesConfirmedTrashWithoutPromotingSingleOperation() async throws {
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

    #expect(report.reconciledOperations == [trash.id])
    #expect(report.restoredRecords == 0)
    #expect(try await baseRecords.records(for: syncSetID).isEmpty)
}

@Test func recoveryKeepsJournalUnfinishedWhileIndeterminateMutationRuns() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .inFlight,
        recoveryResult: .failure(
            .unavailable(provider: .oneDrive, reason: "still running")
        )
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000201")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Pending"),
        precondition: .pathAbsent
    )
    let runID = journalUUID("000000000203")
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000202"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Pending"],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let syncSetID = journalUUID("000000000204")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "indeterminate")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(
        throws: RunRecoveryError.indeterminateMutationStillRunning(
            operationID: operation.id,
            receiptID: receipt.id
        )
    ) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.recoveryProbeCount() == 0)
    #expect(await provider.finishCount() == 0)
}

@Test func recoveryRejectsDurableReceiptWithoutCorrelation() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let operation = Operation(
        id: OperationID(journalUUID("000000000216")),
        location: .oneDrive,
        kind: .makeFolder(at: "/LegacyUnbound"),
        precondition: .pathAbsent
    )
    let legacyReceipt = ProviderMutationReceipt(
        id: journalUUID("000000000217"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/LegacyUnbound"],
        startedAt: journalDate
    )
    let receipt = try CanonicalCoding.decoder().decode(
        ProviderMutationReceipt.self,
        from: CanonicalCoding.encoder().encode(legacyReceipt)
    )
    #expect(receipt.correlation == nil)
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .success(
            ItemObservation(
                location: .oneDrive,
                path: "/LegacyUnbound",
                kind: .folder
            )
        )
    )
    let runID = journalUUID("000000000218")
    let syncSetID = journalUUID("000000000219")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "nil-durable-correlation")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(
        try await journal.unfinishedRun(for: syncSetID)
    )

    await #expect(
        throws: RunRecoveryError.indeterminateMutationProviderCannotRecover(
            operationID: operation.id
        )
    ) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.recoveryProbeCount() == 0)
    #expect(await provider.finishCount() == 0)
}

@Test func recoveryDoesNotClearIndeterminateStateWhenTruthProbeFails() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let providerError = ProviderError.unavailable(
        provider: .oneDrive,
        reason: "provider offline"
    )
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .failure(providerError)
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000205")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Uncertain"),
        precondition: .pathAbsent
    )
    let runID = journalUUID("000000000207")
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000206"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Uncertain"],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let syncSetID = journalUUID("000000000208")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "unavailable-recovery")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(
        throws: RunRecoveryError.providerTruthUnavailable(
            operationID: operation.id,
            detail: String(describing: providerError)
        )
    ) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.recoveryProbeCount() == 1)
    #expect(await provider.finishCount() == 0)
}

@Test func recoveryDoesNotClearPendingIntentWhenProviderTruthIsUnavailable() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let provider = FakeStorageProvider(locationID: .oneDrive)
    await provider.setAvailability(
        .unavailable(.volumeUnreachable(detail: "provider offline"))
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000209")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Unknown"),
        precondition: .pathAbsent
    )
    let runID = journalUUID("000000000210")
    let syncSetID = journalUUID("000000000211")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "pending-unavailable")
    )
    try await journal.append(.intent(operation), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(throws: RunRecoveryError.self) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
}

@Test func recoveryRejectsProviderTruthFromAnotherPath() async throws {
    let journal = InMemoryRunJournalStore()
    let baseRecords = InMemoryBaseRecordStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000212")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Expected"),
        precondition: .pathAbsent
    )
    let runID = journalUUID("000000000214")
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000213"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Expected"],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .success(
            ItemObservation(
                location: .oneDrive,
                path: "/Unrelated",
                kind: .folder
            )
        )
    )
    let syncSetID = journalUUID("000000000215")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "wrong-recovery-attribution")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(throws: RunRecoveryError.self) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await baseRecords.records(for: syncSetID).isEmpty)
    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.finishCount() == 0)
}

@Test(arguments: RelocateRecoveryScenario.allCases)
func relocateRecoveryRequiresTwoEndpointVersionProof(
    scenario: RelocateRecoveryScenario
) async throws {
    let journal = InMemoryRunJournalStore()
    let baseRecords = InMemoryBaseRecordStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let sourcePath: SyncPath = "/Before.txt"
    let destinationPath: SyncPath = "/After.txt"
    let expectedVersion = ItemVersion(contentHash: "expected-content")
    let expected = ItemObservation(
        location: .oneDrive,
        path: sourcePath,
        kind: .file,
        version: expectedVersion
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000301")),
        location: .oneDrive,
        kind: .relocate(itemRef: ItemRef(expected), to: destinationPath),
        precondition: .versionMatches(expectedVersion)
    )
    let runID = journalUUID("000000000303")
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000302"),
        provider: .oneDrive,
        kind: .relocate,
        affectedPaths: [sourcePath, destinationPath],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let provider = PathScriptedRelocateRecoveryProvider(
        locationID: .oneDrive,
        results: scenario.results(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            expectedVersion: expectedVersion
        )
    )
    let syncSetID = journalUUID("000000000304")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "relocate-\(scenario.rawValue)")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))
    let recovery = RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: ExecutionEnvironment(
            now: { journalDate },
            makeID: { journalUUID("000000000305") }
        )
    )

    if scenario.shouldReconcile {
        let report = try await recovery.recover(replay)
        #expect(report.reconciledOperations == [operation.id])
        #expect(await provider.finishCount() == 1)
        #expect(try await baseRecords.records(for: syncSetID).isEmpty)
        #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
    } else {
        await #expect(throws: RunRecoveryError.self) {
            _ = try await recovery.recover(replay)
        }
        #expect(await provider.finishCount() == 0)
        #expect(try await baseRecords.records(for: syncSetID) == [])
        #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    }
    #expect(await provider.probedPaths() == [destinationPath, sourcePath])
}

@Test func recoveryDoesNotPromoteOneSuccessfulDestinationPastFailedSibling() async throws {
    let syncSetID = journalUUID("000000000401")
    let runID = journalUUID("000000000402")
    let oldVersion = ItemVersion(contentHash: "old")
    let newVersion = ItemVersion(contentHash: "new")
    let original = journalBaseRecord(
        id: journalUUID("000000000403"),
        syncSetID: syncSetID,
        path: "/Shared.txt",
        version: oldVersion,
        locations: [.googleDrive, .oneDrive, .localFolder]
    )
    let baseRecords = InMemoryBaseRecordStore(records: [original])
    let journal = InMemoryRunJournalStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let content = ContentRef(
        sourceLocation: .googleDrive,
        itemID: "source-item",
        path: "/Shared.txt",
        kind: .file,
        expectedVersion: newVersion
    )
    let confirmed = Operation(
        id: OperationID(journalUUID("000000000404")),
        location: .oneDrive,
        kind: .transfer(
            content: content,
            to: "/Shared.txt",
            overwrite: .ifVersionMatches(oldVersion)
        ),
        precondition: .versionMatches(oldVersion)
    )
    let failedSibling = Operation(
        id: OperationID(journalUUID("000000000405")),
        location: .localFolder,
        kind: .transfer(
            content: content,
            to: "/Shared.txt",
            overwrite: .ifVersionMatches(oldVersion)
        ),
        precondition: .versionMatches(oldVersion)
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000406"),
        provider: .oneDrive,
        kind: .store,
        affectedPaths: ["/Shared.txt"],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: confirmed.id
        )
    )
    let confirmedProvider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .success(
            ItemObservation(
                location: .oneDrive,
                itemID: "destination-item",
                path: "/Shared.txt",
                kind: .file,
                version: newVersion
            )
        )
    )
    let unappliedProvider = FakeStorageProvider(locationID: .localFolder)

    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "multi-destination-recovery")
    )
    try await journal.append(.intent(confirmed), runID: runID)
    try await journal.append(.intent(failedSibling), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: confirmed.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    let report = try await RunRecovery(
        providers: [
            .oneDrive: confirmedProvider,
            .localFolder: unappliedProvider,
        ],
        stores: stores
    ).recover(replay)

    #expect(report.reconciledOperations == [confirmed.id, failedSibling.id])
    #expect(report.restoredRecords == 0)
    #expect(try await baseRecords.records(for: syncSetID) == [original])
    #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
}

@Test func recoveryRetryAfterJournalCommitFailureLeavesBaseIdentical() async throws {
    let syncSetID = journalUUID("000000000411")
    let runID = journalUUID("000000000412")
    let original = journalBaseRecord(
        id: journalUUID("000000000413"),
        syncSetID: syncSetID,
        path: "/Stable",
        kind: .folder,
        version: ItemVersion(),
        locations: [.oneDrive]
    )
    let baseRecords = InMemoryBaseRecordStore(records: [original])
    let journal = FailOnceMarkReconciledJournalStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000414")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Stable"),
        precondition: .pathAbsent
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000415"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Stable"],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .success(
            ItemObservation(
                location: .oneDrive,
                path: "/Stable",
                kind: .folder
            )
        )
    )
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "retry-stable-base")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let firstReplay = try #require(
        try await journal.unfinishedRun(for: syncSetID)
    )

    await #expect(throws: FailOnceMarkReconciledJournalStore.ExpectedFailure.self) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(firstReplay)
    }
    #expect(try await baseRecords.records(for: syncSetID) == [original])

    let retryReplay = try #require(
        try await journal.unfinishedRun(for: syncSetID)
    )
    _ = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores
    ).recover(retryReplay)

    #expect(try await baseRecords.records(for: syncSetID) == [original])
    #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
}

@Test func relocateRecoveryPreservesExistingRecordIdentityAndTimestamps() async throws {
    let syncSetID = journalUUID("000000000421")
    let runID = journalUUID("000000000422")
    let sourcePath: SyncPath = "/Before.txt"
    let destinationPath: SyncPath = "/After.txt"
    let version = ItemVersion(contentHash: "stable-relocate")
    let original = journalBaseRecord(
        id: journalUUID("000000000423"),
        syncSetID: syncSetID,
        path: sourcePath,
        version: version,
        locations: [.oneDrive]
    )
    let baseRecords = InMemoryBaseRecordStore(records: [original])
    let journal = InMemoryRunJournalStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let expected = ItemObservation(
        location: .oneDrive,
        path: sourcePath,
        kind: .file,
        version: version
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000424")),
        location: .oneDrive,
        kind: .relocate(itemRef: ItemRef(expected), to: destinationPath),
        precondition: .versionMatches(version)
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000425"),
        provider: .oneDrive,
        kind: .relocate,
        affectedPaths: [sourcePath, destinationPath],
        startedAt: journalDate,
        correlation: ProviderMutationCorrelation(
            runID: runID,
            operationID: operation.id
        )
    )
    let provider = PathScriptedRelocateRecoveryProvider(
        locationID: .oneDrive,
        results: [
            sourcePath: .success(nil),
            destinationPath: .success(
                ItemObservation(
                    location: .oneDrive,
                    path: destinationPath,
                    kind: .file,
                    version: version
                )
            ),
        ]
    )
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "stable-relocate-record")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    _ = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores
    ).recover(replay)

    let records = try await baseRecords.records(for: syncSetID)
    #expect(records == [original])
    #expect(records.map(\.id) == [original.id])
    #expect(records.map(\.createdAt) == [original.createdAt])
    #expect(records.map(\.updatedAt) == [original.updatedAt])
}

private func recoveryStores(journal: any RunJournalStore) -> EngineStores {
    EngineStores(
        baseRecords: InMemoryBaseRecordStore(),
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
}

private actor FailOnceMarkReconciledJournalStore: RunJournalStore {
    struct ExpectedFailure: Error {}

    private let delegate = InMemoryRunJournalStore()
    private var shouldFail = true

    func begin(
        runID: UUID,
        syncSetID: UUID,
        fingerprint: PlanFingerprint
    ) async throws {
        try await delegate.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: fingerprint
        )
    }

    func append(_ event: JournalEvent, runID: UUID) async throws {
        try await delegate.append(event, runID: runID)
    }

    func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay? {
        try await delegate.unfinishedRun(for: syncSetID)
    }

    func markReconciled(runID: UUID) async throws {
        if shouldFail {
            shouldFail = false
            throw ExpectedFailure()
        }
        try await delegate.markReconciled(runID: runID)
    }
}

private func journalBaseRecord(
    id: UUID,
    syncSetID: UUID,
    path: SyncPath,
    kind: ItemKind = .file,
    version: ItemVersion,
    locations: [LocationID]
) -> BaseRecord {
    BaseRecord(
        id: id,
        syncSetID: syncSetID,
        path: path,
        kind: kind,
        version: version,
        perLocation: Dictionary(uniqueKeysWithValues: locations.map {
            (
                $0,
                LocationMemory(
                    itemID: "item-\($0.rawValue.uuidString)",
                    revisionToken: version.revisionToken,
                    lastSeenAt: journalDate
                )
            )
        }),
        lastConvergedAt: journalDate,
        createdAt: journalDate.addingTimeInterval(-20),
        updatedAt: journalDate.addingTimeInterval(-10)
    )
}

private actor ScriptedIndeterminateRecoveryProvider:
    IndeterminateMutationRecovering
{
    nonisolated let locationID: LocationID
    nonisolated let capabilities = ProviderCapabilities.fullFidelity

    private let scriptedState: ProviderIndeterminateMutationState
    private let recoveryResult: Result<ItemObservation, ProviderError>
    private var probes = 0
    private var finishes = 0

    init(
        locationID: LocationID,
        state: ProviderIndeterminateMutationState,
        recoveryResult: Result<ItemObservation, ProviderError>
    ) {
        self.locationID = locationID
        self.scriptedState = state
        self.recoveryResult = recoveryResult
    }

    func checkAvailability() async -> LocationAvailability { .available }
    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        LocationSnapshot(location: locationID, scope: scope, observations: [], status: .complete)
    }
    func changedSubtrees(in _: SyncScope, since _: ChangeCursor?) async throws -> ChangeHint {
        ChangeHint(changedRoots: [], isComplete: false)
    }
    func fetch(_: ItemObservation, to _: URL) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "test")
    }
    func store(from _: URL, at path: SyncPath, options _: StoreOptions) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func relocate(_ observation: ItemObservation, to _: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: observation.path.rawValue)
    }
    func trash(_ observation: ItemObservation) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: observation.path.rawValue)
    }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        throw ProviderError.unavailable(provider: locationID, reason: observation.path.rawValue)
    }
    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        scriptedState
    }
    func beginIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderMutationRecoveryClaimResult {
        switch scriptedState {
        case .inFlight:
            return .inFlight
        case .quiescent, .unknownAfterRestart:
            return .claimed(
                ProviderMutationRecoveryClaim(receipt: receipt)
            )
        }
    }
    func currentStateForRecovery(
        of _: ItemObservation,
        claim _: ProviderMutationRecoveryClaim
    ) async throws -> ItemObservation {
        probes += 1
        return try recoveryResult.get()
    }
    func finishIndeterminateMutationRecovery(
        _: ProviderMutationRecoveryClaim
    ) async {
        finishes += 1
    }
    func abandonIndeterminateMutationRecovery(
        _: ProviderMutationRecoveryClaim
    ) async {}
    func recoveryProbeCount() -> Int { probes }
    func finishCount() -> Int { finishes }
}

enum RelocateRecoveryScenario: String, CaseIterable, Sendable {
    case sameVolumeDestinationOnly
    case crossVolumeSourceTrashed
    case copyBeforeTrashBothPresent
    case unrelatedDestination
    case wrongDestinationKind
    case sourceUnavailable
    case destinationUnavailable
    case insufficientVersionEvidence

    var shouldReconcile: Bool {
        self == .sameVolumeDestinationOnly || self == .crossVolumeSourceTrashed
    }

    func results(
        sourcePath: SyncPath,
        destinationPath: SyncPath,
        expectedVersion: ItemVersion
    ) -> [SyncPath: Result<ItemObservation?, ProviderError>] {
        let source = ItemObservation(
            location: .oneDrive,
            path: sourcePath,
            kind: .file,
            version: expectedVersion
        )
        let destination = ItemObservation(
            location: .oneDrive,
            path: destinationPath,
            kind: .file,
            version: expectedVersion
        )
        switch self {
        case .sameVolumeDestinationOnly:
            return [sourcePath: .success(nil), destinationPath: .success(destination)]
        case .crossVolumeSourceTrashed:
            var trashed = source
            trashed.isTrashed = true
            return [sourcePath: .success(trashed), destinationPath: .success(destination)]
        case .copyBeforeTrashBothPresent:
            return [sourcePath: .success(source), destinationPath: .success(destination)]
        case .unrelatedDestination:
            var unrelated = destination
            unrelated.version = ItemVersion(contentHash: "unrelated")
            return [sourcePath: .success(source), destinationPath: .success(unrelated)]
        case .wrongDestinationKind:
            var folder = destination
            folder.kind = .folder
            return [sourcePath: .success(nil), destinationPath: .success(folder)]
        case .sourceUnavailable:
            return [
                sourcePath: .failure(
                    .unavailable(provider: .oneDrive, reason: "source unavailable")
                ),
                destinationPath: .success(destination),
            ]
        case .destinationUnavailable:
            return [
                sourcePath: .success(source),
                destinationPath: .failure(
                    .unavailable(provider: .oneDrive, reason: "destination unavailable")
                ),
            ]
        case .insufficientVersionEvidence:
            var unknown = destination
            unknown.version = ItemVersion()
            return [sourcePath: .success(nil), destinationPath: .success(unknown)]
        }
    }
}

private actor PathScriptedRelocateRecoveryProvider:
    IndeterminateMutationRecovering
{
    nonisolated let locationID: LocationID
    nonisolated let capabilities = ProviderCapabilities.fullFidelity

    private let results: [SyncPath: Result<ItemObservation?, ProviderError>]
    private var probes: [SyncPath] = []
    private var finishes = 0

    init(
        locationID: LocationID,
        results: [SyncPath: Result<ItemObservation?, ProviderError>]
    ) {
        self.locationID = locationID
        self.results = results
    }

    func checkAvailability() async -> LocationAvailability { .available }
    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        LocationSnapshot(
            location: locationID,
            scope: scope,
            observations: [],
            status: .complete
        )
    }
    func changedSubtrees(in _: SyncScope, since _: ChangeCursor?) async throws -> ChangeHint {
        ChangeHint(changedRoots: [], isComplete: false)
    }
    func fetch(_: ItemObservation, to _: URL) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "test")
    }
    func store(
        from _: URL,
        at path: SyncPath,
        options _: StoreOptions
    ) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func relocate(
        _ observation: ItemObservation,
        to _: SyncPath
    ) async throws -> ItemObservation {
        throw ProviderError.unsupported(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func trash(_ observation: ItemObservation) async throws {
        throw ProviderError.unsupported(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        throw ProviderError.unavailable(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        .quiescent(.succeeded)
    }
    func beginIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderMutationRecoveryClaimResult {
        .claimed(ProviderMutationRecoveryClaim(receipt: receipt))
    }
    func currentStateForRecovery(
        of observation: ItemObservation,
        claim _: ProviderMutationRecoveryClaim
    ) async throws -> ItemObservation {
        probes.append(observation.path)
        guard let result = results[observation.path] else {
            throw ProviderError.notFound(
                provider: locationID,
                path: observation.path
            )
        }
        guard let current = try result.get() else {
            throw ProviderError.notFound(
                provider: locationID,
                path: observation.path
            )
        }
        return current
    }
    func finishIndeterminateMutationRecovery(
        _: ProviderMutationRecoveryClaim
    ) async {
        finishes += 1
    }
    func abandonIndeterminateMutationRecovery(
        _: ProviderMutationRecoveryClaim
    ) async {}
    func probedPaths() -> [SyncPath] { probes }
    func finishCount() -> Int { finishes }
}

private func journalUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "93000000-0000-0000-0000-\(suffix)")!
}

private let journalDate = Date(timeIntervalSince1970: 1_770_000_000)
