import Foundation
import Testing
@testable import AetherloomCore
#if canImport(Darwin)
import Darwin
#endif

private let l2Date = Date(timeIntervalSince1970: 1_790_000_000)

@Test func syncPathAncestryIsNormalizedFoldedAndComponentAware() {
    #expect(SyncPath("/Projects/A\u{301}pp/File.txt").isEqualOrDescendant(of: "/projects/äpp"))
    #expect(SyncPath("/Work/App/File").isEqualOrDescendant(of: "/work/app"))
    #expect(!SyncPath("/Work/Apple/File").isEqualOrDescendant(of: "/work/app"))
    #expect(!SyncPath("/Work/Appetite").isEqualOrDescendant(of: "/work/app"))
}

@Test func decodedSyncPathPreservesUnicodeWhileAncestryNormalizes() throws {
    let data = Data(#"{"rawValue":"/Projects/A\u0301pp//Sources"}"#.utf8)
    let decoded = try JSONDecoder().decode(SyncPath.self, from: data)
    #expect(decoded.rawValue == "/Projects/A\u{301}pp/Sources")
    #expect(decoded.isEqualOrDescendant(of: "/projects/ápp"))
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

@Test func packageAncestryUsesNormalizedComponentBoundaries() throws {
    let volume = URL(fileURLWithPath: "/Volumes/DÁTA/", isDirectory: true)
    let selected = URL(
        fileURLWithPath: "/volumes/da\u{301}ta/Documents",
        isDirectory: true
    )
    let inspector = ScriptedSafetyInspector(volumeRoot: volume)
    inspector.overrides[selected.path] = inspector.directory()
    inspector.overrides[selected.deletingLastPathComponent().path] = inspector.directory()

    try LocalPackageAncestryValidator(inspector: inspector)
        .validate(canonicalSelectedRoot: selected)

    let last = try #require(inspector.requestedPaths.last)
    #expect(
        SyncPath(last).caseInsensitiveKey
            == SyncPath(volume.path).caseInsensitiveKey
    )
    #expect(!inspector.requestedPaths.contains("/"))
}

#if canImport(Darwin)
@Test func packageAncestryAcceptsRealTemporaryVolumeRoot() throws {
    let root = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "system-volume-root"
    )
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let selected = root.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: selected,
        withIntermediateDirectories: true
    )

    let inspector = SystemLocalItemSafetyInspector()
    let volumeRoot = try inspector.volumeRoot(for: selected)
    #expect(
        SyncPath(selected.path).isEqualOrDescendant(of: SyncPath(volumeRoot.path))
    )
    try LocalPackageAncestryValidator(inspector: inspector)
        .validate(canonicalSelectedRoot: selected)
}
#endif

@Test func metadataClassifierCoversEveryAcceptedReasonAndBaseline() throws {
    let inspector = ScriptedSafetyInspector(volumeRoot: URL(fileURLWithPath: "/"))
    let uid = LocalItemSafetyClassifier.currentEffectiveUserID
    let gid = LocalItemSafetyClassifier.currentEffectiveGroupID

    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/ordinary.txt",
        metadata: inspector.file(mode: 0o644, owner: uid, group: gid)
    ) == nil)
    #expect(try LocalItemSafetyClassifier.exclusion(
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
        let exclusion = try LocalItemSafetyClassifier.exclusion(
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
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/empty-resource-fork",
        metadata: inspector.file(
            xattrs: [LocalItemSafetyClassifier.resourceForkName: 0]
        )
    ) == nil)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/empty-finder-info",
        metadata: inspector.file(
            xattrs: [LocalItemSafetyClassifier.finderInfoName: 0]
        )
    ) == nil)

    for mode: UInt16 in [0o664, 0o755, 0o600, 0o4755, 0o2755, 0o1755] {
        guard case let .unsupportedPOSIXPermissions(actual, required) =
            try LocalItemSafetyClassifier.exclusion(
                for: "/mode",
                metadata: inspector.file(mode: mode)
            )?.reason else {
            Issue.record("Expected file mode exclusion for \(mode)")
            continue
        }
        #expect(actual == mode)
        #expect(required == 0o644)
    }
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/directory",
        metadata: inspector.directory(mode: 0o775)
    )?.scope == .subtree)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/acl",
        metadata: inspector.file(acl: true)
    )?.reason == .accessControlList)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/owner",
        metadata: inspector.file(owner: uid &+ 1)
    )?.reason == .unsupportedOwnership)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/group",
        metadata: inspector.file(group: gid &+ 1)
    )?.reason == .unsupportedOwnership)
}

@Test func filesystemKindClassificationIsTypedAndFailsClosed() throws {
    let inspector = ScriptedSafetyInspector(volumeRoot: URL(fileURLWithPath: "/"))
    let unsupported: [LocalFilesystemKind] = [
        .fifo,
        .socket,
        .characterDevice,
        .blockDevice,
        .other(modeType: 0o130000),
    ]
    for filesystemKind in unsupported {
        let metadata = LocalItemSafetyMetadata(
            filesystemKind: filesystemKind,
            posixMode: 0o644,
            ownerID: LocalItemSafetyClassifier.currentEffectiveUserID,
            groupID: LocalItemSafetyClassifier.currentEffectiveGroupID
        )
        let exclusion = try #require(
            try LocalItemSafetyClassifier.exclusion(
                for: "/special",
                metadata: metadata
            )
        )
        #expect(exclusion.scope == .item)
        #expect(exclusion.reason == .unsupportedFilesystemKind(filesystemKind))
        #expect(exclusion.reason.message.contains(filesystemKind.displayName))
        let encoded = try JSONEncoder().encode(exclusion)
        #expect(try JSONDecoder().decode(ScanExclusion.self, from: encoded) == exclusion)
    }

    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/file",
        metadata: inspector.file()
    ) == nil)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/folder",
        metadata: inspector.directory()
    ) == nil)
    #expect(try LocalItemSafetyClassifier.exclusion(
        for: "/link",
        metadata: LocalItemSafetyMetadata(
            filesystemKind: .symbolicLink,
            posixMode: 0o777,
            ownerID: LocalItemSafetyClassifier.currentEffectiveUserID,
            groupID: LocalItemSafetyClassifier.currentEffectiveGroupID
        )
    ) == nil)
    #expect(throws: LocalItemSafetyClassificationError.indeterminateFilesystemKind) {
        try LocalItemSafetyClassifier.exclusion(
            for: "/ambiguous",
            metadata: LocalItemSafetyMetadata(
                filesystemKind: .indeterminate,
                posixMode: 0,
                ownerID: 0,
                groupID: 0
            )
        )
    }
}

@Test func symlinkMetadataDoesNotManufacturePermissionExclusion() throws {
    let uid = LocalItemSafetyClassifier.currentEffectiveUserID
    let gid = LocalItemSafetyClassifier.currentEffectiveGroupID
    let metadata = LocalItemSafetyMetadata(
        filesystemKind: .symbolicLink,
        posixMode: 0o755,
        ownerID: uid,
        groupID: gid,
        hasAccessControlList: true,
        extendedAttributeSizes: ["user.link": 1]
    )

    #expect(
        try LocalItemSafetyClassifier.exclusion(
            for: "/current",
            metadata: metadata
        ) == nil
    )
    #expect(
        try LocalItemSafetyClassifier.exclusion(
            for: "/Current.app",
            metadata: LocalItemSafetyMetadata(
                filesystemKind: .symbolicLink,
                isPackage: true,
                posixMode: 0o755,
                ownerID: uid,
                groupID: gid
            )
        ) == nil
    )
}

#if canImport(Darwin)
@Test func systemInspectorSymlinkToExistingFileDoesNotBecomeExclusion() throws {
    let root = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "system-symlink"
    )
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let target = root.appendingPathComponent("target.txt")
    let link = root.appendingPathComponent("current")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: target
    )

    let metadata = try SystemLocalItemSafetyInspector().metadata(at: link)
    #expect(metadata.isSymbolicLink)
    #expect(
        try LocalItemSafetyClassifier.exclusion(
            for: "/current",
            metadata: metadata
        ) == nil
    )
}

@Test(.timeLimit(.minutes(1)))
func fifoAndUnixSocketAreTypedWithoutObservationHashOrFetch() async throws {
    let root = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "special-files"
    )
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let fifoURL = root.appendingPathComponent("events.pipe")
    let socketURL = root.appendingPathComponent("service.sock")
    let fifoResult = fifoURL.withUnsafeFileSystemRepresentation { path in
        path.map { mkfifo($0, mode_t(0o644)) } ?? -1
    }
    guard fifoResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let socketDescriptor = try makeBoundUnixSocket(at: socketURL)
    defer { close(socketDescriptor) }

    let hasher = RecordingSpecialFileHasher()
    let fetcher = RecordingSpecialFileFetcher()
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: SystemLocalItemSafetyInspector(),
        registry: LocalRootIORegistry(),
        fetching: fetcher,
        hashing: hasher
    )
    let snapshot = await provider.scan(.entireDrive)
    #expect(snapshot.status == .complete)
    #expect(snapshot.observations.all.isEmpty)
    #expect(snapshot.exclusions == [
        ScanExclusion(
            path: "/events.pipe",
            scope: .item,
            reason: .unsupportedFilesystemKind(.fifo)
        ),
        ScanExclusion(
            path: "/service.sock",
            scope: .item,
            reason: .unsupportedFilesystemKind(.socket)
        ),
    ])

    for (path, kind) in [
        (SyncPath("/events.pipe"), LocalFilesystemKind.fifo),
        (SyncPath("/service.sock"), LocalFilesystemKind.socket),
    ] {
        let classification = await provider.classify([
            ProviderClassificationRequest(path: path, scope: .item)
        ])
        #expect(classification == .excluded([
            ScanExclusion(
                path: path,
                scope: .item,
                reason: .unsupportedFilesystemKind(kind)
            )
        ]))

        let fabricated = ItemObservation(
            location: .localFolder,
            path: path,
            kind: .file,
            version: ItemVersion(size: 0, modifiedAt: l2Date)
        )
        await #expect(throws: ProviderError.self) {
            try await provider.refineEvidence(for: fabricated)
        }
        let stageURL = root.appendingPathComponent(UUID().uuidString)
        await #expect(throws: ProviderError.self) {
            try await provider.fetch(fabricated, to: stageURL)
        }
        #expect(!FileManager.default.fileExists(atPath: stageURL.path))
    }
    #expect(hasher.callCount == 0)
    #expect(fetcher.callCount == 0)
}
#endif

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

@Test func stableOpaqueRootExternalRelocationCannotAuthorizeDeletion() async throws {
    let left = LocationID(rawValue: UUID())
    let right = LocationID(rawValue: UUID())
    let syncSet = SyncSet(
        id: UUID(),
        name: "Opaque relocation",
        locations: [left, right],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let trackedPath: SyncPath = "/Documents/notes.txt"
    let hiddenRelocation: SyncPath = "/Projects.app/notes.txt"
    let exclusion = ScanExclusion(
        path: "/Projects.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    await leftProvider.setScanExclusions([exclusion])
    _ = await leftProvider.putFile(
        path: trackedPath,
        contents: Data("base".utf8)
    )

    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "opaque-relocation-stage"
    )
    let executor = ScheduleExecutor(
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000),
        environment: ExecutionEnvironment(now: { l2Date })
    )
    let planner = SyncPlanner()

    guard case let .plan(initialPlan) = planner.plan(
        SyncPlanningInput(
            syncSet: syncSet,
            snapshots: [
                await leftProvider.scan(.entireDrive),
                await rightProvider.scan(.entireDrive),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected the initial plan beside the opaque root")
        return
    }
    #expect(initialPlan.gate == .clear)
    let initialSummary = try await executor.execute(initialPlan)
    #expect(initialSummary.outcome == .completedWithExclusions)
    let records = try await stores.baseRecords.records(for: syncSet.id)
    #expect(records.map(\.path) == [trackedPath])
    #expect(await rightProvider.item(at: trackedPath) != nil)

    await leftProvider.remove(path: trackedPath)
    _ = await leftProvider.putFile(
        path: hiddenRelocation,
        contents: Data("base".utf8)
    )
    let relocatedSnapshot = await leftProvider.scan(.entireDrive)
    #expect(relocatedSnapshot.exclusions == [exclusion])
    #expect(!relocatedSnapshot.observations.all.map(\.path).contains(hiddenRelocation))
    guard case let .plan(plan) = planner.plan(
        SyncPlanningInput(
            syncSet: syncSet,
            records: records,
            snapshots: [
                relocatedSnapshot,
                await rightProvider.scan(.entireDrive),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected a review-held plan for opaque relocation")
        return
    }
    #expect(plan.schedule.operations.isEmpty)
    #expect(plan.decisions.count == 1)
    #expect(!plan.decisions.contains { $0.hasDeletionIntent })
    #expect(plan.decisions.allSatisfy { decision in
        if case let .waiting(.unsupportedItem, locations) = decision.verdict {
            return locations == Set([left, right])
        }
        return false
    })
    #expect(plan.exclusions == [
        LocatedScanExclusion(location: left, exclusion: exclusion)
    ])
    #expect(plan.waiting.count == records.count + 1)
    #expect(!plan.gate.permitsApproval)
    let opaqueHolds = plan.gate.holdReasons.compactMap { reason -> OpaqueRelocationEvidence? in
        if case let .opaqueRelocation(evidence) = reason { return evidence }
        return nil
    }
    #expect(opaqueHolds.map(\.trackedPath) == [trackedPath])
    #expect(opaqueHolds.allSatisfy {
        $0.exclusions == [LocatedScanExclusion(location: left, exclusion: exclusion)]
    })

    let preview = ChangePreviewRenderer().render(
        outcome: .plan(plan),
        locations: [:],
        base: records,
        generatedAt: l2Date
    )
    #expect(preview.headline == "Paused for safety")
    let previewHoldExclusions = preview.holds.flatMap { hold -> [LocatedScanExclusion] in
        if case let .opaqueRelocation(evidence) = hold.reason {
            return evidence.exclusions
        }
        return []
    }
    #expect(previewHoldExclusions.contains(
        LocatedScanExclusion(location: left, exclusion: exclusion)
    ))
    let waitingPaths = Set(
        preview.sections.first { $0.kind == .waiting }?.entries.map(\.path) ?? []
    )
    #expect(waitingPaths == Set([trackedPath, exclusion.path]))

    await leftProvider.clearCallLog()
    await rightProvider.clearCallLog()
    let activityBefore = await stores.activity.entries(
        matching: ActivityQuery(limit: 100)
    )
    await #expect(throws: ScheduleExecutionError.planNeedsReview) {
        try await executor.execute(plan)
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(await rightProvider.item(at: trackedPath) != nil)
    #expect(await leftProvider.item(at: hiddenRelocation) != nil)
    #expect(try await stores.baseRecords.records(for: syncSet.id) == records)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
    #expect(await stores.activity.entries(matching: ActivityQuery(limit: 100)) == activityBefore)
}

@Test func longStandingUnrelatedSubtreeExclusionVisiblyHoldsGenuineDeletion() async throws {
    let left = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    let right = LocationID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    )
    let syncSet = SyncSet(
        id: UUID(),
        name: "Unrelated exclusion",
        locations: [left, right],
        mode: .askBeforeDeleting,
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let exclusion = ScanExclusion(
        path: "/Projects/Demo.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let deletedPath: SyncPath = "/Documents/old-draft.txt"
    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    await leftProvider.setScanExclusions([exclusion])
    _ = await leftProvider.putFile(path: deletedPath, contents: Data("draft".utf8))

    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "unrelated-exclusion-stage"
    )
    let executor = ScheduleExecutor(
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000),
        environment: ExecutionEnvironment(now: { l2Date })
    )
    let planner = SyncPlanner()

    guard case let .plan(initialPlan) = planner.plan(
        SyncPlanningInput(
            syncSet: syncSet,
            snapshots: [
                await leftProvider.scan(.entireDrive),
                await rightProvider.scan(.entireDrive),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected initial creation plan")
        return
    }
    #expect(initialPlan.gate == .clear)
    let initialSummary = try await executor.execute(initialPlan)
    #expect(initialSummary.outcome == .completedWithExclusions)

    let records = try await stores.baseRecords.records(for: syncSet.id)
    _ = try #require(records.first { $0.path == deletedPath })
    #expect(await rightProvider.item(at: deletedPath) != nil)

    await leftProvider.remove(path: deletedPath)
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
    guard case let .plan(deletionPlan) = preparation.outcome else {
        Issue.record("Expected a held deletion preparation")
        return
    }

    #expect(deletionPlan.decisions.count == 1)
    #expect(deletionPlan.decisions.first?.hasDeletionIntent == false)
    #expect(deletionPlan.schedule.operations.isEmpty)
    #expect(!deletionPlan.gate.permitsApproval)
    #expect(deletionPlan.gate.holdReasons.contains { reason in
        guard case let .opaqueRelocation(evidence) = reason else { return false }
        return evidence.trackedPath == deletedPath
            && evidence.exclusions == [
                LocatedScanExclusion(location: left, exclusion: exclusion)
            ]
    })
    #expect(deletionPlan.exclusions == [
        LocatedScanExclusion(location: left, exclusion: exclusion)
    ])
    #expect(deletionPlan.waiting.count == 2)

    let activity = await stores.activity.entries(
        matching: ActivityQuery(syncSetID: syncSet.id, runID: preparation.runID, limit: 100)
    )
    #expect(activity.contains { entry in
        entry.message
            == "Deletion of \(deletedPath.rawValue) needs review because an excluded subtree could contain this item."
            && entry.detail
                == "\(deletedPath.rawValue) may be inside \(left.rawValue.uuidString):\(exclusion.path.rawValue)|subtree|\(exclusion.reason.stableKey)"
    })
    #expect(!activity.contains { $0.message == ActivityMessageCatalog.runFinished })

    let preview = ChangePreviewRenderer().render(
        outcome: .plan(deletionPlan),
        locations: [:],
        base: records,
        generatedAt: l2Date
    )
    #expect(preview.headline == "Paused for safety")
    #expect(preview.sections.first { $0.kind == .movesToTrash }?.entries.isEmpty == true)
    #expect(Set(preview.sections.first { $0.kind == .waiting }?.entries.map(\.path) ?? []) == Set([
        deletedPath,
        exclusion.path,
    ]))
    #expect(preview.exclusions.map(\.path) == [exclusion.path])

    await leftProvider.clearCallLog()
    await rightProvider.clearCallLog()
    let injectedOperationID = OperationID(UUID())
    var injectedPlan = deletionPlan
    injectedPlan.schedule.operations.append(
        Operation(
            id: injectedOperationID,
            location: right,
            kind: .makeFolder(at: "/Independent"),
            precondition: .pathAbsent
        )
    )
    injectedPlan.decisions.append(
        ItemDecision(
            id: UUID(),
            path: "/Independent",
            verdict: .propagateCreation(from: left, to: Set([right])),
            operations: [injectedOperationID],
            explanation: "Caller-injected operation."
        )
    )
    #expect(injectedPlan.fingerprint == deletionPlan.fingerprint)
    guard case .safeSubset = injectedPlan.executionAdmission else {
        Issue.record("Expected the forged plan to pass pure safe-subset proof")
        return
    }
    var injectedPreparation = preparation
    injectedPreparation.outcome = .plan(injectedPlan)
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(
            preparation.runID
        )
    ) {
        try await orchestrator.execute(injectedPreparation)
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(await rightProvider.item(at: "/Independent") == nil)
    #expect(try await stores.baseRecords.records(for: syncSet.id) == records)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)

    let approval = PlanApproval(
        planFingerprint: deletionPlan.fingerprint,
        approvedAt: l2Date,
        acknowledgedTrashCount: deletionPlan.approvalTrashCount,
        acknowledgedConflictCount: deletionPlan.approvalConflictCount
    )
    let heldSummary = try await orchestrator.execute(
        preparation,
        approval: approval
    )
    #expect(heldSummary.outcome == .held)
    let heldActivity = await stores.activity.entries(
        matching: ActivityQuery(
            syncSetID: syncSet.id,
            runID: preparation.runID,
            limit: 100
        )
    )
    #expect(heldActivity.contains {
        $0.message == ActivityMessageCatalog.runHeld
    })
    #expect(!heldActivity.contains {
        $0.message == ActivityMessageCatalog.runFinished
    })
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(await rightProvider.item(at: deletedPath) != nil)
    #expect(try await stores.baseRecords.records(for: syncSet.id) == records)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)

    let activityBeforeDirectExecutor = await stores.activity.entries(
        matching: ActivityQuery(limit: 100)
    )
    await #expect(throws: ScheduleExecutionError.planNeedsReview) {
        try await executor.execute(deletionPlan, approval: approval)
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(await rightProvider.item(at: deletedPath) != nil)
    #expect(try await stores.baseRecords.records(for: syncSet.id) == records)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
    #expect(
        await stores.activity.entries(matching: ActivityQuery(limit: 100))
            == activityBeforeDirectExecutor
    )
}

@Test func opaqueDeletionExecutesOnlyIndependentEditCreateAndMove() async throws {
    let left = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
    )
    let right = LocationID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!
    )
    let syncSet = SyncSet(
        id: UUID(),
        name: "Independent opaque work",
        locations: [left, right],
        settings: SyncSettings(
            thresholds: SafetyThresholds(massEditAbsolute: 1)
        ),
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let exclusion = ScanExclusion(
        path: "/Projects/Demo.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let deletedPath: SyncPath = "/Documents/old-draft.txt"
    let editedPath: SyncPath = "/Documents/report.txt"
    let createdPath: SyncPath = "/Documents/new.txt"
    let movedPath: SyncPath = "/Documents/move-me.txt"
    let movedDestination: SyncPath = "/Archive/moved.txt"
    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    await leftProvider.setScanExclusions([exclusion])
    _ = await leftProvider.putFile(
        path: deletedPath,
        contents: Data("delete later".utf8)
    )
    _ = await leftProvider.putFile(
        path: editedPath,
        contents: Data("before".utf8)
    )
    _ = await leftProvider.putFile(
        path: movedPath,
        contents: Data("move".utf8)
    )

    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "opaque-independent-stage"
    )
    let stage = ContentStage(
        rootDirectory: stageRoot,
        byteLimit: 1_000_000
    )
    let planner = SyncPlanner()
    guard case let .plan(initialPlan) = planner.plan(
        SyncPlanningInput(
            syncSet: syncSet,
            snapshots: [
                await leftProvider.scan(.entireDrive),
                await rightProvider.scan(.entireDrive),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected the initial creation plan")
        return
    }
    _ = try await ScheduleExecutor(
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: stage,
        environment: ExecutionEnvironment(now: { l2Date })
    ).execute(initialPlan)

    let initialRecords = try await stores.baseRecords.records(for: syncSet.id)
    let heldRecord = try #require(
        initialRecords.first { $0.path == deletedPath }
    )
    await leftProvider.remove(path: deletedPath)
    let edited = await leftProvider.putFile(
        path: editedPath,
        contents: Data("after".utf8)
    )
    _ = await leftProvider.putFile(
        path: createdPath,
        contents: Data("new".utf8)
    )
    guard let moveSource = await leftProvider.item(at: movedPath) else {
        Issue.record("Expected the move source")
        return
    }
    _ = try await leftProvider.relocate(
        moveSource,
        to: movedDestination
    )

    let locations = Dictionary(uniqueKeysWithValues: [left, right].map {
        ($0, SyncLocation(id: $0, kind: .localFolder, scope: .entireDrive))
    })
    let orchestrator = SyncOrchestrator(
        locations: locations,
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: stage,
        environment: EngineEnvironment(now: { l2Date }, makeID: { UUID() })
    )
    let preparation = try await orchestrator.prepare(syncSet)
    let plan = try #require(preparation.outcome.planValue)
    #expect(plan.schedule.operations.count == 3)
    #expect(plan.decisions.count == 4)
    #expect(!plan.gate.permitsApproval)
    guard case let .safeSubset(proof) = plan.executionAdmission else {
        Issue.record("Expected planner-proven independent execution")
        return
    }
    #expect(proof.heldDecisionIDs.count == 1)
    #expect(proof.scheduledOperationIDs.count == 3)
    #expect(plan.nonOpaqueHoldReasons.contains { reason in
        if case .massEdit = reason { return true }
        return false
    })

    let approval = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: l2Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
    await leftProvider.clearCallLog()
    await rightProvider.clearCallLog()

    var changedSchedule = plan
    changedSchedule.schedule.operations[0].precondition = .folderPresent
    var changedOwnership = plan
    let heldIndex = try #require(
        changedOwnership.decisions.firstIndex { $0.path == deletedPath }
    )
    changedOwnership.decisions[heldIndex].operations = [
        plan.schedule.operations[0].id
    ]
    var changedMembership = plan
    changedMembership.participatingLocations.removeLast()
    let opaqueEvidence = try #require(
        plan.gate.holdReasons.compactMap { reason -> OpaqueRelocationEvidence? in
            if case let .opaqueRelocation(evidence) = reason { return evidence }
            return nil
        }.first
    )
    let changedGate = plan.addingHolds([
        .opaqueRelocation(
            OpaqueRelocationEvidence(
                trackedPath: "/Caller/Changed.txt",
                exclusions: opaqueEvidence.exclusions
            )
        ),
    ])

    for changedPlan in [
        changedSchedule,
        changedOwnership,
        changedMembership,
        changedGate,
    ] {
        var changedPreparation = preparation
        changedPreparation.outcome = .plan(changedPlan)
        #expect(changedPlan.fingerprint == plan.fingerprint)
        await #expect(
            throws: SyncOrchestratorError.freshPreparationRequired(
                preparation.runID
            )
        ) {
            try await orchestrator.execute(
                changedPreparation,
                approval: approval
            )
        }
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)

    var changedPreview = preparation
    changedPreview.preview.headline = "Caller-mutated preview"
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(
            preparation.runID
        )
    ) {
        try await orchestrator.execute(changedPreview, approval: approval)
    }

    var changedFingerprintPlan = plan
    changedFingerprintPlan.fingerprint = PlanFingerprint(
        rawValue: "caller-mutated-fingerprint"
    )
    var changedFingerprint = preparation
    changedFingerprint.outcome = .plan(changedFingerprintPlan)
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(
            preparation.runID
        )
    ) {
        try await orchestrator.execute(
            changedFingerprint,
            approval: approval
        )
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)

    // A value-identical copy remains executable; authority is retained truth,
    // not object identity.
    let identicalCopy = preparation
    let summary = try await orchestrator.execute(
        identicalCopy,
        approval: approval
    )
    #expect(summary.outcome == .completedWithExclusions)
    #expect(summary.appliedOperations.count == 3)
    #expect(summary.failedOperations.isEmpty)
    let heldDecision = try #require(
        plan.decisions.first { $0.path == deletedPath }
    )
    #expect(!summary.perItemResults.contains { $0.id == heldDecision.id })
    #expect(
        Set(summary.perItemResults.map(\.path))
            == Set([editedPath, createdPath, movedDestination])
    )
    #expect(await rightProvider.item(at: deletedPath) != nil)
    #expect(
        await rightProvider.item(at: editedPath)?.version.contentHash
            == edited.version.contentHash
    )
    #expect(await rightProvider.item(at: createdPath) != nil)
    #expect(await rightProvider.item(at: movedPath) == nil)
    #expect(await rightProvider.item(at: movedDestination) != nil)

    let recordsAfterExecution = try await stores.baseRecords.records(
        for: syncSet.id
    )
    #expect(
        recordsAfterExecution.first { $0.id == heldRecord.id }
            == heldRecord
    )
    #expect(recordsAfterExecution.contains { $0.path == createdPath })
    #expect(recordsAfterExecution.contains { $0.path == movedDestination })
    let activity = await stores.activity.entries(
        matching: ActivityQuery(
            syncSetID: syncSet.id,
            runID: preparation.runID,
            limit: 200
        )
    )
    #expect(activity.contains {
        $0.message == ActivityMessageCatalog.independentChangesApplied
    })
    #expect(!activity.contains {
        $0.message == ActivityMessageCatalog.runFinished
            || $0.message == ActivityMessageCatalog.runFinishedWithExclusions
    })

    let rerunPreparation = try await orchestrator.prepare(syncSet)
    let rerunPlan = try #require(rerunPreparation.outcome.planValue)
    #expect(rerunPlan.schedule.operations.isEmpty)
    #expect(rerunPlan.executionAdmission == .blocked)
    await leftProvider.clearCallLog()
    await rightProvider.clearCallLog()
    let rerunSummary = try await orchestrator.execute(rerunPreparation)
    #expect(rerunSummary.outcome == .held)
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(
        try await stores.baseRecords.records(for: syncSet.id)
            == recordsAfterExecution
    )
    #expect(try await stores.journal.unfinishedRun(for: syncSet.id) == nil)
}

@Test func opaqueSafeSubsetAdmissionFailsClosedOnAmbiguousProof() throws {
    let left = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000021")!
    )
    let right = LocationID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000022")!
    )
    let heldID = UUID(
        uuidString: "30000000-0000-0000-0000-000000000023"
    )!
    let independentID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000024"
    )!
    let operationID = OperationID(
        UUID(uuidString: "50000000-0000-0000-0000-000000000025")!
    )
    let exclusion = ScanExclusion(
        path: "/Projects/Demo.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let located = LocatedScanExclusion(
        location: left,
        exclusion: exclusion
    )
    let operation = Operation(
        id: operationID,
        location: right,
        kind: .makeFolder(at: "/Independent"),
        precondition: .pathAbsent
    )
    let held = ItemDecision(
        id: heldID,
        path: "/Documents/deleted.txt",
        verdict: .waiting(
            .unsupportedItem,
            locations: Set([left, right])
        ),
        operations: [],
        explanation: "Paused for safety."
    )
    let independent = ItemDecision(
        id: independentID,
        path: "/Independent",
        verdict: .propagateCreation(from: left, to: Set([right])),
        operations: [operationID],
        explanation: "Independent create."
    )
    let opaque = HoldReason.opaqueRelocation(
        OpaqueRelocationEvidence(
            trackedPath: held.path,
            exclusions: [located]
        )
    )
    let valid = SyncPlan(
        syncSetID: UUID(),
        participatingLocations: [left, right],
        generatedAt: l2Date,
        decisions: [held, independent],
        schedule: OperationSchedule(operations: [operation]),
        exclusions: [located],
        gate: .hold([opaque]),
        fingerprint: PlanFingerprint(rawValue: "safe-subset-proof")
    )
    guard case let .safeSubset(proof) = valid.executionAdmission else {
        Issue.record("Expected a valid safe-subset proof")
        return
    }
    #expect(proof.heldDecisionIDs == [heldID])
    #expect(proof.scheduledOperationIDs == [operationID])

    var unowned = valid
    unowned.decisions[1].operations = []
    #expect(unowned.executionAdmission == .blocked)

    var mismatched = valid
    mismatched.decisions[1].operations = [OperationID(UUID())]
    #expect(mismatched.executionAdmission == .blocked)

    var multiplyOwned = valid
    multiplyOwned.decisions[0].operations = [operationID]
    #expect(multiplyOwned.executionAdmission == .blocked)

    var duplicateHeldPath = valid
    duplicateHeldPath.decisions[1].path = "/documents/DELETED.txt"
    #expect(duplicateHeldPath.executionAdmission == .blocked)

    var duplicateDecisionID = valid
    duplicateDecisionID.decisions[1].id = heldID
    #expect(duplicateDecisionID.executionAdmission == .blocked)

    var trackedOverlap = valid
    trackedOverlap.schedule.operations[0].kind = .makeFolder(
        at: "/documents/deleted.txt/child"
    )
    #expect(trackedOverlap.executionAdmission == .blocked)

    var opaqueRootOverlap = valid
    opaqueRootOverlap.schedule.operations[0].location = left
    opaqueRootOverlap.schedule.operations[0].kind = .makeFolder(
        at: "/projects/demo.app/Child"
    )
    #expect(opaqueRootOverlap.executionAdmission == .blocked)

    var mismatchedItemReference = valid
    mismatchedItemReference.schedule.operations[0].location = left
    mismatchedItemReference.schedule.operations[0].kind = .relocate(
        itemRef: ItemRef(
            location: right,
            itemID: "mismatch",
            path: "/Projects/Demo.app/child",
            kind: .file,
            expectedVersion: ItemVersion(revisionToken: "rev-1")
        ),
        to: "/Elsewhere/child"
    )
    mismatchedItemReference.schedule.operations[0].precondition = .versionMatches(
        ItemVersion(revisionToken: "rev-1")
    )
    #expect(mismatchedItemReference.executionAdmission == .blocked)

    var heldDependency = valid
    let heldOperationID = OperationID(UUID())
    heldDependency.decisions[0].operations = [heldOperationID]
    heldDependency.schedule.operations.insert(
        Operation(
            id: heldOperationID,
            location: right,
            kind: .makeFolder(at: "/Held"),
            precondition: .pathAbsent
        ),
        at: 0
    )
    heldDependency.schedule.operations[1].dependsOn = [heldOperationID]
    #expect(heldDependency.executionAdmission == .blocked)

    var outsideMembership = valid
    outsideMembership.schedule.operations[0].location = LocationID()
    #expect(outsideMembership.executionAdmission == .blocked)

    var mismatchedEvidence = valid
    mismatchedEvidence.exclusions = []
    #expect(mismatchedEvidence.executionAdmission == .blocked)

    var incompleteEvidence = valid
    let secondLocated = LocatedScanExclusion(
        location: left,
        exclusion: ScanExclusion(
            path: "/OtherOpaque.app",
            scope: .subtree,
            reason: .packageDirectory
        )
    )
    incompleteEvidence.exclusions.append(secondLocated)
    #expect(incompleteEvidence.executionAdmission == .blocked)

    var duplicateEvidence = valid
    duplicateEvidence.exclusions.append(located)
    #expect(duplicateEvidence.executionAdmission == .blocked)

    var incompleteWaitingLocations = valid
    incompleteWaitingLocations.decisions[0].verdict = .waiting(
        .unsupportedItem,
        locations: Set([left])
    )
    #expect(incompleteWaitingLocations.executionAdmission == .blocked)

    var duplicateMembership = valid
    duplicateMembership.participatingLocations.append(left)
    #expect(duplicateMembership.executionAdmission == .blocked)

    var empty = valid
    empty.decisions[1].operations = []
    empty.schedule.operations = []
    #expect(empty.executionAdmission == .blocked)

    let massDeletion = MassChangeEvidence(
        intentCount: 25,
        trackedCount: 25,
        groups: [ChangeGroup(ancestor: "/", intentCount: 25)]
    )
    #expect(
        valid.addingHolds([.massDeletion(massDeletion)]).executionAdmission
            == .blocked
    )
    #expect(valid.addingHolds([opaque]).executionAdmission == .blocked)
}

@Test func safeSubsetRetainsApprovalForOtherApprovableHolds() async throws {
    let left = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000031")!
    )
    let right = LocationID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000032")!
    )
    let operationID = OperationID(UUID())
    let exclusion = ScanExclusion(
        path: "/Opaque.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let located = LocatedScanExclusion(location: left, exclusion: exclusion)
    let held = ItemDecision(
        id: UUID(),
        path: "/Documents/deleted.txt",
        verdict: .waiting(.unsupportedItem, locations: Set([left, right])),
        operations: [],
        explanation: "Paused for safety."
    )
    let independent = ItemDecision(
        id: UUID(),
        path: "/Independent",
        verdict: .propagateCreation(from: left, to: Set([right])),
        operations: [operationID],
        explanation: "Independent create."
    )
    let operation = Operation(
        id: operationID,
        location: right,
        kind: .makeFolder(at: independent.path),
        precondition: .pathAbsent
    )
    let plan = SyncPlan(
        syncSetID: UUID(),
        participatingLocations: [left, right],
        generatedAt: l2Date,
        decisions: [held, independent],
        schedule: OperationSchedule(operations: [operation]),
        exclusions: [located],
        gate: .hold([
            .opaqueRelocation(
                OpaqueRelocationEvidence(
                    trackedPath: held.path,
                    exclusions: [located]
                )
            ),
            .massEdit(
                MassChangeEvidence(
                    intentCount: 1,
                    trackedCount: 1,
                    groups: [
                        ChangeGroup(
                            ancestor: independent.path,
                            intentCount: 1
                        )
                    ]
                )
            ),
        ]),
        fingerprint: PlanFingerprint(rawValue: "safe-subset-approval")
    )
    #expect(!plan.gate.permitsApproval)
    guard case .safeSubset = plan.executionAdmission else {
        Issue.record("Expected safe-subset admission")
        return
    }
    let approval = PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: l2Date,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
    #expect(
        approval.validate(against: plan, at: l2Date)
            == .rejected(.safetyHoldNotApprovable)
    )

    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "safe-subset-approval-stage"
    )
    let executor = ScheduleExecutor(
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: ContentStage(
            rootDirectory: stageRoot,
            byteLimit: 1_000_000
        ),
        environment: ExecutionEnvironment(now: { l2Date })
    )
    var duplicateDecisionPlan = plan
    let duplicateDecisionID = duplicateDecisionPlan.decisions[0].id
    duplicateDecisionPlan.decisions[1].id = duplicateDecisionID
    #expect(duplicateDecisionPlan.executionAdmission == .blocked)
    await #expect(throws: ScheduleExecutionError.planNeedsReview) {
        try await executor.execute(
            duplicateDecisionPlan,
            approval: approval
        )
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)
    #expect(try await stores.journal.unfinishedRun(for: plan.syncSetID) == nil)

    await #expect(throws: ScheduleExecutionError.planNeedsReview) {
        try await executor.execute(plan)
    }
    #expect(await leftProvider.callLog().isEmpty)
    #expect(await rightProvider.callLog().isEmpty)

    let summary = try await executor.execute(plan, approval: approval)
    #expect(summary.outcome == .completedWithExclusions)
    #expect(summary.appliedOperations.count == 1)
    #expect(await rightProvider.item(at: independent.path)?.isFolder == true)
    let resultingRecords = try await stores.baseRecords.records(
        for: plan.syncSetID
    )
    #expect(resultingRecords.map(\.path) == [independent.path])
    let activity = await stores.activity.entries(
        matching: ActivityQuery(runID: summary.runID, limit: 100)
    )
    #expect(activity.contains {
        $0.message == ActivityMessageCatalog.independentChangesApplied
    })
    #expect(activity.contains {
        $0.message.hasPrefix("You approved ")
    })
    #expect(!activity.contains {
        $0.message == ActivityMessageCatalog.runFinished
            || $0.message == ActivityMessageCatalog.runFinishedWithExclusions
    })
}

@Test func noOpaqueSubtreeKeepsOrdinaryDeleteToTrashInspectableAndExecutable() async throws {
    let left = LocationID(rawValue: UUID())
    let right = LocationID(rawValue: UUID())
    let syncSet = SyncSet(
        id: UUID(),
        name: "Ordinary deletion",
        locations: [left, right],
        mode: .askBeforeDeleting,
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let path: SyncPath = "/Documents/old-draft.txt"
    let leftProvider = FakeStorageProvider(locationID: left)
    let rightProvider = FakeStorageProvider(locationID: right)
    let leftItem = await leftProvider.putFile(
        path: path,
        contents: Data("draft".utf8)
    )
    let rightItem = await rightProvider.putFile(
        path: path,
        contents: Data("draft".utf8)
    )
    let record = BaseRecord(
        syncSetID: syncSet.id,
        path: path,
        kind: .file,
        version: leftItem.version,
        perLocation: [
            left: LocationMemory(
                itemID: leftItem.itemID,
                revisionToken: leftItem.version.revisionToken,
                lastSeenAt: l2Date
            ),
            right: LocationMemory(
                itemID: rightItem.itemID,
                revisionToken: rightItem.version.revisionToken,
                lastSeenAt: l2Date
            ),
        ],
        lastConvergedAt: l2Date,
        createdAt: l2Date,
        updatedAt: l2Date
    )
    await leftProvider.remove(path: path)

    guard case let .plan(plan) = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            records: [record],
            snapshots: [
                await leftProvider.scan(.entireDrive),
                await rightProvider.scan(.entireDrive),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    ) else {
        Issue.record("Expected an ordinary deletion plan")
        return
    }
    #expect(plan.decisions.count == 1)
    #expect(plan.decisions.first?.hasDeletionIntent == true)
    #expect(plan.schedule.operations.count == 1)
    #expect(plan.schedule.operations.first?.kind.isTrash == true)
    #expect(plan.gate.permitsApproval)
    #expect(!plan.gate.holdReasons.contains { reason in
        if case .opaqueRelocation = reason { return true }
        return false
    })
    let preview = ChangePreviewRenderer().render(
        outcome: .plan(plan),
        locations: [:],
        base: [record],
        generatedAt: l2Date
    )
    #expect(preview.headline == "Needs review")
    #expect(
        preview.sections.first { $0.kind == .movesToTrash }?.entries.map(\.path)
            == [path]
    )

    let stores = EngineStores.inMemory()
    try await stores.baseRecords.apply(.upsert(record))
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "ordinary-deletion-stage"
    )
    let executor = ScheduleExecutor(
        providers: [left: leftProvider, right: rightProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000),
        environment: ExecutionEnvironment(now: { l2Date })
    )
    let summary = try await executor.execute(
        plan,
        approval: PlanApproval(
            planFingerprint: plan.fingerprint,
            approvedAt: l2Date,
            acknowledgedTrashCount: plan.approvalTrashCount,
            acknowledgedConflictCount: plan.approvalConflictCount
        )
    )
    #expect(summary.appliedOperations.count == 1)
    #expect(await rightProvider.item(at: path) == nil)
}

@Test func opaqueRootTransitionsRemainExactIsolatedAndIdempotent() throws {
    let left = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    let right = LocationID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    )
    let syncSet = SyncSet(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        name: "Opaque transitions",
        locations: [left, right],
        mode: .askBeforeDeleting,
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let path: SyncPath = "/Documents/report.txt"
    let version = ItemVersion(contentHash: "content")
    let record = BaseRecord(
        id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
        syncSetID: syncSet.id,
        path: path,
        kind: .file,
        version: version,
        perLocation: [
            left: LocationMemory(lastSeenAt: l2Date),
            right: LocationMemory(lastSeenAt: l2Date),
        ],
        lastConvergedAt: l2Date,
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let leftBase = ItemObservation(
        location: left,
        path: path,
        kind: .file,
        version: version
    )
    let rightBase = ItemObservation(
        location: right,
        path: path,
        kind: .file,
        version: version
    )
    let firstRoot = ScanExclusion(
        path: "/Opaque/Ápp",
        scope: .subtree,
        reason: .packageDirectory
    )
    let secondRoot = ScanExclusion(
        path: "/Other.app",
        scope: .subtree,
        reason: .unsupportedPOSIXPermissions(actual: 0o775, required: 0o755)
    )
    let addedRoot = ScanExclusion(
        path: "/Third.app",
        scope: .subtree,
        reason: .unsupportedOwnership
    )
    let environment = PlanningEnvironment(now: l2Date)

    func makePlan(
        leftObservations: [ItemObservation],
        leftExclusions: [ScanExclusion],
        rightObservations: [ItemObservation] = [rightBase],
        rightExclusions: [ScanExclusion] = [],
        trackedRecord: BaseRecord? = nil
    ) throws -> SyncPlan {
        let outcome = SyncPlanner().plan(
            SyncPlanningInput(
                syncSet: syncSet,
                records: [trackedRecord ?? record],
                snapshots: [
                    LocationSnapshot(
                        location: left,
                        scope: .entireDrive,
                        observations: leftObservations,
                        exclusions: leftExclusions,
                        scannedAt: l2Date
                    ),
                    LocationSnapshot(
                        location: right,
                        scope: .entireDrive,
                        observations: rightObservations,
                        exclusions: rightExclusions,
                        scannedAt: l2Date
                    ),
                ]
            ),
            environment: environment
        )
        guard case let .plan(plan) = outcome else {
            Issue.record("Expected a plan for complete opaque-root snapshots")
            throw CancellationError()
        }
        return plan
    }

    let stable = try makePlan(
        leftObservations: [],
        leftExclusions: [firstRoot, secondRoot]
    )
    let stableRerun = try makePlan(
        leftObservations: [],
        leftExclusions: [secondRoot, firstRoot]
    )
    #expect(stable == stableRerun)
    let stableEvidence = try #require(stable.gate.holdReasons.compactMap { reason in
        if case let .opaqueRelocation(evidence) = reason { return evidence }
        return nil
    }.first)
    #expect(stableEvidence.trackedPath == path)
    #expect(stableEvidence.exclusions == [
        LocatedScanExclusion(location: left, exclusion: firstRoot),
        LocatedScanExclusion(location: left, exclusion: secondRoot),
    ].sorted())

    var legacyRecord = record
    legacyRecord.perLocation = [:]
    let legacy = try makePlan(
        leftObservations: [],
        leftExclusions: [firstRoot, secondRoot],
        trackedRecord: legacyRecord
    )
    #expect(legacy.gate.holdReasons.contains { reason in
        guard case let .opaqueRelocation(evidence) = reason else { return false }
        return evidence.trackedPath == path && evidence.exclusions == stableEvidence.exclusions
    })

    let withAddition = try makePlan(
        leftObservations: [],
        leftExclusions: [firstRoot, secondRoot, addedRoot]
    )
    #expect(withAddition.gate.holdReasons.contains { reason in
        guard case let .opaqueRelocation(evidence) = reason else { return false }
        return evidence.exclusions.count == 3
    })

    let removed = try makePlan(leftObservations: [], leftExclusions: [])
    #expect(removed.decisions.first?.hasDeletionIntent == true)
    #expect(removed.schedule.operations.first?.kind.isTrash == true)
    #expect(removed.gate.permitsApproval)

    let respelledRoot = ScanExclusion(
        path: "/opaque/A\u{301}PP",
        scope: .subtree,
        reason: .packageDirectory
    )
    let reappeared = try makePlan(
        leftObservations: [],
        leftExclusions: [respelledRoot]
    )
    #expect(reappeared.gate.holdReasons.contains { reason in
        guard case let .opaqueRelocation(evidence) = reason else { return false }
        return evidence.exclusions == [
            LocatedScanExclusion(location: left, exclusion: respelledRoot)
        ] && evidence.exclusions.first?.exclusion.path.rawValue
            == respelledRoot.path.rawValue
    })

    let isolated = try makePlan(
        leftObservations: [],
        leftExclusions: [],
        rightExclusions: [firstRoot, secondRoot]
    )
    #expect(isolated.decisions.first?.hasDeletionIntent == true)
    #expect(!isolated.gate.holdReasons.contains { reason in
        if case .opaqueRelocation = reason { return true }
        return false
    })

    let inSync = try makePlan(
        leftObservations: [leftBase],
        leftExclusions: [firstRoot, secondRoot]
    )
    #expect(inSync.decisions.isEmpty)
    #expect(inSync.schedule.operations.isEmpty)
    #expect(inSync.gate == .clear)

    let movedPath: SyncPath = "/Moved/report.txt"
    let moved = try makePlan(
        leftObservations: [
            ItemObservation(
                location: left,
                path: movedPath,
                kind: .file,
                version: version
            )
        ],
        leftExclusions: [firstRoot, secondRoot]
    )
    #expect(moved.schedule.operations.contains { operation in
        if case let .relocate(_, newPath) = operation.kind {
            return operation.location == right && newPath == movedPath
        }
        return false
    })
    #expect(!moved.gate.holdReasons.contains { reason in
        if case .opaqueRelocation = reason { return true }
        return false
    })
}

@Test func incompleteSnapshotWithOpaqueEvidenceRefusesBeforeAbsenceReasoning() {
    let left = LocationID(rawValue: UUID())
    let right = LocationID(rawValue: UUID())
    let syncSet = SyncSet(
        id: UUID(),
        name: "Incomplete opaque snapshot",
        locations: [left, right],
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let path: SyncPath = "/Tracked.txt"
    let record = BaseRecord(
        syncSetID: syncSet.id,
        path: path,
        kind: .file,
        version: ItemVersion(contentHash: "base"),
        createdAt: l2Date,
        updatedAt: l2Date
    )
    let exclusion = ScanExclusion(
        path: "/Opaque.app",
        scope: .subtree,
        reason: .packageDirectory
    )
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            records: [record],
            snapshots: [
                LocationSnapshot(
                    location: left,
                    scope: .entireDrive,
                    observations: [],
                    exclusions: [exclusion],
                    status: .incomplete(reason: "lstat ambiguity"),
                    scannedAt: l2Date
                ),
                LocationSnapshot(
                    location: right,
                    scope: .entireDrive,
                    observations: [
                        ItemObservation(
                            location: right,
                            path: path,
                            kind: .file,
                            version: record.version
                        )
                    ],
                    scannedAt: l2Date
                ),
            ]
        ),
        environment: PlanningEnvironment(now: l2Date)
    )
    guard case let .refusal(refusal) = outcome else {
        Issue.record("Expected incomplete-scan refusal")
        return
    }
    #expect(refusal.reasons.contains { reason in
        if case let .scanIncomplete(location, detail) = reason {
            return location == left && detail == "lstat ambiguity"
        }
        return false
    })
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
        ProviderClassificationRequest(path: "/Folder", scope: .subtree)
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

    await lastProvider.setClassification(nil)
    let replacement = try await orchestrator.prepare(syncSet)
    #expect(replacement.runID != preparation.runID)
    await #expect(
        throws: SyncOrchestratorError.freshPreparationRequired(preparation.runID)
    ) {
        try await orchestrator.execute(preparation)
    }
}

@Test func makeFolderDescendantDriftAbortsEveryLocationBeforeMutation() async throws {
    let first = LocationID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    let last = LocationID(
        rawValue: UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!
    )
    let firstProvider = FakeStorageProvider(locationID: first)
    let root = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "make-folder-descendant-preflight"
    )
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let folder = root.appendingPathComponent("Shared", isDirectory: true)
    let descendant = folder.appendingPathComponent("private.txt")
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )
    try Data("private".utf8).write(to: descendant)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.overrides[descendant.path] = inspector.file(mode: 0o600)
    let lastProvider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry(),
        locationID: last
    )
    let operation = Operation(
        id: OperationID(UUID()),
        location: first,
        kind: .makeFolder(at: "/Shared"),
        precondition: .pathAbsent
    )
    let syncSetID = UUID()
    let plan = SyncPlan(
        syncSetID: syncSetID,
        participatingLocations: [first, last],
        generatedAt: l2Date,
        decisions: [],
        schedule: OperationSchedule(operations: [operation]),
        gate: .clear,
        fingerprint: PlanFingerprint(rawValue: "make-folder-descendant-preflight")
    )
    let stores = EngineStores.inMemory()
    let stageRoot = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "make-folder-descendant-stage"
    )
    let executor = ScheduleExecutor(
        providers: [first: firstProvider, last: lastProvider],
        stores: stores,
        stage: ContentStage(rootDirectory: stageRoot, byteLimit: 1_000_000)
    )

    await #expect(throws: ScheduleExecutionError.self) {
        try await executor.execute(plan)
    }
    #expect(await firstProvider.callLog().map(\.operation) == [.classify])
    #expect(await firstProvider.item(at: "/Shared") == nil)
    #expect(inspector.requestedPaths.contains(descendant.path))
    #expect(FileManager.default.fileExists(atPath: descendant.path))
    #expect(try await stores.journal.unfinishedRun(for: syncSetID) == nil)
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
        ),
        Operation(
            id: OperationID(UUID()),
            location: destination,
            kind: .makeFolder(at: "/Created"),
            precondition: .pathAbsent
        )
    ]))
    let requests = await provider.classificationRequestLog().first ?? []
    #expect(requests.contains(.init(path: "/Projects/App", scope: .subtree)))
    #expect(requests.contains(.init(path: "/Archive/App", scope: .subtree)))
    #expect(requests.contains(.init(path: "/Projects", scope: .item)))
    #expect(requests.contains(.init(path: "/Archive", scope: .item)))
    #expect(requests.contains(.init(path: "/Created", scope: .subtree)))
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

@Test func indeterminateFilesystemKindMakesScanAndLiveClassificationAmbiguous() async throws {
    let root = try TestTemporaryDirectory.make(
        suite: "l2",
        name: "kind-ambiguity"
    )
    let lease = TestDirectoryLease(rootURL: root)
    _ = lease
    let ambiguous = root.appendingPathComponent("ambiguous.txt")
    try Data("truth".utf8).write(to: ambiguous)
    let inspector = ScriptedSafetyInspector(volumeRoot: root)
    inspector.overrides[ambiguous.path] = LocalItemSafetyMetadata(
        filesystemKind: .indeterminate,
        posixMode: 0,
        ownerID: 0,
        groupID: 0
    )
    let provider = await makeLocalProvider(
        root: root,
        safetyInspector: inspector,
        registry: LocalRootIORegistry()
    )

    let snapshot = await provider.scan(.entireDrive)
    guard case .incomplete = snapshot.status else {
        Issue.record("An indeterminate lstat kind must make the scan incomplete")
        return
    }
    #expect(snapshot.observations.all.isEmpty)
    #expect(snapshot.exclusions.isEmpty)
    guard case .ambiguous = await provider.classify([
        ProviderClassificationRequest(path: "/ambiguous.txt", scope: .item)
    ]) else {
        Issue.record("An indeterminate lstat kind must make live classification ambiguous")
        return
    }
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
    registry: LocalRootIORegistry,
    locationID: LocationID = .localFolder,
    fetching: any LocalFetchPerforming = SystemLocalFetchPerformer(),
    hashing: any LocalFileHashing = SystemLocalFileHasher()
) async -> LocalFolderStorageProvider {
    var location = SyncLocation(
        id: locationID,
        kind: .localFolder,
        displayName: "Local",
        scope: .entireDrive
    )
    location.configuration[LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey] = "scripted-volume"
    return await LocalFolderStorageProvider.make(
        location: location,
        rootURL: root,
        volumes: ScriptedVolumeInspector(),
        fetching: fetching,
        hashing: hashing,
        safetyInspector: safetyInspector,
        registry: registry
    )
}

#if canImport(Darwin)
private func makeBoundUnixSocket(at url: URL) throws -> Int32 {
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(url.path.utf8) + [0]
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else {
        close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return descriptor
}
#endif

private final class RecordingSpecialFileHasher: @unchecked Sendable, LocalFileHashing {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func hashFile(at _: URL, chunkSize _: Int) throws -> (hash: String, size: Int64) {
        lock.lock()
        calls += 1
        lock.unlock()
        return ("unexpected", 0)
    }
}

private final class RecordingSpecialFileFetcher: @unchecked Sendable, LocalFetchPerforming {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func copyItem(at _: URL, to _: URL) throws {
        lock.lock()
        calls += 1
        lock.unlock()
    }
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
            filesystemKind: .regularFile,
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
            filesystemKind: .directory,
            isPackage: package,
            posixMode: mode,
            ownerID: owner,
            groupID: group,
            hasAccessControlList: acl,
            extendedAttributeSizes: xattrs
        )
    }
}
