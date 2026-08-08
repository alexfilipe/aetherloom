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

@Test func indeterminateMutationRemainsPendingAndStopsTheSchedule() async throws {
    let base = FakeStorageProvider(locationID: .oneDrive)
    let receipt = ProviderMutationReceipt(
        id: uuid("000000000611"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Indeterminate"],
        startedAt: phase06Date
    )
    let provider = DeadlineMakeFolderProvider(
        base: base,
        error: .mutationIndeterminate(receipt)
    )
    let operation = operation(
        "000000000612",
        location: .oneDrive,
        kind: .makeFolder(at: "/Indeterminate"),
        precondition: .pathAbsent
    )
    let plan = planForOperations([operation], path: "/Indeterminate")
    let stores = EngineStores.inMemory()
    let runID = uuid("000000000613")
    let executor = try executor(
        providerMap: [.oneDrive: provider],
        stores: stores,
        name: "indeterminate-mutation"
    )

    let summary = try await executor.execute(plan, runID: runID)
    let replay = try #require(
        try await stores.journal.unfinishedRun(for: plan.syncSetID)
    )

    #expect(
        summary.outcome
            == .mutationIndeterminate(
                location: .oneDrive,
                path: "/Indeterminate",
                receiptID: receipt.id
            )
    )
    #expect(summary.appliedOperations.isEmpty)
    #expect(summary.failedOperations.isEmpty)
    #expect(replay.pendingOperationIDs == [operation.id])
    #expect(replay.indeterminateReceiptsByOperation == [operation.id: receipt])
    #expect(!replay.events.contains { $0.isRunFinished })
    #expect(!replay.events.contains { $0.resultOperationID == operation.id })
    let messages = await stores.activity.entries(
        matching: ActivityQuery(runID: runID, limit: 100)
    ).map(\.message)
    #expect(messages.contains(ActivityMessageCatalog.mutationIndeterminate))
    #expect(!messages.contains(ActivityMessageCatalog.runFinished))
}

@Test func indeterminateMutationDominatesOtherSameBatchStops() async throws {
    let receipt = ProviderMutationReceipt(
        id: uuid("000000000616"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Indeterminate"],
        startedAt: phase06Date
    )
    let indeterminateProvider = DeadlineMakeFolderProvider(
        base: FakeStorageProvider(locationID: .oneDrive),
        error: .mutationIndeterminate(receipt)
    )
    let driftedProvider = FakeStorageProvider(locationID: .localFolder)
    _ = await driftedProvider.putFile(
        path: "/Drifted",
        contents: Data("occupied".utf8),
        modifiedAt: phase06Date
    )
    let indeterminate = operation(
        "000000000617",
        location: .oneDrive,
        kind: .makeFolder(at: "/Indeterminate"),
        precondition: .pathAbsent
    )
    let drifted = operation(
        "000000000618",
        location: .localFolder,
        kind: .makeFolder(at: "/Drifted"),
        precondition: .pathAbsent
    )
    let plan = planForOperations(
        [indeterminate, drifted],
        path: "/MixedStops"
    )
    let stores = EngineStores.inMemory()
    let executor = try executor(
        providerMap: [
            .oneDrive: indeterminateProvider,
            .localFolder: driftedProvider,
        ],
        stores: stores,
        name: "mixed-indeterminate-stop"
    )

    let summary = try await executor.execute(
        plan,
        runID: uuid("000000000619")
    )
    let replay = try #require(
        try await stores.journal.unfinishedRun(for: plan.syncSetID)
    )

    #expect(
        summary.outcome == .mutationIndeterminate(
            location: .oneDrive,
            path: "/Indeterminate",
            receiptID: receipt.id
        )
    )
    #expect(replay.indeterminateReceiptsByOperation[indeterminate.id] == receipt)
    #expect(!replay.events.contains { $0.isRunFinished })
}

@Test func indeterminateJournalFailureNeverWritesTerminalResult() async throws {
    let receipt = ProviderMutationReceipt(
        id: uuid("000000000620"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/JournalFailure"],
        startedAt: phase06Date
    )
    let provider = DeadlineMakeFolderProvider(
        base: FakeStorageProvider(locationID: .oneDrive),
        error: .mutationIndeterminate(receipt)
    )
    let operation = operation(
        "000000000621",
        location: .oneDrive,
        kind: .makeFolder(at: "/JournalFailure"),
        precondition: .pathAbsent
    )
    let plan = planForOperations([operation], path: "/JournalFailure")
    let journal = FailIndeterminateRunJournalStore()
    let stores = engineStores(journal: journal)
    let executor = try executor(
        providerMap: [.oneDrive: provider],
        stores: stores,
        name: "indeterminate-journal-failure"
    )
    let runID = uuid("000000000622")

    do {
        _ = try await executor.execute(plan, runID: runID)
        Issue.record("Execution did not surface the journal failure.")
    } catch let ScheduleExecutionError.journalWriteFailed(operationID, detail) {
        #expect(operationID == operation.id)
        #expect(detail.contains("scriptedIndeterminateFailure"))
    }

    let replay = try #require(
        try await journal.unfinishedRun(for: plan.syncSetID)
    )
    #expect(replay.pendingOperationIDs == [operation.id])
    #expect(replay.indeterminateReceiptsByOperation.isEmpty)
    #expect(!replay.events.contains { $0.resultOperationID == operation.id })
    #expect(!replay.events.contains { $0.isRunFinished })

    let report = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: phase06Environment()
    ).recover(replay)
    #expect(report.reconciledOperations == [operation.id])
    #expect(await provider.didFinishRecovery())
    #expect(try await journal.unfinishedRun(for: plan.syncSetID) == nil)
}

@Test func preStartMutationDeadlineIsTerminalWithoutIndeterminateReceipt() async throws {
    let base = FakeStorageProvider(locationID: .oneDrive)
    let provider = DeadlineMakeFolderProvider(
        base: base,
        error: .mutationDeadlineExpiredBeforeStart(
            provider: .oneDrive,
            path: "/NeverStarted"
        )
    )
    let operation = operation(
        "000000000614",
        location: .oneDrive,
        kind: .makeFolder(at: "/NeverStarted"),
        precondition: .pathAbsent
    )
    let plan = planForOperations([operation], path: "/NeverStarted")
    let stores = EngineStores.inMemory()
    let executor = try executor(
        providerMap: [.oneDrive: provider],
        stores: stores,
        name: "pre-start-deadline"
    )

    let summary = try await executor.execute(
        plan,
        runID: uuid("000000000615")
    )

    #expect(summary.failedOperations.map(\.operationID) == [operation.id])
    #expect(try await stores.journal.unfinishedRun(for: plan.syncSetID) == nil)
    #expect(await base.item(at: "/NeverStarted") == nil)
}

@Test func indeterminateFetchNeverStartsDestinationStoreAndRecoversWithoutReplay() async throws {
    let sourceBase = FakeStorageProvider(locationID: .googleDrive)
    let sourceItem = await sourceBase.putFile(
        path: "/LateFetch.txt",
        contents: Data("late fetch".utf8),
        modifiedAt: phase06Date
    )
    let receipt = ProviderMutationReceipt(
        id: uuid("000000000616"),
        provider: .googleDrive,
        kind: .fetch,
        affectedPaths: [sourceItem.path],
        startedAt: phase06Date
    )
    let source = IndeterminateFetchProvider(base: sourceBase, receipt: receipt)
    let destination = FakeStorageProvider(locationID: .oneDrive)
    let conflictCopyPath: SyncPath = "/LateFetch (Conflict copy).txt"
    let operation = operation(
        "000000000617",
        location: .oneDrive,
        kind: .transfer(
            content: ContentRef(sourceItem),
            to: conflictCopyPath,
            overwrite: .neverOverwrite
        ),
        precondition: .pathAbsent
    )
    let plan = planForOperations([operation], path: conflictCopyPath)
    let stores = EngineStores.inMemory()
    let stageRoot = try temporaryDirectory("phase06-indeterminate-fetch")
    let stage = ContentStage(rootDirectory: stageRoot, byteLimit: 0)
    let executor = ScheduleExecutor(
        providers: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        stage: stage,
        environment: phase06Environment()
    )

    let summary = try await executor.execute(
        plan,
        runID: uuid("000000000618")
    )
    #expect(
        summary.outcome
            == .mutationIndeterminate(
                location: .googleDrive,
                path: sourceItem.path,
                receiptID: receipt.id
            )
    )
    let indeterminateRecord = try #require(summary.indeterminateOperations.first)
    #expect(summary.indeterminateOperations.count == 1)
    #expect(indeterminateRecord.operationID == operation.id)
    #expect(indeterminateRecord.location == .googleDrive)
    #expect(indeterminateRecord.path == sourceItem.path)
    #expect(indeterminateRecord.status == .indeterminate)
    #expect(await destination.callLog().filter { $0.operation == .store }.isEmpty)
    #expect(await stage.retainedArtifactCount(for: receipt) == 1)
    #expect(
        try FileManager.default.contentsOfDirectory(
            at: stageRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tmp" }.count == 1
    )
    let replay = try #require(
        try await stores.journal.unfinishedRun(for: plan.syncSetID)
    )
    #expect(replay.indeterminateReceiptsByOperation[operation.id] == receipt)
    let persistedIntent = try #require(
        replay.events.compactMap { event -> AetherloomCore.Operation? in
            guard case let .intent(operation) = event else { return nil }
            return operation
        }.first
    )
    #expect(persistedIntent.location == .oneDrive)
    #expect(persistedIntent.kind.targetPath == conflictCopyPath)
    #expect(!replay.events.contains { $0.resultOperationID == operation.id })
    #expect(!replay.events.contains { $0.isRunFinished })
    let safetyEntries = await stores.activity.entries(
        matching: ActivityQuery(
            runID: summary.runID,
            categories: [.safety],
            limit: 20
        )
    )
    let indeterminateActivity = try #require(
        safetyEntries.first {
            $0.message == ActivityMessageCatalog.mutationIndeterminate
        }
    )
    #expect(indeterminateActivity.locationID == .googleDrive)
    #expect(indeterminateActivity.path == sourceItem.path)
    #expect(indeterminateActivity.detail?.contains(conflictCopyPath.rawValue) == true)

    let report = try await RunRecovery(
        providers: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        stage: stage,
        environment: phase06Environment()
    ).recover(replay)

    #expect(report.reconciledOperations == [operation.id])
    #expect(await source.didFinishRecovery())
    #expect(await destination.callLog().filter { $0.operation == .store }.isEmpty)
    #expect(await stage.retainedArtifactCount(for: receipt) == 0)
    #expect(
        try FileManager.default.contentsOfDirectory(
            at: stageRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tmp" }.isEmpty
    )
    #expect(try await stores.journal.unfinishedRun(for: plan.syncSetID) == nil)
}

@Test func legacySyncRunSummaryDecodesWithoutIndeterminateOperations() throws {
    let summary = SyncRunSummary(
        runID: uuid("000000000619"),
        syncSetID: uuid("000000000620"),
        outcome: .completed
    )
    let encoded = try CanonicalCoding.encoder().encode(summary)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "indeterminateOperations")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try CanonicalCoding.decoder().decode(
        SyncRunSummary.self,
        from: legacyData
    )
    #expect(decoded.indeterminateOperations.isEmpty)
    #expect(decoded.runID == summary.runID)
    #expect(decoded.syncSetID == summary.syncSetID)
}

@Test func indeterminateStoreKeepsSourcePinnedOnlyUntilRecovery() async throws {
    let source = FakeStorageProvider(locationID: .googleDrive)
    let sourceItem = await source.putFile(
        path: "/LateStore.txt",
        contents: Data("late store".utf8),
        modifiedAt: phase06Date
    )
    let receipt = ProviderMutationReceipt(
        id: uuid("000000000623"),
        provider: .oneDrive,
        kind: .store,
        affectedPaths: [sourceItem.path],
        startedAt: phase06Date
    )
    let destination = IndeterminateStoreProvider(
        base: FakeStorageProvider(locationID: .oneDrive),
        receipt: receipt
    )
    let operation = operation(
        "000000000624",
        location: .oneDrive,
        kind: .transfer(
            content: ContentRef(sourceItem),
            to: sourceItem.path,
            overwrite: .neverOverwrite
        ),
        precondition: .pathAbsent
    )
    let plan = planForOperations([operation], path: sourceItem.path)
    let stores = EngineStores.inMemory()
    let stageRoot = try temporaryDirectory("phase06-indeterminate-store")
    let stage = ContentStage(rootDirectory: stageRoot, byteLimit: 0)
    let executor = ScheduleExecutor(
        providers: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        stage: stage,
        environment: phase06Environment()
    )

    let summary = try await executor.execute(
        plan,
        runID: uuid("000000000625")
    )
    #expect(
        summary.outcome == .mutationIndeterminate(
            location: .oneDrive,
            path: sourceItem.path,
            receiptID: receipt.id
        )
    )
    #expect(await stage.retainedArtifactCount(for: receipt) == 1)
    #expect(await destination.storeCallCount() == 1)
    #expect(
        try FileManager.default.contentsOfDirectory(
            at: stageRoot,
            includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "stage" }
    )

    let replay = try #require(
        try await stores.journal.unfinishedRun(for: plan.syncSetID)
    )
    _ = try await RunRecovery(
        providers: [.googleDrive: source, .oneDrive: destination],
        stores: stores,
        stage: stage,
        environment: phase06Environment()
    ).recover(replay)

    #expect(await stage.retainedArtifactCount(for: receipt) == 0)
    #expect(await destination.storeCallCount() == 1)
    #expect(await destination.didFinishRecovery())
    #expect(
        try FileManager.default.contentsOfDirectory(
            at: stageRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "stage" }.isEmpty
    )
}

@Test func contentStageStartupReclaimsOnlyAbandonedTemporaryWrites() throws {
    let root = try temporaryDirectory("phase06-stage-startup-cleanup")
    let abandoned = root.appendingPathComponent(
        "00000000-0000-0000-0000-000000000626.tmp"
    )
    let unrelated = root.appendingPathComponent("unrelated.tmp")
    let cache = root.appendingPathComponent("retained.stage")
    try Data("temporary".utf8).write(to: abandoned)
    try Data("not ours".utf8).write(to: unrelated)
    try Data("cache".utf8).write(to: cache)

    _ = ContentStage(rootDirectory: root, byteLimit: 10_000_000)

    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(FileManager.default.fileExists(atPath: cache.path))
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

private actor DeadlineMakeFolderProvider: IndeterminateMutationRecovering {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let error: ProviderError
    private var finishedRecovery = false

    init(base: FakeStorageProvider, error: ProviderError) {
        self.base = base
        self.error = error
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability {
        await base.checkAvailability()
    }

    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        await base.scan(scope)
    }

    func changedSubtrees(
        in scope: SyncScope,
        since cursor: ChangeCursor?
    ) async throws -> ChangeHint {
        try await base.changedSubtrees(in: scope, since: cursor)
    }

    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await base.fetch(observation, to: stagingURL)
    }

    func store(
        from stagingURL: URL,
        at path: SyncPath,
        options: StoreOptions
    ) async throws -> ItemObservation {
        try await base.store(from: stagingURL, at: path, options: options)
    }

    func makeFolder(at _: SyncPath) async throws -> ItemObservation {
        throw error
    }

    func relocate(
        _ observation: ItemObservation,
        to newPath: SyncPath
    ) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }

    func trash(_ observation: ItemObservation) async throws {
        try await base.trash(observation)
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }

    func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        guard case let .mutationIndeterminate(receipt) = error else {
            return nil
        }
        return receipt
    }

    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        .quiescent(.succeeded)
    }

    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }

    func finishIndeterminateMutationRecovery(
        for _: ProviderMutationReceipt
    ) async {
        finishedRecovery = true
    }

    func didFinishRecovery() -> Bool {
        finishedRecovery
    }
}

private actor IndeterminateFetchProvider: IndeterminateMutationRecovering {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let receipt: ProviderMutationReceipt
    private var finishedRecovery = false

    init(base: FakeStorageProvider, receipt: ProviderMutationReceipt) {
        self.base = base
        self.receipt = receipt
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
        throw ProviderError.mutationIndeterminate(receipt)
    }
    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        try await base.store(from: stagingURL, at: path, options: options)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try await base.makeFolder(at: path)
    }
    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }
    func trash(_ observation: ItemObservation) async throws {
        try await base.trash(observation)
    }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
    func indeterminateMutationState(for _: ProviderMutationReceipt) async -> ProviderIndeterminateMutationState {
        .quiescent(.succeeded)
    }
    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
    func finishIndeterminateMutationRecovery(for _: ProviderMutationReceipt) async {
        finishedRecovery = true
    }
    func didFinishRecovery() -> Bool { finishedRecovery }
}

private actor IndeterminateStoreProvider: IndeterminateMutationRecovering {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let receipt: ProviderMutationReceipt
    private var stores = 0
    private var finishedRecovery = false

    init(base: FakeStorageProvider, receipt: ProviderMutationReceipt) {
        self.base = base
        self.receipt = receipt
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability {
        await base.checkAvailability()
    }

    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        await base.scan(scope)
    }

    func changedSubtrees(
        in scope: SyncScope,
        since cursor: ChangeCursor?
    ) async throws -> ChangeHint {
        try await base.changedSubtrees(in: scope, since: cursor)
    }

    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await base.fetch(observation, to: stagingURL)
    }

    func store(
        from stagingURL: URL,
        at _: SyncPath,
        options _: StoreOptions
    ) async throws -> ItemObservation {
        _ = try Data(contentsOf: stagingURL)
        stores += 1
        throw ProviderError.mutationIndeterminate(receipt)
    }

    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try await base.makeFolder(at: path)
    }

    func relocate(
        _ observation: ItemObservation,
        to newPath: SyncPath
    ) async throws -> ItemObservation {
        try await base.relocate(observation, to: newPath)
    }

    func trash(_ observation: ItemObservation) async throws {
        try await base.trash(observation)
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }

    func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        receipt
    }

    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        .quiescent(.failed(detail: "scripted late failure"))
    }

    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }

    func finishIndeterminateMutationRecovery(
        for _: ProviderMutationReceipt
    ) async {
        finishedRecovery = true
    }

    func storeCallCount() -> Int { stores }
    func didFinishRecovery() -> Bool { finishedRecovery }
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
        case let .mutationIndeterminate(operationID, receipt, _):
            await recorder.record(
                "journal.indeterminate:\(operationID.rawValue.uuidString):\(receipt.id.uuidString)"
            )
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

private enum ScriptedJournalFailure: Error {
    case scriptedIndeterminateFailure
}

private actor FailIndeterminateRunJournalStore: RunJournalStore {
    private let delegate = InMemoryRunJournalStore()
    private var shouldFailIndeterminateAppend = true

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
        if case .mutationIndeterminate = event,
           shouldFailIndeterminateAppend {
            shouldFailIndeterminateAppend = false
            throw ScriptedJournalFailure.scriptedIndeterminateFailure
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
