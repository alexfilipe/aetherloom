import Foundation
import Testing
@testable import AetherloomCore

@Suite("StorageProvider conformance")
struct ProviderConformanceTests {
    @Test(arguments: providerConformanceHarnesses)
    func truthfulness_emptyScopeIsComplete(
        harness: any ProviderConformanceHarness
    ) async throws {
        let provider = try await harness.makeProvider(seeded: [])
        let snapshot = await provider.scan(.entireDrive)

        #expect(snapshot.status == .complete)
        #expect(snapshot.observations.all.isEmpty)
    }

    @Test(
        arguments: providerConformanceHarnesses,
        providerConformanceUnavailableReasons
    )
    func truthfulness_unavailabilityNeverMasqueradesAsEmpty(
        harness: any ProviderConformanceHarness,
        reason: LocationUnavailabilityReason
    ) async throws {
        guard let provider = try await harness.makeUnavailableProvider(reason: reason) else {
            withKnownIssue(
                "Skipped: \(harness.testDescription) cannot reproduce \(reason)."
            ) {
                Issue.record("Unavailable-provider harness returned nil.")
            }
            return
        }

        let availability = await provider.checkAvailability()
        guard case .unavailable = availability else {
            Issue.record("Availability was reported as reachable for \(reason).")
            return
        }

        let snapshot = await provider.scan(.entireDrive)
        guard case .unavailable = snapshot.status else {
            Issue.record("Scan failure masqueraded as \(snapshot.status).")
            return
        }
        #expect(snapshot.status != .complete)
    }

    @Test(arguments: providerConformanceHarnesses)
    func truthfulness_enumerationFailureIsIncomplete(
        harness: any ProviderConformanceHarness
    ) async throws {
        let seed = ConformanceSeedItem(
            path: "/ObservedBeforeFailure.txt",
            kind: .file,
            contents: providerContractData("partial"),
            modifiedAt: providerContractDate
        )
        let provider = try await harness.makeIncompleteProvider(
            seeded: [seed],
            reason: "Enumeration stopped."
        )

        let snapshot = await provider.scan(.entireDrive)

        guard case .incomplete = snapshot.status else {
            Issue.record("Enumeration failure was reported as \(snapshot.status).")
            return
        }
        #expect(snapshot.status != .complete)
    }

    @Test(arguments: providerConformanceHarnesses)
    func scanFidelity_observesKindsAndRoundTripsCurrentState(
        harness: any ProviderConformanceHarness
    ) async throws {
        let seeds = [
            ConformanceSeedItem(
                path: "/Zero.dat",
                kind: .file,
                contents: Data(),
                modifiedAt: providerContractDate
            ),
            ConformanceSeedItem(
                path: "/Empty",
                kind: .folder,
                modifiedAt: providerContractDate
            ),
            ConformanceSeedItem(
                path: "/Deep/One/Two/Payload.txt",
                kind: .file,
                contents: providerContractData("deep"),
                modifiedAt: providerContractDate
            ),
            ConformanceSeedItem(
                path: "/Linked",
                kind: .symlink(target: "/Volumes/NAS"),
                modifiedAt: providerContractDate
            ),
        ]
        let provider = try await harness.makeProvider(seeded: seeds)
        let snapshot = await provider.scan(.entireDrive)

        #expect(snapshot.status == .complete)
        #expect(snapshot.observations.byPath["/Zero.dat"]?.version.size == 0)
        #expect(snapshot.observations.byPath["/Empty"]?.kind == .folder)
        #expect(snapshot.observations.byPath["/Deep/One/Two/Payload.txt"]?.kind == .file)
        #expect(snapshot.observations.byPath["/Linked"]?.kind == .symlink(target: "/Volumes/NAS"))

        for observation in snapshot.observations.all {
            #expect(try await provider.currentState(of: observation) == observation)
        }
    }

    @Test(arguments: providerConformanceHarnesses)
    func scanFidelity_preservesNFCAndNFDNames(
        harness: any ProviderConformanceHarness
    ) async throws {
        let names = [
            "/Caf\u{00E9}.txt",
            "/Cafe\u{0301}.txt",
        ]

        for name in names {
            let seed = ConformanceSeedItem(
                path: SyncPath(name),
                kind: .file,
                contents: providerContractData(name),
                modifiedAt: providerContractDate
            )
            let provider = try await harness.makeProvider(seeded: [seed])
            let observation = try #require(
                await provider.scan(.entireDrive).observations.all.first
            )

            if harness.preservesSeededUnicodeScalars {
                #expect(
                    observation.path.rawValue.unicodeScalars.map(\.value)
                        == name.unicodeScalars.map(\.value)
                )
            } else {
                #expect(
                    observation.path.rawValue.precomposedStringWithCanonicalMapping
                        == name.precomposedStringWithCanonicalMapping
                )
            }
        }
    }

    @Test(arguments: providerConformanceHarnesses)
    func mutation_storeIsIdempotentAndEnforcesNeverOverwrite(
        harness: any ProviderConformanceHarness
    ) async throws {
        guard harness.runsMutationConformance else {
            withKnownIssue("Skipped: \(harness.testDescription) read side has no mutations.") {
                Issue.record("Mutation conformance is deferred.")
            }
            return
        }
        let oldData = providerContractData("old")
        let seed = ConformanceSeedItem(
            path: "/Existing.txt",
            kind: .file,
            contents: oldData,
            modifiedAt: providerContractDate
        )
        let provider = try await harness.makeProvider(
            seeded: [
                seed,
                ConformanceSeedItem(
                    path: "/ExistingFolder",
                    kind: .folder,
                    modifiedAt: providerContractDate
                ),
                ConformanceSeedItem(
                    path: "/ExistingLink",
                    kind: .symlink(target: "/Target"),
                    modifiedAt: providerContractDate
                ),
            ]
        )
        let existing = try #require(
            await provider.scan(.entireDrive).observations.byPath["/Existing.txt"]
        )
        let identicalURL = try providerContractTemporaryFile(
            "identical.txt",
            contents: oldData
        )
        let differentURL = try providerContractTemporaryFile(
            "different.txt",
            contents: providerContractData("different")
        )
        defer {
            try? FileManager.default.removeItem(at: identicalURL)
            try? FileManager.default.removeItem(at: differentURL)
        }

        let reapplied = try await provider.store(
            from: identicalURL,
            at: "/Existing.txt",
            options: StoreOptions(overwrite: .neverOverwrite)
        )
        #expect(reapplied.path == existing.path)
        #expect(reapplied.version == existing.version)
        if harness.declaredCapabilities.hasStableItemIDs {
            #expect(reapplied.itemID == existing.itemID)
        }

        await #expect(
            throws: ProviderError.itemAlreadyExists(
                provider: provider.locationID,
                path: "/Existing.txt"
            )
        ) {
            _ = try await provider.store(
                from: differentURL,
                at: "/Existing.txt",
                options: StoreOptions(overwrite: .neverOverwrite)
            )
        }

        for occupiedPath: SyncPath in ["/ExistingFolder", "/ExistingLink"] {
            await #expect(
                throws: ProviderError.itemAlreadyExists(
                    provider: provider.locationID,
                    path: occupiedPath
                )
            ) {
                _ = try await provider.store(
                    from: identicalURL,
                    at: occupiedPath,
                    options: StoreOptions(overwrite: .neverOverwrite)
                )
            }
        }
    }

    @Test(arguments: providerConformanceHarnesses)
    func mutation_versionCheckedStoreRejectsDrift(
        harness: any ProviderConformanceHarness
    ) async throws {
        guard harness.runsMutationConformance else {
            withKnownIssue("Skipped: \(harness.testDescription) read side has no mutations.") {
                Issue.record("Mutation conformance is deferred.")
            }
            return
        }
        let seed = ConformanceSeedItem(
            path: "/Versioned.txt",
            kind: .file,
            contents: providerContractData("original"),
            modifiedAt: providerContractDate
        )
        let provider = try await harness.makeProvider(seeded: [seed])
        let original = try #require(
            await provider.scan(.entireDrive).observations.byPath["/Versioned.txt"]
        )
        let firstURL = try providerContractTemporaryFile(
            "first-version.txt",
            contents: providerContractData("first replacement")
        )
        let staleURL = try providerContractTemporaryFile(
            "stale-version.txt",
            contents: providerContractData("stale replacement")
        )
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: staleURL)
        }

        _ = try await provider.store(
            from: firstURL,
            at: original.path,
            options: StoreOptions(overwrite: .ifVersionMatches(original.version))
        )

        let expectedError = ProviderError.preconditionFailed(
            provider: provider.locationID,
            path: original.path
        )
        if harness.declaredCapabilities.supportsVersionCheckedStore {
            await #expect(throws: expectedError) {
                _ = try await provider.store(
                    from: staleURL,
                    at: original.path,
                    options: StoreOptions(overwrite: .ifVersionMatches(original.version))
                )
            }
        } else {
            await #expect(throws: expectedError) {
                _ = try await providerContractEmulatedVersionCheckedStore(
                    provider: provider,
                    observation: original,
                    stagingURL: staleURL
                )
            }
        }
    }

    @Test(arguments: providerConformanceHarnesses)
    func mutation_makeFolderIsIdempotentAndRejectsFileOccupant(
        harness: any ProviderConformanceHarness
    ) async throws {
        guard harness.runsMutationConformance else {
            withKnownIssue("Skipped: \(harness.testDescription) read side has no mutations.") {
                Issue.record("Mutation conformance is deferred.")
            }
            return
        }
        let provider = try await harness.makeProvider(
            seeded: [
                ConformanceSeedItem(
                    path: "/ExistingFolder",
                    kind: .folder,
                    modifiedAt: providerContractDate
                ),
                ConformanceSeedItem(
                    path: "/Occupied",
                    kind: .file,
                    contents: providerContractData("file"),
                    modifiedAt: providerContractDate
                ),
            ]
        )
        let existing = try #require(
            await provider.scan(.entireDrive).observations.byPath["/ExistingFolder"]
        )

        let reapplied = try await provider.makeFolder(at: "/ExistingFolder")
        #expect(reapplied == existing)

        await #expect(
            throws: ProviderError.itemAlreadyExists(
                provider: provider.locationID,
                path: "/Occupied"
            )
        ) {
            _ = try await provider.makeFolder(at: "/Occupied")
        }
    }

    @Test(arguments: providerConformanceHarnesses)
    func mutation_relocateIsIdempotentAndPreservesContent(
        harness: any ProviderConformanceHarness
    ) async throws {
        guard harness.runsMutationConformance else {
            withKnownIssue("Skipped: \(harness.testDescription) read side has no mutations.") {
                Issue.record("Mutation conformance is deferred.")
            }
            return
        }
        let contents = providerContractData("move me")
        let seeds = [
            ConformanceSeedItem(
                path: "/Move.txt",
                kind: .file,
                contents: contents,
                modifiedAt: providerContractDate
            ),
            ConformanceSeedItem(
                path: "/Occupied.txt",
                kind: .file,
                contents: providerContractData("occupied"),
                modifiedAt: providerContractDate
            ),
        ]
        let provider = try await harness.makeProvider(seeded: seeds)
        let original = try #require(
            await provider.scan(.entireDrive).observations.byPath["/Move.txt"]
        )

        #expect(try await provider.relocate(original, to: original.path) == original)
        await #expect(
            throws: ProviderError.itemAlreadyExists(
                provider: provider.locationID,
                path: "/Occupied.txt"
            )
        ) {
            _ = try await provider.relocate(original, to: "/Occupied.txt")
        }

        let moved = try await provider.relocate(original, to: "/Moved.txt")
        #expect(moved.path == "/Moved.txt")
        if harness.declaredCapabilities.hasStableItemIDs {
            #expect(original.itemID != nil)
            #expect(moved.itemID == original.itemID)
        } else {
            #expect(original.itemID == nil)
            #expect(moved.itemID == nil)
        }

        let fetchURL = try providerContractTemporaryURL("moved-fetch.txt")
        defer { try? FileManager.default.removeItem(at: fetchURL) }
        try await provider.fetch(moved, to: fetchURL)
        #expect(try Data(contentsOf: fetchURL) == contents)

        let snapshot = await provider.scan(.entireDrive)
        #expect(snapshot.observations.byPath["/Move.txt"] == nil)
        #expect(snapshot.observations.byPath["/Moved.txt"] != nil)
    }

    @Test(arguments: providerConformanceHarnesses)
    func preservation_trashIsIdempotentRecoverableAndAbsentFromScan(
        harness: any ProviderConformanceHarness
    ) async throws {
        guard harness.runsPreservationConformance else {
            withKnownIssue("Skipped: \(harness.testDescription) read side has no trash.") {
                Issue.record("Preservation conformance is deferred.")
            }
            return
        }
        let contents = providerContractData("preserve me")
        let provider = try await harness.makeProvider(
            seeded: [
                ConformanceSeedItem(
                    path: "/Trash.txt",
                    kind: .file,
                    contents: contents,
                    modifiedAt: providerContractDate
                )
            ]
        )
        let original = try #require(
            await provider.scan(.entireDrive).observations.byPath["/Trash.txt"]
        )

        try await provider.trash(original)
        try await provider.trash(original)

        let snapshot = await provider.scan(.entireDrive)
        #expect(snapshot.observations.byPath[original.path] == nil)

        #expect(
            try await harness.recoverableContents(for: original, from: provider)
                == contents
        )
    }

    @Test(arguments: providerConformanceHarnesses)
    func degradation_declaredCapabilitiesMatchObservedBehavior(
        harness: any ProviderConformanceHarness
    ) async throws {
        let contents = providerContractData("capabilities")
        let provider = try await harness.makeProvider(
            seeded: [
                ConformanceSeedItem(
                    path: "/Capabilities.txt",
                    kind: .file,
                    contents: contents,
                    modifiedAt: providerContractDate
                )
            ]
        )
        #expect(provider.capabilities == harness.declaredCapabilities)

        let observation = try #require(
            await provider.scan(.entireDrive).observations.byPath["/Capabilities.txt"]
        )
        if harness.declaredCapabilities.hasContentHashes {
            #expect(observation.version.contentHash != nil)
        } else {
            #expect(observation.version.contentHash == nil)
        }
        if harness.declaredCapabilities.hasStableItemIDs {
            #expect(observation.itemID != nil)
        } else {
            #expect(observation.itemID == nil)
        }

        let hint = try await provider.changedSubtrees(in: .entireDrive, since: nil)
        #expect(hint.isComplete == harness.declaredCapabilities.hasChangeHints)
    }
}

@Test func storageProviderContract_fakeProviderIncompleteScanKeepsScriptedPartialView() async {
    let provider = FakeStorageProvider(locationID: .localFolder)
    await provider.putFile(
        path: "/Present.txt",
        contents: providerContractData("present"),
        modifiedAt: providerContractDate
    )

    await provider.setAvailability(.unavailable(.volumeNotMounted(detail: "Disk unplugged.")))
    let unavailable = await provider.scan(.entireDrive)
    #expect(
        unavailable.status
            == .unavailable(reason: .volumeNotMounted(detail: "Disk unplugged."))
    )

    await provider.setAvailability(.available)
    await provider.setIncompleteScan(reason: "Enumeration stopped.")
    let incomplete = await provider.scan(.entireDrive)
    #expect(incomplete.observations.all.map(\.path) == ["/Present.txt"])
}

@Test func storageProviderContract_fakeProviderPlaceholderScriptingIsVisible() async {
    let provider = FakeStorageProvider(locationID: .iCloudDrive)
    await provider.putFile(
        path: "/Dataless.pages",
        contents: providerContractData("stub"),
        modifiedAt: providerContractDate,
        isPlaceholder: true
    )

    let snapshot = await provider.scan(.entireDrive)

    #expect(snapshot.observations.byPath["/Dataless.pages"]?.isPlaceholder == true)
}

@Test func storageProviderContract_fakeTrashIsInspectableThroughTestSeam() async throws {
    let provider = FakeStorageProvider(locationID: .googleDrive)
    let existing = await provider.putFile(
        path: "/Existing.txt",
        contents: providerContractData("old"),
        modifiedAt: providerContractDate
    )

    try await provider.trash(existing)
    let trashed = try #require(
        await provider.item(at: "/Existing.txt", includeTrashed: true)
    )
    let fetchURL = try providerContractTemporaryURL("fake-trash-fetch.txt")
    defer { try? FileManager.default.removeItem(at: fetchURL) }
    try await provider.fetch(trashed, to: fetchURL)
    #expect(try Data(contentsOf: fetchURL) == providerContractData("old"))
}

@Test func storageProviderContract_fakeProviderCallLogRecordsExpectedOrder() async throws {
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let item = await provider.putFile(
        path: "/Log.txt",
        contents: providerContractData("log"),
        modifiedAt: providerContractDate
    )
    await provider.clearCallLog()

    _ = await provider.checkAvailability()
    _ = await provider.scan(.entireDrive)
    _ = try await provider.changedSubtrees(
        in: .entireDrive,
        since: ChangeCursor(rawValue: "cursor")
    )
    _ = try await provider.currentState(of: item)

    #expect(
        await provider.callLog().map(\.operation)
            == [.checkAvailability, .scan, .changedSubtrees, .currentState]
    )
    #expect(await provider.callLog().map(\.order) == [0, 1, 2, 3])
}

@Test func storageProviderContract_quarantinePrefixIsVisibleButExcludedFromPlanning() async {
    let syncSet = SyncSet(
        name: "Quarantine",
        locations: [.localFolder, .nasFolder],
        createdAt: providerContractDate,
        updatedAt: providerContractDate
    )
    let local = FakeStorageProvider(locationID: .localFolder)
    let nas = FakeStorageProvider(locationID: .nasFolder)
    await local.putFile(
        path: "/.aetherloom/trash/run/Quarantined.txt",
        contents: providerContractData("internal"),
        modifiedAt: providerContractDate
    )

    let snapshot = await local.scan(.entireDrive)
    let outcome = SyncPlanner().plan(
        SyncPlanningInput(
            syncSet: syncSet,
            snapshots: [snapshot, await nas.scan(.entireDrive)]
        ),
        environment: PlanningEnvironment(now: providerContractDate)
    )

    #expect(snapshot.observations.byPath["/.aetherloom/trash/run/Quarantined.txt"] != nil)
    #expect(outcome.planValue?.schedule.operations.isEmpty == true)
}

private func providerContractEmulatedVersionCheckedStore(
    provider: any StorageProvider,
    observation: ItemObservation,
    stagingURL: URL
) async throws -> ItemObservation {
    let current = try await provider.currentState(of: observation)
    guard current.version.isSameVersion(as: observation.version) else {
        throw ProviderError.preconditionFailed(
            provider: provider.locationID,
            path: observation.path
        )
    }
    return try await provider.store(
        from: stagingURL,
        at: observation.path,
        options: StoreOptions(overwrite: .ifVersionMatches(current.version))
    )
}

private func providerContractTemporaryURL(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AetherloomProviderContractTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
}

private func providerContractTemporaryFile(_ name: String, contents: Data) throws -> URL {
    let url = try providerContractTemporaryURL(name)
    try contents.write(to: url)
    return url
}

private func providerContractData(_ string: String) -> Data {
    Data(string.utf8)
}

private let providerContractDate = Date(timeIntervalSince1970: 1_770_000_000)

private let providerConformanceUnavailableReasons: [LocationUnavailabilityReason] = [
    .notAuthenticated(detail: "Authentication unavailable."),
    .networkUnreachable(detail: "Network unavailable."),
    .volumeNotMounted(detail: "Volume not mounted."),
    .volumeUnreachable(detail: "Volume unreachable."),
    .scopeMissing(detail: "Scope missing."),
    .rateLimited(retryAfter: providerContractDate),
    .unknown(detail: "Unknown failure."),
]
