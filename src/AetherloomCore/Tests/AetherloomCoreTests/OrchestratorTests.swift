import Foundation
import Testing
@testable import AetherloomCore

@Test func phase07PrepareIsReadOnlyAgainstProviders() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/OnlyScan.txt", contents: phase07Data("new"), modifiedAt: phase07Date)
    await google.clearCallLog()
    await oneDrive.clearCallLog()
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive])

    let preparation = try await orchestrator.prepare(syncSet)

    #expect(preparation.outcome.planValue != nil)
    #expect(await google.callLog().map(\.operation) == [.checkAvailability, .scan])
    #expect(await oneDrive.callLog().map(\.operation) == [.checkAvailability, .scan])
}

@Test func phase07UnavailableShortCircuitsBeforeScan() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.setAvailability(.unavailable(.networkUnreachable(detail: "Offline")))
    await google.clearCallLog()
    await oneDrive.clearCallLog()
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive])

    let preparation = try await orchestrator.prepare(syncSet)
    let refusal = try #require(preparation.outcome.refusalValue)

    #expect(refusal.reasons.contains { reason in
        if case .locationUnavailable(.googleDrive, .networkUnreachable) = reason { return true }
        return false
    })
    #expect(preparation.preview.headline == "Paused for safety")
    #expect(preparation.preview.refusals.first?.message == ActivityMessageCatalog.providerUnavailable)
    #expect(await google.callLog().map(\.operation) == [.checkAvailability])
    #expect(await oneDrive.callLog().map(\.operation) == [.checkAvailability])
}

@Test func phase07ScanTimeoutProducesRefusal() async throws {
    let syncSet = phase07SyncSet([.googleDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google], scanTimeoutSeconds: 0)

    let preparation = try await orchestrator.prepare(syncSet)
    let refusal = try #require(preparation.outcome.refusalValue)

    #expect(refusal.reasons.contains { reason in
        if case let .locationUnavailable(.googleDrive, .unknown(detail)) = reason {
            return detail.contains("Scan timed out")
        }
        return false
    })
}

@Test func phase07SafeRunConvergesAndSecondPreparePlansNothing() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Ready.txt", contents: phase07Data("ready"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)

    let firstPreparation = try await orchestrator.prepare(syncSet)
    let firstSummary = try await orchestrator.execute(firstPreparation)
    let secondPreparation = try await orchestrator.prepare(syncSet)
    let secondPlan = try #require(secondPreparation.outcome.planValue)

    #expect(firstSummary.outcome == .completed)
    #expect(await oneDrive.item(at: "/Ready.txt") != nil)
    #expect(try await stores.baseRecords.records(for: syncSet.id).count == 1)
    #expect(secondPlan.decisions.isEmpty)
    #expect(secondPreparation.preview.headline == "0 changes ready to sync")
}

@Test func phase07HeldPlanReturnsHeldWithoutApprovalAndDoesNotTrash() async throws {
    let (syncSet, stores, google, oneDrive) = await phase07DeletionFixture(mode: .askBeforeDeleting)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)

    let preparation = try await orchestrator.prepare(syncSet)
    let summary = try await orchestrator.execute(preparation)

    #expect(preparation.outcome.planValue?.gate.isClear == false)
    #expect(summary.outcome == .held)
    #expect(await oneDrive.item(at: "/Review.txt", includeTrashed: true)?.isTrashed == false)
}

@Test func phase07HeldPlanRunsWithValidApproval() async throws {
    let (syncSet, stores, google, oneDrive) = await phase07DeletionFixture(mode: .askBeforeDeleting)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)
    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    let approval = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: phase07Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )

    let summary = try await orchestrator.execute(preparation, approval: approval)

    #expect(summary.outcome == .completed)
    #expect(await oneDrive.item(at: "/Review.txt", includeTrashed: true)?.isTrashed == true)
    let approvalEntries = await stores.activity.entries(matching: ActivityQuery(categories: [.safety], limit: 100))
    #expect(approvalEntries.contains { $0.message == "You approved 1 items to move to trash for 'Documents'." })
}

@Test func phase07ApprovedButDriftedPlanStopsForReplan() async throws {
    let (syncSet, stores, google, oneDrive) = await phase07DeletionFixture(mode: .askBeforeDeleting)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)
    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    await oneDrive.putFile(path: "/Review.txt", contents: phase07Data("surprise"), modifiedAt: phase07Date.addingTimeInterval(10))
    let approval = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: phase07Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )

    let summary = try await orchestrator.execute(preparation, approval: approval)

    #expect(summary.outcome == .stoppedForReplan(location: .oneDrive, path: "/Review.txt"))
    #expect(await oneDrive.item(at: "/Review.txt", includeTrashed: true)?.isTrashed == false)
}

@Test func phase07ApprovalValidationMatrixRejectsMismatches() async throws {
    let (syncSet, stores, google, oneDrive) = await phase07DeletionFixture(mode: .askBeforeDeleting)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)
    let plan = try #require(try await orchestrator.prepare(syncSet).outcome.planValue)

    let wrongFingerprint = PlanApproval(
        planFingerprint: PlanFingerprint(rawValue: "wrong"),
        approvedAt: phase07Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
    let expired = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: phase07Date.addingTimeInterval(-1_000),
        expiresAt: phase07Date.addingTimeInterval(-1),
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
    let wrongTrash = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: phase07Date,
        acknowledgedTrashCount: plan.approvalTrashCount + 1,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
    let wrongConflicts = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: phase07Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount + 1
    )

    #expect(wrongFingerprint.validate(against: plan, at: phase07Date) == .rejected(.wrongFingerprint))
    #expect(expired.validate(against: plan, at: phase07Date) == .rejected(.expired))
    #expect(wrongTrash.validate(against: plan, at: phase07Date) == .rejected(.trashCountMismatch(expected: 1, actual: 2)))
    #expect(wrongConflicts.validate(against: plan, at: phase07Date) == .rejected(.conflictCountMismatch(expected: 0, actual: 1)))
}

@Test func phase07MakeCanonicalConflictResolutionFeedsNextPrepare() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleBase = await google.putFile(path: "/Budget.xlsx", contents: phase07Data("base"), modifiedAt: phase07Date)
    let oneDriveBase = await oneDrive.putFile(path: "/Budget.xlsx", contents: phase07Data("base"), modifiedAt: phase07Date)
    try await stores.baseRecords.apply(.upsert(phase07Record(syncSetID: syncSet.id, path: "/Budget.xlsx", items: [.googleDrive: googleBase, .oneDrive: oneDriveBase])))
    await google.putFile(path: "/Budget.xlsx", contents: phase07Data("google edit"), modifiedAt: phase07Date.addingTimeInterval(1))
    await oneDrive.putFile(path: "/Budget.xlsx", contents: phase07Data("onedrive edit"), modifiedAt: phase07Date.addingTimeInterval(2))
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)
    _ = try await orchestrator.prepare(syncSet)
    let conflict = try #require(try await stores.conflicts.openConflicts(for: syncSet.id).first)

    try await stores.conflicts.resolve(conflict.id, as: .makeCanonical(.googleDrive), at: phase07Date)
    let nextPlan = try #require(try await orchestrator.prepare(syncSet).outcome.planValue)

    #expect(nextPlan.conflicts.isEmpty)
    #expect(nextPlan.schedule.operations.contains { operation in
        if case let .transfer(content, path, overwrite) = operation.kind {
            if case .ifVersionMatches = overwrite {
                return content.sourceLocation == .googleDrive && operation.location == .oneDrive && path == "/Budget.xlsx"
            }
        }
        return false
    })
}

@Test func phase07ClearPlanIgnoresStrayApproval() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Stray.txt", contents: phase07Data("stray"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive])
    let preparation = try await orchestrator.prepare(syncSet)
    let stray = PlanApproval(
        planFingerprint: PlanFingerprint(rawValue: "wrong"),
        approvedAt: phase07Date.addingTimeInterval(-10_000),
        expiresAt: phase07Date.addingTimeInterval(-9_000),
        acknowledgedTrashCount: 99,
        acknowledgedConflictCount: 99
    )

    let summary = try await orchestrator.execute(preparation, approval: stray)

    #expect(summary.outcome == .completed)
    #expect(await oneDrive.item(at: "/Stray.txt") != nil)
}

@Test func phase07PreviewPartitionsEveryDecisionInFixedSectionOrder() async throws {
    let syncSet = phase07SyncSet([.iCloudDrive, .googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let iCloudPhoto = await iCloud.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date, isPlaceholder: true)
    let googlePhoto = await google.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date)
    let oneDrivePhoto = await oneDrive.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date)
    try await stores.baseRecords.apply(.upsert(phase07Record(syncSetID: syncSet.id, path: "/Photo.jpg", items: [.iCloudDrive: iCloudPhoto, .googleDrive: googlePhoto, .oneDrive: oneDrivePhoto])))
    await google.putFile(path: "/Photo.jpg", contents: phase07Data("new"), modifiedAt: phase07Date.addingTimeInterval(1))
    await google.putFile(path: "/New.txt", contents: phase07Data("new"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [iCloud, google, oneDrive], stores: stores)

    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    let previewIDs = Set(preparation.preview.sections.flatMap(\.entries).map(\.decisionID))
    let planIDs = Set(plan.decisions.map(\.id))

    #expect(preparation.preview.sections.map(\.kind) == PreviewSectionKind.allCases)
    #expect(previewIDs == planIDs)
    #expect(preparation.preview.sections.flatMap(\.entries).count == plan.decisions.count)
    #expect(preparation.preview.sections.first { $0.kind == .waiting }?.entries.count == 1)
}

@Test func phase07RefusalPreviewGolden() async throws {
    let syncSet = phase07SyncSet([.googleDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    await google.setAvailability(.unavailable(.notAuthenticated(detail: "Sign in required.")))
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google])

    let preview = try await orchestrator.prepare(syncSet).preview

    #expect(preview.headline == "Paused for safety")
    #expect(preview.planFingerprint == nil)
    #expect(preview.sections.isEmpty)
    #expect(preview.refusals.map(\.message) == [ActivityMessageCatalog.providerUnavailable])
    #expect(preview.refusals.first?.detail == "Google Drive: Sign in required.")
}

@Test func phase07MassDeleteHoldPreviewIncludesAttribution() async throws {
    let syncSet = phase07SyncSet(
        [.googleDrive, .oneDrive],
        settings: SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 2, massDeleteRatio: 1, massEditAbsolute: 99, massEditRatio: 1))
    )
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    for name in ["One", "Two", "Three"] {
        let path = SyncPath("/Photos/2019/\(name).jpg")
        let googleItem = await google.putFile(path: path, contents: phase07Data(name), modifiedAt: phase07Date)
        let oneDriveItem = await oneDrive.putFile(path: path, contents: phase07Data(name), modifiedAt: phase07Date)
        try await stores.baseRecords.apply(.upsert(phase07Record(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem])))
        await google.remove(path: path)
    }
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)

    let preview = try await orchestrator.prepare(syncSet).preview
    let evidence = try #require(preview.holds.compactMap(\.evidence).first)

    #expect(preview.headline == "Needs review")
    #expect(preview.holds.map(\.message).contains(ActivityMessageCatalog.manyDeletions))
    #expect(evidence.groups == [ChangeGroup(ancestor: "/Photos/2019", intentCount: 3)])
}

@Test func phase07WaitingItemRunSyncsRestAndReportsNoTrash() async throws {
    let syncSet = phase07SyncSet([.iCloudDrive, .googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let iCloudPhoto = await iCloud.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date, isPlaceholder: true)
    let googlePhoto = await google.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date)
    let oneDrivePhoto = await oneDrive.putFile(path: "/Photo.jpg", contents: phase07Data("old"), modifiedAt: phase07Date)
    try await stores.baseRecords.apply(.upsert(phase07Record(syncSetID: syncSet.id, path: "/Photo.jpg", items: [.iCloudDrive: iCloudPhoto, .googleDrive: googlePhoto, .oneDrive: oneDrivePhoto])))
    await google.putFile(path: "/Photo.jpg", contents: phase07Data("new"), modifiedAt: phase07Date.addingTimeInterval(1))
    await google.putFile(path: "/Other.txt", contents: phase07Data("other"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [iCloud, google, oneDrive], stores: stores)

    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    let summary = try await orchestrator.execute(preparation)

    #expect(phase07TrashCount(plan) == 0)
    #expect(plan.waiting.map(\.path) == ["/Photo.jpg"])
    #expect(preparation.preview.sections.first { $0.kind == .waiting }?.entries.first?.summary == "Waiting for \"Photo.jpg\" to download from iCloud Drive.")
    #expect(summary.outcome == .completed)
    #expect(await oneDrive.item(at: "/Other.txt") != nil)
}

@Test func phase07TombstoneReappearancePlansNewFile() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let tombstone = BaseRecord(
        syncSetID: syncSet.id,
        path: "/Returned.txt",
        kind: .file,
        version: phase07Version("old"),
        perLocation: [:],
        tombstone: Tombstone(deletedAt: phase07Date.addingTimeInterval(-10), initiatedBy: .googleDrive),
        lastConvergedAt: phase07Date.addingTimeInterval(-20),
        createdAt: phase07Date.addingTimeInterval(-30),
        updatedAt: phase07Date.addingTimeInterval(-10)
    )
    try await stores.baseRecords.apply(.upsert(tombstone))
    await google.putFile(path: "/Returned.txt", contents: phase07Data("new"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)

    let plan = try #require(try await orchestrator.prepare(syncSet).outcome.planValue)

    #expect(plan.decisions.contains { decision in
        if case .propagateCreation(.googleDrive, let destinations) = decision.verdict {
            return destinations == [.oneDrive]
        }
        return false
    })
}

@Test func phase07OverlapGuardFailsFast() async throws {
    let syncSet = phase07SyncSet([.googleDrive])
    let base = FakeStorageProvider(locationID: .googleDrive)
    let gate = BlockingAvailabilityGate()
    let blocking = BlockingAvailabilityProvider(base: base, gate: gate)
    let orchestrator = try phase07Orchestrator(
        syncSet: syncSet,
        providerMap: [.googleDrive: blocking],
        stores: .inMemory()
    )

    let first = Task {
        try await orchestrator.prepare(syncSet)
    }
    await gate.waitUntilBlocked()
    await #expect(throws: SyncOrchestratorError.runAlreadyInProgress(syncSet.id)) {
        _ = try await orchestrator.prepare(syncSet)
    }
    await gate.release()
    _ = try await first.value
}

@Test func phase07ActivityChecklistEndToEndUsesOneRunID() async throws {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Activity.txt", contents: phase07Data("activity"), modifiedAt: phase07Date)
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google, oneDrive], stores: stores)

    let preparation = try await orchestrator.prepare(syncSet)
    _ = try await orchestrator.execute(preparation)
    let entries = await stores.activity.entries(matching: ActivityQuery(runID: preparation.runID, limit: 100))
    let messages = Set(entries.map(\.message))

    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Recovery")))
    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Availability")))
    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Scan")))
    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Plan")))
    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Preview")))
    #expect(messages.contains(ActivityMessageCatalog.stageStarted("Execute")))
    #expect(messages.contains(ActivityMessageCatalog.runFinished))
    #expect(messages.contains(ActivityMessageCatalog.created(path: "/Activity.txt", destination: .oneDrive, source: .googleDrive)))
}

@Test func phase07RecoveryRunsBeforeAvailability() async throws {
    let syncSet = phase07SyncSet([.googleDrive])
    let stores = EngineStores.inMemory()
    let record = phase07Record(syncSetID: syncSet.id, path: "/Recovered.txt", items: [:])
    let unfinishedRunID = phase07UUID("000000000501")
    try await stores.journal.begin(runID: unfinishedRunID, syncSetID: syncSet.id, fingerprint: PlanFingerprint(rawValue: "unfinished"))
    try await stores.journal.append(.itemConverged(decisionID: phase07UUID("000000000502"), record: record), runID: unfinishedRunID)
    let google = FakeStorageProvider(locationID: .googleDrive)
    await google.setAvailability(.unavailable(.networkUnreachable(detail: "Offline")))
    let orchestrator = try phase07Orchestrator(syncSet: syncSet, providers: [google], stores: stores)

    let preparation = try await orchestrator.prepare(syncSet)
    let recoveredRecords = try await stores.baseRecords.records(for: syncSet.id)
    let activity = await stores.activity.entries(matching: ActivityQuery(runID: preparation.runID, categories: [.safety], limit: 100))

    #expect(preparation.outcome.refusalValue != nil)
    #expect(recoveredRecords.map(\.path) == ["/Recovered.txt"])
    #expect(activity.contains { $0.message == ActivityMessageCatalog.recoveryPerformed })
}

@Test func phase07IndeterminateRecoveryBlocksScanningThenReplansFresh() async throws {
    let syncSet = phase07SyncSet([.googleDrive])
    let stores = EngineStores.inMemory()
    let base = FakeStorageProvider(locationID: .googleDrive)
    let folder = await base.putFolder(path: "/LateFolder", modifiedAt: phase07Date)
    let provider = RecoveryGatedProvider(base: base, state: .inFlight)
    let operation = Operation(
        id: OperationID(phase07UUID("000000000511")),
        location: .googleDrive,
        kind: .makeFolder(at: folder.path),
        precondition: .pathAbsent
    )
    let receipt = ProviderMutationReceipt(
        id: phase07UUID("000000000512"),
        provider: .googleDrive,
        kind: .makeFolder,
        affectedPaths: [folder.path],
        startedAt: phase07Date
    )
    let unfinishedRunID = phase07UUID("000000000513")
    try await stores.journal.begin(
        runID: unfinishedRunID,
        syncSetID: syncSet.id,
        fingerprint: PlanFingerprint(rawValue: "indeterminate")
    )
    try await stores.journal.append(.intent(operation), runID: unfinishedRunID)
    try await stores.journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: phase07Date
        ),
        runID: unfinishedRunID
    )
    let orchestrator = try phase07Orchestrator(
        syncSet: syncSet,
        providerMap: [.googleDrive: provider],
        stores: stores
    )

    await #expect(
        throws: RunRecoveryError.indeterminateMutationStillRunning(
            operationID: operation.id,
            receiptID: receipt.id
        )
    ) {
        _ = try await orchestrator.prepare(syncSet)
    }
    #expect(await provider.availabilityCount() == 0)
    #expect(await provider.scanCount() == 0)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) != nil)

    await provider.setState(.quiescent(.succeeded))
    let preparation = try await orchestrator.prepare(syncSet)

    #expect(await provider.recoveryProbeCount() == 1)
    #expect(await provider.availabilityCount() == 1)
    #expect(await provider.scanCount() == 1)
    #expect(await provider.mutationCount() == 0)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
    guard case let .plan(plan) = preparation.outcome else {
        Issue.record("Fresh preparation did not produce a plan.")
        return
    }
    #expect(plan.schedule.operations.isEmpty)
}

@Test func phase07ReconstructedLocalOrchestratorSharesLiveRootOwner() async throws {
    let root = try phase07TemporaryDirectory("reconstructed-local-owner")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = LocalRootIORegistry()
    let location = SyncLocation(
        id: .localFolder,
        kind: .localFolder,
        configuration: [
            LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                "scripted-volume",
        ]
    )
    let clock = OrchestratorMutationClock()
    let hook = OrchestratorBlockingMutationHook()
    let receiptID = phase07UUID("000000000521")
    let firstProvider = await LocalFolderStorageProvider.make(
        location: location,
        rootURL: root,
        volumes: ScriptedVolumeInspector(),
        deadlines: ProviderDeadlines(
            ioNanoseconds: 1,
            clock: clock,
            now: {
                Date(timeIntervalSince1970: 1_800_000_100.123_456_7)
            },
            makeMutationID: { receiptID }
        ),
        mutationHook: hook,
        registry: registry
    )
    await clock.waitUntilIdle()
    let syncSet = phase07SyncSet([.localFolder])
    let journalRoot = root
        .appendingPathComponent(".aetherloom", isDirectory: true)
        .appendingPathComponent("orchestrator-file-journal", isDirectory: true)
    let stores = EngineStores(
        baseRecords: InMemoryBaseRecordStore(),
        journal: try FileRunJournalStore(rootURL: journalRoot),
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let oldOrchestrator = try phase07Orchestrator(
        syncSet: syncSet,
        providerMap: [.localFolder: firstProvider],
        stores: stores
    )
    _ = oldOrchestrator

    let mutation = Task { () -> ProviderMutationReceipt? in
        do {
            _ = try await firstProvider.makeFolder(at: "/LateFolder")
            return nil
        } catch let ProviderError.mutationIndeterminate(receipt) {
            return receipt
        } catch {
            Issue.record("Unexpected local mutation error: \(error)")
            return nil
        }
    }
    await hook.waitUntilStarted()
    await clock.waitUntilSleeping()
    await clock.fireAll()
    let receipt = try #require(await mutation.value)

    let operation = Operation(
        id: OperationID(phase07UUID("000000000522")),
        location: .localFolder,
        kind: .makeFolder(at: "/LateFolder"),
        precondition: .pathAbsent
    )
    let runID = phase07UUID("000000000523")
    try await stores.journal.begin(
        runID: runID,
        syncSetID: syncSet.id,
        fingerprint: PlanFingerprint(rawValue: "reconstructed-local-owner")
    )
    try await stores.journal.append(.intent(operation), runID: runID)
    try await stores.journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: phase07Date
        ),
        runID: runID
    )

    let reconstructedProvider = await LocalFolderStorageProvider.make(
        location: location,
        rootURL: root,
        volumes: ScriptedVolumeInspector(),
        registry: registry
    )
    var reconstructedStores = stores
    reconstructedStores.journal = try FileRunJournalStore(rootURL: journalRoot)
    let reconstructedOrchestrator = try phase07Orchestrator(
        syncSet: syncSet,
        providerMap: [.localFolder: reconstructedProvider],
        stores: reconstructedStores
    )

    await #expect(
        throws: RunRecoveryError.indeterminateMutationStillRunning(
            operationID: operation.id,
            receiptID: receipt.id
        )
    ) {
        _ = try await reconstructedOrchestrator.prepare(syncSet)
    }

    hook.release()
    while await reconstructedProvider.indeterminateMutationState(for: receipt)
        == .inFlight {
        await Task.yield()
    }
    let preparation = try await reconstructedOrchestrator.prepare(syncSet)

    #expect(hook.startedCount() == 1)
    #expect(
        try await reconstructedStores.journal.unfinishedRun(for: syncSet.id)
            == nil
    )
    guard case let .plan(plan) = preparation.outcome else {
        Issue.record("Reconstructed orchestrator did not freshly replan.")
        return
    }
    #expect(plan.schedule.operations.isEmpty)
}

private func phase07SyncSet(
    _ locations: [LocationID],
    mode: SyncMode = .balancedMirror,
    settings: SyncSettings = SyncSettings()
) -> SyncSet {
    SyncSet(
        id: phase07UUID("000000000001"),
        name: "Documents",
        locations: locations,
        mode: mode,
        settings: settings,
        createdAt: phase07Date,
        updatedAt: phase07Date
    )
}

private func phase07Orchestrator(
    syncSet: SyncSet,
    providers: [FakeStorageProvider],
    stores: EngineStores = .inMemory(),
    scanTimeoutSeconds: TimeInterval = 120
) throws -> SyncOrchestrator {
    var providerMap: [LocationID: any StorageProvider] = [:]
    for provider in providers {
        providerMap[provider.locationID] = provider
    }
    return try phase07Orchestrator(
        syncSet: syncSet,
        providerMap: providerMap,
        stores: stores,
        scanTimeoutSeconds: scanTimeoutSeconds
    )
}

private func phase07Orchestrator(
    syncSet: SyncSet,
    providerMap: [LocationID: any StorageProvider],
    stores: EngineStores,
    scanTimeoutSeconds: TimeInterval = 120
) throws -> SyncOrchestrator {
    let idSequence = UUIDSequence(prefix: "70000000-0000-0000-0000")
    let locations = Dictionary(uniqueKeysWithValues: syncSet.locations.map { locationID in
        (
            locationID,
            SyncLocation(
                id: locationID,
                kind: locationID.defaultKind,
                displayName: locationID.displayName,
                scope: .entireDrive
            )
        )
    })
    return SyncOrchestrator(
        locations: locations,
        providers: providerMap,
        stores: stores,
        stage: ContentStage(rootDirectory: try phase07TemporaryDirectory("stage-\(idSequence.next().uuidString)"), byteLimit: 10_000_000),
        environment: EngineEnvironment(
            now: { phase07Date },
            makeID: { idSequence.next() },
            scanTimeoutSeconds: scanTimeoutSeconds
        )
    )
}

private func phase07DeletionFixture(
    mode: SyncMode
) async -> (SyncSet, EngineStores, FakeStorageProvider, FakeStorageProvider) {
    let syncSet = phase07SyncSet([.googleDrive, .oneDrive], mode: mode)
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleItem = await google.putFile(path: "/Review.txt", contents: phase07Data("old"), modifiedAt: phase07Date)
    let oneDriveItem = await oneDrive.putFile(path: "/Review.txt", contents: phase07Data("old"), modifiedAt: phase07Date)
    try? await stores.baseRecords.apply(
        .upsert(
            phase07Record(
                syncSetID: syncSet.id,
                path: "/Review.txt",
                items: [.googleDrive: googleItem, .oneDrive: oneDriveItem]
            )
        )
    )
    await google.remove(path: "/Review.txt")
    return (syncSet, stores, google, oneDrive)
}

private func phase07Record(
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
        version: baseline?.version ?? phase07Version(path.name),
        perLocation: Dictionary(uniqueKeysWithValues: items.map { location, item in
            (
                location,
                LocationMemory(
                    itemID: item.itemID,
                    revisionToken: item.version.revisionToken,
                    lastSeenAt: phase07Date
                )
            )
        }),
        lastConvergedAt: phase07Date,
        createdAt: phase07Date,
        updatedAt: phase07Date
    )
}

private func phase07TrashCount(_ plan: SyncPlan) -> Int {
    plan.schedule.operations.filter { $0.kind.isTrash }.count
}

private func phase07Version(_ token: String) -> ItemVersion {
    ItemVersion(contentHash: "hash-\(token)", size: Int64(token.count), modifiedAt: phase07Date, revisionToken: "rev-\(token)")
}

private func phase07Data(_ string: String) -> Data {
    Data(string.utf8)
}

private func phase07TemporaryDirectory(_ name: String) throws -> URL {
    try TestTemporaryDirectory.make(suite: "AetherloomPhase07Tests", name: name)
}

private func phase07UUID(_ suffix: String) -> UUID {
    UUID(uuidString: "70000000-0000-0000-0000-\(suffix)")!
}

private let phase07Date = Date(timeIntervalSince1970: 1_770_000_000)

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var counter = 1

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter += 1
        return UUID(uuidString: "\(prefix)-\(String(format: "%012d", value))")!
    }
}

private actor BlockingAvailabilityGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        for waiter in blockedWaiters {
            waiter.resume()
        }
        blockedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilBlocked() async {
        if blocked {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private actor BlockingAvailabilityProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private let gate: BlockingAvailabilityGate

    init(base: FakeStorageProvider, gate: BlockingAvailabilityGate) {
        self.base = base
        self.gate = gate
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability {
        await gate.block()
        return await base.checkAvailability()
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
}

private actor RecoveryGatedProvider: IndeterminateMutationRecovering {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: FakeStorageProvider
    private var state: ProviderIndeterminateMutationState
    private var availabilityCalls = 0
    private var scanCalls = 0
    private var recoveryProbes = 0
    private var mutations = 0

    init(
        base: FakeStorageProvider,
        state: ProviderIndeterminateMutationState
    ) {
        self.base = base
        self.state = state
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func checkAvailability() async -> LocationAvailability {
        availabilityCalls += 1
        return await base.checkAvailability()
    }

    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        scanCalls += 1
        return await base.scan(scope)
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
        mutations += 1
        return try await base.store(from: stagingURL, at: path, options: options)
    }

    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        mutations += 1
        return try await base.makeFolder(at: path)
    }

    func relocate(
        _ observation: ItemObservation,
        to newPath: SyncPath
    ) async throws -> ItemObservation {
        mutations += 1
        return try await base.relocate(observation, to: newPath)
    }

    func trash(_ observation: ItemObservation) async throws {
        mutations += 1
        try await base.trash(observation)
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }

    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        state
    }

    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        recoveryProbes += 1
        return try await base.currentState(of: observation)
    }

    func finishIndeterminateMutationRecovery(for _: ProviderMutationReceipt) async {}

    func setState(_ state: ProviderIndeterminateMutationState) {
        self.state = state
    }

    func availabilityCount() -> Int { availabilityCalls }
    func scanCount() -> Int { scanCalls }
    func recoveryProbeCount() -> Int { recoveryProbes }
    func mutationCount() -> Int { mutations }
}

private actor OrchestratorMutationClock: ProviderDeadlineClock {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds _: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                let observers = sleeperWaiters
                sleeperWaiters.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitUntilSleeping() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            sleeperWaiters.append(continuation)
        }
    }

    func waitUntilIdle() async {
        while !waiters.isEmpty {
            await Task.yield()
        }
    }

    func fireAll() {
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class OrchestratorBlockingMutationHook:
    LocalMutationStarting,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var starts = 0
    private var released = false

    func beforeMutation(_: ProviderMutationReceipt) throws {
        condition.lock()
        starts += 1
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilStarted() async {
        while startedCount() == 0 {
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func startedCount() -> Int {
        condition.withLock { starts }
    }
}
