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

@Suite("Real local-to-local sync acceptance")
struct RealLocalSyncEndToEndTests {
    @Test func createEditAndFolderPropagationRunsBothDirections() async throws {
        let world = try await LocalRealE2EWorld.make(name: "create-edit-folders")
        defer { try? FileManager.default.removeItem(at: world.root) }

        try localRealE2EWrite(
            Data("created in A".utf8),
            to: "/From A.txt",
            under: world.rootA
        )
        try localRealE2EWrite(
            Data("nested in A".utf8),
            to: "/Folder A/Nested.txt",
            under: world.rootA
        )
        try localRealE2EMakeFolder("/Empty A", under: world.rootA)

        try await world.executeClearPlan()

        #expect(try localRealE2ERead("/From A.txt", under: world.rootB) == Data("created in A".utf8))
        #expect(try localRealE2ERead("/Folder A/Nested.txt", under: world.rootB) == Data("nested in A".utf8))
        #expect(localRealE2EIsDirectory("/Empty A", under: world.rootB))

        try localRealE2EWrite(
            Data("edited in B".utf8),
            to: "/From A.txt",
            under: world.rootB,
            modifiedAt: localE2EDate.addingTimeInterval(10)
        )
        try localRealE2EWrite(
            Data("nested in B".utf8),
            to: "/Folder B/Nested.txt",
            under: world.rootB
        )
        try localRealE2EMakeFolder("/Empty B", under: world.rootB)

        try await world.executeClearPlan()

        #expect(try localRealE2ERead("/From A.txt", under: world.rootA) == Data("edited in B".utf8))
        #expect(try localRealE2ERead("/Folder B/Nested.txt", under: world.rootA) == Data("nested in B".utf8))
        #expect(localRealE2EIsDirectory("/Empty B", under: world.rootA))
        #expect(try await world.stores.baseRecords.records(for: world.syncSet.id).count >= 7)
        #expect(await world.stores.activity.entries(matching: ActivityQuery(limit: 100)).isEmpty == false)
        #expect(try await world.stores.journal.unfinishedRun(for: world.syncSet.id) == nil)
        try await world.expectEmptyPreview()
    }

    @Test func renameAndMoveDegradeToCreatePlusRecoverableTrash() async throws {
        let world = try await LocalRealE2EWorld.make(name: "rename-move")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let renamedContents = Data("rename bytes".utf8)
        let movedContents = Data("move bytes".utf8)
        try localRealE2EWrite(renamedContents, to: "/Original.txt", under: world.rootA)
        try localRealE2EWrite(movedContents, to: "/Source/Move.txt", under: world.rootA)
        try await world.executeClearPlan()
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()

        try FileManager.default.moveItem(
            at: localRealE2EURL("/Original.txt", under: world.rootA),
            to: localRealE2EURL("/Renamed.txt", under: world.rootA)
        )
        try localRealE2EMakeFolder("/Destination", under: world.rootA)
        try FileManager.default.moveItem(
            at: localRealE2EURL("/Source/Move.txt", under: world.rootA),
            to: localRealE2EURL("/Destination/Move.txt", under: world.rootA)
        )

        let plan = try await world.executeClearPlan()

        #expect(plan.decisions.contains { $0.path == "/Original.txt" })
        #expect(plan.decisions.contains { $0.path == "/Renamed.txt" })
        #expect(plan.decisions.contains { $0.path == "/Source/Move.txt" })
        #expect(plan.decisions.contains { $0.path == "/Destination/Move.txt" })
        #expect(try localRealE2ERead("/Renamed.txt", under: world.rootB) == renamedContents)
        #expect(try localRealE2ERead("/Destination/Move.txt", under: world.rootB) == movedContents)
        #expect(!FileManager.default.fileExists(atPath: localRealE2EURL("/Original.txt", under: world.rootB).path))
        #expect(!FileManager.default.fileExists(atPath: localRealE2EURL("/Source/Move.txt", under: world.rootB).path))
        let destinationCalls = await world.providerB.mutationCalls()
        #expect(destinationCalls.contains(.store("/Renamed.txt")))
        #expect(destinationCalls.contains(.store("/Destination/Move.txt")))
        #expect(destinationCalls.contains(.trash("/Original.txt")))
        #expect(destinationCalls.contains(.trash("/Source/Move.txt")))

        let renamedRecovery = try #require(
            await world.localProviderB.recoveryURL(for: "/Original.txt")
        )
        let movedRecovery = try #require(
            await world.localProviderB.recoveryURL(for: "/Source/Move.txt")
        )
        #expect(try Data(contentsOf: renamedRecovery) == renamedContents)
        #expect(try Data(contentsOf: movedRecovery) == movedContents)
        try await world.expectEmptyPreview()
    }

    @Test func deletePropagationMovesDestinationToRecoverableTrash() async throws {
        let world = try await LocalRealE2EWorld.make(name: "delete-trash")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let contents = Data("recover this deletion".utf8)
        try localRealE2EWrite(contents, to: "/Recoverable.txt", under: world.rootA)
        try await world.executeClearPlan()
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()

        try FileManager.default.removeItem(
            at: localRealE2EURL("/Recoverable.txt", under: world.rootA)
        )
        try await world.executeClearPlan()

        #expect(!FileManager.default.fileExists(atPath: localRealE2EURL("/Recoverable.txt", under: world.rootB).path))
        #expect(await world.providerA.mutationCalls().isEmpty)
        #expect(await world.providerB.mutationCalls() == [.trash("/Recoverable.txt")])
        let recoveryURL = try #require(
            await world.localProviderB.recoveryURL(for: "/Recoverable.txt")
        )
        #expect(try Data(contentsOf: recoveryURL) == contents)
        try await world.expectEmptyPreview()
    }

    @Test func independentEditsPreserveBothVersionsThenResolveAndConverge() async throws {
        let world = try await LocalRealE2EWorld.make(name: "conflict-resolution")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try localRealE2EWrite(
            Data("original workbook".utf8),
            to: "/Budget.xlsx",
            under: world.rootA
        )
        try await world.executeClearPlan()

        let editA = Data("Folder A independent workbook edit".utf8)
        let editB = Data("Folder B independent workbook edit".utf8)
        try localRealE2EWrite(
            editA,
            to: "/Budget.xlsx",
            under: world.rootA,
            modifiedAt: localE2EDate.addingTimeInterval(10)
        )
        try localRealE2EWrite(
            editB,
            to: "/Budget.xlsx",
            under: world.rootB,
            modifiedAt: localE2EDate.addingTimeInterval(20)
        )

        let preparation = try await world.orchestrator.prepare(world.syncSet)
        let plan = try #require(preparation.outcome.planValue)
        let conflict = try #require(plan.conflicts.first)
        #expect(plan.conflicts.count == 1)
        #expect(conflict.kind == .editEdit)
        #expect(conflict.path == "/Budget.xlsx")
        let conflictCopies = plan.schedule.operations.compactMap {
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

        let summary = try await world.orchestrator.execute(
            preparation,
            approval: localE2EApproval(for: plan)
        )
        #expect(summary.outcome == .completed)

        let preserved = try Set(conflictCopies.map { copy in
            try localRealE2ERead(
                copy.path,
                under: copy.destination == world.locationA.id ? world.rootA : world.rootB
            )
        })
        #expect(preserved == Set([editA, editB]))
        #expect(try localRealE2ERead("/Budget.xlsx", under: world.rootA) == editA)
        #expect(try localRealE2ERead("/Budget.xlsx", under: world.rootB) == editB)

        try await world.stores.conflicts.resolve(
            conflict.id,
            as: .makeCanonical(world.locationA.id),
            at: localE2EDate
        )
        let resolutionPreparation = try await world.orchestrator.prepare(world.syncSet)
        let resolutionPlan = try #require(resolutionPreparation.outcome.planValue)
        #expect(resolutionPlan.gate.isClear)
        #expect(!resolutionPlan.conflicts.contains { candidate in
            candidate.id == conflict.id
                || (candidate.kind == conflict.kind && candidate.path == conflict.path)
        })
        let resolutionSummary = try await world.orchestrator.execute(resolutionPreparation)
        #expect(resolutionSummary.outcome == .completed)
        #expect(try localRealE2ERead("/Budget.xlsx", under: world.rootA) == editA)
        #expect(try localRealE2ERead("/Budget.xlsx", under: world.rootB) == editA)
        try await world.expectEmptyPreview()
    }

    @Test func massDeleteHoldPerformsNoProviderMutationBeforeApproval() async throws {
        let settings = SyncSettings(
            thresholds: SafetyThresholds(
                massDeleteAbsolute: 2,
                massDeleteRatio: 1,
                massEditAbsolute: 99,
                massEditRatio: 1
            )
        )
        let world = try await LocalRealE2EWorld.make(
            name: "mass-delete-hold",
            settings: settings
        )
        defer { try? FileManager.default.removeItem(at: world.root) }
        let paths: [SyncPath] = ["/Bulk/One.txt", "/Bulk/Two.txt", "/Bulk/Three.txt"]
        for path in paths {
            try localRealE2EWrite(Data(path.name.utf8), to: path, under: world.rootA)
        }
        try await world.executeClearPlan()
        for path in paths {
            try FileManager.default.removeItem(at: localRealE2EURL(path, under: world.rootA))
        }
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()
        let beforeB = try localRealE2ETree(at: world.rootB)

        let preparation = try await world.orchestrator.prepare(world.syncSet)
        let plan = try #require(preparation.outcome.planValue)
        #expect(plan.gate.holdReasons.contains { reason in
            if case let .massDeletion(evidence) = reason {
                return evidence.intentCount == paths.count
            }
            return false
        })
        let held = try await world.orchestrator.execute(preparation)

        #expect(held.outcome == .held)
        #expect(await world.providerA.mutationCalls().isEmpty)
        #expect(await world.providerB.mutationCalls().isEmpty)
        #expect(try localRealE2ETree(at: world.rootB) == beforeB)
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: localRealE2EURL(path, under: world.rootB).path))
        }

        let approved = try await world.orchestrator.execute(
            preparation,
            approval: localE2EApproval(for: plan)
        )
        #expect(approved.outcome == .completed)
        for path in paths {
            #expect(!FileManager.default.fileExists(atPath: localRealE2EURL(path, under: world.rootB).path))
            let recoveryURL = try #require(
                await world.localProviderB.recoveryURL(for: path)
            )
            #expect(try Data(contentsOf: recoveryURL) == Data(path.name.utf8))
        }
    }

    @Test func unavailableVolumeRefusesWithCanonicalLanguageAndNoMutations() async throws {
        let world = try await LocalRealE2EWorld.make(name: "unavailable")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try localRealE2EWrite(Data("do not sync".utf8), to: "/Waiting.txt", under: world.rootA)
        await world.inspectorB.setMountState(.notMounted(detail: "Test volume unplugged."))
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()
        let beforeA = try localRealE2ETree(at: world.rootA)
        let beforeB = try localRealE2ETree(at: world.rootB)

        let preparation = try await world.orchestrator.prepare(world.syncSet)
        let refusal = try #require(preparation.outcome.refusalValue)

        #expect(refusal.reasons.contains { reason in
            if case .locationUnavailable(world.locationB.id, .volumeNotMounted) = reason {
                return true
            }
            return false
        })
        #expect(preparation.preview.headline == "Paused for safety")
        #expect(preparation.preview.refusals.contains { refusal in
            refusal.message == ActivityMessageCatalog.providerUnavailable
        })
        #expect(
            ActivityMessageCatalog.providerUnavailable
                == "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable."
        )
        #expect(await world.providerA.mutationCalls().isEmpty)
        #expect(await world.providerB.mutationCalls().isEmpty)
        #expect(try localRealE2ETree(at: world.rootA) == beforeA)
        #expect(try localRealE2ETree(at: world.rootB) == beforeB)
    }

    @Test func destinationDriftStopsForReplanWithoutOverwrite() async throws {
        let world = try await LocalRealE2EWorld.make(name: "drift-abort")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try localRealE2EWrite(Data("base".utf8), to: "/Drift.txt", under: world.rootA)
        try await world.executeClearPlan()
        try localRealE2EWrite(
            Data("planned edit".utf8),
            to: "/Drift.txt",
            under: world.rootA,
            modifiedAt: localE2EDate.addingTimeInterval(10)
        )
        let preparation = try await world.orchestrator.prepare(world.syncSet)
        let plan = try #require(preparation.outcome.planValue)
        #expect(plan.decisions.contains { $0.path == "/Drift.txt" })

        let surprise = Data("destination changed after planning".utf8)
        try localRealE2EWrite(
            surprise,
            to: "/Drift.txt",
            under: world.rootB,
            modifiedAt: localE2EDate.addingTimeInterval(20)
        )
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()
        let summary = try await world.orchestrator.execute(preparation)

        #expect(summary.outcome == .stoppedForReplan(
            location: world.locationB.id,
            path: "/Drift.txt"
        ))
        #expect(try localRealE2ERead("/Drift.txt", under: world.rootB) == surprise)
        #expect(await world.providerB.mutationCalls().isEmpty)
        #expect(await world.localProviderB.recoveryURL(for: "/Drift.txt") == nil)
    }

    @Test func convergedRerunIsEmptyAndPerformsZeroProviderMutations() async throws {
        let world = try await LocalRealE2EWorld.make(name: "idempotence")
        defer { try? FileManager.default.removeItem(at: world.root) }
        try localRealE2EWrite(Data("once".utf8), to: "/Once.txt", under: world.rootA)
        try await world.executeClearPlan()
        await world.providerA.clearMutationCalls()
        await world.providerB.clearMutationCalls()
        let beforeA = try localRealE2ETree(at: world.rootA)
        let beforeB = try localRealE2ETree(at: world.rootB)

        let preparation = try await world.orchestrator.prepare(world.syncSet)
        let plan = try #require(preparation.outcome.planValue)
        #expect(plan.decisions.isEmpty)
        #expect(preparation.preview.headline == "0 changes ready to sync")
        let summary = try await world.orchestrator.execute(preparation)

        #expect(summary.outcome == .completed)
        #expect(await world.providerA.mutationCalls().isEmpty)
        #expect(await world.providerB.mutationCalls().isEmpty)
        #expect(try localRealE2ETree(at: world.rootA) == beforeA)
        #expect(try localRealE2ETree(at: world.rootB) == beforeB)
        try await world.expectEmptyPreview()
    }

    @Test func unicodeZeroByteAndEmptyFolderSurviveBothDirections() async throws {
        let world = try await LocalRealE2EWorld.make(name: "edge-fixtures")
        defer { try? FileManager.default.removeItem(at: world.root) }
        let fromA: SyncPath = "/Résumé-مرحبا-文件.txt"
        let fromB: SyncPath = "/日本語-данные.txt"
        let contentsA = Data("unicode from A".utf8)
        let contentsB = Data("unicode from B".utf8)
        try localRealE2EWrite(contentsA, to: fromA, under: world.rootA)
        try localRealE2EWrite(Data(), to: "/Zero bytes.dat", under: world.rootA)
        try localRealE2EMakeFolder("/Empty Unicode 📁", under: world.rootA)
        try await world.executeClearPlan()

        #expect(try localRealE2ERead(fromA, under: world.rootB) == contentsA)
        #expect(try localRealE2ERead("/Zero bytes.dat", under: world.rootB).isEmpty)
        #expect(localRealE2EIsDirectory("/Empty Unicode 📁", under: world.rootB))

        try localRealE2EWrite(contentsB, to: fromB, under: world.rootB)
        try await world.executeClearPlan()

        #expect(try localRealE2ERead(fromB, under: world.rootA) == contentsB)
        #expect(try localRealE2ERead(fromA, under: world.rootA) == contentsA)
        #expect(try localRealE2ERead("/Zero bytes.dat", under: world.rootA).isEmpty)
        #expect(localRealE2EIsDirectory("/Empty Unicode 📁", under: world.rootA))
        try await world.expectEmptyPreview()
    }
}

private struct LocalRealE2EWorld {
    let root: URL
    let rootA: URL
    let rootB: URL
    let locationA: SyncLocation
    let locationB: SyncLocation
    let inspectorA: ScriptedVolumeInspector
    let inspectorB: ScriptedVolumeInspector
    let localProviderA: LocalFolderStorageProvider
    let localProviderB: LocalFolderStorageProvider
    let providerA: LocalE2EMutationRecordingProvider
    let providerB: LocalE2EMutationRecordingProvider
    let stores: EngineStores
    let syncSet: SyncSet
    let orchestrator: SyncOrchestrator

    static func make(
        name: String,
        mode: SyncMode = .balancedMirror,
        settings: SyncSettings = SyncSettings(
            thresholds: SafetyThresholds(
                massDeleteAbsolute: 10_000,
                massDeleteRatio: 1,
                massEditAbsolute: 10_000,
                massEditRatio: 1
            )
        )
    ) async throws -> LocalRealE2EWorld {
        let root = try TestTemporaryDirectory.make(
            suite: "AetherloomLocalSyncEndToEndTests",
            name: name
        )
        let rootA = root.appendingPathComponent("Folder A", isDirectory: true)
        let rootB = root.appendingPathComponent("Folder B", isDirectory: true)
        let engineRoot = root.appendingPathComponent("Engine", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        let configuration = [
            LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                "scripted-volume"
        ]
        let locationA = SyncLocation(
            id: localE2ELocationA,
            kind: .localFolder,
            displayName: "Folder A",
            configuration: configuration
        )
        let locationB = SyncLocation(
            id: localE2ELocationB,
            kind: .localFolder,
            displayName: "Folder B",
            configuration: configuration
        )
        let inspectorA = ScriptedVolumeInspector()
        let inspectorB = ScriptedVolumeInspector()
        let deadlines = ProviderDeadlines(now: { localE2EDate })
        let localProviderA = await LocalFolderStorageProvider.make(
            location: locationA,
            rootURL: rootA,
            volumes: inspectorA,
            deadlines: deadlines
        )
        let localProviderB = await LocalFolderStorageProvider.make(
            location: locationB,
            rootURL: rootB,
            volumes: inspectorB,
            deadlines: deadlines
        )
        let providerA = LocalE2EMutationRecordingProvider(base: localProviderA)
        let providerB = LocalE2EMutationRecordingProvider(base: localProviderB)
        let stores = EngineStores(
            baseRecords: try FileBaseRecordStore(
                rootURL: engineRoot.appendingPathComponent("Base Records", isDirectory: true)
            ),
            journal: try FileRunJournalStore(
                rootURL: engineRoot.appendingPathComponent("Run Journal", isDirectory: true)
            ),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: try FileActivityStore(
                rootURL: engineRoot.appendingPathComponent("Activity", isDirectory: true)
            ),
            locations: InMemoryLocationRegistry(locations: [locationA, locationB])
        )
        let syncSet = SyncSet(
            id: localE2EUUID("000000000002"),
            name: "Real local sync",
            locations: [locationA.id, locationB.id],
            mode: mode,
            settings: settings,
            createdAt: localE2EDate,
            updatedAt: localE2EDate
        )
        let ids = LocalE2EUUIDSequence(prefix: "e4100000-0000-0000-0000")
        let orchestrator = SyncOrchestrator(
            locations: [locationA.id: locationA, locationB.id: locationB],
            providers: [locationA.id: providerA, locationB.id: providerB],
            stores: stores,
            stage: ContentStage(
                rootDirectory: root.appendingPathComponent("Stage", isDirectory: true),
                byteLimit: 20_000_000
            ),
            environment: EngineEnvironment(
                now: { localE2EDate },
                makeID: { ids.next() }
            )
        )
        return LocalRealE2EWorld(
            root: root,
            rootA: rootA,
            rootB: rootB,
            locationA: locationA,
            locationB: locationB,
            inspectorA: inspectorA,
            inspectorB: inspectorB,
            localProviderA: localProviderA,
            localProviderB: localProviderB,
            providerA: providerA,
            providerB: providerB,
            stores: stores,
            syncSet: syncSet,
            orchestrator: orchestrator
        )
    }

    @discardableResult
    func executeClearPlan() async throws -> SyncPlan {
        let preparation = try await orchestrator.prepare(syncSet)
        let plan = try #require(preparation.outcome.planValue)
        #expect(plan.gate.isClear)
        let summary = try await orchestrator.execute(preparation)
        #expect(summary.outcome == .completed)
        return plan
    }

    func expectEmptyPreview() async throws {
        let preparation = try await orchestrator.prepare(syncSet)
        let plan = try #require(preparation.outcome.planValue)
        #expect(plan.decisions.isEmpty)
        #expect(preparation.preview.headline == "0 changes ready to sync")
    }
}

private enum LocalE2EMutationCall: Hashable, Sendable {
    case store(SyncPath)
    case makeFolder(SyncPath)
    case relocate(SyncPath, SyncPath)
    case trash(SyncPath)
}

private actor LocalE2EMutationRecordingProvider: StorageProvider {
    nonisolated let locationID: LocationID
    nonisolated let capabilities: ProviderCapabilities

    private let base: LocalFolderStorageProvider
    private var calls: [LocalE2EMutationCall] = []

    init(base: LocalFolderStorageProvider) {
        self.base = base
        self.locationID = base.locationID
        self.capabilities = base.capabilities
    }

    func mutationCalls() -> [LocalE2EMutationCall] {
        calls
    }

    func clearMutationCalls() {
        calls.removeAll()
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
        calls.append(.store(path))
        return try await base.store(from: stagingURL, at: path, options: options)
    }

    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        calls.append(.makeFolder(path))
        return try await base.makeFolder(at: path)
    }

    func relocate(
        _ observation: ItemObservation,
        to newPath: SyncPath
    ) async throws -> ItemObservation {
        calls.append(.relocate(observation.path, newPath))
        return try await base.relocate(observation, to: newPath)
    }

    func trash(_ observation: ItemObservation) async throws {
        calls.append(.trash(observation.path))
        try await base.trash(observation)
    }

    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await base.currentState(of: observation)
    }
}

private func localRealE2EWrite(
    _ data: Data,
    to path: SyncPath,
    under root: URL,
    modifiedAt: Date = localE2EDate
) throws {
    let destination = localRealE2EURL(path, under: root)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: destination.path
    )
}

private func localRealE2EMakeFolder(
    _ path: SyncPath,
    under root: URL
) throws {
    try FileManager.default.createDirectory(
        at: localRealE2EURL(path, under: root),
        withIntermediateDirectories: true
    )
}

private func localRealE2ERead(
    _ path: SyncPath,
    under root: URL
) throws -> Data {
    try Data(contentsOf: localRealE2EURL(path, under: root))
}

private func localRealE2EIsDirectory(
    _ path: SyncPath,
    under root: URL
) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: localRealE2EURL(path, under: root).path,
        isDirectory: &isDirectory
    ) && isDirectory.boolValue
}

private func localRealE2EURL(
    _ path: SyncPath,
    under root: URL
) -> URL {
    path.components.reduce(root) { partial, component in
        partial.appendingPathComponent(component)
    }
}

private func localRealE2ETree(at root: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false }
    ) else {
        return []
    }
    var entries: Set<String> = []
    while let url = enumerator.nextObject() as? URL {
        let relativePath = String(url.path.dropFirst(root.path.count))
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        if values.isDirectory == true {
            entries.insert("folder:\(relativePath)")
        } else if values.isSymbolicLink == true {
            entries.insert(
                "symlink:\(relativePath):\(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))"
            )
        } else {
            entries.insert("file:\(relativePath):\(try Data(contentsOf: url).base64EncodedString())")
        }
    }
    return entries
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
