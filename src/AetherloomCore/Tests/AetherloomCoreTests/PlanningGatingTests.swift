import Foundation
import Testing
@testable import AetherloomCore

@Test func fileCreatedInOneProviderPropagatesToOthers() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let source = await google.putFile(path: "/Documents/Resume.docx", contents: data("resume"))

    let plan = await makePlan(syncSet: syncSet, providers: [iCloud, google, oneDrive])

    #expect(plan.gate == .clear)
    #expect(uploadCount(plan) == 2)
    #expect(containsUpload(plan, source: source.location, destination: .iCloudDrive, path: source.path))
    #expect(containsUpload(plan, source: source.location, destination: .oneDrive, path: source.path))
}

@Test func folderCreatedInOneProviderPropagatesToOthers() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFolder(path: "/Projects/Website")

    let plan = await makePlan(syncSet: syncSet, providers: [iCloud, google, oneDrive])

    #expect(createFolderCount(plan) == 2)
    #expect(containsCreateFolder(plan, destination: .iCloudDrive, path: "/Projects/Website"))
    #expect(containsCreateFolder(plan, destination: .oneDrive, path: "/Projects/Website"))
}

@Test func editedFileOverwritesUnchangedCopies() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
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
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let oldItems = await seedFile(path: "/Budget.xlsx", contents: "old", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Budget.xlsx", items: oldItems)
    await google.putFile(path: "/Budget.xlsx", contents: data("google edit"))
    await oneDrive.putFile(path: "/Budget.xlsx", contents: data("onedrive edit"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(!plan.gate.isClear)
    #expect(plan.isAutoExecutable == false)
    #expect(plan.conflicts.count == 1)
    #expect(conflictCopyCount(plan) == 4)
    #expect(overwriteCount(plan) == 0)
}

@Test func renamedFilePropagatesRename() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let oldItems = await seedFile(path: "/Old Name.txt", contents: "note", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Old Name.txt", items: oldItems)
    _ = try await google.relocate(oldItems[.googleDrive]!, to: "/New Name.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(renameCount(plan) == 2)
    #expect(containsRename(plan, destination: .iCloudDrive, newName: "New Name.txt"))
    #expect(containsRename(plan, destination: .oneDrive, newName: "New Name.txt"))
}

@Test func movedFilePropagatesMove() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let oldItems = await seedFile(path: "/Report.txt", contents: "report", providers: [iCloud, google, oneDrive])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Report.txt", items: oldItems)
    _ = try await google.relocate(oldItems[.googleDrive]!, to: "/Archive/Report.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [iCloud, google, oneDrive])

    #expect(moveCount(plan) == 2)
    #expect(containsMove(plan, destination: .iCloudDrive, newPath: "/Archive/Report.txt"))
    #expect(containsMove(plan, destination: .oneDrive, newPath: "/Archive/Report.txt"))
}

@Test func deletedFileMovesMatchingFilesToTrash() async throws {
    let syncSet = makeSyncSet()
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
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
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let item = await oneDrive.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.oneDrive: item])
    await google.setAvailability(.unavailable(.networkUnreachable(detail: "Network unavailable")))

    let outcome = await makePlanOutcome(syncSet: syncSet, records: [record], providers: [google, oneDrive])
    let refusal = try #require(outcome.refusalValue)
    #expect(refusal.reasons.contains { reason in
        if case .locationUnavailable(.googleDrive, .networkUnreachable) = reason { return true }
        return false
    })
}

@Test func disconnectedLocalVolumePausesWithCanonicalUnavailableSentenceAndNoTrashActions() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    let item = await nas.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.nasFolder: item])
    await local.setAvailability(.unavailable(.volumeNotMounted(detail: "External disk is not mounted.")))

    let outcome = await makePlanOutcome(syncSet: syncSet, records: [record], providers: [local, nas])
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.messages.first == "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.")
}

@Test func unreachableNASPausesWithCanonicalUnavailableSentenceAndNoTrashActions() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    let item = await local.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.localFolder: item])
    await nas.setAvailability(.unavailable(.volumeUnreachable(detail: "Sleeping NAS did not respond.")))

    let outcome = await makePlanOutcome(syncSet: syncSet, records: [record], providers: [local, nas])
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.messages.first == "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.")
}

@Test func incompleteScanDoesNotProduceDeleteActions() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let item = await oneDrive.putFile(path: "/Keep.txt", contents: data("keep"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Keep.txt", items: [.oneDrive: item])
    await google.setIncompleteScan(reason: "Pagination stopped early")

    let outcome = await makePlanOutcome(syncSet: syncSet, records: [record], providers: [google, oneDrive])
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.reasons.contains { reason in
        if case .scanIncomplete(.googleDrive, "Pagination stopped early") = reason { return true }
        return false
    })
}

@Test func degradedHashIndependentEditsUseSizeAndMtimeToPreserveConflicts() async throws {
    var capabilities = ProviderCapabilities.fullFidelity
    capabilities.hasContentHashes = false
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder, capabilities: capabilities)
    let nas = FakeStorageProvider(locationID: .nasFolder, capabilities: capabilities)
    let oldItems = await seedFile(path: "/Design.sketch", contents: "base", providers: [local, nas])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Design.sketch", items: oldItems)
    await local.putFile(path: "/Design.sketch", contents: data("aaaa"), modifiedAt: fixedDate.addingTimeInterval(10))
    await nas.putFile(path: "/Design.sketch", contents: data("bbbb"), modifiedAt: fixedDate.addingTimeInterval(20))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [local, nas])

    #expect(!plan.gate.isClear)
    #expect(plan.conflicts.count == 1)
    #expect(conflictCopyCount(plan) == 2)
    #expect(overwriteCount(plan) == 0)
}

@Test func degradedHashEqualSizeAndMtimeProducesNoAction() async throws {
    var capabilities = ProviderCapabilities.fullFidelity
    capabilities.hasContentHashes = false
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder, capabilities: capabilities)
    let nas = FakeStorageProvider(locationID: .nasFolder, capabilities: capabilities)
    let oldItems = await seedFile(path: "/Same.dat", contents: "base", providers: [local, nas])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Same.dat", items: oldItems)
    await local.putFile(path: "/Same.dat", contents: data("aaaa"), modifiedAt: fixedDate)
    await nas.putFile(path: "/Same.dat", contents: data("bbbb"), modifiedAt: fixedDate)

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [local, nas])

    #expect(plan.schedule.operations.isEmpty)
    #expect(plan.conflicts.isEmpty)
}

@Test func iCloudPlaceholderDoesNotProduceDeleteActions() async throws {
    let syncSet = makeSyncSet([.iCloudDrive, .googleDrive])
    let iCloud = FakeStorageProvider(locationID: .iCloudDrive)
    let google = FakeStorageProvider(locationID: .googleDrive)
    let icloudObservation = await iCloud.putFile(path: "/Photo.jpg", contents: data("placeholder"), isPlaceholder: true)
    let googleItem = await google.putFile(path: "/Photo.jpg", contents: data("placeholder"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Photo.jpg", items: [.iCloudDrive: icloudObservation, .googleDrive: googleItem])
    await google.remove(path: "/Photo.jpg")

    let outcome = await makePlanOutcome(syncSet: syncSet, records: [record], providers: [iCloud, google])
    let plan = try #require(outcome.planValue)

    #expect(trashCount(plan) == 0)
    #expect(plan.waiting.count == 1)
    #expect(plan.waiting.first?.path == "/Photo.jpg")
}

@Test func massDeletePausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive, .localFolder])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let local = FakeStorageProvider(locationID: .localFolder)
    var records: [BaseRecord] = []
    for index in 0..<6 {
        let path = SyncPath("/Deleted-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        let localItem = await local.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem, .localFolder: localItem]))
        await google.remove(path: path)
    }
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 3, massDeleteRatio: 0.5, massEditAbsolute: 99, massEditRatio: 1))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive, local], settings: settings)

    #expect(plan.gate.holdReasons.contains { reason in
        if case let .massDeletion(evidence) = reason {
            return evidence.intentCount == 6
        }
        return false
    })
    #expect(trashCount(plan) == 12)
}

@Test func massEditPausesPlan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive, .localFolder])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let local = FakeStorageProvider(locationID: .localFolder)
    var records: [BaseRecord] = []
    for index in 0..<6 {
        let path = SyncPath("/Edited-\(index).txt")
        let googleItem = await google.putFile(path: path, contents: data("old \(index)"))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data("old \(index)"))
        let localItem = await local.putFile(path: path, contents: data("old \(index)"))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem, .localFolder: localItem]))
        await google.putFile(path: path, contents: data("new \(index)"))
    }
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 99, massDeleteRatio: 1, massEditAbsolute: 3, massEditRatio: 0.5))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive, local], settings: settings)

    #expect(plan.gate.holdReasons.contains { reason in
        if case let .massEdit(evidence) = reason {
            return evidence.intentCount == 6
        }
        return false
    })
    #expect(overwriteCount(plan) == 12)
}

@Test func refusalCollectsAllSnapshotFailures() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive, .localFolder])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.setAvailability(.unavailable(.networkUnreachable(detail: "Offline")))
    await oneDrive.setIncompleteScan(reason: "Stopped early")

    let outcome = await makePlanOutcome(syncSet: syncSet, providers: [google, oneDrive])
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.reasons.count == 3)
    #expect(refusal.reasons.contains { reason in
        if case .locationUnavailable(.googleDrive, .networkUnreachable) = reason { return true }
        return false
    })
    #expect(refusal.reasons.contains { reason in
        if case .scanIncomplete(.oneDrive, "Stopped early") = reason { return true }
        return false
    })
    #expect(refusal.reasons.contains { reason in
        if case .locationUnavailable(.localFolder, .unknown) = reason { return true }
        return false
    })
}

@Test func baseStateUnreadableProducesRefusal() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)

    let outcome = await makePlanOutcome(
        syncSet: syncSet,
        providers: [google, oneDrive],
        baseStateUnreadableDetail: "Corrupt base records"
    )
    let refusal = try #require(outcome.refusalValue)

    #expect(refusal.reasons.contains { reason in
        if case .baseStateUnreadable("Corrupt base records") = reason { return true }
        return false
    })
}

@Test func askBeforeDeletingHoldsButKeepsTrashSchedule() async throws {
    var syncSet = makeSyncSet([.googleDrive, .oneDrive])
    syncSet.mode = .askBeforeDeleting
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleItem = await google.putFile(path: "/Review.txt", contents: data("old"))
    let oneDriveItem = await oneDrive.putFile(path: "/Review.txt", contents: data("old"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Review.txt", items: [.googleDrive: googleItem, .oneDrive: oneDriveItem])
    await google.remove(path: "/Review.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])

    #expect(trashCount(plan) == 1)
    #expect(plan.gate.holdReasons.contains { reason in
        if case .deletionsNeedReview(count: 1) = reason { return true }
        return false
    })
}

@Test func noDeletePropagationCreatesInformationalDecisionWithNoTrash() async throws {
    var syncSet = makeSyncSet([.googleDrive, .oneDrive])
    syncSet.mode = .noDeletePropagation
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleItem = await google.putFile(path: "/KeepVisible.txt", contents: data("old"))
    let oneDriveItem = await oneDrive.putFile(path: "/KeepVisible.txt", contents: data("old"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/KeepVisible.txt", items: [.googleDrive: googleItem, .oneDrive: oneDriveItem])
    await google.remove(path: "/KeepVisible.txt")

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])

    #expect(plan.gate == .clear)
    #expect(trashCount(plan) == 0)
    #expect(plan.decisions.contains { $0.hasDeletionIntent })
}

@Test func intentCountingIsIndependentOfLocationFanout() async throws {
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 50, massDeleteRatio: 1, massEditAbsolute: 99, massEditRatio: 1))
    let twoLocationPlan = await massDeletionPlan(locations: [.googleDrive, .oneDrive], itemCount: 30, settings: settings)
    let fourLocationPlan = await massDeletionPlan(locations: [.googleDrive, .oneDrive, .localFolder, .nasFolder], itemCount: 30, settings: settings)

    #expect(twoLocationPlan.gate == .clear)
    #expect(fourLocationPlan.gate == .clear)
    #expect(trashCount(twoLocationPlan) == 30)
    #expect(trashCount(fourLocationPlan) == 90)
}

@Test func massChangeEvidenceUsesNearestCommonAncestor() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    var records: [BaseRecord] = []
    for name in ["One", "Two", "Three"] {
        let path = SyncPath("/Photos/2019/\(name).jpg")
        let googleItem = await google.putFile(path: path, contents: data(name))
        let oneDriveItem = await oneDrive.putFile(path: path, contents: data(name))
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleItem, .oneDrive: oneDriveItem]))
        await google.remove(path: path)
    }
    let settings = SyncSettings(thresholds: SafetyThresholds(massDeleteAbsolute: 2, massDeleteRatio: 1, massEditAbsolute: 99, massEditRatio: 1))

    let plan = await makePlan(syncSet: syncSet, records: records, providers: [google, oneDrive], settings: settings)

    let evidence = try #require(plan.gate.holdReasons.compactMap { reason -> MassChangeEvidence? in
        if case let .massDeletion(evidence) = reason { return evidence }
        return nil
    }.first)
    #expect(evidence.groups == [ChangeGroup(ancestor: "/Photos/2019", intentCount: 3)])
}

@Test func scheduleValidatorAcceptsConstructedPlanSchedule() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Nested/File.txt", contents: data("new"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    try plan.schedule.validate(decisions: plan.decisions)
}

@Test func scheduleValidatorRejectsTransferAfterTrash() throws {
    let trashID = testOperationID("000000000001")
    let transferID = testOperationID("000000000002")
    let schedule = OperationSchedule(operations: [
        Operation(id: trashID, location: .oneDrive, kind: .trash(itemRef: testItemRef(path: "/Old.txt")), precondition: .versionMatches(testVersion())),
        Operation(id: transferID, location: .oneDrive, kind: .transfer(content: testContentRef(path: "/New.txt"), to: "/New.txt", overwrite: .neverOverwrite), precondition: .pathAbsent)
    ])

    #expect(throws: OperationScheduleValidationError.transferAfterTrash(transferID)) {
        try schedule.validate()
    }
}

@Test func scheduleValidatorRejectsPerItemChainWithoutDependency() throws {
    let firstID = testOperationID("000000000003")
    let secondID = testOperationID("000000000004")
    let schedule = OperationSchedule(operations: [
        Operation(id: firstID, location: .oneDrive, kind: .transfer(content: testContentRef(path: "/One.txt"), to: "/One.txt", overwrite: .neverOverwrite), precondition: .pathAbsent),
        Operation(id: secondID, location: .localFolder, kind: .transfer(content: testContentRef(path: "/Two.txt"), to: "/Two.txt", overwrite: .neverOverwrite), precondition: .pathAbsent)
    ])
    let decision = ItemDecision(id: testUUID("000000000101"), path: "/One.txt", verdict: .propagateContent(from: .googleDrive, to: [.oneDrive, .localFolder]), operations: [firstID, secondID], explanation: "Changed at Google Drive since last sync.")

    #expect(throws: OperationScheduleValidationError.itemChainMissingDependency(decision: decision.id, operation: secondID)) {
        try schedule.validate(decisions: [decision])
    }
}

@Test func scheduleValidatorRejectsCaseFoldedTargetCollision() throws {
    let firstID = testOperationID("000000000005")
    let secondID = testOperationID("000000000006")
    let schedule = OperationSchedule(operations: [
        Operation(id: firstID, location: .oneDrive, kind: .transfer(content: testContentRef(path: "/Readme.txt"), to: "/Readme.txt", overwrite: .neverOverwrite), precondition: .pathAbsent),
        Operation(id: secondID, location: .oneDrive, kind: .transfer(content: testContentRef(path: "/README.txt"), to: "/README.txt", overwrite: .neverOverwrite), precondition: .pathAbsent)
    ])

    do {
        try schedule.validate()
        #expect(Bool(false))
    } catch let error as OperationScheduleValidationError {
        if case let .caseFoldedTargetCollision(location, path, _, second) = error {
            #expect(location == .oneDrive)
            #expect(path == "/README.txt")
            #expect(second == secondID)
        } else {
            #expect(Bool(false))
        }
    }
}

@Test func fingerprintIsStableForIdenticalInputs() {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let source = makeObservation(.googleDrive, path: "/Stable.txt", hash: "stable")
    let snapshots = [
        LocationSnapshot(location: .googleDrive, scope: .entireDrive, observations: [source], scannedAt: fixedDate),
        LocationSnapshot(location: .oneDrive, scope: .entireDrive, observations: [], scannedAt: fixedDate)
    ]

    let first = planFromSnapshots(syncSet: syncSet, snapshots: snapshots)
    let second = planFromSnapshots(syncSet: syncSet, snapshots: snapshots)

    #expect(first.fingerprint == second.fingerprint)
}

@Test func fingerprintChangesWhenSnapshotVersionChanges() {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let firstSnapshots = [
        LocationSnapshot(location: .googleDrive, scope: .entireDrive, observations: [makeObservation(.googleDrive, path: "/Stable.txt", hash: "one")], scannedAt: fixedDate),
        LocationSnapshot(location: .oneDrive, scope: .entireDrive, observations: [], scannedAt: fixedDate)
    ]
    let secondSnapshots = [
        LocationSnapshot(location: .googleDrive, scope: .entireDrive, observations: [makeObservation(.googleDrive, path: "/Stable.txt", hash: "two")], scannedAt: fixedDate),
        LocationSnapshot(location: .oneDrive, scope: .entireDrive, observations: [], scannedAt: fixedDate)
    ]

    let first = planFromSnapshots(syncSet: syncSet, snapshots: firstSnapshots)
    let second = planFromSnapshots(syncSet: syncSet, snapshots: secondSnapshots)

    #expect(first.fingerprint != second.fingerprint)
}

@Test func gateAddingHoldsNeverClearsExistingHold() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Readme.txt", contents: data("google"))
    await oneDrive.putFile(path: "/README.txt", contents: data("onedrive"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])
    let updated = plan.addingHolds([])

    #expect(!plan.gate.isClear)
    #expect(!updated.gate.isClear)
    #expect(updated.gate == plan.gate)
}

@Test func destinationChangedAfterPlanningStopsExecutionForReplan() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    let googleOld = await google.putFile(path: "/Draft.txt", contents: data("old"))
    let oneDriveOld = await oneDrive.putFile(path: "/Draft.txt", contents: data("old"))
    let record = makeRecord(syncSetID: syncSet.id, path: "/Draft.txt", items: [.googleDrive: googleOld, .oneDrive: oneDriveOld])
    await google.putFile(path: "/Draft.txt", contents: data("new from google"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [google, oneDrive])
    await oneDrive.putFile(path: "/Draft.txt", contents: data("surprise edit"))
    let executor = try makeExecutor(providers: [google, oneDrive], name: "drift-stops")

    let summary = try await executor.execute(plan, runID: testUUID("000000000201"))

    #expect(summary.outcome == .stoppedForReplan(location: .oneDrive, path: "/Draft.txt"))
    #expect(summary.appliedOperations.isEmpty)
}

@Test func rerunningSameSyncPlanIsIdempotent() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/New.txt", contents: data("hello"))
    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])
    let executor = try makeExecutor(providers: [google, oneDrive], name: "rerun-idempotent")

    let firstReport = try await executor.execute(plan, runID: testUUID("000000000202"))
    let secondReport = try await executor.execute(plan, runID: testUUID("000000000203"))

    #expect(firstReport.appliedOperations.count == 1)
    #expect(secondReport.appliedOperations.isEmpty)
    #expect(secondReport.skippedOperations.count == 1)
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
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Readme.txt", contents: data("google"))
    await oneDrive.putFile(path: "/README.txt", contents: data("onedrive"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(!plan.gate.isClear)
    #expect(conflictCopyCount(plan) > 0)
    #expect(overwriteCount(plan) == 0)
    #expect(trashCount(plan) == 0)
}

@Test func unicodeFilenamesAreHandledSafely() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/Résumé.txt", contents: data("unicode"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsUpload(plan, source: .googleDrive, destination: .oneDrive, path: "/Résumé.txt"))
}

@Test func emptyFoldersAreSynchronized() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFolder(path: "/Empty")

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsCreateFolder(plan, destination: .oneDrive, path: "/Empty"))
}

@Test func zeroByteFilesAreSynchronized() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/zero.dat", contents: Data())

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(containsUpload(plan, source: .googleDrive, destination: .oneDrive, path: "/zero.dat"))
}

@Test func excludedFilesAreIgnored() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/.DS_Store", contents: data("metadata"))
    let settings = SyncSettings(exclusions: [
        SyncExclusion(pattern: ".DS_Store", matchStyle: .filename)
    ])

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive], settings: settings)

    #expect(plan.schedule.operations.isEmpty)
}

@Test func builtInAetherloomFolderExclusionAppliesWithEmptyUserExclusions() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/.aetherloom/trash/run/Keep.txt", contents: data("internal"))

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive], settings: SyncSettings())

    #expect(plan.schedule.operations.isEmpty)
}

@Test func symlinkExclusionAppliesWithEmptyUserExclusions() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putSymlink(path: "/Linked", target: "/Volumes/Other")

    let plan = await makePlan(syncSet: syncSet, providers: [google, oneDrive], settings: SyncSettings())

    #expect(plan.schedule.operations.isEmpty)
}

@Test func scanCompleteEmptyOnlyWhenAvailableAndUnscripted() async throws {
    let provider = FakeStorageProvider(locationID: .localFolder)

    let empty = await provider.scan(.entireDrive)
    #expect(empty.status == .complete)
    #expect(empty.observations.all.isEmpty)

    await provider.setAvailability(.unavailable(.scopeMissing(detail: "Selected folder is gone.")))
    let unavailable = await provider.scan(.entireDrive)
    #expect(unavailable.status == .unavailable(reason: .scopeMissing(detail: "Selected folder is gone.")))

    await provider.setAvailability(.available)
    await provider.setIncompleteScan(reason: "Enumeration stopped.")
    let incomplete = await provider.scan(.entireDrive)
    #expect(incomplete.status == .incomplete(reason: "Enumeration stopped."))
}

@Test func planningRecordsOnlyScanCalls() async throws {
    let syncSet = makeSyncSet([.googleDrive, .oneDrive])
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDrive = FakeStorageProvider(locationID: .oneDrive)
    await google.putFile(path: "/OnlyScan.txt", contents: data("scan"))
    await google.clearCallLog()
    await oneDrive.clearCallLog()

    _ = await makePlan(syncSet: syncSet, providers: [google, oneDrive])

    #expect(await google.callLog().map(\.operation) == [.scan])
    #expect(await oneDrive.callLog().map(\.operation) == [.scan])
}

@Test func fakeTrashKeepsContentRetrievable() async throws {
    let provider = FakeStorageProvider(locationID: .googleDrive)
    let item = await provider.putFile(path: "/TrashMe.txt", contents: data("preserve me"))
    try await provider.trash(item)
    let trashed = try #require(await provider.item(at: "/TrashMe.txt", includeTrashed: true))
    let fetchURL = try temporaryTestURL(name: "fake-trash-retrievable.txt")
    defer { try? FileManager.default.removeItem(at: fetchURL) }

    try await provider.fetch(trashed, to: fetchURL)

    #expect(try Data(contentsOf: fetchURL) == data("preserve me"))
}

@Test func twoSameKindLocationsPropagateCreates() async throws {
    let first = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    let second = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
    let syncSet = makeSyncSet([first, second])
    let firstFolder = FakeStorageProvider(locationID: first, displayName: "Local A")
    let secondFolder = FakeStorageProvider(locationID: second, displayName: "Local B")
    await firstFolder.putFile(path: "/Shared.txt", contents: data("same kind"))

    let plan = await makePlan(syncSet: syncSet, providers: [firstFolder, secondFolder])

    #expect(plan.gate == .clear)
    #expect(containsUpload(plan, source: first, destination: second, path: "/Shared.txt"))
}

@Test func localAndNASLocationsPropagateCreates() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    await local.putFile(path: "/Media.mov", contents: data("movie"))

    let plan = await makePlan(syncSet: syncSet, providers: [local, nas])

    #expect(plan.gate == .clear)
    #expect(containsUpload(plan, source: .localFolder, destination: .nasFolder, path: "/Media.mov"))
}

@Test func localAndNASLocationsPreserveIndependentEditConflicts() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    let oldItems = await seedFile(path: "/Sketch.psd", contents: "base", providers: [local, nas])
    let record = makeRecord(syncSetID: syncSet.id, path: "/Sketch.psd", items: oldItems)
    await local.putFile(path: "/Sketch.psd", contents: data("local"))
    await nas.putFile(path: "/Sketch.psd", contents: data("nas"))

    let plan = await makePlan(syncSet: syncSet, records: [record], providers: [local, nas])

    #expect(!plan.gate.isClear)
    #expect(plan.conflicts.count == 1)
    #expect(conflictCopyCount(plan) == 2)
    #expect(overwriteCount(plan) == 0)
}

@Test func localAndNASLocationsPropagateDeletesToTrash() async throws {
    let syncSet = makeSyncSet([.localFolder, .nasFolder])
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
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

private func massDeletionPlan(
    locations: [LocationID],
    itemCount: Int,
    settings: SyncSettings
) async -> SyncPlan {
    let syncSet = makeSyncSet(locations)
    let providers = locations.map { FakeStorageProvider(locationID: $0) }
    let source = providers[0]
    var records: [BaseRecord] = []

    for index in 0..<itemCount {
        let path = SyncPath("/Deleted-\(index).txt")
        var items: [LocationID: ItemObservation] = [:]
        for provider in providers {
            items[provider.locationID] = await provider.putFile(path: path, contents: data("old \(index)"))
        }
        records.append(makeRecord(syncSetID: syncSet.id, path: path, items: items))
        await source.remove(path: path)
    }

    return await makePlan(syncSet: syncSet, records: records, providers: providers, settings: settings)
}

private func planFromSnapshots(
    syncSet: SyncSet,
    records: [BaseRecord] = [],
    snapshots: [LocationSnapshot]
) -> SyncPlan {
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(syncSet: syncSet, records: records, snapshots: snapshots),
        environment: makeEnvironment()
    )
    guard let plan = outcome.planValue else {
        fatalError("Expected plan, got refusal \(String(describing: outcome.refusalValue))")
    }
    return plan
}

private func makePlan(
    syncSet: SyncSet,
    records: [BaseRecord] = [],
    providers: [FakeStorageProvider],
    settings: SyncSettings? = nil
) async -> SyncPlan {
    let outcome = await makePlanOutcome(syncSet: syncSet, records: records, providers: providers, settings: settings)
    guard let plan = outcome.planValue else {
        fatalError("Expected plan, got refusal \(String(describing: outcome.refusalValue))")
    }
    return plan
}

private func makePlanOutcome(
    syncSet: SyncSet,
    records: [BaseRecord] = [],
    providers: [FakeStorageProvider],
    settings: SyncSettings? = nil,
    baseStateUnreadableDetail: String? = nil
) async -> PlanOutcome {
    let resolvedSettings = settings ?? syncSet.settings
    let locations = providers.map {
        SyncLocation(
            id: $0.locationID,
            kind: $0.locationID.defaultKind,
            displayName: $0.displayName,
            scope: .entireDrive
        )
    }
    var snapshots: [LocationSnapshot] = []
    for provider in providers {
        let scope = locations.first { $0.id == provider.locationID }?.scope ?? .entireDrive
        snapshots.append(await provider.scan(scope))
    }
    return SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            locations: locations,
            records: records,
            snapshots: snapshots,
            settings: resolvedSettings,
            baseStateUnreadableDetail: baseStateUnreadableDetail
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
    providers: [FakeStorageProvider]
) async -> [LocationID: ItemObservation] {
    var items: [LocationID: ItemObservation] = [:]
    for provider in providers {
        items[provider.locationID] = await provider.putFile(path: path, contents: data(contents), modifiedAt: fixedDate)
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

private func makeObservation(
    _ location: LocationID,
    path: SyncPath,
    hash: String,
    kind: ItemKind = .file,
    itemID: String? = nil
) -> ItemObservation {
    ItemObservation(
        location: location,
        itemID: itemID ?? "\(location.rawValue.uuidString):\(path.rawValue)",
        path: path,
        kind: kind,
        version: testVersion(hash: hash)
    )
}

private func testVersion(hash: String = "hash") -> ItemVersion {
    ItemVersion(contentHash: hash, size: Int64(hash.count), modifiedAt: fixedDate, revisionToken: hash)
}

private func testContentRef(path: SyncPath) -> ContentRef {
    ContentRef(makeObservation(.googleDrive, path: path, hash: "source"))
}

private func testItemRef(path: SyncPath) -> ItemRef {
    ItemRef(makeObservation(.oneDrive, path: path, hash: "destination"))
}

private func testOperationID(_ suffix: String) -> OperationID {
    OperationID(testUUID(suffix))
}

private func testUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "40000000-0000-0000-0000-\(suffix)")!
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}

private func temporaryTestURL(name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    return url
}

private func temporaryTestDirectory(name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomCoreTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeExecutor(
    providers: [FakeStorageProvider],
    stores: EngineStores = .inMemory(),
    name: String,
    maxParallelism: Int = 3
) throws -> ScheduleExecutor {
    var providerMap: [LocationID: any StorageProvider] = [:]
    for provider in providers {
        providerMap[provider.locationID] = provider
    }
    let stage = ContentStage(rootDirectory: try temporaryTestDirectory(name: "stage-\(name)"), byteLimit: 10_000_000)
    return ScheduleExecutor(
        providers: providerMap,
        stores: stores,
        stage: stage,
        environment: ExecutionEnvironment(
            now: { fixedDate },
            makeID: { testUUID("000000000999") },
            maxConcurrentLocationOperations: maxParallelism
        )
    )
}

private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

private func uploadCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case let .transfer(content, path, overwrite) = $0.kind {
            return path == content.path && overwrite == .neverOverwrite
        }
        return false
    }
}

private func overwriteCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case let .transfer(_, _, overwrite) = $0.kind {
            if case .ifVersionMatches = overwrite { return true }
        }
        return false
    }
}

private func createFolderCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .makeFolder = $0.kind { return true }
        return false
    }
}

private func conflictCopyCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case let .transfer(content, path, overwrite) = $0.kind {
            return path != content.path && overwrite == .neverOverwrite
        }
        return false
    }
}

private func renameCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case let .relocate(itemRef, newPath) = $0.kind {
            return itemRef.path.parent == newPath.parent
        }
        return false
    }
}

private func moveCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case let .relocate(itemRef, newPath) = $0.kind {
            return itemRef.path.parent != newPath.parent
        }
        return false
    }
}

private func trashCount(_ plan: SyncPlan) -> Int {
    count(plan) {
        if case .trash = $0.kind { return true }
        return false
    }
}

private func count(_ plan: SyncPlan, where predicate: (AetherloomCore.Operation) -> Bool) -> Int {
    plan.schedule.operations.reduce(0) { total, operation in
        total + (predicate(operation) ? 1 : 0)
    }
}

private func containsUpload(_ plan: SyncPlan, source: LocationID, destination: LocationID, path: SyncPath) -> Bool {
    plan.schedule.operations.contains {
        if case let .transfer(content, destinationPath, overwrite) = $0.kind {
            return content.sourceLocation == source
                && $0.location == destination
                && destinationPath == path
                && destinationPath == content.path
                && overwrite == .neverOverwrite
        }
        return false
    }
}

private func containsOverwrite(_ plan: SyncPlan, source: LocationID, destination: LocationID, path: SyncPath) -> Bool {
    plan.schedule.operations.contains {
        if case let .transfer(content, destinationPath, overwrite) = $0.kind {
            if case .ifVersionMatches = overwrite {
                return content.sourceLocation == source && $0.location == destination && destinationPath == path
            }
        }
        return false
    }
}

private func containsCreateFolder(_ plan: SyncPlan, destination: LocationID, path: SyncPath) -> Bool {
    plan.schedule.operations.contains {
        if case let .makeFolder(actionPath) = $0.kind {
            return $0.location == destination && actionPath == path
        }
        return false
    }
}

private func containsRename(_ plan: SyncPlan, destination: LocationID, newName: String) -> Bool {
    plan.schedule.operations.contains {
        if case let .relocate(itemRef, newPath) = $0.kind {
            return $0.location == destination && itemRef.path.parent == newPath.parent && newPath.name == newName
        }
        return false
    }
}

private func containsMove(_ plan: SyncPlan, destination: LocationID, newPath: SyncPath) -> Bool {
    plan.schedule.operations.contains {
        if case let .relocate(_, actionNewPath) = $0.kind {
            return $0.location == destination && actionNewPath == newPath
        }
        return false
    }
}

private func containsTrash(_ plan: SyncPlan, destination: LocationID, path: SyncPath) -> Bool {
    plan.schedule.operations.contains {
        if case let .trash(itemRef) = $0.kind {
            return $0.location == destination && itemRef.path == path
        }
        return false
    }
}
