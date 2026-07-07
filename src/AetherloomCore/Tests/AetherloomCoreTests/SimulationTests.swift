import Foundation
import Testing
@testable import AetherloomCore

@Test(.timeLimit(.minutes(1)))
func seededSimulation_prepareExecutePreservesConvergesAndRefusesSafely() async throws {
    for seed in simulationDefaultSeeds {
        try await runSimulation(seed: seed)
    }
}

@Test func simulationRegression_flakyMidRunFailureStopsForReplanWithoutTrash() async throws {
    let syncSet = simulationSyncSet([.googleDrive, .oneDrive])
    let stores = EngineStores.inMemory()
    let google = FakeStorageProvider(locationID: .googleDrive)
    let oneDriveBase = FakeStorageProvider(locationID: .oneDrive)
    let googleItem = await google.putFile(path: "/Flaky.txt", contents: simulationData("base"), modifiedAt: simulationDate)
    let oneDriveItem = await oneDriveBase.putFile(path: "/Flaky.txt", contents: simulationData("base"), modifiedAt: simulationDate)
    try await stores.baseRecords.apply(.upsert(simulationRecord(syncSetID: syncSet.id, path: "/Flaky.txt", items: [.googleDrive: googleItem, .oneDrive: oneDriveItem])))
    await google.putFile(path: "/Flaky.txt", contents: simulationData("new"), modifiedAt: simulationDate.addingTimeInterval(1))
    let flaky = FlakyStorageProvider(wrapping: oneDriveBase)
    await flaky.mutateBeforeNext(.currentState) {
        await oneDriveBase.putFile(path: "/Flaky.txt", contents: simulationData("surprise"), modifiedAt: simulationDate.addingTimeInterval(2))
    }
    let orchestrator = try simulationOrchestrator(
        syncSet: syncSet,
        providers: [.googleDrive: google, .oneDrive: flaky],
        stores: stores,
        seed: 0xfeed
    )

    let preparation = try await orchestrator.prepare(syncSet)
    let summary = try await orchestrator.execute(preparation)

    #expect(summary.outcome == .stoppedForReplan(location: .oneDrive, path: "/Flaky.txt"))
    #expect(summary.appliedOperations.isEmpty)
    #expect(await oneDriveBase.item(at: "/Flaky.txt", includeTrashed: true)?.isTrashed == false)
}

@Test(.timeLimit(.minutes(1)))
func performanceSmoke_reconcileAndPlanTenThousandItemsThreeLocations() {
    let syncSet = simulationSyncSet([.googleDrive, .oneDrive, .localFolder])
    var records: [BaseRecord] = []
    var snapshots: [LocationSnapshot] = []
    var observationsByLocation: [LocationID: [ItemObservation]] = [
        .googleDrive: [],
        .oneDrive: [],
        .localFolder: []
    ]

    for index in 0..<10_000 {
        let path = SyncPath("/Bulk/Item-\(index).txt")
        var items: [LocationID: ItemObservation] = [:]
        for location in syncSet.locations {
            let observation = ItemObservation(
                location: location,
                itemID: "\(location.rawValue.uuidString):\(index)",
                path: path,
                kind: .file,
                version: ItemVersion(contentHash: "hash-\(index)", size: Int64(index), modifiedAt: simulationDate, revisionToken: "rev-\(index)")
            )
            observationsByLocation[location, default: []].append(observation)
            items[location] = observation
        }
        records.append(simulationRecord(syncSetID: syncSet.id, path: path, items: items))
    }

    for location in syncSet.locations {
        snapshots.append(LocationSnapshot(location: location, scope: .entireDrive, observations: observationsByLocation[location] ?? [], scannedAt: simulationDate))
    }

    let startedAt = Date()
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(syncSet: syncSet, records: records, snapshots: snapshots),
        environment: PlanningEnvironment(now: simulationDate)
    )

    #expect(outcome.planValue?.decisions.isEmpty == true)
    #expect(Date().timeIntervalSince(startedAt) < 7)
}

private let simulationDefaultSeeds: [UInt64] = (1...500).map { 0x09_0000 + UInt64($0) }

private func runSimulation(seed: UInt64) async throws {
    var rng = SeededRandom(seed: seed)
    let locations = Array([LocationID.googleDrive, .oneDrive, .localFolder, .nasFolder].prefix(2 + rng.int(upperBound: 3)))
    let syncSet = simulationSyncSet(locations)
    let stores = EngineStores.inMemory()
    let providers = Dictionary(uniqueKeysWithValues: locations.map { ($0, FakeStorageProvider(locationID: $0)) })
    let orchestrator = try simulationOrchestrator(syncSet: syncSet, providers: providers, stores: stores, seed: seed)
    let source = locations[rng.int(upperBound: locations.count)]
    let primaryPath = SyncPath("/Sim-\(seed).txt")
    await providers[source]?.putFile(path: primaryPath, contents: simulationData("seed-\(seed)-base"), modifiedAt: simulationDate)

    var knownContent = await simulationContentSet(providers.values.map { $0 })
    try await simulationRunToFixedPoint(orchestrator: orchestrator, syncSet: syncSet, stores: stores, providers: providers.values.map { $0 })
    try await simulationAssertConverged(providers.values.map { $0 })
    #expect(await simulationContentSet(providers.values.map { $0 }).isSuperset(of: knownContent))

    knownContent = await simulationContentSet(providers.values.map { $0 })
    let mutationSource = locations[rng.int(upperBound: locations.count)]
    let mutationKind = rng.int(upperBound: 7)
    switch mutationKind {
    case 0:
        await providers[mutationSource]?.putFile(path: primaryPath, contents: simulationData("seed-\(seed)-edit"), modifiedAt: simulationDate.addingTimeInterval(Double(seed % 1000 + 1)))
    case 1:
        if let item = await providers[mutationSource]?.item(at: primaryPath) {
            _ = try await providers[mutationSource]?.relocate(item, to: SyncPath("/Renamed-\(seed).txt"))
        }
    case 2:
        if let item = await providers[mutationSource]?.item(at: primaryPath) {
            _ = try await providers[mutationSource]?.relocate(item, to: SyncPath("/Moved/\(seed)/Sim.txt"))
        }
    case 3:
        await providers[mutationSource]?.remove(path: primaryPath)
    case 4:
        if let item = await providers[mutationSource]?.item(at: primaryPath) {
            _ = try await providers[mutationSource]?.relocate(item, to: SyncPath("/SIM-\(seed).TXT"))
        }
    case 5:
        await providers[mutationSource]?.putFolder(path: SyncPath("/Folder-\(seed)"), modifiedAt: simulationDate)
    default:
        await providers[mutationSource]?.putFile(path: SyncPath("/Created-\(seed).txt"), contents: simulationData("seed-\(seed)-new"), modifiedAt: simulationDate)
    }

    try await simulationRunToFixedPoint(orchestrator: orchestrator, syncSet: syncSet, stores: stores, providers: providers.values.map { $0 })
    let afterMutationContent = await simulationContentSet(providers.values.map { $0 })
    if mutationKind != 0 {
        #expect(afterMutationContent.isSuperset(of: knownContent))
    }
    try await simulationAssertConverged(providers.values.map { $0 })

    let beforeFailure = await simulationTreeAndTrash(providers.values.map { $0 })
    for provider in providers.values {
        await provider.clearCallLog()
    }
    let failing = locations[rng.int(upperBound: locations.count)]
    if rng.bool() {
        await providers[failing]?.setAvailability(.unavailable(.volumeUnreachable(detail: "Seed \(seed) simulated outage.")))
    } else {
        await providers[failing]?.setIncompleteScan(reason: "Seed \(seed) incomplete scan.")
    }
    let refusalPreparation = try await orchestrator.prepare(syncSet)
    #expect(refusalPreparation.outcome.refusalValue != nil)
    let afterFailure = await simulationTreeAndTrash(providers.values.map { $0 })
    let mutationCalls = await providers.values.asyncFlatMap { provider in
        await provider.callLog().filter { [.store, .makeFolder, .relocate, .trash].contains($0.operation) }
    }
    #expect(beforeFailure == afterFailure)
    #expect(mutationCalls.isEmpty)
}

private func simulationRunToFixedPoint(
    orchestrator: SyncOrchestrator,
    syncSet: SyncSet,
    stores: EngineStores,
    providers: [FakeStorageProvider]
) async throws {
    for run in 0..<2 {
        let preparation = try await orchestrator.prepare(syncSet)
        if let refusal = preparation.outcome.refusalValue {
            Issue.record("Unexpected refusal during healthy simulation run \(run): \(refusal.reasons)")
            return
        }
        let plan = try #require(preparation.outcome.planValue)
        guard !plan.decisions.isEmpty else { return }
        let approval = plan.gate.isClear ? nil : simulationApproval(for: plan)
        if !plan.gate.isClear {
            #expect(plan.gate.holdReasons.allSatisfy { reason in
                switch reason {
                case .conflicts, .deletionsNeedReview:
                    return true
                case let .massDeletion(evidence), let .massEdit(evidence):
                    return evidence.intentCount > 0
                }
            })
        }
        let summary = try await orchestrator.execute(preparation, approval: approval)
        #expect(summary.outcome == .completed || summary.outcome == .held)
        if summary.outcome == .held {
            Issue.record("Simulation generated a held run without approval.")
            return
        }
        _ = try await stores.baseRecords.records(for: syncSet.id)
        _ = providers
    }
    let finalPreparation = try await orchestrator.prepare(syncSet)
    #expect(finalPreparation.outcome.planValue?.decisions.isEmpty == true)
}

private func simulationApproval(for plan: SyncPlan) -> PlanApproval {
    PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: simulationDate,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
}

private func simulationAssertConverged(_ providers: [FakeStorageProvider]) async throws {
    let trees = await providers.asyncMap { provider in
        await simulationActiveTree(provider)
    }
    guard let first = trees.first else { return }
    for tree in trees.dropFirst() {
        #expect(tree == first)
    }
}

private func simulationActiveTree(_ provider: FakeStorageProvider) async -> Set<String> {
    Set(await provider.allItems().map { item in
        "\(item.kind.simulationKey)|\(item.path.rawValue)|\(item.version.contentHash ?? item.version.revisionToken ?? "")"
    })
}

private func simulationTreeAndTrash(_ providers: [FakeStorageProvider]) async -> Set<String> {
    await providers.asyncReduce(into: Set<String>()) { result, provider in
        let items = await provider.allItems(includeTrashed: true)
        for item in items {
            result.insert("\(provider.locationID.rawValue.uuidString)|\(item.isTrashed)|\(item.path.rawValue)|\(item.version.contentHash ?? item.version.revisionToken ?? "")")
        }
    }
}

private func simulationContentSet(_ providers: [FakeStorageProvider]) async -> Set<String> {
    await providers.asyncReduce(into: Set<String>()) { result, provider in
        let items = await provider.allItems(includeTrashed: true)
        for item in items where item.kind == .file {
            if let hash = item.version.contentHash {
                result.insert(hash)
            }
        }
    }
}

private func simulationOrchestrator(
    syncSet: SyncSet,
    providers: [LocationID: any StorageProvider],
    stores: EngineStores,
    seed: UInt64
) throws -> SyncOrchestrator {
    let sequence = SimulationUUIDSequence(prefix: "94000000-0000-0000-0000", start: Int(seed % 100_000) + 1)
    let locations = Dictionary(uniqueKeysWithValues: syncSet.locations.map { locationID in
        (locationID, SyncLocation(id: locationID, kind: locationID.defaultKind, displayName: locationID.displayName))
    })
    return SyncOrchestrator(
        locations: locations,
        providers: providers,
        stores: stores,
        stage: ContentStage(rootDirectory: try simulationTemporaryDirectory("stage-\(seed)"), byteLimit: 20_000_000),
        environment: EngineEnvironment(now: { simulationDate }, makeID: { sequence.next() })
    )
}

private func simulationSyncSet(_ locations: [LocationID]) -> SyncSet {
    SyncSet(
        id: simulationUUID("000000000001"),
        name: "Simulation",
        locations: locations,
        createdAt: simulationDate,
        updatedAt: simulationDate
    )
}

private func simulationRecord(syncSetID: UUID, path: SyncPath, items: [LocationID: ItemObservation]) -> BaseRecord {
    let baseline = items.values.sorted { $0.location < $1.location }.first
    return BaseRecord(
        syncSetID: syncSetID,
        path: path,
        kind: baseline?.kind ?? .file,
        version: baseline?.version ?? ItemVersion(),
        perLocation: Dictionary(uniqueKeysWithValues: items.map { location, item in
            (location, LocationMemory(itemID: item.itemID, revisionToken: item.version.revisionToken, lastSeenAt: simulationDate))
        }),
        lastConvergedAt: simulationDate,
        createdAt: simulationDate,
        updatedAt: simulationDate
    )
}

private func simulationTemporaryDirectory(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomSimulationTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func simulationUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "94000000-0000-0000-0000-\(suffix)")!
}

private func simulationData(_ string: String) -> Data {
    Data(string.utf8)
}

private let simulationDate = Date(timeIntervalSince1970: 1_770_000_000)

private final class SimulationUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var counter: Int

    init(prefix: String, start: Int) {
        self.prefix = prefix
        self.counter = start
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter += 1
        return UUID(uuidString: "\(prefix)-\(String(format: "%012d", value))")!
    }
}

private extension ItemKind {
    var simulationKey: String {
        switch self {
        case .file:
            return "file"
        case .folder:
            return "folder"
        case let .symlink(target):
            return "symlink:\(target)"
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(await transform(element))
        }
        return result
    }

    func asyncFlatMap<T>(_ transform: (Element) async -> [T]) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(contentsOf: await transform(element))
        }
        return result
    }

    func asyncReduce<Result>(
        into initialResult: Result,
        _ updateAccumulatingResult: (inout Result, Element) async -> Void
    ) async -> Result {
        var result = initialResult
        for element in self {
            await updateAccumulatingResult(&result, element)
        }
        return result
    }
}
