import Foundation
import Testing
@testable import AetherloomCore

private let l2Date = Date(timeIntervalSince1970: 1_790_000_000)

@Test func syncPathAncestryIsNormalizedFoldedAndComponentAware() {
    #expect(SyncPath("/Projects/A\u{301}pp/File.txt").isEqualOrDescendant(of: "/projects/äpp"))
    #expect(SyncPath("/Work/App/File").isEqualOrDescendant(of: "/work/app"))
    #expect(!SyncPath("/Work/Apple/File").isEqualOrDescendant(of: "/work/app"))
    #expect(!SyncPath("/Work/Appetite").isEqualOrDescendant(of: "/work/app"))
}

@Test func decodedSyncPathCannotBypassNormalization() throws {
    let data = Data(#"{"rawValue":"/Projects/A\u0301pp//Sources"}"#.utf8)
    let decoded = try JSONDecoder().decode(SyncPath.self, from: data)
    #expect(decoded == SyncPath("/Projects/Ápp/Sources"))
}

@Test func exclusionEvidenceParticipatesInPlanFingerprint() {
    let syncSetID = UUID()
    let location = LocationID(rawValue: UUID())
    let ordinary = LocationSnapshot(
        location: location,
        scope: .entireDrive,
        observations: [],
        scannedAt: l2Date
    )
    let excluded = LocationSnapshot(
        location: location,
        scope: .entireDrive,
        observations: [],
        exclusions: [
            ScanExclusion(path: "/Package", scope: .subtree, reason: .packageDirectory)
        ],
        scannedAt: l2Date
    )
    let first = PlanFingerprint.compute(
        syncSetID: syncSetID,
        decisions: [],
        schedule: OperationSchedule(),
        gate: .clear,
        snapshots: [ordinary]
    )
    let second = PlanFingerprint.compute(
        syncSetID: syncSetID,
        decisions: [],
        schedule: OperationSchedule(),
        gate: .clear,
        snapshots: [excluded]
    )
    #expect(first != second)
}

@Test func exactCaseDistinctExclusionRootsRemainIndividuallyInspectable() {
    let upper = ScanExclusion(
        path: "/Projects/App",
        scope: .subtree,
        reason: .packageDirectory
    )
    let lower = ScanExclusion(
        path: "/Projects/app",
        scope: .subtree,
        reason: .packageDirectory
    )
    #expect(ScanExclusion.normalized([upper, lower]).count == 2)
    #expect(upper.covers("/projects/APP/child"))
}

@Test func packageAncestryRejectsPackageRootAndPackageInterior() throws {
    let volume = URL(fileURLWithPath: "/Volumes/Test", isDirectory: true)
    let package = volume.appendingPathComponent("Library.photoslibrary", isDirectory: true)
    let interior = package.appendingPathComponent("Masters/2026", isDirectory: true)
    let inspector = ScriptedSafetyInspector(volumeRoot: volume)
    inspector.overrides[package.path] = inspector.directory(package: true)

    #expect(throws: LocalPackageAncestryValidationError.selectedRootIsPackage) {
        try LocalPackageAncestryValidator(inspector: inspector)
            .validate(canonicalSelectedRoot: package)
    }
    #expect(throws: LocalPackageAncestryValidationError.selectedRootIsInsidePackage) {
        try LocalPackageAncestryValidator(inspector: inspector)
            .validate(canonicalSelectedRoot: interior)
    }
    #expect(inspector.requestedPaths.allSatisfy { $0.hasPrefix(volume.path) })
}

@Test func packageAncestryFailsClosedAndStopsAtVolumeRoot() throws {
    let volume = URL(fileURLWithPath: "/Volumes/Test", isDirectory: true)
    let selected = volume.appendingPathComponent("Users/me/Documents", isDirectory: true)
    let inspector = ScriptedSafetyInspector(volumeRoot: volume)
    inspector.failures.insert(volume.appendingPathComponent("Users").path)

    #expect(throws: LocalPackageAncestryValidationError.metadataUnavailable) {
        try LocalPackageAncestryValidator(inspector: inspector)
            .validate(canonicalSelectedRoot: selected)
    }

    inspector.failures.removeAll()
    inspector.requestedPaths.removeAll()
    try LocalPackageAncestryValidator(inspector: inspector)
        .validate(canonicalSelectedRoot: selected)
    #expect(inspector.requestedPaths.last == volume.path)
    #expect(!inspector.requestedPaths.contains("/"))
}

@Test func packageAncestryRejectsMismatchedVolumeWithoutWalkingOutsideIt() {
    let inspector = ScriptedSafetyInspector(
        volumeRoot: URL(fileURLWithPath: "/Volumes/Other", isDirectory: true)
    )
    #expect(throws: LocalPackageAncestryValidationError.selectedRootOutsideVolume) {
        try LocalPackageAncestryValidator(inspector: inspector).validate(
            canonicalSelectedRoot: URL(
                fileURLWithPath: "/Volumes/Test/Documents",
                isDirectory: true
            )
        )
    }
    #expect(inspector.requestedPaths.isEmpty)
}

@Test func metadataClassifierCoversEveryAcceptedReasonAndBaseline() {
    let inspector = ScriptedSafetyInspector(volumeRoot: URL(fileURLWithPath: "/"))
    let uid = LocalItemSafetyClassifier.currentEffectiveUserID
    let gid = LocalItemSafetyClassifier.currentEffectiveGroupID

    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/ordinary.txt",
        metadata: inspector.file(mode: 0o644, owner: uid, group: gid)
    ) == nil)
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/ordinary",
        metadata: inspector.directory(mode: 0o755, owner: uid, group: gid)
    ) == nil)

    let metadataCases: [(String, Int, MetadataKind)] = [
        ("user.example", 1, .extendedAttributes),
        (LocalItemSafetyClassifier.finderTagsName, 2, .finderTags),
        (LocalItemSafetyClassifier.finderInfoName, 32, .finderInfo),
        (LocalItemSafetyClassifier.resourceForkName, 64, .resourceFork),
    ]
    for (name, size, expectedKind) in metadataCases {
        let exclusion = LocalItemSafetyClassifier.exclusion(
            for: "/metadata",
            metadata: inspector.file(xattrs: [name: size])
        )
        guard case let .unsupportedMetadata(kinds) = exclusion?.reason else {
            Issue.record("Expected unsupported metadata for \(name)")
            continue
        }
        #expect(kinds.contains(.extendedAttributes))
        #expect(kinds.contains(expectedKind))
    }
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/empty-resource-fork",
        metadata: inspector.file(
            xattrs: [LocalItemSafetyClassifier.resourceForkName: 0]
        )
    ) == nil)
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/empty-finder-info",
        metadata: inspector.file(
            xattrs: [LocalItemSafetyClassifier.finderInfoName: 0]
        )
    ) == nil)

    for mode: UInt16 in [0o664, 0o755, 0o600, 0o4755, 0o2755, 0o1755] {
        guard case let .unsupportedPOSIXPermissions(actual, required) =
            LocalItemSafetyClassifier.exclusion(
                for: "/mode",
                metadata: inspector.file(mode: mode)
            )?.reason else {
            Issue.record("Expected file mode exclusion for \(mode)")
            continue
        }
        #expect(actual == mode)
        #expect(required == 0o644)
    }
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/directory",
        metadata: inspector.directory(mode: 0o775)
    )?.scope == .subtree)
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/acl",
        metadata: inspector.file(acl: true)
    )?.reason == .accessControlList)
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/owner",
        metadata: inspector.file(owner: uid &+ 1)
    )?.reason == .unsupportedOwnership)
    #expect(LocalItemSafetyClassifier.exclusion(
        for: "/group",
        metadata: inspector.file(group: gid &+ 1)
    )?.reason == .unsupportedOwnership)
}

@Test(.timeLimit(.minutes(1)))
func realisticDocumentsProjectsVolumeHasBoundedExactRootEvidence() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "realistic-volume")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let projects = root.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

    let ordinary = documents.appendingPathComponent("ordinary.txt")
    let privateFile = documents.appendingPathComponent("private.txt")
    let executable = projects.appendingPathComponent("tool.sh")
    let team = projects.appendingPathComponent("team.txt")
    let foreign = projects.appendingPathComponent("foreign.txt")
    let tagged = projects.appendingPathComponent("tagged.txt")
    let acl = projects.appendingPathComponent("acl.txt")
    for url in [ordinary, privateFile, executable, team, foreign, tagged, acl] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: privateFile.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: executable.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o664)],
        ofItemAtPath: team.path
    )
    let package = projects.appendingPathComponent("Demo.app", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: package.appendingPathComponent("inside.bin"))
    let wide = projects.appendingPathComponent("Shared", isDirectory: true)
    try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
    try Data("child".utf8).write(to: wide.appendingPathComponent("child.txt"))
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o775)],
        ofItemAtPath: wide.path
    )

    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.overrides[privateFile.path] = inspector.file(mode: 0o600)
    inspector.overrides[executable.path] = inspector.file(mode: 0o755)
    inspector.overrides[team.path] = inspector.file(mode: 0o664)
    inspector.overrides[foreign.path] = inspector.file(
        owner: LocalItemSafetyClassifier.currentEffectiveUserID &+ 1
    )
    inspector.overrides[tagged.path] = inspector.file(
        xattrs: [LocalItemSafetyClassifier.finderTagsName: 4]
    )
    inspector.overrides[acl.path] = inspector.file(acl: true)
    inspector.overrides[package.path] = inspector.directory(package: true)
    inspector.overrides[wide.path] = inspector.directory(mode: 0o775)

    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )
    let clock = ContinuousClock()
    let scanStarted = clock.now
    let snapshot = await provider.scan(.entireDrive)
    let scanDuration = scanStarted.duration(to: clock.now)

    #expect(snapshot.status == .complete)
    #expect(snapshot.exclusions.count == 8)
    #expect(Set(snapshot.exclusions.map(\.path)).count == 8)
    #expect(snapshot.observations.all.map(\.path).contains("/Documents/ordinary.txt"))
    #expect(!inspector.requestedPaths.contains(package.appendingPathComponent("inside.bin").path))
    #expect(!inspector.requestedPaths.contains(wide.appendingPathComponent("child.txt").path))

    let located = snapshot.exclusions.map {
        LocatedScanExclusion(location: .localFolder, exclusion: $0)
    }
    let plan = SyncPlan(
        syncSetID: UUID(),
        participatingLocations: [.localFolder, .oneDrive],
        generatedAt: l2Date,
        decisions: [],
        schedule: OperationSchedule(),
        waiting: located.map {
            WaitingItem(
                id: UUID(),
                path: $0.exclusion.path,
                reason: .unsupportedItem,
                locations: [.localFolder, .oneDrive]
            )
        },
        exclusions: located,
        gate: .clear,
        fingerprint: PlanFingerprint(rawValue: "qualification")
    )
    let preview = ChangePreviewRenderer().render(
        outcome: .plan(plan),
        locations: [:],
        base: [],
        generatedAt: l2Date
    )
    #expect(preview.exclusions.count == 8)
    #expect(preview.sections.first { $0.kind == .waiting }?.entries.count == 8)
    #expect(preview.exclusionGroups.reduce(0) { $0 + $1.rootCount } == 8)
    #expect(scanDuration < .seconds(5))
    print(
        "L2 realistic-volume measurement: 11 fixture roots, 8 exact exclusion roots, "
            + "\(snapshot.observations.all.count) ordinary observations, "
            + "\(preview.exclusionGroups.count) display groups, scan \(scanDuration)."
    )
}

@Test func subtreeExclusionKeepsTrackedDescendantsWaitingEverywhere() async throws {
    let left = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    let right = LocationID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)
    let syncSet = SyncSet(
        id: UUID(),
        name: "Excluded",
        locations: [left, right],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let paths: [SyncPath] = [
        "/Projects/Ápp",
        "/Projects/Ápp/Sources",
        "/Projects/Ápp/Sources/main.swift",
    ]
    let records = paths.map {
        BaseRecord(
            syncSetID: syncSet.id,
            path: $0,
            kind: $0.pathExtension.isEmpty ? .folder : .file,
            version: ItemVersion(contentHash: "base"),
            createdAt: l2Date,
            updatedAt: l2Date
        )
    }
    let exclusion = ScanExclusion(
        path: "/projects/a\u{301}pp",
        scope: .subtree,
        reason: .packageDirectory
    )
    let leftSnapshot = LocationSnapshot(
        location: left,
        scope: .entireDrive,
        observations: [],
        exclusions: [exclusion],
        scannedAt: l2Date
    )
    let rightObservations = records.map {
        ItemObservation(location: right, path: $0.path, kind: $0.kind, version: $0.version)
    }
    let rightSnapshot = LocationSnapshot(
        location: right,
        scope: .entireDrive,
        observations: rightObservations,
        scannedAt: l2Date
    )
    let input = ReconciliationInput(
        syncSet: syncSet,
        base: records,
        snapshots: [left: leftSnapshot, right: rightSnapshot],
        environment: PlanningEnvironment(now: l2Date, locationNames: [:])
    )
    let reconciler = Reconciler(environment: input.environment)
    let reconciled = deriveFacts(input).filter { paths.contains($0.primaryPath) }
    #expect(reconciled.count == 3)
    for item in reconciled {
        guard case let .excluded(evidence, locations) = reconciler.reconcile(item) else {
            Issue.record("Expected excluded verdict for \(item.primaryPath)")
            continue
        }
        #expect(evidence == [LocatedScanExclusion(location: left, exclusion: exclusion)])
        #expect(locations == Set([left, right]))
    }

    let outcome = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            records: records,
            snapshots: [leftSnapshot, rightSnapshot]
        ),
        environment: input.environment
    )
    guard case let .plan(plan) = outcome else {
        Issue.record("Expected a plan carrying positive exclusions")
        return
    }
    #expect(plan.schedule.operations.isEmpty)
    #expect(plan.decisions.isEmpty)
    #expect(plan.exclusions == [LocatedScanExclusion(location: left, exclusion: exclusion)])
    #expect(plan.waiting.count == 1)

    let stores = EngineStores.inMemory()
    for record in records { try await stores.baseRecords.apply(.upsert(record)) }
    let stageRoot = try TestTemporaryDirectory.make(suite: "l2", name: "excluded-stage")
    let executor = ScheduleExecutor(
        providers: [left: FakeStorageProvider(locationID: left), right: FakeStorageProvider(locationID: right)],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000)
    )
    let summary = try await executor.execute(plan)
    #expect(summary.outcome == .completedWithExclusions)
    #expect(summary.appliedOperations.isEmpty)
    #expect(try await stores.baseRecords.records(for: syncSet.id) == records)
    let activity = await stores.activity.entries(matching: ActivityQuery(limit: 100))
    #expect(!activity.contains { $0.message == ActivityMessageCatalog.runFinished })
}

@Test func subtreeExclusionAlsoBlocksUntrackedCounterpartCreation() {
    let left = LocationID(rawValue: UUID())
    let right = LocationID(rawValue: UUID())
    let syncSet = SyncSet(
        id: UUID(),
        name: "Untracked exclusion",
        locations: [left, right],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let exclusion = ScanExclusion(
        path: "/Projects/App",
        scope: .subtree,
        reason: .packageDirectory
    )
    let rightItem = ItemObservation(
        location: right,
        path: "/projects/app/child.txt",
        kind: .file,
        version: ItemVersion(contentHash: "new")
    )
    let input = SyncPlanningInput(
        syncSet: syncSet,
        records: [],
        snapshots: [
            LocationSnapshot(
                location: left,
                scope: .entireDrive,
                observations: [],
                exclusions: [exclusion],
                scannedAt: l2Date
            ),
            LocationSnapshot(
                location: right,
                scope: .entireDrive,
                observations: [rightItem],
                scannedAt: l2Date
            ),
        ]
    )
    guard case let .plan(plan) = SyncPlanner().plan(
        input,
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected an exclusion-only plan")
        return
    }
    #expect(plan.schedule.operations.isEmpty)
    #expect(plan.decisions.isEmpty)
    #expect(plan.exclusions.count == 1)
}

@Test func preparationPersistsExactExclusionEvidenceInActivity() async throws {
    let left = LocationID(rawValue: UUID())
    let right = LocationID(rawValue: UUID())
    let syncSet = SyncSet(
        id: UUID(),
        name: "Activity evidence",
        locations: [left, right],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    let exclusion = ScanExclusion(
        path: "/Projects/Tagged.txt",
        scope: .item,
        reason: .unsupportedMetadata([.extendedAttributes, .finderTags])
    )
    await leftProvider.setScanExclusions([exclusion])
    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "activity-stage"
    )
    let locations = Dictionary(uniqueKeysWithValues: [left, right].map {
        ($0, SyncLocation(id: $0, kind: .localFolder, scope: .entireDrive))
    })
    let orchestrator = SyncOrchestrator(
        locations: locations,
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000),
        environment: EngineEnvironment(now: { l2Date }, makeID: { UUID() })
    )

    let preparation = try await orchestrator.prepare(syncSet)
    #expect(preparation.preview.headline == "Some items are waiting")
    let activity = await stores.activity.entries(
        matching: ActivityQuery(syncSetID: syncSet.id, limit: 100)
    )
    let exact = activity.filter {
        $0.locationID == left && $0.path == exclusion.path
    }
    #expect(exact.count == 1)
    #expect(exact.first?.message == exclusion.reason.message)
    #expect(exact.first?.detail == "item|\(exclusion.reason.stableKey)")
    #expect(!activity.contains { $0.message == ActivityMessageCatalog.runFinished })
}

@Test func allLocationPreflightChecksLastLocationBeforeFirstMutation() async throws {
    let first = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    let last = LocationID(rawValue: UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!)
    let firstProvider = FakeStorageProvider(locationID: first)
    let lastProvider = FakeStorageProvider(locationID: last)
    _ = await lastProvider.putFolder(path: "/Folder", modifiedAt: l2Date)
    let syncSet = SyncSet(
        id: UUID(),
        name: "Prepared preflight",
        locations: [first, last],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(suite: "l2", name: "preflight-stage")
    let locations = Dictionary(uniqueKeysWithValues: [first, last].map {
        ($0, SyncLocation(id: $0, kind: .localFolder, scope: .entireDrive))
    })
    let orchestrator = SyncOrchestrator(
        locations: locations,
        providers: [first: firstProvider, last: lastProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000),
        environment: EngineEnvironment(now: { l2Date }, makeID: { UUID() })
    )
    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    #expect(plan.schedule.operations.count == 1)
    await firstProvider.clearCallLog()
    await lastProvider.clearCallLog()

    // Drift occurs only after the exact schedule has been prepared and shown.
    await lastProvider.setClassification(
        .excluded([
            ScanExclusion(path: "/Folder", scope: .subtree, reason: .packageDirectory)
        ])
    )

    await #expect(throws: ScheduleExecutionError.self) {
        try await orchestrator.execute(preparation)
    }
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(preparation.runID)
    ) {
        try await orchestrator.execute(preparation)
    }
    #expect(await firstProvider.callLog().map(\.operation) == [.classify])
    #expect(await lastProvider.callLog().map(\.operation) == [.classify])
    #expect(await firstProvider.classificationRequestLog().first?.contains(
        ProviderClassificationRequest(path: "/Folder", scope: .item)
    ) == true)
    #expect(await firstProvider.item(at: "/Folder") == nil)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
    let driftActivity = await stores.activity.entries(
        matching: ActivityQuery(runID: preparation.runID, limit: 100)
    )
    #expect(driftActivity.contains {
        $0.locationID == last
            && $0.path == "/Folder"
            && $0.detail == "subtree|packageDirectory"
    })
}

@Test func folderOperationPreflightRecursivelyFindsPostConfirmationDrift() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "subtree-preflight")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    let descendant = folder.appendingPathComponent("newly-private.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("drift".utf8).write(to: descendant)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.overrides[descendant.path] = inspector.file(mode: 0o600)
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )

    let classification = await provider.classify([
        ProviderClassificationRequest(path: "/Folder", scope: .subtree)
    ])
    guard case let .excluded(exclusions) = classification else {
        Issue.record("Subtree preflight must discover unsafe descendants")
        return
    }
    #expect(exclusions == [
        ScanExclusion(
            path: "/Folder/newly-private.txt",
            scope: .item,
            reason: .unsupportedPOSIXPermissions(actual: 0o600, required: 0o644)
        )
    ])
}

@Test func mutationAdjacentFolderCheckStopsUnsafeDescendantDrift() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "adjacent-subtree")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let folderURL = root.appendingPathComponent("Folder", isDirectory: true)
    let childURL = folderURL.appendingPathComponent("child.txt")
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try Data("safe at prepare".utf8).write(to: childURL)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )
    let snapshot = await provider.scan(.entireDrive)
    let folder = try #require(snapshot.observations.all.first { $0.path == "/Folder" })

    inspector.overrides[childURL.path] = inspector.file(mode: 0o600)
    await #expect(throws: ProviderError.self) {
        try await provider.relocate(folder, to: "/Moved")
    }
    #expect(FileManager.default.fileExists(atPath: folderURL.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Moved").path))
}

@Test func classificationRequestsPreserveDirectorySubtreeScopeAndItemAncestors() async {
    let source = LocationID(rawValue: UUID())
    let destination = LocationID(rawValue: UUID())
    let provider = FakeStorageProvider(locationID: destination)
    let folder = ContentRef(
        sourceLocation: source,
        itemID: "folder",
        path: "/Projects/App",
        kind: .folder,
        expectedVersion: ItemVersion(revisionToken: "1")
    )
    _ = await provider.classify(ProviderClassificationRequest.forOperations([
        Operation(
            id: OperationID(UUID()),
            location: destination,
            kind: .transfer(content: folder, to: "/Archive/App", overwrite: .neverOverwrite),
            precondition: .pathAbsent
        )
    ]))
    let requests = await provider.classificationRequestLog().first ?? []
    #expect(requests.contains(.init(path: "/Projects/App", scope: .subtree)))
    #expect(requests.contains(.init(path: "/Archive/App", scope: .subtree)))
    #expect(requests.contains(.init(path: "/Projects", scope: .item)))
    #expect(requests.contains(.init(path: "/Archive", scope: .item)))
}

@Test(arguments: [
    ProviderPathClassification.ambiguous(detail: "metadata probe failed"),
    ProviderPathClassification.unavailable(detail: "volume unavailable"),
])
func classificationAmbiguityOrUnavailabilityHasZeroMutations(
    classification: ProviderPathClassification
) async throws {
    let source = LocationID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
    let destination = LocationID(rawValue: UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!)
    let sourceProvider = FakeStorageProvider(locationID: source)
    let destinationProvider = FakeStorageProvider(locationID: destination)
    _ = await sourceProvider.putFolder(path: "/Blocked", modifiedAt: l2Date)
    let syncSet = SyncSet(
        id: UUID(),
        name: "Ambiguous preflight",
        locations: [source, destination],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let stores = EngineStores.inMemory()
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "ambiguous-stage")
    let locations = Dictionary(uniqueKeysWithValues: [source, destination].map {
        ($0, SyncLocation(id: $0, kind: .localFolder, scope: .entireDrive))
    })
    let orchestrator = SyncOrchestrator(
        locations: locations,
        providers: [source: sourceProvider, destination: destinationProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: root, byteLimit: 1_000_000),
        environment: EngineEnvironment(now: { l2Date }, makeID: { UUID() })
    )
    let preparation = try await orchestrator.prepare(syncSet)
    #expect(preparation.outcome.planValue?.schedule.operations.count == 1)
    await sourceProvider.clearCallLog()
    await destinationProvider.clearCallLog()
    await destinationProvider.setClassification(classification)

    do {
        _ = try await orchestrator.execute(preparation)
        Issue.record("Ambiguous classification must fail the preflight")
    } catch let error as ScheduleExecutionError {
        #expect(error.requiresFreshPreparation)
    }
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(preparation.runID)
    ) {
        try await orchestrator.execute(preparation)
    }
    #expect(await sourceProvider.callLog().map(\.operation) == [.classify])
    #expect(await destinationProvider.callLog().map(\.operation) == [.classify])
    #expect(await destinationProvider.item(at: "/Blocked") == nil)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
}

@Test func localCreatedTargetsHaveExactBaselineModeAndOwnership() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "created-baseline")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: SystemLocalItemSafetyInspector(),
        registry: LocalRootIORegistry()
    )
    let folder = try await provider.makeFolder(at: "/Created")
    #expect(folder.kind == .folder)

    let stage = root.appendingPathComponent("stage-source")
    try Data("content".utf8).write(to: stage)
    let file = try await provider.store(
        from: stage,
        at: "/Created/file.txt",
        options: StoreOptions(overwrite: .neverOverwrite)
    )
    #expect(file.kind == .file)

    let folderAttributes = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent("Created").path
    )
    let fileAttributes = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent("Created/file.txt").path
    )
    #expect((folderAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o644)
    #expect((fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == LocalItemSafetyClassifier.currentEffectiveUserID)
    #expect((fileAttributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == LocalItemSafetyClassifier.currentEffectiveGroupID)
}

@Test func unreadableItemClassificationMakesLocalScanIncomplete() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "scan-ambiguity")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let unreadable = root.appendingPathComponent("ambiguous.txt")
    try Data("truth".utf8).write(to: unreadable)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.failures.insert(unreadable.path)
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )

    let snapshot = await provider.scan(.entireDrive)
    guard case .incomplete = snapshot.status else {
        Issue.record("Unreadable classification must make the scan incomplete")
        return
    }
    #expect(snapshot.observations.all.isEmpty)
    #expect(snapshot.exclusions.isEmpty)
}

@Test func unreadableDirectoryMetadataDoesNotAuthorizeDescent() async throws {
    let root = try TestTemporaryDirectory.make(suite: "l2", name: "directory-ambiguity")
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let directory = root.appendingPathComponent("MaybePackage", isDirectory: true)
    let child = directory.appendingPathComponent("private-child.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("truth".utf8).write(to: child)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.failures.insert(directory.path)
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )

    let snapshot = await provider.scan(.entireDrive)
    guard case .incomplete = snapshot.status else {
        Issue.record("Unreadable directory classification must make the scan incomplete")
        return
    }
    #expect(!inspector.requestedPaths.contains(child.path))
    #expect(!snapshot.observations.all.map(\.path).contains("/MaybePackage/private-child.txt"))
}

@Test func recoveryClassificationExclusionKeepsJournalAndBaseUnresolved() async throws {
    let location = LocationID(rawValue: UUID())
    let provider = FakeStorageProvider(locationID: location)
    await provider.setClassification(
        .excluded([
            ScanExclusion(path: "/Recovered", scope: .subtree, reason: .packageDirectory)
        ])
    )
    let operation = Operation(
        id: OperationID(UUID()),
        location: location,
        kind: .makeFolder(at: "/Recovered"),
        precondition: .pathAbsent
    )
    let runID = UUID()
    let syncSetID = UUID()
    let stores = EngineStores.inMemory()
    try await stores.journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "recovery-classification")
    )
    try await stores.journal.append(.intent(operation), runID: runID)
    let replay = try #require(try await stores.journal.unfinishedRun(for: syncSetID))

    await #expect(throws: RunRecoveryError.self) {
        try await RunRecovery(providers: [location: provider], stores: stores)
            .recover(replay)
    }
    #expect(try await stores.journal.unfinishedRun(for: syncSetID) != nil)
    #expect(try await stores.baseRecords.records(for: syncSetID).isEmpty)
    #expect(await provider.callLog().map(\.operation) == [.classify])
    let activity = await stores.activity.entries(
        matching: ActivityQuery(runID: runID, limit: 100)
    )
    #expect(activity.contains {
        $0.path == "/Recovered" && $0.detail == "subtree|packageDirectory"
    })
}

private func makeLocalProvider(
    root: URL,
    safetyInspector: any LocalItemSafetyInspecting,
    registry: LocalRootIORegistry
) async -> LocalFolderStorageProvider {
    var location = SyncLocation(
        id: .localFolder,
        kind: .localFolder,
        displayName: "Local",
        scope: .entireDrive
    )
    location.configuration[LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey] = "scripted-volume"
    return await LocalFolderStorageProvider.make(
        location: location,
        rootURL: root,
        volumes: ScriptedVolumeInspector(),
        safetyInspector: safetyInspector,
        registry: registry
    )
}

private final class ScriptedSafetyInspector: @unchecked Sendable, LocalItemSafetyInspecting {
    let volumeRootURL: URL
    var overrides: [String: LocalItemSafetyMetadata] = [:]
    var failures: Set<String> = []
    var requestedPaths: [String] = []

    init(volumeRoot: URL) {
        volumeRootURL = volumeRoot.standardizedFileURL
    }

    func metadata(at url: URL) throws -> LocalItemSafetyMetadata {
        let path = url.standardizedFileURL.path
        requestedPaths.append(path)
        if failures.contains(path) { throw CocoaError(.fileReadUnknown) }
        if let value = overrides[path] { return value }
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if !exists, path.hasPrefix("/Volumes/Test") {
            return directory()
        }
        guard exists else { throw CocoaError(.fileNoSuchFile) }
        return isDirectory.boolValue ? directory() : file()
    }

    func volumeRoot(for _: URL) throws -> URL { volumeRootURL }

    func file(
        mode: UInt16 = 0o644,
        owner: UInt32 = LocalItemSafetyClassifier.currentEffectiveUserID,
        group: UInt32 = LocalItemSafetyClassifier.currentEffectiveGroupID,
        acl: Bool = false,
        xattrs: [String: Int] = [:]
    ) -> LocalItemSafetyMetadata {
        LocalItemSafetyMetadata(
            isDirectory: false,
            isRegularFile: true,
            posixMode: mode,
            ownerID: owner,
            groupID: group,
            hasAccessControlList: acl,
            extendedAttributeSizes: xattrs
        )
    }

    func directory(
        package: Bool = false,
        mode: UInt16 = 0o755,
        owner: UInt32 = LocalItemSafetyClassifier.currentEffectiveUserID,
        group: UInt32 = LocalItemSafetyClassifier.currentEffectiveGroupID,
        acl: Bool = false,
        xattrs: [String: Int] = [:]
    ) -> LocalItemSafetyMetadata {
        LocalItemSafetyMetadata(
            isDirectory: true,
            isRegularFile: false,
            isPackage: package,
            posixMode: mode,
            ownerID: owner,
            groupID: group,
            hasAccessControlList: acl,
            extendedAttributeSizes: xattrs
        )
    }
}
