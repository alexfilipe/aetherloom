import Foundation
import Testing
@testable import AetherloomCore

@Test
func localSyncEndToEnd_fakeBaselineIndependentEditsResolveAndConverge() async throws {
    let world = try TestTemporaryDirectory.make(
        suite: "AetherloomLocalSyncEndToEndTests",
        name: "fake-conflict-baseline"
    )
    defer { try? FileManager.default.removeItem(at: world) }

    let locationA = SyncLocation(
        id: localE2ELocationA,
        kind: .localFolder,
        displayName: "Folder A"
    )
    let locationB = SyncLocation(
        id: localE2ELocationB,
        kind: .localFolder,
        displayName: "Folder B"
    )
    let providerA = FakeStorageProvider(location: locationA)
    let providerB = FakeStorageProvider(location: locationB)
    let providers = [
        locationA.id: providerA,
        locationB.id: providerB,
    ]
    let stores = EngineStores.inMemory()
    let syncSet = SyncSet(
        id: localE2EUUID("000000000001"),
        name: "Local conflict baseline",
        locations: [locationA.id, locationB.id],
        createdAt: localE2EDate,
        updatedAt: localE2EDate
    )
    let ids = LocalE2EUUIDSequence(prefix: "e4000000-0000-0000-0000")
    let orchestrator = SyncOrchestrator(
        locations: [
            locationA.id: locationA,
            locationB.id: locationB,
        ],
        providers: [
            locationA.id: providerA,
            locationB.id: providerB,
        ],
        stores: stores,
        stage: ContentStage(
            rootDirectory: world.appendingPathComponent("stage", isDirectory: true),
            byteLimit: 10_000_000
        ),
        environment: EngineEnvironment(
            now: { localE2EDate },
            makeID: { ids.next() }
        )
    )

    let original = Data("original workbook".utf8)
    await providerA.putFile(
        path: "/Budget.xlsx",
        contents: original,
        modifiedAt: localE2EDate
    )
    let baselinePreparation = try await orchestrator.prepare(syncSet)
    let baselineSummary = try await orchestrator.execute(baselinePreparation)
    #expect(baselineSummary.outcome == .completed)
    #expect(await providerB.item(at: "/Budget.xlsx") != nil)

    let convergedBaseline = try await orchestrator.prepare(syncSet)
    #expect(convergedBaseline.outcome.planValue?.decisions.isEmpty == true)

    let editA = Data("Folder A independent workbook edit".utf8)
    let editB = Data("Folder B made a different workbook edit".utf8)
    await providerA.putFile(
        path: "/Budget.xlsx",
        contents: editA,
        modifiedAt: localE2EDate.addingTimeInterval(10)
    )
    await providerB.putFile(
        path: "/Budget.xlsx",
        contents: editB,
        modifiedAt: localE2EDate.addingTimeInterval(20)
    )

    let conflictPreparation = try await orchestrator.prepare(syncSet)
    let conflictPlan = try #require(conflictPreparation.outcome.planValue)
    let conflict = try #require(conflictPlan.conflicts.first)
    #expect(conflictPlan.conflicts.count == 1)
    #expect(conflict.kind == .editEdit)
    #expect(conflict.path == "/Budget.xlsx")

    let conflictCopies = conflictPlan.schedule.operations.compactMap {
        operation -> (destination: LocationID, path: SyncPath)? in
        guard case let .transfer(content, path, overwrite) = operation.kind,
              overwrite == .neverOverwrite,
              path != content.path else {
            return nil
        }
        return (operation.location, path)
    }
    #expect(conflictCopies.count == 2)
    #expect(conflictCopies.allSatisfy { $0.path.pathExtension == "xlsx" })

    let conflictSummary = try await orchestrator.execute(
        conflictPreparation,
        approval: localE2EApproval(for: conflictPlan)
    )
    #expect(conflictSummary.outcome == .completed)

    var preservedContents: Set<Data> = []
    for (index, copy) in conflictCopies.enumerated() {
        let provider = try #require(providers[copy.destination])
        let observation = try #require(await provider.item(at: copy.path))
        let fetchURL = world.appendingPathComponent(
            "preserved-\(index).xlsx",
            isDirectory: false
        )
        try await provider.fetch(observation, to: fetchURL)
        preservedContents.insert(try Data(contentsOf: fetchURL))
    }
    #expect(preservedContents == Set([editA, editB]))
    #expect(await providerA.item(at: "/Budget.xlsx") != nil)
    #expect(await providerB.item(at: "/Budget.xlsx") != nil)

    try await stores.conflicts.resolve(
        conflict.id,
        as: .makeCanonical(locationA.id),
        at: localE2EDate
    )

    let resolutionPreparation = try await orchestrator.prepare(syncSet)
    let resolutionPlan = try #require(resolutionPreparation.outcome.planValue)
    #expect(!resolutionPlan.conflicts.contains { candidate in
        candidate.id == conflict.id
            || (candidate.kind == conflict.kind && candidate.path == conflict.path)
    })
    #expect(resolutionPlan.gate.isClear)

    let resolutionSummary = try await orchestrator.execute(resolutionPreparation)
    #expect(resolutionSummary.outcome == .completed)

    let finalPreparation = try await orchestrator.prepare(syncSet)
    let finalPlan = try #require(finalPreparation.outcome.planValue)
    #expect(finalPlan.decisions.isEmpty)
    #expect(finalPreparation.preview.headline == "0 changes ready to sync")
}

private func localE2EApproval(for plan: SyncPlan) -> PlanApproval {
    PlanApproval(
        planFingerprint: plan.fingerprint,
        approvedAt: localE2EDate,
        acknowledgedTrashCount: plan.approvalTrashCount,
        acknowledgedConflictCount: plan.approvalConflictCount
    )
}

private func localE2EUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "e4000000-0000-0000-0000-\(suffix)")!
}

private let localE2ELocationA = LocationID(
    rawValue: localE2EUUID("00000000000a")
)
private let localE2ELocationB = LocationID(
    rawValue: localE2EUUID("00000000000b")
)
private let localE2EDate = Date(timeIntervalSince1970: 1_780_000_000)

private final class LocalE2EUUIDSequence: @unchecked Sendable {
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
        return UUID(
            uuidString: "\(prefix)-\(String(format: "%012d", value))"
        )!
    }
}
