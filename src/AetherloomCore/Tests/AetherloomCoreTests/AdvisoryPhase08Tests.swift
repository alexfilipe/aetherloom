import AetherloomIntelligence
import Foundation
import Testing
@testable import AetherloomCore

@Test func phase08NilAdvisorAndStubAdvisorKeepPlanOutcomeByteIdentical() async throws {
    let fixture = phase08ConflictFixture()
    let nilStores = phase08Stores(records: [fixture.record])
    let stubStores = phase08Stores(records: [fixture.record])
    let nilOrchestrator = try phase08Orchestrator(syncSet: fixture.syncSet, snapshots: fixture.snapshots, stores: nilStores)
    let stub = StubAdvisor.canned(generatedAt: phase08Date)
    let stubOrchestrator = try phase08Orchestrator(syncSet: fixture.syncSet, snapshots: fixture.snapshots, stores: stubStores, advisor: stub)

    let withoutAdvisor = try await nilOrchestrator.prepare(fixture.syncSet)
    let withAdvisor = try await stubOrchestrator.prepare(fixture.syncSet)

    #expect(withoutAdvisor.outcome == withAdvisor.outcome)
}

@Test func phase08AdviceChangesPreviewAnnotationsOnly() async throws {
    let fixture = phase08ConflictFixture()
    let nilOrchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: phase08Stores(records: [fixture.record])
    )
    let stub = StubAdvisor.canned(generatedAt: phase08Date)
    let stubOrchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: phase08Stores(records: [fixture.record]),
        advisor: stub
    )

    let withoutAdvisor = try await nilOrchestrator.prepare(fixture.syncSet)
    let withAdvisor = try await stubOrchestrator.prepare(fixture.syncSet)
    var strippedPreview = withAdvisor.preview
    strippedPreview.advice = []

    #expect(strippedPreview == withoutAdvisor.preview)
    #expect(withAdvisor.advice == withAdvisor.preview.advice)
    #expect(withAdvisor.preview.advice.count == 1)
}

@Test func phase08ValidatorRejectsMalformedOptionsRationalesMarkdownAndNotes() {
    let request = phase08AdviceRequest()
    let validator = AdviceValidator()
    let descriptor = AdvisorDescriptor(name: "Bad Stub", backend: "stub")
    let validDate = phase08Date
    let wrongOption = ConflictAdvice(
        conflictID: request.conflict.id,
        recommended: .makeCanonical(.dropbox),
        confidence: .low,
        rationale: "Use this one.",
        generatedBy: descriptor,
        generatedAt: validDate
    )
    let longRationale = ConflictAdvice(
        conflictID: request.conflict.id,
        recommended: .keepBoth,
        confidence: .low,
        rationale: String(repeating: "a", count: 500),
        generatedBy: descriptor,
        generatedAt: validDate
    )
    let markdown = ConflictAdvice(
        conflictID: request.conflict.id,
        recommended: .keepBoth,
        confidence: .low,
        rationale: "See [winner](file).",
        generatedBy: descriptor,
        generatedAt: validDate
    )
    let badNote = ConflictAdvice(
        conflictID: request.conflict.id,
        recommended: .keepBoth,
        confidence: .low,
        rationale: "Keep both.",
        perVersionNotes: [.dropbox: "Not involved."],
        generatedBy: descriptor,
        generatedAt: validDate
    )

    #expect(validator.validate(wrongOption, for: request).rejection == .recommendedOptionUnavailable)
    #expect(validator.validate(longRationale, for: request).rejection == .rationaleTooLong)
    #expect(validator.validate(markdown, for: request).rejection == .disallowedRationaleContent)
    #expect(validator.validate(badNote, for: request).rejection == .noteForUninvolvedLocation)
}

@Test func phase08MalformedAdvisorOutputIsDiscardedAndLogged() async throws {
    let fixture = phase08ConflictFixture()
    let stores = phase08Stores(records: [fixture.record])
    let malformed = StubAdvisor { request, descriptor in
        ConflictAdvice(
            conflictID: request.conflict.id,
            recommended: .keepBoth,
            confidence: .low,
            rationale: "Use `this` one.",
            generatedBy: descriptor,
            generatedAt: phase08Date
        )
    }
    let orchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: stores,
        advisor: malformed
    )

    let preparation = try await orchestrator.prepare(fixture.syncSet)
    let advisoryEntries = await stores.activity.entries(matching: ActivityQuery(categories: [.advisory], limit: 10))

    #expect(preparation.advice.isEmpty)
    #expect(preparation.preview.advice.isEmpty)
    #expect(advisoryEntries.contains { entry in
        entry.message == ActivityMessageCatalog.adviceUnavailable
            && entry.detail == "validation.disallowedRationaleContent"
    })
}

@Test func phase08SlowAdvisorTimesOutWithoutBlockingPrepare() async throws {
    let fixture = phase08ConflictFixture()
    let stores = phase08Stores(records: [fixture.record])
    let orchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: stores,
        advisor: StubAdvisor.slow(),
        advisoryBudget: AdvisoryBudget(
            perConflictSeconds: 0,
            perPreparationSeconds: 10,
            timeoutMode: .immediateAfterYield
        )
    )

    let preparation = try await orchestrator.prepare(fixture.syncSet)
    let advisoryEntries = await stores.activity.entries(matching: ActivityQuery(categories: [.advisory], limit: 10))

    #expect(preparation.outcome.planValue?.gate.isClear == false)
    #expect(preparation.advice.isEmpty)
    #expect(advisoryEntries.contains { $0.detail == "timeout" })
}

@Test func phase08HeuristicIdenticalHashesKeepsBothWithHighConfidence() async throws {
    let request = phase08AdviceRequest(
        google: phase08Version(hash: "same", size: 0, modifiedAt: phase08Date.addingTimeInterval(200_000)),
        oneDrive: phase08Version(hash: "same", size: 99, modifiedAt: phase08Date)
    )
    let advice = try #require(await HeuristicConflictAdvisor(generatedAt: phase08Date).advise(on: request))

    #expect(advice.recommended == .keepBoth)
    #expect(advice.confidence == .high)
}

@Test func phase08HeuristicMtimeGapChoosesNewerWithMediumConfidence() async throws {
    let request = phase08AdviceRequest(
        google: phase08Version(hash: "google", size: 10, modifiedAt: phase08Date),
        oneDrive: phase08Version(hash: "onedrive", size: 10, modifiedAt: phase08Date.addingTimeInterval(25 * 60 * 60))
    )
    let advice = try #require(await HeuristicConflictAdvisor(generatedAt: phase08Date).advise(on: request))

    #expect(advice.recommended == .makeCanonical(.oneDrive))
    #expect(advice.confidence == .medium)
}

@Test func phase08HeuristicZeroByteChoosesNonEmptyWhenMtimeDoesNotDecide() async throws {
    let request = phase08AdviceRequest(
        google: phase08Version(hash: "empty", size: 0, modifiedAt: phase08Date),
        oneDrive: phase08Version(hash: "non-empty", size: 12, modifiedAt: phase08Date.addingTimeInterval(60))
    )
    let advice = try #require(await HeuristicConflictAdvisor(generatedAt: phase08Date).advise(on: request))

    #expect(advice.recommended == .makeCanonical(.oneDrive))
    #expect(advice.confidence == .medium)
}

@Test func phase08HeuristicRulePrecedenceUsesMtimeBeforeZeroByte() async throws {
    let request = phase08AdviceRequest(
        google: phase08Version(hash: "non-empty", size: 12, modifiedAt: phase08Date),
        oneDrive: phase08Version(hash: "empty-newer", size: 0, modifiedAt: phase08Date.addingTimeInterval(25 * 60 * 60))
    )
    let advice = try #require(await HeuristicConflictAdvisor(generatedAt: phase08Date).advise(on: request))

    #expect(advice.recommended == .makeCanonical(.oneDrive))
    #expect(advice.rationale.contains("24 hours"))
}

@Test func phase08AdviceCachePreventsRepeatedInference() async throws {
    let fixture = phase08ConflictFixture()
    let adviceCache = InMemoryAdviceCacheStore()
    let stub = StubAdvisor.canned(generatedAt: phase08Date)
    let firstStores = phase08Stores(records: [fixture.record], adviceCache: adviceCache)
    let secondStores = phase08Stores(records: [fixture.record], adviceCache: adviceCache)
    let first = try phase08Orchestrator(syncSet: fixture.syncSet, snapshots: fixture.snapshots, stores: firstStores, advisor: stub)
    let second = try phase08Orchestrator(syncSet: fixture.syncSet, snapshots: fixture.snapshots, stores: secondStores, advisor: stub)

    let firstPreparation = try await first.prepare(fixture.syncSet)
    let secondPreparation = try await second.prepare(fixture.syncSet)

    #expect(firstPreparation.advice.count == 1)
    #expect(secondPreparation.advice == firstPreparation.advice)
    #expect(await stub.adviceCalls() == 1)
}

@Test func phase08ConflictRequestsNeverPopulateContentExcerpts() async throws {
    let fixture = phase08ConflictFixture()
    let stub = StubAdvisor.canned(generatedAt: phase08Date)
    let orchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: phase08Stores(records: [fixture.record]),
        advisor: stub
    )

    _ = try await orchestrator.prepare(fixture.syncSet)
    let request = try #require(await stub.requests().first)

    #expect(request.contentExcerpts == nil)
}

@Test func phase08HoldTriageNotesAttachOnlyToMassChangeHolds() async throws {
    let fixture = phase08MassDeleteFixture()
    let stub = StubAdvisor(
        advice: { _, _ in nil },
        triage: { request, descriptor in
            HoldTriageNote(
                syncSetID: request.syncSetID,
                holdReason: request.holdReason,
                summary: "All changes are grouped under one folder and still require review.",
                generatedBy: descriptor,
                generatedAt: phase08Date
            )
        }
    )
    let orchestrator = try phase08Orchestrator(
        syncSet: fixture.syncSet,
        snapshots: fixture.snapshots,
        stores: phase08Stores(records: fixture.records),
        advisor: stub
    )

    let preparation = try await orchestrator.prepare(fixture.syncSet)
    let notes = preparation.preview.holds.compactMap(\.advisoryNote)

    #expect(preparation.preview.advice.isEmpty)
    #expect(notes.count == 1)
    #expect(notes.first?.holdReason.massChangeEvidence?.intentCount == 3)
    #expect(await stub.triageCalls() == 1)
}

@Test func phase08ConflictOptionsKeepBothFirstAndContentExcerptsDefaultNil() {
    let request = phase08AdviceRequest(options: [.makeCanonical(.oneDrive), .keepBoth, .makeCanonical(.googleDrive)])

    #expect(request.options == [.keepBoth, .makeCanonical(.oneDrive), .makeCanonical(.googleDrive)])
    #expect(request.contentExcerpts == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AETHERLOOM_ENABLE_MODEL_TESTS"] == "1"))
func phase08FoundationModelsBehavioralTestsAreOptIn() async throws {
    let request = phase08AdviceRequest()

    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let advisor = FoundationModelConflictAdvisor(generatedAt: { phase08Date })
        let advice = await advisor.advise(on: request)
        #expect(advice == nil || request.options.contains(advice?.recommended ?? .keepBoth))
    }
    #else
    #expect(request.options.first == .keepBoth)
    #endif
}

private struct Phase08ConflictFixture {
    var syncSet: SyncSet
    var record: BaseRecord
    var snapshots: [LocationSnapshot]
}

private struct Phase08MassDeleteFixture {
    var syncSet: SyncSet
    var records: [BaseRecord]
    var snapshots: [LocationSnapshot]
}

private func phase08ConflictFixture() -> Phase08ConflictFixture {
    let syncSet = phase08SyncSet([.googleDrive, .oneDrive])
    let path = SyncPath("/Conflict.txt")
    let googleBase = phase08Observation(.googleDrive, path: path, hash: "base", size: 4, modifiedAt: phase08Date, itemID: "google-conflict")
    let oneDriveBase = phase08Observation(.oneDrive, path: path, hash: "base", size: 4, modifiedAt: phase08Date, itemID: "onedrive-conflict")
    let record = phase08Record(syncSetID: syncSet.id, path: path, items: [.googleDrive: googleBase, .oneDrive: oneDriveBase])
    let googleCurrent = phase08Observation(.googleDrive, path: path, hash: "google-edit", size: 11, modifiedAt: phase08Date.addingTimeInterval(10), itemID: "google-conflict")
    let oneDriveCurrent = phase08Observation(.oneDrive, path: path, hash: "onedrive-edit", size: 13, modifiedAt: phase08Date.addingTimeInterval(20), itemID: "onedrive-conflict")
    return Phase08ConflictFixture(
        syncSet: syncSet,
        record: record,
        snapshots: [
            phase08Snapshot(.googleDrive, observations: [googleCurrent]),
            phase08Snapshot(.oneDrive, observations: [oneDriveCurrent])
        ]
    )
}

private func phase08MassDeleteFixture() -> Phase08MassDeleteFixture {
    let settings = SyncSettings(
        thresholds: SafetyThresholds(massDeleteAbsolute: 2, massDeleteRatio: 1, massEditAbsolute: 99, massEditRatio: 1)
    )
    let syncSet = phase08SyncSet([.googleDrive, .oneDrive], settings: settings)
    let observations = (1...3).map { index in
        phase08Observation(
            .oneDrive,
            path: SyncPath("/Photos/2019/\(index).jpg"),
            hash: "photo-\(index)",
            size: Int64(index),
            modifiedAt: phase08Date,
            itemID: "onedrive-photo-\(index)"
        )
    }
    let records = observations.map { oneDrive in
        let google = phase08Observation(
            .googleDrive,
            path: oneDrive.path,
            hash: oneDrive.version.contentHash ?? "",
            size: oneDrive.version.size ?? 0,
            modifiedAt: phase08Date,
            itemID: "google-\(oneDrive.path.name)"
        )
        return phase08Record(syncSetID: syncSet.id, path: oneDrive.path, items: [.googleDrive: google, .oneDrive: oneDrive])
    }
    return Phase08MassDeleteFixture(
        syncSet: syncSet,
        records: records,
        snapshots: [
            phase08Snapshot(.googleDrive, observations: []),
            phase08Snapshot(.oneDrive, observations: observations)
        ]
    )
}

private func phase08AdviceRequest(
    google: ItemVersion = phase08Version(hash: "google", size: 8, modifiedAt: phase08Date),
    oneDrive: ItemVersion = phase08Version(hash: "onedrive", size: 9, modifiedAt: phase08Date.addingTimeInterval(60)),
    options: [ConflictResolutionOption]? = nil
) -> ConflictAdvisoryRequest {
    let conflict = ConflictDecision(
        id: phase08UUID("000000000301"),
        path: "/Conflict.txt",
        versions: [
            ConflictVersion(location: .googleDrive, observation: phase08Observation(.googleDrive, path: "/Conflict.txt", version: google, itemID: "google")),
            ConflictVersion(location: .oneDrive, observation: phase08Observation(.oneDrive, path: "/Conflict.txt", version: oneDrive, itemID: "onedrive"))
        ],
        message: ActivityMessageCatalog.conflictPreserved
    )
    return ConflictAdvisoryRequest(
        conflict: conflict,
        options: options,
        locationNames: [
            .googleDrive: "Google Drive",
            .oneDrive: "OneDrive"
        ],
        contentExcerpts: nil
    )
}

private func phase08Orchestrator(
    syncSet: SyncSet,
    snapshots: [LocationSnapshot],
    stores: EngineStores,
    advisor: (any ConflictAdvisor)? = nil,
    advisoryBudget: AdvisoryBudget = .default
) throws -> SyncOrchestrator {
    let idSequence = Phase08UUIDSequence(prefix: "80000000-0000-0000-0000")
    let providers = Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
        (snapshot.location, FixedSnapshotProvider(snapshot: snapshot) as any StorageProvider)
    })
    let locations = Dictionary(uniqueKeysWithValues: syncSet.locations.map { locationID in
        (
            locationID,
            SyncLocation(id: locationID, kind: locationID.defaultKind, displayName: locationID.displayName)
        )
    })
    return SyncOrchestrator(
        locations: locations,
        providers: providers,
        stores: stores,
        stage: ContentStage(rootDirectory: try phase08TemporaryDirectory("stage-\(idSequence.next().uuidString)"), byteLimit: 10_000_000),
        environment: EngineEnvironment(now: { phase08Date }, makeID: { idSequence.next() }),
        advisor: advisor,
        advisoryBudget: advisoryBudget
    )
}

private func phase08Stores(
    records: [BaseRecord] = [],
    adviceCache: InMemoryAdviceCacheStore = InMemoryAdviceCacheStore(),
    activity: InMemoryActivityStore = InMemoryActivityStore()
) -> EngineStores {
    EngineStores(
        baseRecords: InMemoryBaseRecordStore(records: records),
        journal: InMemoryRunJournalStore(),
        conflicts: InMemoryConflictStore(),
        adviceCache: adviceCache,
        activity: activity,
        locations: InMemoryLocationRegistry()
    )
}

private func phase08SyncSet(
    _ locations: [LocationID],
    settings: SyncSettings = SyncSettings()
) -> SyncSet {
    SyncSet(
        id: phase08UUID("000000000001"),
        name: "Documents",
        locations: locations,
        settings: settings,
        createdAt: phase08Date,
        updatedAt: phase08Date
    )
}

private func phase08Record(syncSetID: UUID, path: SyncPath, items: [LocationID: ItemObservation]) -> BaseRecord {
    let baseline = items.values.sorted { $0.location < $1.location }.first
    return BaseRecord(
        syncSetID: syncSetID,
        path: path,
        kind: .file,
        version: baseline?.version ?? phase08Version(hash: "base", size: 0, modifiedAt: phase08Date),
        perLocation: Dictionary(uniqueKeysWithValues: items.map { location, item in
            (
                location,
                LocationMemory(
                    itemID: item.itemID,
                    revisionToken: item.version.revisionToken,
                    lastSeenAt: phase08Date
                )
            )
        }),
        lastConvergedAt: phase08Date,
        createdAt: phase08Date,
        updatedAt: phase08Date
    )
}

private func phase08Snapshot(_ location: LocationID, observations: [ItemObservation]) -> LocationSnapshot {
    LocationSnapshot(
        location: location,
        scope: .entireDrive,
        observations: observations,
        scannedAt: phase08Date
    )
}

private func phase08Observation(
    _ location: LocationID,
    path: SyncPath,
    hash: String,
    size: Int64,
    modifiedAt: Date,
    itemID: String
) -> ItemObservation {
    phase08Observation(
        location,
        path: path,
        version: phase08Version(hash: hash, size: size, modifiedAt: modifiedAt),
        itemID: itemID
    )
}

private func phase08Observation(
    _ location: LocationID,
    path: SyncPath,
    version: ItemVersion,
    itemID: String
) -> ItemObservation {
    ItemObservation(
        location: location,
        itemID: itemID,
        path: path,
        kind: .file,
        version: version
    )
}

private func phase08Version(hash: String, size: Int64, modifiedAt: Date) -> ItemVersion {
    ItemVersion(contentHash: hash, size: size, modifiedAt: modifiedAt, revisionToken: "rev-\(hash)")
}

private func phase08TemporaryDirectory(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomPhase08Tests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func phase08UUID(_ suffix: String) -> UUID {
    UUID(uuidString: "80000000-0000-0000-0000-\(suffix)")!
}

private let phase08Date = Date(timeIntervalSince1970: 1_780_000_000)

private final class Phase08UUIDSequence: @unchecked Sendable {
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

private actor FixedSnapshotProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities = ProviderCapabilities.fullFidelity

    private let snapshot: LocationSnapshot

    init(snapshot: LocationSnapshot) {
        self.snapshot = snapshot
        self.locationID = snapshot.location
    }

    func checkAvailability() async -> LocationAvailability {
        .available
    }

    func scan(_: SyncScope) async -> LocationSnapshot {
        snapshot
    }

    func changedSubtrees(in _: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        ChangeHint(changedRoots: snapshot.observations.all.map(\.path), nextCursor: cursor)
    }

    func fetch(_: ItemObservation, to _: URL) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "FixedSnapshotProvider is read-only.")
    }

    func store(from _: URL, at path: SyncPath, options _: StoreOptions) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: "Cannot store \(path.rawValue).")
    }

    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: "Cannot make folder \(path.rawValue).")
    }

    func relocate(_ observation: ItemObservation, to _: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: "Cannot relocate \(observation.path.rawValue).")
    }

    func trash(_ observation: ItemObservation) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "Cannot trash \(observation.path.rawValue).")
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        guard let current = snapshot.observations.byPath[observation.path] else {
            throw ProviderError.notFound(provider: locationID, path: observation.path)
        }
        return current
    }
}
