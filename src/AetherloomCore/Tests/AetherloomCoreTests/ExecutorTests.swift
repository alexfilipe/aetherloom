import Foundation
import Testing
@testable import AetherloomCore

@Test func contentStageFansOutOneFetchToThreeStores() async throws {
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destinations = [
        FakeStorageProvider(locationID: .oneDrive),
        FakeStorageProvider(locationID: .localFolder),
        FakeStorageProvider(locationID: .nasFolder)
    ]
    let sourceItem = await source.putFile(path: "/Fanout.txt", contents: Data("fanout".utf8), modifiedAt: phase06Date)
    let content = ContentRef(sourceItem)
    let operations = destinations.enumerated().map { index, provider in
        operation(
            String(format: "00000000010%d", index),
            location: provider.locationID,
            kind: .transfer(content: content, to: sourceItem.path, overwrite: .neverOverwrite),
            precondition: .pathAbsent
        )
    }
    let plan = planForOperations(operations, path: sourceItem.path)
    let stores = EngineStores.inMemory()
    let executor = try executor(
        providers: [source] + destinations,
        stores: stores,
        name: "fanout",
        maxParallelism: 3
    )

    let summary = try await executor.execute(plan, runID: uuid("000000000101"))

    #expect(summary.appliedOperations.count == 3)
    #expect(await source.callLog().filter { $0.operation == .fetch }.count == 1)
    for destination in destinations {
        #expect(await destination.callLog().filter { $0.operation == .store }.count == 1)
        #expect(await destination.item(at: "/Fanout.txt") != nil)
    }
}

@Test func hashMismatchFailsItemAndDoesNotStoreCorruptContent() async throws {
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destination = FakeStorageProvider(locationID: .oneDrive)
    let sourceItem = await source.putFile(path: "/Corrupt.txt", contents: Data("truth".utf8), modifiedAt: phase06Date)
    var corruptRef = ContentRef(sourceItem)
    corruptRef.expectedVersion.contentHash = "wrong-hash"
    let transfer = operation(
        "000000000201",
        location: .oneDrive,
        kind: .transfer(content: corruptRef, to: "/Corrupt.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let plan = planForOperations([transfer], path: "/Corrupt.txt")
    let stores = EngineStores.inMemory()
    let executor = try executor(providers: [source, destination], stores: stores, name: "hash-mismatch")

    let summary = try await executor.execute(plan, runID: uuid("000000000202"))
    let errors = await stores.activity.entries(matching: ActivityQuery(categories: [.error], limit: 10))

    #expect(summary.failedOperations.count == 1)
    #expect(await destination.item(at: "/Corrupt.txt") == nil)
    #expect(errors.contains { $0.message == ActivityMessageCatalog.verificationFailed })
}

@Test func postWriteVerificationFailureIsRecordedAndRunContinues() async throws {
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destinationBase = FakeStorageProvider(locationID: .oneDrive)
    let destination = CorruptAfterStoreProvider(base: destinationBase, replacement: Data("truncated".utf8))
    let sourceItem = await source.putFile(path: "/Verify.txt", contents: Data("expected content".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000000301",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/Verify.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let plan = planForOperations([transfer], path: "/Verify.txt")
    let stores = EngineStores.inMemory()
    let executor = try executor(
        providerMap: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        name: "verify-failure"
    )

    let summary = try await executor.execute(plan, runID: uuid("000000000302"))

    #expect(summary.outcome == .failed(message: summary.failedOperations.first?.detail ?? ""))
    #expect(summary.failedOperations.count == 1)
    #expect(summary.perItemResults.first?.status == .failed)
}

@Test func transferOperationsCompleteBeforeTrashBegins() async throws {
    let recorder = EventRecorder()
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destination = RecordingProvider(base: FakeStorageProvider(locationID: .oneDrive), recorder: recorder)
    let trashBase = FakeStorageProvider(locationID: .localFolder)
    let trashProvider = RecordingProvider(base: trashBase, recorder: recorder)
    let sourceItem = await source.putFile(path: "/New.txt", contents: Data("new".utf8), modifiedAt: phase06Date)
    let oldItem = await trashBase.putFile(path: "/Old.txt", contents: Data("old".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000000401",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/New.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let trash = operation(
        "000000000402",
        location: .localFolder,
        kind: .trash(itemRef: ItemRef(oldItem)),
        precondition: .versionMatches(oldItem.version)
    )
    let plan = planForOperations([transfer, trash], path: "/Barrier.txt")
    let executor = try executor(
        providerMap: [.googleDrive: source, .oneDrive: destination, .localFolder: trashProvider],
        stores: .inMemory(),
        name: "barrier",
        maxParallelism: 3
    )

    _ = try await executor.execute(plan, runID: uuid("000000000403"))
    let events = await recorder.events()
    let storeIndex = try #require(events.firstIndex(of: "oneDrive.store:/New.txt"))
    let trashIndex = try #require(events.firstIndex(of: "localFolder.trash:/Old.txt"))

    #expect(storeIndex < trashIndex)
}

@Test func crossLocationParallelismBoundIsRespected() async throws {
    let gate = StoreGate()
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destinations: [GatedStoreProvider] = [
        GatedStoreProvider(base: FakeStorageProvider(locationID: .oneDrive), gate: gate),
        GatedStoreProvider(base: FakeStorageProvider(locationID: .localFolder), gate: gate),
        GatedStoreProvider(base: FakeStorageProvider(locationID: .nasFolder), gate: gate)
    ]
    let sourceItem = await source.putFile(path: "/Parallel.txt", contents: Data("parallel".utf8), modifiedAt: phase06Date)
    let operations = destinations.enumerated().map { index, provider in
        operation(
            String(format: "00000000050%d", index),
            location: provider.locationID,
            kind: .transfer(content: ContentRef(sourceItem), to: "/Parallel.txt", overwrite: .neverOverwrite),
            precondition: .pathAbsent
        )
    }
    let plan = planForOperations(operations, path: "/Parallel.txt")
    let executor = try executor(
        providerMap: Dictionary(uniqueKeysWithValues: [(.googleDrive, source)] + destinations.map { ($0.locationID, $0 as any StorageProvider) }),
        stores: .inMemory(),
        name: "parallelism",
        maxParallelism: 2
    )

    let task = Task {
        try await executor.execute(plan, runID: uuid("000000000501"))
    }
    await gate.waitForActiveCount(2)
    #expect(await gate.maxActiveCount() == 2)
    await gate.releaseAll()
    let summary = try await task.value

    #expect(summary.appliedOperations.count == 3)
    #expect(await gate.maxActiveCount() == 2)
}

@Test func journalIntentIsWrittenBeforeProviderSideEffect() async throws {
    let recorder = EventRecorder()
    let journal = RecordingRunJournalStore(delegate: InMemoryRunJournalStore(), recorder: recorder)
    let stores = engineStores(journal: journal)
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destination = RecordingProvider(base: FakeStorageProvider(locationID: .oneDrive), recorder: recorder)
    let sourceItem = await source.putFile(path: "/Wal.txt", contents: Data("wal".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000000601",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/Wal.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let plan = planForOperations([transfer], path: "/Wal.txt")
    let executor = try executor(
        providerMap: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        name: "wal"
    )

    _ = try await executor.execute(plan, runID: uuid("000000000602"))
    let events = await recorder.events()
    let intentIndex = try #require(events.firstIndex(of: "journal.intent:/Wal.txt"))
    let storeIndex = try #require(events.firstIndex(of: "oneDrive.store:/Wal.txt"))

    #expect(intentIndex < storeIndex)
}

@Test func baseRecordUpdatesLandBeforeRunFinished() async throws {
    let recorder = EventRecorder()
    let baseRecords = RecordingBaseRecordStore(delegate: InMemoryBaseRecordStore(), recorder: recorder)
    let journal = RecordingRunJournalStore(delegate: InMemoryRunJournalStore(), recorder: recorder)
    let stores = engineStores(baseRecords: baseRecords, journal: journal)
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destination = FakeStorageProvider(locationID: .oneDrive)
    let sourceItem = await source.putFile(path: "/Record.txt", contents: Data("record".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000000701",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/Record.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let plan = planForOperations([transfer], path: "/Record.txt")
    let executor = try executor(providers: [source, destination], stores: stores, name: "record-before-finish")

    _ = try await executor.execute(plan, runID: uuid("000000000702"))
    let events = await recorder.events()
    let applyIndex = try #require(events.firstIndex(of: "base.apply:/Record.txt"))
    let finishIndex = try #require(events.firstIndex(of: "journal.runFinished"))

    #expect(applyIndex < finishIndex)
}

@Test func runRecoveryRestoresJournaledConvergenceAndMarksRunReconciled() async throws {
    let baseRecords = InMemoryBaseRecordStore()
    let journal = InMemoryRunJournalStore()
    let stores = engineStores(baseRecords: baseRecords, journal: journal)
    let syncSetID = uuid("000000000801")
    let runID = uuid("000000000802")
    let record = baseRecord(syncSetID: syncSetID, path: "/Recovered.txt")

    try await journal.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "phase06"))
    try await journal.append(.itemConverged(decisionID: uuid("000000000803"), record: record), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    let report = try await RunRecovery(providers: [:], stores: stores, environment: phase06Environment()).recover(replay)

    #expect(report.restoredRecords == 1)
    #expect(try await baseRecords.records(for: syncSetID) == [record])
    #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
}

@Test func runRecoveryProbesPendingIntentAndRecordsObservedTruth() async throws {
    let baseRecords = InMemoryBaseRecordStore()
    let journal = InMemoryRunJournalStore()
    let stores = engineStores(baseRecords: baseRecords, journal: journal)
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let syncSetID = uuid("000000000901")
    let runID = uuid("000000000902")
    let makeFolder = operation(
        "000000000903",
        location: .oneDrive,
        kind: .makeFolder(at: "/RecoveredFolder"),
        precondition: .pathAbsent
    )
    await provider.putFolder(path: "/RecoveredFolder", modifiedAt: phase06Date)
    try await journal.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "phase06"))
    try await journal.append(.intent(makeFolder), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    let report = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: phase06Environment()
    ).recover(replay)

    #expect(report.reconciledOperations == [makeFolder.id])
    #expect(try await baseRecords.records(for: syncSetID).map(\.path) == ["/RecoveredFolder"])
}

@Test func heldPlansAreNotExecutableInPhase06() async throws {
    let source = FakeStorageProvider(locationID: .googleDrive)
    let destination = FakeStorageProvider(locationID: .oneDrive)
    let sourceItem = await source.putFile(path: "/Held.txt", contents: Data("held".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000001001",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/Held.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let plan = planForOperations([transfer], path: "/Held.txt", gate: .hold([.deletionsNeedReview(count: 1)]))
    let executor = try executor(providers: [source, destination], stores: .inMemory(), name: "held")

    await #expect(throws: ScheduleExecutionError.planNeedsReview) {
        _ = try await executor.execute(plan, runID: uuid("000000001002"))
    }
}

@Test func hashlessSourceGetsEngineComputedHashInBaseRecord() async throws {
    var capabilities = ProviderCapabilities.fullFidelity
    capabilities.hasContentHashes = false
    let source = FakeStorageProvider(locationID: .googleDrive, capabilities: capabilities)
    let destination = FakeStorageProvider(locationID: .oneDrive)
    let sourceItem = await source.putFile(path: "/Hashless.txt", contents: Data("hash me".utf8), modifiedAt: phase06Date)
    let transfer = operation(
        "000000001101",
        location: .oneDrive,
        kind: .transfer(content: ContentRef(sourceItem), to: "/Hashless.txt", overwrite: .neverOverwrite),
        precondition: .pathAbsent
    )
    let baseRecords = InMemoryBaseRecordStore()
    let stores = engineStores(baseRecords: baseRecords)
    let plan = planForOperations([transfer], path: "/Hashless.txt")
    let executor = try executor(providers: [source, destination], stores: stores, name: "hash-upgrade")

    _ = try await executor.execute(plan, runID: uuid("000000001102"))
    let record = try #require(try await baseRecords.records(for: phase06SyncSetID).first)

    #expect(sourceItem.version.contentHash == nil)
    #expect(record.version.contentHash != nil)
}

@Test func alreadyTrashedOperationIsSkippedAsSatisfied() async throws {
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let item = await provider.putFile(path: "/AlreadyTrash.txt", contents: Data("trash".utf8), modifiedAt: phase06Date)
    try await provider.trash(item)
    let trash = operation(
        "000000001201",
        location: .oneDrive,
        kind: .trash(itemRef: ItemRef(item)),
        precondition: .versionMatches(item.version)
    )
    let stores = EngineStores.inMemory()
    try await stores.baseRecords.apply(.upsert(baseRecord(syncSetID: phase06SyncSetID, path: "/AlreadyTrash.txt", item: item)))
    let executor = try executor(providers: [provider], stores: stores, name: "already-trash")

    let summary = try await executor.execute(planForOperations([trash], path: "/AlreadyTrash.txt"), runID: uuid("000000001202"))

    #expect(summary.appliedOperations.isEmpty)
    #expect(summary.skippedOperations.map(\.operationID) == [trash.id])
}

private actor EventRecorder {
    private var recorded: [String] = []

    func record(_ event: String) {
        recorded.append(event)
    }

    func events() -> [String] {
        recorded
    }
}

private actor StoreGate {
    private var active = 0
    private var maxActive = 0
    private var released = false
    private var activeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        active += 1
        maxActive = max(maxActive, active)
        resumeActiveWaiters()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        active -= 1
    }

    func waitForActiveCount(_ count: Int) async {
        if maxActive >= count {
            return
        }
        await withCheckedContinuation { continuation in
            activeWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func maxActiveCount() -> Int {
        maxActive
    }

    private func resumeActiveWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in activeWaiters {
            if maxActive >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        activeWaiters = remaining
    }
}

private actor RecordingProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let recorder: EventRecorder

    init(base: FakeStorageProvider, recorder: EventRecorder) {
        self.base = base
        self.recorder = recorder
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability {
        await base.checkAvailability()
    }

    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        await base.scan(scope)
    }

    func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        try await base.changedSubtrees(in: scope, since: cursor)
    }

    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await base.fetch(observation, to: stagingURL)
    }

    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        await recorder.record("\(locationID.shortName).store:\(path.rawValue)")
        return try await base.store(from: stagingURL, at: path, options: options)
    }

    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try await base.makeFolder(at: path)
    }

    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }

    func trash(_ observation: ItemObservation) async throws {
        await recorder.record("\(locationID.shortName).trash:\(observation.path.rawValue)")
        try await base.trash(observation)
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
}

private actor GatedStoreProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let gate: StoreGate

    init(base: FakeStorageProvider, gate: StoreGate) {
        self.base = base
        self.gate = gate
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability { await base.checkAvailability() }
    func scan(_ scope: SyncScope) async -> LocationSnapshot { await base.scan(scope) }
    func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        try await base.changedSubtrees(in: scope, since: cursor)
    }
    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await base.fetch(observation, to: stagingURL)
    }
    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        await gate.enterAndWait()
        return try await base.store(from: stagingURL, at: path, options: options)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation { try await base.makeFolder(at: path) }
    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }
    func trash(_ observation: ItemObservation) async throws { try await base.trash(observation) }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
}

private actor CorruptAfterStoreProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let replacement: Data

    init(base: FakeStorageProvider, replacement: Data) {
        self.base = base
        self.replacement = replacement
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability { await base.checkAvailability() }
    func scan(_ scope: SyncScope) async -> LocationSnapshot { await base.scan(scope) }
    func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        try await base.changedSubtrees(in: scope, since: cursor)
    }
    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await base.fetch(observation, to: stagingURL)
    }
    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        let stored = try await base.store(from: stagingURL, at: path, options: options)
        await base.putFile(path: path, contents: replacement, modifiedAt: phase06Date.addingTimeInterval(1), itemID: stored.itemID)
        return stored
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation { try await base.makeFolder(at: path) }
    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }
    func trash(_ observation: ItemObservation) async throws { try await base.trash(observation) }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
}

private actor RecordingRunJournalStore: RunJournalStore {
    private let delegate: InMemoryRunJournalStore
    private let recorder: EventRecorder

    init(delegate: InMemoryRunJournalStore, recorder: EventRecorder) {
        self.delegate = delegate
        self.recorder = recorder
    }

    func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws {
        try await delegate.begin(runID: runID, syncSetID: syncSetID, fingerprint: fingerprint)
    }

    func append(_ event: JournalEvent, runID: UUID) async throws {
        switch event {
        case let .intent(operation):
            await recorder.record("journal.intent:\(operation.kind.targetPath.rawValue)")
        case .runFinished:
            await recorder.record("journal.runFinished")
        case .result, .itemConverged:
            break
        }
        try await delegate.append(event, runID: runID)
    }

    func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay? {
        try await delegate.unfinishedRun(for: syncSetID)
    }

    func markReconciled(runID: UUID) async throws {
        try await delegate.markReconciled(runID: runID)
    }
}

private actor RecordingBaseRecordStore: BaseRecordStore {
    private let delegate: InMemoryBaseRecordStore
    private let recorder: EventRecorder

    init(delegate: InMemoryBaseRecordStore, recorder: EventRecorder) {
        self.delegate = delegate
        self.recorder = recorder
    }

    func records(for syncSetID: UUID) async throws -> [BaseRecord] {
        try await delegate.records(for: syncSetID)
    }

    func apply(_ update: BaseRecordUpdate) async throws {
        if case let .upsert(record) = update.kind {
            await recorder.record("base.apply:\(record.path.rawValue)")
        }
        try await delegate.apply(update)
    }
}

private func executor(
    providers: [FakeStorageProvider],
    stores: EngineStores,
    name: String,
    maxParallelism: Int = 3
) throws -> ScheduleExecutor {
    var providerMap: [LocationID: any StorageProvider] = [:]
    for provider in providers {
        providerMap[provider.locationID] = provider
    }
    return try executor(providerMap: providerMap, stores: stores, name: name, maxParallelism: maxParallelism)
}

private func executor(
    providerMap: [LocationID: any StorageProvider],
    stores: EngineStores,
    name: String,
    maxParallelism: Int = 3
) throws -> ScheduleExecutor {
    ScheduleExecutor(
        providers: providerMap,
        stores: stores,
        stage: ContentStage(rootDirectory: try temporaryDirectory("phase06-\(name)"), byteLimit: 10_000_000),
        environment: phase06Environment(maxParallelism: maxParallelism)
    )
}

private func engineStores(
    baseRecords: any BaseRecordStore = InMemoryBaseRecordStore(),
    journal: any RunJournalStore = InMemoryRunJournalStore()
) -> EngineStores {
    EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
}

private func planForOperations(
    _ operations: [AetherloomCore.Operation],
    path: SyncPath,
    gate: ExecutionGate = .clear
) -> SyncPlan {
    let decisions = operations.enumerated().map { index, operation in
        ItemDecision(
            id: uuid(String(format: "000000009%03d", index)),
            path: operation.kind.targetPath,
            verdict: verdict(for: [operation]),
            operations: [operation.id],
            explanation: "Phase 06 execution test."
        )
    }
    let schedule = OperationSchedule(operations: operations)
    return SyncPlan(
        syncSetID: phase06SyncSetID,
        generatedAt: phase06Date,
        decisions: decisions,
        schedule: schedule,
        gate: gate,
        fingerprint: PlanFingerprint(rawValue: "phase06-\(path.rawValue)")
    )
}

private func verdict(for operations: [AetherloomCore.Operation]) -> ItemVerdict {
    if operations.allSatisfy({ if case .trash = $0.kind { return true }; return false }) {
        return .propagateDeletion(to: Set(operations.map(\.location)), initiatedBy: .googleDrive)
    }
    if let transfer = operations.compactMap(\.transferSource).first {
        return .propagateCreation(from: transfer, to: Set(operations.map(\.location)))
    }
    return .propagatePath(to: Set(operations.map(\.location)), newPath: operations.first?.kind.targetPath ?? "/")
}

private func operation(
    _ suffix: String,
    location: LocationID,
    kind: OperationKind,
    precondition: Precondition,
    dependsOn: [OperationID] = []
) -> AetherloomCore.Operation {
    AetherloomCore.Operation(
        id: OperationID(uuid(suffix)),
        location: location,
        kind: kind,
        precondition: precondition,
        dependsOn: dependsOn
    )
}

private func baseRecord(syncSetID: UUID, path: SyncPath, item: ItemObservation? = nil) -> BaseRecord {
    let version = item?.version ?? ItemVersion(contentHash: "base", size: 4, modifiedAt: phase06Date, revisionToken: "base")
    return BaseRecord(
        id: uuid("000000009101"),
        syncSetID: syncSetID,
        path: path,
        kind: item?.kind ?? .file,
        version: version,
        perLocation: item.map {
            [$0.location: LocationMemory(itemID: $0.itemID, revisionToken: $0.version.revisionToken, lastSeenAt: phase06Date)]
        } ?? [:],
        lastConvergedAt: phase06Date,
        createdAt: phase06Date,
        updatedAt: phase06Date
    )
}

private func phase06Environment(maxParallelism: Int = 3) -> ExecutionEnvironment {
    ExecutionEnvironment(
        now: { phase06Date },
        makeID: { uuid("000000009999") },
        maxConcurrentLocationOperations: maxParallelism
    )
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomPhase06Tests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func uuid(_ suffix: String) -> UUID {
    UUID(uuidString: "60000000-0000-0000-0000-\(suffix)")!
}

private let phase06Date = Date(timeIntervalSince1970: 1_770_000_000)
private let phase06SyncSetID = uuid("000000000001")

private extension LocationID {
    var shortName: String {
        switch self {
        case .googleDrive:
            return "googleDrive"
        case .oneDrive:
            return "oneDrive"
        case .localFolder:
            return "localFolder"
        case .nasFolder:
            return "nasFolder"
        case .iCloudDrive:
            return "iCloudDrive"
        case .dropbox:
            return "dropbox"
        default:
            return rawValue.uuidString
        }
    }
}

private extension AetherloomCore.Operation {
    var transferSource: LocationID? {
        guard case let .transfer(content, _, _) = kind else { return nil }
        return content.sourceLocation
    }
}
