import Foundation
import Testing
@testable import AetherloomCore

// This suite intentionally exercises process-wide root ownership and several
// synchronous Foundation gates. Running its cases concurrently can exhaust
// cooperative executor threads before the owning test can release a gate.
@Suite("LocalFolderStorageProvider", .serialized)
struct LocalFolderStorageProviderTests {
    @Test func filesystemRootContainsDescendants() {
        #expect(
            LocalFolderStorageProvider.contains(
                URL(fileURLWithPath: "/Volumes/Archive/Document.txt"),
                in: URL(fileURLWithPath: "/", isDirectory: true)
            )
        )
    }

    @Test func factoryFreezesProbedCapabilitiesAndDegradesNAS() async throws {
        let root = try makeRoot("capabilities")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = ScriptedVolumeInspector(
            properties: VolumeProperties(
                isCaseSensitive: true,
                supportsNativeTrash: true,
                isNetwork: false
            )
        )
        let local = await makeProvider(root: root, inspector: inspector)
        #expect(local.capabilities.hasNativeTrash)
        #expect(local.capabilities.isCaseSensitive == true)
        #expect(!local.capabilities.hasStableItemIDs)
        #expect(!local.capabilities.hasContentHashes)
        #expect(!local.capabilities.hasChangeHints)
        #expect(!local.capabilities.supportsVersionCheckedStore)
        #expect(
            await inspector.calls() == [.properties]
        )
        await inspector.setProperties(
            VolumeProperties(
                isCaseSensitive: false,
                supportsNativeTrash: false,
                isNetwork: true
            )
        )
        #expect(local.capabilities.hasNativeTrash)
        #expect(local.capabilities.isCaseSensitive == true)

        let nas = await LocalFolderStorageProvider.make(
            location: localLocation(kind: .nasFolder),
            rootURL: root,
            volumes: inspector
        )
        #expect(!nas.capabilities.hasNativeTrash)
        #expect(nas.capabilities.isCaseSensitive == nil)
    }

    @Test func failedCapabilityProbeFreezesConservativeValues() async throws {
        let root = try makeRoot("capability-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(probeNanoseconds: 0)
        )
        #expect(!provider.capabilities.hasNativeTrash)
        #expect(provider.capabilities.isCaseSensitive == nil)
    }

    @Test func availabilityUsesVolumeFirstOrderAndAllOutcomes() async throws {
        let root = try makeRoot("availability")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = ScriptedVolumeInspector()
        let provider = await makeProvider(root: root, inspector: inspector)

        await inspector.clearCalls()
        #expect(await provider.checkAvailability() == .available)
        #expect(
            await inspector.calls()
                == [
                    .mount,
                    .volumeIdentity(root.resolvingSymlinksInPath().standardizedFileURL.path),
                    .responsiveness,
                    .volumeIdentity(root.resolvingSymlinksInPath().standardizedFileURL.path),
                    .directory(root.standardizedFileURL.path),
                    .volumeIdentity(root.resolvingSymlinksInPath().standardizedFileURL.path),
                ]
        )

        await inspector.setMountState(.notMounted(detail: "unplugged"))
        await inspector.clearCalls()
        #expect(
            await provider.checkAvailability()
                == .unavailable(.volumeNotMounted(detail: "unplugged"))
        )
        #expect(await inspector.calls() == [.mount])

        await inspector.setMountState(.mounted)
        await inspector.setVolumeIdentity("replacement-volume")
        await inspector.clearCalls()
        #expect(
            await provider.checkAvailability()
                == .unavailable(
                    .volumeNotMounted(
                        detail: "The selected volume was replaced by a different volume."
                    )
                )
        )
        #expect(
            await inspector.calls() == [
                .mount,
                .volumeIdentity(root.resolvingSymlinksInPath().standardizedFileURL.path),
            ]
        )
        await inspector.setVolumeIdentity("scripted-volume")

        await inspector.setResponsiveness(.unreachable(detail: "sleeping"))
        #expect(
            await provider.checkAvailability()
                == .unavailable(.volumeUnreachable(detail: "sleeping"))
        )

        await inspector.setResponsiveness(.responsive)
        await inspector.setDirectoryState(.missing)
        #expect(
            await provider.checkAvailability()
                == .unavailable(.scopeMissing(detail: "The selected folder is missing."))
        )

        await inspector.setDirectoryState(.present(isReadable: false))
        #expect(
            await provider.checkAvailability()
                == .unavailable(.unknown(detail: "The selected folder is not readable."))
        )

        await inspector.setDirectoryState(.missing)
        await inspector.enqueueMountStates([
            .mounted,
            .notMounted(detail: "removed during inspection"),
        ])
        #expect(
            await provider.checkAvailability()
                == .unavailable(
                    .volumeNotMounted(detail: "removed during inspection")
                )
        )
    }

    @Test func durableVolumeIdentityIsRequiredAndRevalidatedAfterScan() async throws {
        let root = try makeRoot("durable-volume-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preserve".utf8).write(to: root.appendingPathComponent("Present.txt"))

        let missingIdentityProvider = await LocalFolderStorageProvider.make(
            location: SyncLocation(kind: .localFolder),
            rootURL: root,
            volumes: ScriptedVolumeInspector()
        )
        #expect(
            await missingIdentityProvider.checkAvailability()
                == .unavailable(
                    .unknown(
                        detail: "The selected volume identity could not be recorded safely."
                    )
                )
        )

        let replacementInspector = ScriptedVolumeInspector()
        await replacementInspector.setVolumeIdentity("replacement-volume")
        let reconstructed = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: replacementInspector
        )
        #expect(
            await reconstructed.checkAvailability()
                == .unavailable(
                    .volumeNotMounted(
                        detail: "The selected volume was replaced by a different volume."
                    )
                )
        )

        let swappedDuringScan = ScriptedVolumeInspector()
        await swappedDuringScan.enqueueVolumeIdentities([
            "scripted-volume",
            "replacement-volume",
        ])
        let provider = await makeProvider(root: root, inspector: swappedDuringScan)
        let snapshot = await provider.scan(.entireDrive)
        #expect(
            snapshot.status
                == .unavailable(
                    reason: .volumeNotMounted(
                        detail: "The selected volume was replaced by a different volume."
                    )
                )
        )
        #expect(snapshot.observations.all.isEmpty)
    }

    @Test func enrollmentPersistsVolumeIdentityAcrossLocationRoundTrip() async throws {
        let root = try makeRoot("volume-enrollment")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = ScriptedVolumeInspector()
        let original = SyncLocation(kind: .localFolder)
        let enrolled = try await LocalFolderStorageProvider
            .locationByRecordingVolumeIdentity(
                original,
                rootURL: root,
                volumes: inspector
            )
        let encoded = try JSONEncoder().encode(enrolled)
        let restored = try JSONDecoder().decode(SyncLocation.self, from: encoded)
        let registry = InMemoryLocationRegistry()
        try await registry.upsert(restored)
        let persisted = try #require(
            try await registry.allLocations().first
        )

        #expect(
            persisted.configuration[
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey
            ] == "scripted-volume"
        )
        let provider = await LocalFolderStorageProvider.make(
            location: persisted,
            rootURL: root,
            volumes: inspector
        )
        #expect(await provider.checkAvailability() == .available)

        await inspector.setVolumeIdentity("replacement-volume")
        let reconstructed = await LocalFolderStorageProvider.make(
            location: persisted,
            rootURL: root,
            volumes: inspector
        )
        #expect(
            await reconstructed.checkAvailability()
                == .unavailable(
                    .volumeNotMounted(
                        detail: "The selected volume was replaced by a different volume."
                    )
                )
        )
    }

    @Test func enrollmentRejectsVolumeWithoutPersistentIdentityAsUnsupported() async throws {
        let root = try makeRoot("volume-enrollment-without-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity(nil)
        let location = SyncLocation(kind: .nasFolder)

        await #expect(
            throws: ProviderError.unsupported(
                provider: location.id,
                reason: "The selected volume does not provide a persistent identity and cannot be enrolled safely."
            )
        ) {
            _ = try await LocalFolderStorageProvider.locationByRecordingVolumeIdentity(
                location,
                rootURL: root,
                volumes: inspector
            )
        }
    }

    @Test func systemVolumeIdentityUsesPersistentVolumeUUID() async throws {
        let root = try makeRoot("system-volume-uuid")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = SystemVolumeInspector()
        let first = try #require(await inspector.volumeIdentity(for: root))
        let second = try #require(await inspector.volumeIdentity(for: root))

        #expect(UUID(uuidString: first) != nil)
        #expect(second == first)
    }

    @Test func scanDiscardsObservationsWhenRootDisappearsAfterEnumeration() async throws {
        let root = try makeRoot("root-disappears-during-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("must not look deleted".utf8).write(
            to: root.appendingPathComponent("Present.txt")
        )
        let inspector = ScriptedVolumeInspector()
        await inspector.enqueueDirectoryStates([
            .present(isReadable: true),
            .missing,
        ])
        let provider = await makeProvider(root: root, inspector: inspector)
        let snapshot = await provider.scan(.entireDrive)

        #expect(
            snapshot.status
                == .unavailable(
                    reason: .scopeMissing(detail: "The selected folder is missing.")
                )
        )
        #expect(snapshot.observations.all.isEmpty)
    }

    @Test func scanObservesRealFixturesAndSuppressesInternalSpace() async throws {
        let root = try makeRoot("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let zero = root.appendingPathComponent("Zero.dat")
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let deep = root.appendingPathComponent("Deep/One/Payload.txt")
        let link = root.appendingPathComponent("Linked")
        let internalFile = root.appendingPathComponent(
            ".aetherloom/trash/run/Hidden.txt"
        )
        try Data().write(to: zero)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: deep.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(to: deep)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/Volumes/NAS"
        )
        try FileManager.default.createDirectory(
            at: internalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hidden".utf8).write(to: internalFile)

        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let snapshot = await provider.scan(.entireDrive)
        #expect(snapshot.status == .complete)
        #expect(snapshot.observations.byPath["/Zero.dat"]?.version.size == 0)
        #expect(snapshot.observations.byPath["/Empty"]?.kind == .folder)
        #expect(snapshot.observations.byPath["/Deep/One/Payload.txt"]?.kind == .file)
        #expect(snapshot.observations.byPath["/Linked"]?.kind == .symlink(target: "/Volumes/NAS"))
        #expect(snapshot.observations.all.allSatisfy { !$0.path.isDescendant(of: "/.aetherloom") })

        let observed = try #require(snapshot.observations.byPath["/Deep/One/Payload.txt"])
        #expect(try await provider.currentState(of: observed) == observed)
        let staging = root.appendingPathComponent("staging-copy")
        try await provider.fetch(observed, to: staging)
        #expect(try Data(contentsOf: staging) == Data("payload".utf8))
    }

    @Test func scanDoesNotReadRegularFileContents() async throws {
        let root = try makeRoot("unreadable-file-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("MetadataOnly.txt")
        try Data("content must not be opened".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: file.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
        }
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let snapshot = await provider.scan(.entireDrive)

        #expect(snapshot.status == .complete)
        #expect(snapshot.observations.byPath["/MetadataOnly.txt"]?.kind == .file)
        #expect(snapshot.observations.byPath["/MetadataOnly.txt"]?.version.contentHash == nil)
    }

    @Test func fetchRejectsSourceDriftBeforeCopy() async throws {
        let root = try makeRoot("fetch-source-drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.txt")
        let fixedModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try Data("first bytes".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModifiedAt],
            ofItemAtPath: source.path
        )
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let planned = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )

        try Data("other bytes".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModifiedAt.addingTimeInterval(10)],
            ofItemAtPath: source.path
        )
        let staging = root.appendingPathComponent("staging")
        await #expect(
            throws: ProviderError.preconditionFailed(
                provider: provider.locationID,
                path: planned.path
            )
        ) {
            try await provider.fetch(planned, to: staging)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func fetchRejectsSourceMutationAfterCopy() async throws {
        let root = try makeRoot("fetch-drift-after-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.txt")
        let fixedModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try Data("first bytes".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModifiedAt],
            ofItemAtPath: source.path
        )
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            fetching: SourceMutatingFetchPerformer(
                replacement: Data("other bytes".utf8),
                modifiedAt: fixedModifiedAt.addingTimeInterval(10)
            )
        )
        let planned = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )
        let staging = root.appendingPathComponent("staging")

        await #expect(
            throws: ProviderError.preconditionFailed(
                provider: provider.locationID,
                path: planned.path
            )
        ) {
            try await provider.fetch(planned, to: staging)
        }
    }

    @Test func fetchRejectsCorruptedStagingCopy() async throws {
        let root = try makeRoot("fetch-corrupted-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.txt")
        try Data("first bytes".utf8).write(to: source)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            fetching: CorruptingFetchPerformer(
                replacement: Data("other bytes".utf8)
            )
        )
        let planned = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )
        let staging = root.appendingPathComponent("staging")

        await #expect(
            throws: ProviderError.preconditionFailed(
                provider: provider.locationID,
                path: planned.path
            )
        ) {
            try await provider.fetch(planned, to: staging)
        }
    }

    @Test func scanPreservesNFCAndNFDNamesSeparately() async throws {
        for (index, name) in ["Caf\u{00E9}.txt", "Cafe\u{0301}.txt"].enumerated() {
            let root = try makeRoot("unicode-\(index)")
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("name".utf8).write(to: root.appendingPathComponent(name))
            let fileSystemName = try #require(
                FileManager.default.contentsOfDirectory(atPath: root.path).first
            )
            let provider = await makeProvider(
                root: root,
                inspector: ScriptedVolumeInspector()
            )
            let path = try #require((await provider.scan(.entireDrive)).observations.all.first?.path)
            #expect(
                path.name.unicodeScalars.map(\.value)
                    == fileSystemName.unicodeScalars.map(\.value)
            )
            #expect(
                path.name.precomposedStringWithCanonicalMapping
                    == name.precomposedStringWithCanonicalMapping
            )
        }
    }

    @Test func expiredScanDeadlineIsIncomplete() async throws {
        let root = try makeRoot("deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("present".utf8).write(to: root.appendingPathComponent("Present.txt"))
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(scanNanoseconds: 0)
        )
        let snapshot = await provider.scan(.entireDrive)
        #expect(snapshot.status == .incomplete(reason: "Filesystem scan timed out."))
        #expect(snapshot.observations.all.isEmpty)
    }

    @Test func missingCurrentStateRequiresHealthyVolume() async throws {
        let root = try makeRoot("missing-current")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = ScriptedVolumeInspector()
        let provider = await makeProvider(root: root, inspector: inspector)
        let missing = ItemObservation(
            location: provider.locationID,
            path: "/Missing.txt",
            kind: .file
        )
        await #expect(
            throws: ProviderError.notFound(
                provider: provider.locationID,
                path: "/Missing.txt"
            )
        ) {
            _ = try await provider.currentState(of: missing)
        }

        await inspector.setMountState(.notMounted(detail: "gone"))
        await #expect(
            throws: ProviderError.unavailable(
                provider: provider.locationID,
                reason: "gone"
            )
        ) {
            _ = try await provider.currentState(of: missing)
        }
    }

    @Test func canonicalContainmentRejectsSymlinkEscapes() async throws {
        let world = try makeRoot("containment")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let outside = world.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(
            to: outside.appendingPathComponent("Secret.txt")
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Escape").path,
            withDestinationPath: outside.path
        )

        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let snapshot = await provider.scan(.entireDrive)
        #expect(snapshot.observations.byPath["/Escape"]?.kind == .symlink(target: outside.path))
        #expect(snapshot.observations.byPath["/Escape/Secret.txt"] == nil)

        let escaped = ItemObservation(
            location: provider.locationID,
            path: "/Escape/Secret.txt",
            kind: .file
        )
        await #expect(
            throws: ProviderError.itemUnavailable(
                provider: provider.locationID,
                path: escaped.path
            )
        ) {
            _ = try await provider.currentState(of: escaped)
        }
        let staging = world.appendingPathComponent("escaped-staging")
        await #expect(throws: ProviderError.self) {
            try await provider.fetch(escaped, to: staging)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        let escapedScope = await provider.scan(
            .selectedFolder(path: "/Escape")
        )
        guard case .incomplete = escapedScope.status else {
            Issue.record("Escaped scope was reported as \(escapedScope.status).")
            return
        }
        #expect(escapedScope.observations.all.isEmpty)
    }

    @Test func placeholderFetchRefusesWithoutCreatingStagingOutput() async throws {
        let root = try makeRoot("placeholder-fetch")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("stub".utf8).write(
            to: root.appendingPathComponent("Placeholder.pages")
        )
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let placeholder = ItemObservation(
            location: provider.locationID,
            path: "/Placeholder.pages",
            kind: .file,
            isPlaceholder: true
        )
        let staging = root.appendingPathComponent("staging")
        await #expect(
            throws: ProviderError.placeholderOnly(
                provider: provider.locationID,
                path: placeholder.path
            )
        ) {
            try await provider.fetch(placeholder, to: staging)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func fetchDeadlineAndFailureNeverMasqueradeAsItemSuccess() async throws {
        let root = try makeRoot("fetch-deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.txt")
        try Data("source".utf8).write(to: source)
        let inspector = ScriptedVolumeInspector()
        let timedProvider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(ioNanoseconds: 0)
        )
        let observation = try #require(
            (await timedProvider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        let timedStaging = root.appendingPathComponent("timed-staging")
        await #expect(
            throws: ProviderError.mutationDeadlineExpiredBeforeStart(
                provider: timedProvider.locationID,
                path: observation.path
            )
        ) {
            try await timedProvider.fetch(observation, to: timedStaging)
        }
        #expect(!FileManager.default.fileExists(atPath: timedStaging.path))

        let failureInspector = ScriptedVolumeInspector()
        let failureProvider = await makeProvider(
            root: root,
            inspector: failureInspector
        )
        let failureObservation = try #require(
            (await failureProvider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        await failureInspector.enqueueMountStates([
            .mounted,
            .notMounted(detail: "gone during copy"),
        ])
        let invalidStaging = root
            .appendingPathComponent("MissingParent")
            .appendingPathComponent("staging")
        await #expect(
            throws: ProviderError.unavailable(
                provider: failureProvider.locationID,
                reason: "gone during copy"
            )
        ) {
            try await failureProvider.fetch(
                failureObservation,
                to: invalidStaging
            )
        }
    }

    @Test func postStartFetchTimeoutRetainsLateStagingWrite() async throws {
        let root = try makeRoot("fetch-late-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.txt")
        let contents = Data("owned late fetch".utf8)
        try contents.write(to: source)
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(ioNanoseconds: 1, clock: clock),
            mutationHook: hook
        )
        await clock.waitUntilIdle()
        let observation = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )
        let staging = root.appendingPathComponent("Late.stage")
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a5000000-0000-0000-0000-000000000001")!,
            operationID: OperationID(
                UUID(uuidString: "a5000000-0000-0000-0000-000000000002")!
            )
        )

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await provider.fetch(observation, to: staging)
                    }
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected fetch error: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await call.value)
        #expect(receipt.kind == .fetch)
        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("Scan raced an indeterminate fetch.")
            hook.release()
            return
        }

        hook.release()
        await waitForProviderMutationQuiescence(provider, receipt: receipt)
        #expect(try Data(contentsOf: staging) == contents)
        guard case let .claimed(claim) = await provider
            .beginIndeterminateMutationRecovery(for: receipt) else {
            Issue.record("Fetch recovery could not claim the receipt.")
            return
        }
        await provider.finishIndeterminateMutationRecovery(claim)
        guard case .complete = (await provider.scan(.entireDrive)).status else {
            Issue.record("Provider stayed blocked after fetch reconciliation.")
            return
        }
    }

    @Test func deadlineRaceFailsClosedAndIgnoresLateCompletion() async {
        let failedClockOperation = ControlledDeadlineOperation()
        let failedClockResult = await withProviderDeadline(
            nanoseconds: 1,
            clock: FailingProviderDeadlineClock()
        ) {
            await failedClockOperation.run()
        }
        guard case .timedOut = failedClockResult else {
            Issue.record("Clock failure did not resolve as a timeout.")
            return
        }
        await failedClockOperation.finish(with: 1)

        let clock = ControlledProviderDeadlineClock()
        let operation = ControlledDeadlineOperation()
        let race = Task {
            await withProviderDeadline(nanoseconds: 1, clock: clock) {
                await operation.run()
            }
        }
        while true {
            let clockWaiting = await clock.isWaiting()
            let operationWaiting = await operation.isWaiting()
            if clockWaiting && operationWaiting {
                break
            }
            await Task.yield()
        }
        await clock.fire()
        let result = await race.value
        guard case .timedOut = result else {
            Issue.record("Controlled deadline did not win the race.")
            return
        }

        await operation.finish(with: 42)
        await Task.yield()
        guard case .timedOut = result else {
            Issue.record("Late completion changed the deadline result.")
            return
        }
    }

    @Test func unreadableSubdirectoryMakesScanIncomplete() async throws {
        let root = try makeRoot("unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: blocked.appendingPathComponent("Secret.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: blocked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: blocked.path
            )
        }

        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let snapshot = await provider.scan(.entireDrive)
        guard case .incomplete = snapshot.status else {
            Issue.record("Unreadable directory was reported as \(snapshot.status).")
            return
        }
    }

    @Test func storeIsAtomicIdempotentAndRejectsVersionDrift() async throws {
        let world = try makeRoot("store")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = world.appendingPathComponent("staging")
        try Data("first".utf8).write(to: staging)
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )

        let stored = try await provider.store(
            from: staging,
            at: "/Document.txt",
            options: StoreOptions(overwrite: .neverOverwrite)
        )
        #expect(stored.path == "/Document.txt")
        #expect(
            try Data(contentsOf: root.appendingPathComponent("Document.txt"))
                == Data("first".utf8)
        )
        #expect(
            try await provider.store(
                from: staging,
                at: "/Document.txt",
                options: StoreOptions(overwrite: .neverOverwrite)
            ) == stored
        )

        try Data("external drift".utf8).write(
            to: root.appendingPathComponent("Document.txt")
        )
        await #expect(
            throws: ProviderError.preconditionFailed(
                provider: provider.locationID,
                path: "/Document.txt"
            )
        ) {
            _ = try await provider.store(
                from: staging,
                at: "/Document.txt",
                options: StoreOptions(overwrite: .ifVersionMatches(stored.version))
            )
        }
        #expect(
            try Data(contentsOf: root.appendingPathComponent("Document.txt"))
                == Data("external drift".utf8)
        )
    }

    @Test func caseInsensitiveOccupancyBlocksCaseVariantMutations() async throws {
        let world = try makeRoot("case-fold")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(
            to: root.appendingPathComponent("README.txt")
        )
        try Data("source".utf8).write(
            to: root.appendingPathComponent("Source.txt")
        )
        let staging = world.appendingPathComponent("staging")
        try Data("new".utf8).write(to: staging)
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: false,
                    supportsNativeTrash: false,
                    isNetwork: false
                )
            )
        )

        await #expect(
            throws: ProviderError.itemAlreadyExists(
                provider: provider.locationID,
                path: "/readme.TXT"
            )
        ) {
            _ = try await provider.store(
                from: staging,
                at: "/readme.TXT",
                options: StoreOptions(overwrite: .neverOverwrite)
            )
        }
        let source = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        await #expect(
            throws: ProviderError.itemAlreadyExists(
                provider: provider.locationID,
                path: "/readme.TXT"
            )
        ) {
            _ = try await provider.relocate(source, to: "/readme.TXT")
        }
        #expect(
            try Data(contentsOf: root.appendingPathComponent("README.txt"))
                == Data("occupied".utf8)
        )
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Source.txt").path))
    }

    @Test func crossVolumeRelocateCopiesVerifiesAndTrashesSource() async throws {
        let world = try makeRoot("cross-volume")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Source.txt")
        let contents = Data("preserved across volumes".utf8)
        try contents.write(to: sourceURL)
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("source-volume", at: sourceURL)
        await inspector.setVolumeIdentity("destination-volume", at: destinationFolder)
        let provider = await makeProvider(root: root, inspector: inspector)
        let source = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )

        let moved = try await provider.relocate(
            source,
            to: "/Destination/Moved.txt"
        )
        #expect(moved.path == "/Destination/Moved.txt")
        #expect(
            try Data(contentsOf: destinationFolder.appendingPathComponent("Moved.txt"))
                == contents
        )
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        let recoveryURL = try #require(await provider.recoveryURL(for: source.path))
        #expect(try Data(contentsOf: recoveryURL) == contents)
    }

    @Test func crossVolumePartialCopyIsQuarantinedAndRetryCanProceed() async throws {
        let world = try makeRoot("cross-volume-partial")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Source.txt")
        let contents = Data("complete source".utf8)
        try contents.write(to: sourceURL)
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("source-volume", at: sourceURL)
        await inspector.setVolumeIdentity("destination-volume", at: destinationFolder)
        let relocation = PartialCopyOnceRelocationPerformer()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector,
            relocation: relocation
        )
        let source = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        let destinationPath: SyncPath = "/Destination/Moved.txt"

        await #expect(
            throws: ProviderError.itemUnavailable(
                provider: provider.locationID,
                path: source.path
            )
        ) {
            _ = try await provider.relocate(source, to: destinationPath)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationFolder.appendingPathComponent("Moved.txt").path
            )
        )
        let partialRecovery = try #require(
            await provider.recoveryURL(for: destinationPath)
        )
        #expect(try Data(contentsOf: partialRecovery) == Data("partial".utf8))

        let moved = try await provider.relocate(source, to: destinationPath)
        #expect(moved.path == destinationPath)
        #expect(
            try Data(contentsOf: destinationFolder.appendingPathComponent("Moved.txt"))
                == contents
        )
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func crossVolumeTrashFailureQuarantinesCopyAndRetryCanProceed() async throws {
        let world = try makeRoot("cross-volume-trash-failure")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Source.txt")
        let contents = Data("source survives failed trash".utf8)
        try contents.write(to: sourceURL)
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("source-volume", at: sourceURL)
        await inspector.setVolumeIdentity("destination-volume", at: destinationFolder)
        let relocation = TrashFailureOnceRelocationPerformer()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector,
            relocation: relocation
        )
        let source = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        let destinationPath: SyncPath = "/Destination/Moved.txt"

        await #expect(
            throws: ProviderError.itemUnavailable(
                provider: provider.locationID,
                path: source.path
            )
        ) {
            _ = try await provider.relocate(source, to: destinationPath)
        }
        #expect(try Data(contentsOf: sourceURL) == contents)
        #expect(
            !FileManager.default.fileExists(
                atPath: destinationFolder.appendingPathComponent("Moved.txt").path
            )
        )
        let copiedRecovery = try #require(
            await provider.recoveryURL(for: destinationPath)
        )
        #expect(try Data(contentsOf: copiedRecovery) == contents)

        let moved = try await provider.relocate(source, to: destinationPath)
        #expect(moved.path == destinationPath)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func quarantineUsesInjectedTimestampAndNumericCollisions() async throws {
        let root = try makeRoot("quarantine-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Document.txt")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(now: { fixedDate })
        )
        let repeatedContents = Data("same".utf8)
        try repeatedContents.write(to: sourceURL)
        let repeatedModifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try FileManager.default.setAttributes(
            [.modificationDate: repeatedModifiedAt],
            ofItemAtPath: sourceURL.path
        )
        let first = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Document.txt"]
        )
        try await provider.trash(first)
        let firstRecovery = try #require(
            await provider.recoveryURL(for: first.path)
        )

        try repeatedContents.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: repeatedModifiedAt],
            ofItemAtPath: sourceURL.path
        )
        let second = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Document.txt"]
        )
        try await provider.trash(second)
        let secondRecovery = try #require(
            await provider.recoveryURL(for: second.path)
        )

        #expect(firstRecovery.lastPathComponent == "Document.txt")
        #expect(secondRecovery.lastPathComponent == "Document 2.txt")
        #expect(firstRecovery.deletingLastPathComponent() == secondRecovery.deletingLastPathComponent())
        #expect(try Data(contentsOf: firstRecovery) == repeatedContents)
        #expect(try Data(contentsOf: secondRecovery) == repeatedContents)
    }

    @Test func quarantineReceiptSurvivesProviderReconstruction() async throws {
        let root = try makeRoot("persistent-trash-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = localLocation()
        let sourceURL = root.appendingPathComponent("Recoverable.txt")
        let contents = Data("recover after provider restart".utf8)
        try contents.write(to: sourceURL)
        let firstProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector()
        )
        let original = try #require(
            (await firstProvider.scan(.entireDrive))
                .observations.byPath["/Recoverable.txt"]
        )
        try await firstProvider.trash(original)
        let recoveryURL = try #require(
            await firstProvider.recoveryURL(for: original.path)
        )

        let restartedProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector()
        )
        #expect(await restartedProvider.recoveryURL(for: original.path) == recoveryURL)
        let recovered = try await restartedProvider.currentState(of: original)
        #expect(recovered.isTrashed)
        #expect(recovered.path == original.path)
        #expect(recovered.version.revisionToken == original.version.revisionToken)
        try await restartedProvider.trash(original)
        #expect(try Data(contentsOf: recoveryURL) == contents)
    }

    @Test func pendingTrashIntentRecoversAfterProviderReconstruction() async throws {
        let root = try makeRoot("persistent-trash-journal-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = SyncLocation(
            id: LocationID(rawValue: UUID(uuidString: "aa000000-0000-0000-0000-000000000001")!),
            kind: .localFolder,
            configuration: [
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                    "scripted-volume",
            ]
        )
        let sourceURL = root.appendingPathComponent("Journaled.txt")
        try Data("journal recovery".utf8).write(to: sourceURL)
        let firstProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector()
        )
        let original = try #require(
            (await firstProvider.scan(.entireDrive))
                .observations.byPath["/Journaled.txt"]
        )
        let operationID = OperationID(
            UUID(uuidString: "aa000000-0000-0000-0000-000000000002")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .trash(itemRef: ItemRef(original)),
            precondition: .versionMatches(original.version)
        )
        let syncSetID = UUID(uuidString: "aa000000-0000-0000-0000-000000000003")!
        let runID = UUID(uuidString: "aa000000-0000-0000-0000-000000000004")!
        let engineRoot = root
            .appendingPathComponent(".aetherloom", isDirectory: true)
            .appendingPathComponent("recovery-test", isDirectory: true)
        let firstStores = EngineStores(
            baseRecords: try FileBaseRecordStore(rootURL: engineRoot.appendingPathComponent("records")),
            journal: try FileRunJournalStore(rootURL: engineRoot.appendingPathComponent("journal")),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
        try await firstStores.journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "pending-local-trash")
        )
        try await firstStores.journal.append(.intent(operation), runID: runID)

        try await firstProvider.trash(original)
        let recoveryURL = try #require(
            await firstProvider.recoveryURL(for: original.path)
        )
        let mutationReceipt = ProviderMutationReceipt(
            id: UUID(uuidString: "aa000000-0000-0000-0000-000000000006")!,
            provider: location.id,
            kind: .trash,
            affectedPaths: [original.path],
            startedAt: Date(timeIntervalSince1970: 1_800_000_050),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            ),
            rootIdentity: mutationRootIdentity(for: root)
        )
        try await firstStores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: mutationReceipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_051)
            ),
            runID: runID
        )
        let recoveryHook = RecordingLocalMutationHook()
        let restartedProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: recoveryHook
        )
        let restartedStores = EngineStores(
            baseRecords: try FileBaseRecordStore(rootURL: engineRoot.appendingPathComponent("records")),
            journal: try FileRunJournalStore(rootURL: engineRoot.appendingPathComponent("journal")),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
        let replay = try #require(
            try await restartedStores.journal.unfinishedRun(for: syncSetID)
        )
        let recoveredAt = Date(timeIntervalSince1970: 1_800_000_100)
        let report = try await RunRecovery(
            providers: [location.id: restartedProvider],
            stores: restartedStores,
            environment: ExecutionEnvironment(
                now: { recoveredAt },
                makeID: {
                    UUID(uuidString: "aa000000-0000-0000-0000-000000000005")!
                }
            )
        ).recover(replay)

        #expect(report.reconciledOperations == [operationID])
        let records = try await restartedStores.baseRecords.records(for: syncSetID)
        #expect(records.isEmpty)
        #expect(recoveryHook.kinds().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: recoveryURL) == Data("journal recovery".utf8))
        #expect(try await restartedStores.journal.unfinishedRun(for: syncSetID) == nil)
    }

    @Test func quarantineRejectsInternalSymlinkEscape() async throws {
        let world = try makeRoot("quarantine-containment")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let outside = world.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".aetherloom").path,
            withDestinationPath: outside.path
        )
        let sourceURL = root.appendingPathComponent("Keep.txt")
        try Data("keep".utf8).write(to: sourceURL)
        let provider = await makeProvider(
            root: root,
            inspector: ScriptedVolumeInspector()
        )
        let observation = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Keep.txt"]
        )

        await #expect(
            throws: ProviderError.itemUnavailable(
                provider: provider.locationID,
                path: observation.path
            )
        ) {
            try await provider.trash(observation)
        }
        #expect(try Data(contentsOf: sourceURL) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func staleNativeTrashCapabilityFallsBackToQuarantine() async throws {
        let root = try makeRoot("native-trash-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Fallback.txt")
        let contents = Data("fallback recovery".utf8)
        try contents.write(to: sourceURL)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: false,
                    supportsNativeTrash: true,
                    isNetwork: false
                )
            ),
            nativeTrash: AlwaysFailingNativeTrashPerformer()
        )
        #expect(provider.capabilities.hasNativeTrash)
        let observation = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Fallback.txt"]
        )

        try await provider.trash(observation)
        let recoveryURL = try #require(
            await provider.recoveryURL(for: observation.path)
        )
        #expect(recoveryURL.path.hasPrefix(root.path + "/.aetherloom/trash/"))
        #expect(try Data(contentsOf: recoveryURL) == contents)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func preparedNativeTrashReceiptNeverProvesLaterAbsence() async throws {
        let root = try makeRoot("prepared-native-trash-receipt")
        let outside = try makeRoot("prepared-native-trash-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let sourceURL = root.appendingPathComponent("Prepared.txt")
        try Data("prepared only".utf8).write(to: sourceURL)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: true,
                    supportsNativeTrash: true,
                    isNetwork: false
                )
            ),
            nativeTrash: FailingNativeTrashThatBlocksQuarantine(
                root: root,
                outside: outside
            )
        )
        let observation = try #require(
            (await provider.scan(.entireDrive)).observations.byPath[
                "/Prepared.txt"
            ]
        )

        await #expect(throws: ProviderError.self) {
            try await provider.trash(observation)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        // Simulate a later independent absence. A write-ahead-only receipt
        // must not let Aetherloom attribute that absence to its failed trash.
        try FileManager.default.removeItem(at: sourceURL)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.currentState(of: observation)
        }
    }

    @Test func preparedOnlyTrashKeepsRecoveryAndNextPreparationBlocked() async throws {
        let world = try makeRoot("prepared-trash-recovery")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let nativeRecovery = world.appendingPathComponent(
            "NativeRecovery.txt",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Prepared.txt")
        let contents = Data("prepared recovery must pause".utf8)
        try contents.write(to: sourceURL)
        let location = localLocation()
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let receiptID = UUID(
            uuidString: "a3000000-0000-0000-0000-000000000001"
        )!
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: true,
                    supportsNativeTrash: true,
                    isNetwork: false
                )
            ),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                now: { Date(timeIntervalSince1970: 1_800_000_200) },
                makeMutationID: { receiptID }
            ),
            nativeTrash: MovingNativeTrashPerformer(
                destination: nativeRecovery
            ),
            mutationHook: hook,
            trashReceiptPersistence: FailAfterFirstTrashReceiptPersister()
        )
        await clock.waitUntilIdle()
        let observation = try #require(
            (await provider.scan(.entireDrive)).observations.byPath[
                "/Prepared.txt"
            ]
        )
        await clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a3000000-0000-0000-0000-000000000003")!,
            operationID: OperationID(
                UUID(uuidString: "a3000000-0000-0000-0000-000000000004")!
            )
        )

        let mutation = Task { () -> ProviderMutationReceipt? in
            do {
                try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await provider.trash(observation)
                    }
                Issue.record("Prepared-only trash unexpectedly completed.")
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected trash result: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await mutation.value)
        hook.release()
        await waitForProviderMutationQuiescence(provider, receipt: receipt)

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: nativeRecovery.path))
        #expect(await provider.indeterminateMutationReceipt() == receipt)

        let syncSetID = UUID(
            uuidString: "a3000000-0000-0000-0000-000000000002"
        )!
        let runID = UUID(
            uuidString: "a3000000-0000-0000-0000-000000000003"
        )!
        let operationID = OperationID(
            UUID(uuidString: "a3000000-0000-0000-0000-000000000004")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .trash(itemRef: ItemRef(observation)),
            precondition: .versionMatches(observation.version)
        )
        var durableReceipt = receipt
        durableReceipt.correlation = ProviderMutationCorrelation(
            runID: runID,
            operationID: operationID
        )
        let originalRecord = BaseRecord(
            id: UUID(uuidString: "a3000000-0000-0000-0000-000000000005")!,
            syncSetID: syncSetID,
            path: observation.path,
            kind: observation.kind,
            version: observation.version,
            perLocation: [
                location.id: LocationMemory(
                    itemID: observation.itemID,
                    revisionToken: observation.version.revisionToken,
                    lastSeenAt: observation.version.modifiedAt
                ),
                .oneDrive: LocationMemory(lastSeenAt: observation.version.modifiedAt),
            ],
            lastConvergedAt: Date(timeIntervalSince1970: 1_800_000_100),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let baseRecords = InMemoryBaseRecordStore(records: [originalRecord])
        let journal = InMemoryRunJournalStore()
        let stores = EngineStores(
            baseRecords: baseRecords,
            journal: journal,
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
        try await journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "prepared-trash-recovery")
        )
        try await journal.append(.intent(operation), runID: runID)
        try await journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: durableReceipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_201)
            ),
            runID: runID
        )
        let replay = try #require(
            try await journal.unfinishedRun(for: syncSetID)
        )

        await #expect(throws: RunRecoveryError.self) {
            _ = try await RunRecovery(
                providers: [location.id: provider],
                stores: stores
            ).recover(replay)
        }
        #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
        #expect(try await baseRecords.records(for: syncSetID) == [originalRecord])
        #expect(await provider.indeterminateMutationReceipt() == receipt)

        let remoteLocation = SyncLocation(
            id: .oneDrive,
            kind: .oneDrive
        )
        let remote = FakeStorageProvider(location: remoteLocation)
        _ = await remote.putFile(
            path: observation.path,
            contents: contents,
            modifiedAt: observation.version.modifiedAt
                ?? Date(timeIntervalSince1970: 1_800_000_200)
        )
        await remote.clearCallLog()
        let syncSet = SyncSet(
            id: syncSetID,
            name: "Prepared trash recovery",
            locations: [location.id, remoteLocation.id]
        )
        let orchestrator = SyncOrchestrator(
            locations: [
                location.id: location,
                remoteLocation.id: remoteLocation,
            ],
            providers: [
                location.id: provider,
                remoteLocation.id: remote,
            ],
            stores: stores,
            stage: ContentStage(
                rootDirectory: world.appendingPathComponent("Stage"),
                byteLimit: 1_000_000
            ),
            environment: EngineEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_202) },
                makeID: {
                    UUID(
                        uuidString: "a3000000-0000-0000-0000-000000000006"
                    )!
                }
            )
        )

        await #expect(throws: RunRecoveryError.self) {
            _ = try await orchestrator.prepare(syncSet)
        }
        #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
        #expect(try await baseRecords.records(for: syncSetID) == [originalRecord])
        #expect(await provider.indeterminateMutationReceipt() == receipt)
        #expect(await remote.callLog().isEmpty)
    }

    @Test func systemQuarantineInspectionDistinguishesMissingAndPresent() throws {
        let root = try makeRoot("quarantine-artifact-inspection")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("Artifact.txt")
        let quarantine = SystemLocalQuarantinePerformer()

        guard case .missing = quarantine.artifactState(at: artifact) else {
            Issue.record("A positively missing quarantine artifact was not distinguished.")
            return
        }
        try Data("recoverable".utf8).write(to: artifact)
        guard case .present = quarantine.artifactState(at: artifact) else {
            Issue.record("A present quarantine artifact was not proven present.")
            return
        }
    }

    @Test func quarantineMoveFailureWithSourcePresentRemainsOrdinary() async throws {
        let root = try makeRoot("quarantine-source-preserved-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Preserved.txt")
        let contents = Data("source remains authoritative".utf8)
        try contents.write(to: sourceURL)
        let hook = RecordingLocalMutationHook()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            quarantine: ThrowWithoutMovingQuarantinePerformer(),
            mutationHook: hook
        )
        let observation = try #require(
            (await provider.scan(.entireDrive)).observations.byPath[
                "/Preserved.txt"
            ]
        )

        await #expect(
            throws: ProviderError.itemUnavailable(
                provider: provider.locationID,
                path: observation.path
            )
        ) {
            try await provider.trash(observation)
        }
        #expect(try Data(contentsOf: sourceURL) == contents)
        #expect(await provider.indeterminateMutationReceipt() == nil)
        guard case .complete = (await provider.scan(.entireDrive)).status else {
            Issue.record("A source-preserved quarantine failure retained a barrier.")
            return
        }
        _ = try await provider.makeFolder(at: "/FreshMutation")
        #expect(hook.kinds() == [.trash, .makeFolder])
    }

    @Test(arguments: PostMoveTrashMode.allCases)
    func postMoveUncertaintyRetainsWALAndRootBarrier(
        mode: PostMoveTrashMode
    ) async throws {
        let world = try makeRoot("post-move-uncertainty-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Uncommitted.txt")
        let contents = Data("durable trash evidence is required".utf8)
        try contents.write(to: sourceURL)

        let location = localLocation()
        let remoteLocation = SyncLocation(id: .oneDrive, kind: .oneDrive)
        let receiptID = mode.receiptID
        let mutationIDs = LockedUUIDSequence(
            [
                receiptID,
                UUID(uuidString: "a3000000-0000-0000-0000-000000000018")!,
                UUID(uuidString: "a3000000-0000-0000-0000-000000000019")!,
            ]
        )
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let nativeRecovery = world.appendingPathComponent(
            "NativeRecovery.txt",
            isDirectory: false
        )
        let reportedNativeRecovery = world.appendingPathComponent(
            "ReportedNativeRecovery.txt",
            isDirectory: false
        )
        let hiddenRoot = world.appendingPathComponent(
            "UnavailableRoot",
            isDirectory: true
        )
        let quarantineHolding = world.appendingPathComponent(
            "QuarantineHolding.txt",
            isDirectory: false
        )
        let nativeTrash: any LocalNativeTrashPerforming
        let quarantine: any LocalQuarantinePerforming
        let trashReceiptPersistence: any LocalTrashReceiptPersisting
        switch mode {
        case .nativeTrash:
            nativeTrash = MovingNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = FailAfterFirstTrashReceiptPersister()
        case .nativeTrashMoveThenThrow:
            nativeTrash = MoveThenThrowNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .nativeTrashNilResult:
            nativeTrash = MoveThenReturnNilNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .nativeTrashSourceChanged:
            nativeTrash = ChangeSourceThenThrowNativeTrashPerformer(
                holdingURL: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .nativeTrashSourceUnavailable:
            nativeTrash = HideRootThenThrowNativeTrashPerformer(
                root: root,
                hiddenRoot: hiddenRoot,
                holdingURL: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .nativeTrashArtifactMissing:
            nativeTrash = ScriptedArtifactNativeTrashPerformer(
                holdingURL: nativeRecovery,
                reportedURL: reportedNativeRecovery,
                scriptedArtifactState: .missing
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .nativeTrashArtifactUnavailable:
            nativeTrash = ScriptedArtifactNativeTrashPerformer(
                holdingURL: nativeRecovery,
                reportedURL: reportedNativeRecovery,
                scriptedArtifactState: .unavailable(
                    detail: "scripted native artifact inspection failure"
                )
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .quarantine:
            nativeTrash = MovingNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = SystemLocalQuarantinePerformer()
            trashReceiptPersistence = FailAfterFirstTrashReceiptPersister()
        case .quarantineMissingArtifact:
            nativeTrash = MovingNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = MoveThenThrowQuarantinePerformer(
                holdingURL: quarantineHolding,
                scriptedArtifactState: .missing
            )
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        case .quarantineUnavailableArtifact:
            nativeTrash = MovingNativeTrashPerformer(
                destination: nativeRecovery
            )
            quarantine = MoveThenThrowQuarantinePerformer(
                holdingURL: quarantineHolding,
                scriptedArtifactState: .unavailable(
                    detail: "scripted inspection failure"
                )
            )
            trashReceiptPersistence = AtomicLocalTrashReceiptPersister()
        }
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: true,
                    supportsNativeTrash: mode.usesNativeTrash,
                    isNetwork: false
                )
            ),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                now: { Date(timeIntervalSince1970: 1_800_000_210) },
                makeMutationID: { mutationIDs.next() }
            ),
            nativeTrash: nativeTrash,
            quarantine: quarantine,
            mutationHook: hook,
            trashReceiptPersistence: trashReceiptPersistence
        )
        await clock.waitUntilIdle()
        let observation = try #require(
            (await provider.scan(.entireDrive)).observations.byPath[
                "/Uncommitted.txt"
            ]
        )
        await clock.waitUntilIdle()

        let operationID = OperationID(
            UUID(uuidString: "a3000000-0000-0000-0000-000000000013")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .trash(itemRef: ItemRef(observation)),
            precondition: .versionMatches(observation.version)
        )
        let syncSetID = UUID(
            uuidString: "a3000000-0000-0000-0000-000000000014"
        )!
        let plan = SyncPlan(
            syncSetID: syncSetID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_210),
            decisions: [
                ItemDecision(
                    id: UUID(
                        uuidString: "a3000000-0000-0000-0000-000000000015"
                    )!,
                    path: observation.path,
                    verdict: .propagateDeletion(
                        to: [location.id],
                        initiatedBy: remoteLocation.id
                    ),
                    operations: [operationID],
                    explanation: "Exercise post-move recovery uncertainty."
                ),
            ],
            schedule: OperationSchedule(operations: [operation]),
            gate: .clear,
            fingerprint: PlanFingerprint(
                rawValue: "post-move-uncertainty-\(mode.rawValue)"
            )
        )
        let stores = EngineStores.inMemory()
        let runID = UUID(
            uuidString: "a3000000-0000-0000-0000-000000000016"
        )!
        let execution = Task {
            try await ScheduleExecutor(
                providers: [location.id: provider],
                stores: stores,
                stage: ContentStage(
                    rootDirectory: world.appendingPathComponent("ExecutionStage"),
                    byteLimit: 1_000_000
                ),
                environment: ExecutionEnvironment(
                    now: { Date(timeIntervalSince1970: 1_800_000_211) }
                )
            ).execute(plan, runID: runID)
        }
        await hook.waitUntilStarted(count: 1)
        let queuedPath: SyncPath = "/QueuedMustStayBlocked"
        let queuedMutation = Task { () -> ProviderError? in
            do {
                _ = try await provider.makeFolder(at: queuedPath)
                Issue.record("A queued mutation crossed post-move uncertainty.")
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                Issue.record("Unexpected queued mutation error: \(error)")
                return nil
            }
        }
        await clock.waitUntilSleeping(nanoseconds: 1, count: 2)
        hook.release()
        let summary = try await execution.value
        let queuedError = await queuedMutation.value
        #expect(
            queuedError == .mutationDeadlineExpiredBeforeStart(
                provider: location.id,
                path: queuedPath
            )
        )
        await clock.waitUntilIdle()

        let replay = try #require(
            try await stores.journal.unfinishedRun(for: syncSetID)
        )
        let receipt = try #require(
            replay.indeterminateReceiptsByOperation[operationID]
        )
        #expect(receipt.id == receiptID)
        #expect(
            receipt.correlation == ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            )
        )
        #expect(
            summary.outcome == .mutationIndeterminate(
                location: location.id,
                path: observation.path,
                receiptID: receiptID
            )
        )
        #expect(summary.appliedOperations.isEmpty)
        #expect(summary.failedOperations.isEmpty)
        #expect(replay.pendingOperationIDs == [operationID])
        #expect(!replay.events.contains { $0.isRunFinished })
        #expect(!replay.events.contains { $0.resultOperationID == operationID })
        guard case .quiescent(.failed) = await provider
            .indeterminateMutationState(for: receipt) else {
            Issue.record("Post-move uncertainty did not retain a quiescent owner.")
            return
        }
        #expect(await provider.indeterminateMutationReceipt() == receipt)
        if mode == .nativeTrashSourceChanged {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: sourceURL.path,
                    isDirectory: &isDirectory
                )
            )
            #expect(isDirectory.boolValue)
        } else {
            #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        }
        switch mode {
        case .nativeTrashMoveThenThrow,
             .nativeTrashNilResult,
             .nativeTrashSourceChanged,
             .nativeTrashSourceUnavailable,
             .nativeTrashArtifactMissing,
             .nativeTrashArtifactUnavailable:
            #expect(try Data(contentsOf: nativeRecovery) == contents)
        case .quarantineMissingArtifact, .quarantineUnavailableArtifact:
            #expect(try Data(contentsOf: quarantineHolding) == contents)
        case .nativeTrash, .quarantine:
            break
        }
        #expect(hook.kinds() == [.trash])
        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("A fresh scan crossed the unresolved trash barrier.")
            return
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.makeFolder(at: "/MustStayBlocked")
        }
        #expect(hook.kinds() == [.trash])

        let remote = FakeStorageProvider(location: remoteLocation)
        _ = await remote.putFile(
            path: observation.path,
            contents: contents,
            modifiedAt: observation.version.modifiedAt
                ?? Date(timeIntervalSince1970: 1_800_000_210)
        )
        await remote.clearCallLog()
        let orchestrator = SyncOrchestrator(
            locations: [
                location.id: location,
                remoteLocation.id: remoteLocation,
            ],
            providers: [
                location.id: provider,
                remoteLocation.id: remote,
            ],
            stores: stores,
            stage: ContentStage(
                rootDirectory: world.appendingPathComponent("PreparationStage"),
                byteLimit: 1_000_000
            ),
            environment: EngineEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_212) },
                makeID: {
                    UUID(
                        uuidString: "a3000000-0000-0000-0000-000000000017"
                    )!
                }
            )
        )
        let syncSet = SyncSet(
            id: syncSetID,
            name: "Post-move receipt uncertainty",
            locations: [location.id, remoteLocation.id]
        )

        do {
            _ = try await orchestrator.prepare(syncSet)
            Issue.record("Fresh preparation crossed the unresolved trash barrier.")
        } catch is RunRecoveryError {
            // The unfinished WAL and prepared-only receipt must stop preparation.
        } catch {
            Issue.record("Unexpected preparation error: \(error)")
        }
        #expect(try await stores.journal.unfinishedRun(for: syncSetID) != nil)
        #expect(await provider.indeterminateMutationReceipt() == receipt)
        #expect(await remote.callLog().isEmpty)
        #expect(hook.kinds() == [.trash])
    }

    @Test(arguments: PostPhysicalCommitMode.allCases)
    func postPhysicalCommitFailureRetainsWALAndRootBarrier(
        mode: PostPhysicalCommitMode
    ) async throws {
        let world = try makeRoot("post-physical-commit-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let unrelatedURL = root.appendingPathComponent("Unrelated.txt")
        let unrelatedContents = Data("must stay untouched".utf8)
        try unrelatedContents.write(to: unrelatedURL)
        let inspector = ScriptedVolumeInspector()

        let targetPath: SyncPath = mode.targetPath
        let targetURL = root.appendingPathComponent(
            String(targetPath.rawValue.dropFirst())
        )
        let originalContents = Data("original destination".utf8)
        if mode == .replacementStore {
            try originalContents.write(to: targetURL)
        } else if mode.isRelocate {
            try Data("relocate me".utf8).write(
                to: root.appendingPathComponent("RelocateSource.txt")
            )
        }
        if mode.isCrossVolume {
            let destinationFolder = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
            await inspector.setVolumeIdentity(
                "source-volume",
                at: root.appendingPathComponent("RelocateSource.txt")
            )
            await inspector.setVolumeIdentity(
                "destination-volume",
                at: destinationFolder
            )
        }

        let location = localLocation()
        let receiptID = mode.receiptID
        let mutationIDs = LockedUUIDSequence(
            [
                receiptID,
                UUID(uuidString: "a4000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "a4000000-0000-0000-0000-000000000012")!,
            ]
        )
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook(
            failsAfterPhysicalCommitCall: mode.physicalCommitFailureCall
        )
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                now: { Date(timeIntervalSince1970: 1_800_000_220) },
                makeMutationID: { mutationIDs.next() }
            ),
            mutationHook: hook
        )
        await clock.waitUntilIdle()
        let initialSnapshot = await provider.scan(.entireDrive)
        await clock.waitUntilIdle()

        let remote = FakeStorageProvider(locationID: .oneDrive)
        let operationID = OperationID(
            UUID(uuidString: "a4000000-0000-0000-0000-000000000002")!
        )
        let operation: AetherloomCore.Operation
        switch mode {
        case .newStore:
            let source = await remote.putFile(
                path: targetPath,
                contents: Data("new store".utf8),
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_220)
            )
            operation = AetherloomCore.Operation(
                id: operationID,
                location: location.id,
                kind: .transfer(
                    content: ContentRef(source),
                    to: targetPath,
                    overwrite: .neverOverwrite
                ),
                precondition: .pathAbsent
            )
        case .replacementStore:
            let existing = try #require(
                initialSnapshot.observations.byPath[targetPath]
            )
            let source = await remote.putFile(
                path: "/ReplacementSource.txt",
                contents: Data("replacement store".utf8),
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_221)
            )
            operation = AetherloomCore.Operation(
                id: operationID,
                location: location.id,
                kind: .transfer(
                    content: ContentRef(source),
                    to: targetPath,
                    overwrite: .ifVersionMatches(existing.version)
                ),
                precondition: .versionMatches(existing.version)
            )
        case .makeFolder:
            operation = AetherloomCore.Operation(
                id: operationID,
                location: location.id,
                kind: .makeFolder(at: targetPath),
                precondition: .pathAbsent
            )
        case .sameVolumeRelocate,
             .crossVolumePostCopy,
             .crossVolumePostTrash:
            let source = try #require(
                initialSnapshot.observations.byPath["/RelocateSource.txt"]
            )
            operation = AetherloomCore.Operation(
                id: operationID,
                location: location.id,
                kind: .relocate(itemRef: ItemRef(source), to: targetPath),
                precondition: .versionMatches(source.version)
            )
        }

        let syncSetID = UUID(
            uuidString: "a4000000-0000-0000-0000-000000000003"
        )!
        let runID = UUID(
            uuidString: "a4000000-0000-0000-0000-000000000004"
        )!
        let plan = SyncPlan(
            syncSetID: syncSetID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_220),
            decisions: [],
            schedule: OperationSchedule(operations: [operation]),
            gate: .clear,
            fingerprint: PlanFingerprint(
                rawValue: "post-physical-commit-\(mode.rawValue)"
            )
        )
        let stores = EngineStores.inMemory()
        let execution = Task {
            try await ScheduleExecutor(
                providers: [
                    location.id: provider,
                    .oneDrive: remote,
                ],
                stores: stores,
                stage: ContentStage(
                    rootDirectory: world.appendingPathComponent("ExecutionStage"),
                    byteLimit: 1_000_000
                ),
                environment: ExecutionEnvironment(
                    now: { Date(timeIntervalSince1970: 1_800_000_221) }
                )
            ).execute(plan, runID: runID)
        }
        await hook.waitUntilStarted(count: 1)
        let queuedPath: SyncPath = "/QueuedAfterCommit"
        let queuedMutation = Task { () -> ProviderError? in
            do {
                _ = try await provider.makeFolder(at: queuedPath)
                Issue.record("Queued work crossed a post-commit barrier.")
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                Issue.record("Unexpected queued mutation error: \(error)")
                return nil
            }
        }
        await clock.waitUntilSleeping(nanoseconds: 1, count: 2)
        hook.release()

        let summary = try await execution.value
        let queuedError = await queuedMutation.value
        #expect(
            queuedError == .mutationDeadlineExpiredBeforeStart(
                provider: location.id,
                path: queuedPath
            )
        )
        await clock.waitUntilIdle()
        let replay = try #require(
            try await stores.journal.unfinishedRun(for: syncSetID)
        )
        let receipt = try #require(
            replay.indeterminateReceiptsByOperation[operationID]
        )
        #expect(receipt.id == receiptID)
        #expect(receipt.provider == location.id)
        #expect(receipt.kind == mode.expectedMutationKind)
        #expect(
            receipt.correlation == ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            )
        )
        if mode.isRelocate {
            #expect(
                receipt.affectedPaths == ["/RelocateSource.txt", targetPath]
            )
        }
        #expect(
            summary.outcome == .mutationIndeterminate(
                location: location.id,
                path: receipt.affectedPaths[0],
                receiptID: receiptID
            )
        )
        #expect(summary.appliedOperations.isEmpty)
        #expect(summary.failedOperations.isEmpty)
        #expect(replay.pendingOperationIDs == [operationID])
        #expect(!replay.events.contains { $0.isRunFinished })
        #expect(!replay.events.contains { $0.resultOperationID == operationID })
        guard case .quiescent(.failed) = await provider
            .indeterminateMutationState(for: receipt) else {
            Issue.record("Post-commit uncertainty released its root owner.")
            return
        }
        #expect(await provider.indeterminateMutationReceipt() == receipt)
        #expect(try Data(contentsOf: unrelatedURL) == unrelatedContents)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    String(queuedPath.rawValue.dropFirst())
                ).path
            )
        )

        switch mode {
        case .newStore:
            #expect(try Data(contentsOf: targetURL) == Data("new store".utf8))
        case .replacementStore:
            #expect(
                try Data(contentsOf: targetURL)
                    == Data("replacement store".utf8)
            )
        case .makeFolder:
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: targetURL.path,
                    isDirectory: &isDirectory
                )
            )
            #expect(isDirectory.boolValue)
        case .sameVolumeRelocate:
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("RelocateSource.txt").path
                )
            )
            #expect(try Data(contentsOf: targetURL) == Data("relocate me".utf8))
        case .crossVolumePostCopy:
            #expect(
                try Data(
                    contentsOf: root.appendingPathComponent("RelocateSource.txt")
                ) == Data("relocate me".utf8)
            )
            #expect(try Data(contentsOf: targetURL) == Data("relocate me".utf8))
        case .crossVolumePostTrash:
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("RelocateSource.txt").path
                )
            )
            #expect(try Data(contentsOf: targetURL) == Data("relocate me".utf8))
        }

        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("A scan crossed unresolved post-commit ownership.")
            return
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.makeFolder(at: "/FreshAfterCommit")
        }
        #expect(hook.kinds().count == 1)
        #expect(try await stores.journal.unfinishedRun(for: syncSetID) != nil)

        if mode.isCrossVolume {
            await inspector.setResponsiveness(
                .unreachable(detail: "Cross-volume recovery truth unavailable.")
            )
            await remote.clearCallLog()
            let remoteLocation = SyncLocation(id: .oneDrive, kind: .oneDrive)
            let orchestrator = SyncOrchestrator(
                locations: [
                    location.id: location,
                    remoteLocation.id: remoteLocation,
                ],
                providers: [
                    location.id: provider,
                    remoteLocation.id: remote,
                ],
                stores: stores,
                stage: ContentStage(
                    rootDirectory: world.appendingPathComponent("PreparationStage"),
                    byteLimit: 1_000_000
                ),
                environment: EngineEnvironment(
                    now: { Date(timeIntervalSince1970: 1_800_000_222) },
                    makeID: {
                        UUID(
                            uuidString: "a4000000-0000-0000-0000-000000000013"
                        )!
                    }
                )
            )
            let syncSet = SyncSet(
                id: syncSetID,
                name: "Cross-volume post-commit uncertainty",
                locations: [location.id, remoteLocation.id]
            )
            do {
                _ = try await orchestrator.prepare(syncSet)
                Issue.record(
                    "Preparation crossed unavailable cross-volume recovery truth."
                )
            } catch is RunRecoveryError {
                // Recovery must keep the WAL and owner until both endpoints
                // become positively inspectable.
            } catch {
                Issue.record("Unexpected preparation error: \(error)")
            }
            #expect(try await stores.journal.unfinishedRun(for: syncSetID) != nil)
            #expect(await provider.indeterminateMutationReceipt() == receipt)
            #expect(await remote.callLog().isEmpty)
        }
    }

    @Test(arguments: CrossVolumeCopyFailureMode.allCases)
    func crossVolumeCopyFailureRetainsOwnershipOnlyWhenTruthIsAmbiguous(
        mode: CrossVolumeCopyFailureMode
    ) async throws {
        let world = try makeRoot("cross-volume-copy-failure-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let destinationFolder = root.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Source.txt")
        let destinationURL = destinationFolder.appendingPathComponent("Moved.txt")
        let contents = Data("copy failure must remain attributable".utf8)
        try contents.write(to: sourceURL)
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("source-volume", at: sourceURL)
        await inspector.setVolumeIdentity(
            "destination-volume",
            at: destinationFolder
        )
        let location = localLocation()
        let mutationIDs = LockedUUIDSequence(
            [
                mode.receiptID,
                UUID(uuidString: "a6000000-0000-0000-0000-000000000024")!,
            ]
        )
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(
                now: { Date(timeIntervalSince1970: 1_800_000_230) },
                makeMutationID: { mutationIDs.next() }
            ),
            relocation: ScriptedCrossVolumeCopyFailurePerformer(
                mode: mode,
                destination: destinationURL
            ),
            registry: LocalRootIORegistry()
        )
        let source = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )
        let destinationPath: SyncPath = "/Destination/Moved.txt"
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a6000000-0000-0000-0000-000000000001")!,
            operationID: OperationID(
                UUID(uuidString: "a6000000-0000-0000-0000-000000000002")!
            )
        )
        let caughtError: ProviderError?
        do {
            _ = try await ProviderMutationExecutionContext.$correlation
                .withValue(correlation) {
                    try await provider.relocate(source, to: destinationPath)
                }
            Issue.record("The scripted cross-volume copy failure succeeded.")
            caughtError = nil
        } catch let providerError as ProviderError {
            caughtError = providerError
        } catch {
            Issue.record("Unexpected cross-volume copy error: \(error)")
            caughtError = nil
        }

        #expect(try Data(contentsOf: sourceURL) == contents)
        switch mode {
        case .noMutation:
            #expect(
                caughtError == .itemUnavailable(
                    provider: location.id,
                    path: source.path
                )
            )
            #expect(await provider.indeterminateMutationReceipt() == nil)
            #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
            guard case .complete = (await provider.scan(.entireDrive)).status else {
                Issue.record("A proven no-op copy retained false ownership.")
                return
            }
            _ = try await provider.makeFolder(at: "/AfterProvenNoMutation")

        case .destinationInspectionUnavailable,
             .cleanupArtifactInspectionUnavailable:
            guard case let .mutationIndeterminate(receipt)? = caughtError else {
                Issue.record("Ambiguous copy failure did not retain its receipt.")
                return
            }
            #expect(receipt.id == mode.receiptID)
            #expect(receipt.provider == location.id)
            #expect(receipt.kind == .relocate)
            #expect(receipt.affectedPaths == [source.path, destinationPath])
            #expect(receipt.correlation == correlation)
            #expect(await provider.indeterminateMutationReceipt() == receipt)
            guard case .quiescent(.failed) = await provider
                .indeterminateMutationState(for: receipt) else {
                Issue.record("Ambiguous copy cleanup released root ownership.")
                return
            }
            guard case .unavailable = (await provider.scan(.entireDrive)).status else {
                Issue.record("A scan crossed ambiguous copy cleanup.")
                return
            }
            await #expect(throws: ProviderError.self) {
                _ = try await provider.makeFolder(at: "/BlockedAfterCopyFailure")
            }
        }
    }

    @Test func crossVolumePostTrashWALSurvivesRestartAndReconciles() async throws {
        let world = try makeRoot("cross-volume-durable-restart")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let destinationFolder = root.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Source.txt")
        let destinationURL = destinationFolder.appendingPathComponent("Moved.txt")
        let contents = Data("durable cross-volume relocate".utf8)
        try contents.write(to: sourceURL)
        let location = SyncLocation(
            id: LocationID(
                rawValue: UUID(
                    uuidString: "a6000000-0000-0000-0000-000000000011"
                )!
            ),
            kind: .localFolder,
            configuration: [
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                    "scripted-volume",
            ]
        )
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("source-volume", at: sourceURL)
        await inspector.setVolumeIdentity(
            "destination-volume",
            at: destinationFolder
        )
        let receiptID = UUID(
            uuidString: "a6000000-0000-0000-0000-000000000012"
        )!
        let hook = BlockingLocalMutationHook(
            failsAfterPhysicalCommitCall: 2
        )
        hook.release()
        let firstProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(
                now: { Date(timeIntervalSince1970: 1_800_000_240) },
                makeMutationID: { receiptID }
            ),
            mutationHook: hook,
            registry: LocalRootIORegistry()
        )
        let source = try #require(
            (await firstProvider.scan(.entireDrive))
                .observations.byPath["/Source.txt"]
        )
        let destinationPath: SyncPath = "/Destination/Moved.txt"
        let operationID = OperationID(
            UUID(uuidString: "a6000000-0000-0000-0000-000000000013")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .relocate(itemRef: ItemRef(source), to: destinationPath),
            precondition: .versionMatches(source.version)
        )
        let syncSetID = UUID(
            uuidString: "a6000000-0000-0000-0000-000000000014"
        )!
        let runID = UUID(
            uuidString: "a6000000-0000-0000-0000-000000000015"
        )!
        let engineRoot = world.appendingPathComponent("Engine", isDirectory: true)
        let recordsRoot = engineRoot.appendingPathComponent("Records")
        let journalRoot = engineRoot.appendingPathComponent("Journal")
        let firstStores = EngineStores(
            baseRecords: try FileBaseRecordStore(rootURL: recordsRoot),
            journal: try FileRunJournalStore(rootURL: journalRoot),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
        let plan = SyncPlan(
            syncSetID: syncSetID,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_240),
            decisions: [],
            schedule: OperationSchedule(operations: [operation]),
            gate: .clear,
            fingerprint: PlanFingerprint(rawValue: "cross-volume-durable-restart")
        )
        let summary = try await ScheduleExecutor(
            providers: [location.id: firstProvider],
            stores: firstStores,
            stage: ContentStage(
                rootDirectory: world.appendingPathComponent("ExecutionStage"),
                byteLimit: 1_000_000
            ),
            environment: ExecutionEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_241) }
            )
        ).execute(plan, runID: runID)
        #expect(
            summary.outcome == .mutationIndeterminate(
                location: location.id,
                path: source.path,
                receiptID: receiptID
            )
        )
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: destinationURL) == contents)

        let restartInspector = ScriptedVolumeInspector()
        await restartInspector.setVolumeIdentity("source-volume", at: sourceURL)
        await restartInspector.setVolumeIdentity(
            "destination-volume",
            at: destinationFolder
        )
        let recoveryHook = RecordingLocalMutationHook()
        let restartedProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: restartInspector,
            mutationHook: recoveryHook,
            registry: LocalRootIORegistry()
        )
        let restartedStores = EngineStores(
            baseRecords: try FileBaseRecordStore(rootURL: recordsRoot),
            journal: try FileRunJournalStore(rootURL: journalRoot),
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
        let replay = try #require(
            try await restartedStores.journal.unfinishedRun(for: syncSetID)
        )
        let durableReceipt = try #require(
            replay.indeterminateReceiptsByOperation[operationID]
        )
        #expect(durableReceipt.id == receiptID)
        #expect(durableReceipt.provider == location.id)
        #expect(durableReceipt.kind == .relocate)
        #expect(durableReceipt.affectedPaths == [source.path, destinationPath])
        #expect(
            durableReceipt.correlation == ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            )
        )
        #expect(replay.pendingOperationIDs == [operationID])
        #expect(!replay.events.contains { $0.isRunFinished })
        #expect(!replay.events.contains { $0.resultOperationID == operationID })

        let report = try await RunRecovery(
            providers: [location.id: restartedProvider],
            stores: restartedStores,
            environment: ExecutionEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_242) }
            )
        ).recover(replay)

        #expect(report.reconciledOperations == [operationID])
        #expect(report.restoredRecords == 0)
        #expect(try await restartedStores.baseRecords.records(for: syncSetID).isEmpty)
        #expect(try await restartedStores.journal.unfinishedRun(for: syncSetID) == nil)
        #expect(recoveryHook.kinds().isEmpty)
        #expect(hook.kinds() == [.relocate])
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: destinationURL) == contents)
        guard case .complete = (await restartedProvider.scan(.entireDrive)).status else {
            Issue.record("Provider did not resume after durable relocate recovery.")
            return
        }
        _ = try await restartedProvider.makeFolder(at: "/AfterRestartRecovery")
    }

    @Test(arguments: LegacyTrashRecoveryOperation.allCases)
    func legacyReceiptWithExactArtifactRecoversUnfinishedWAL(
        _ recoveryOperation: LegacyTrashRecoveryOperation
    ) async throws {
        let world = try makeRoot("legacy-receipt-\(recoveryOperation.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Legacy.txt")
        let contents = Data("legacy exact artifact".utf8)
        try contents.write(to: sourceURL)
        let location = localLocation(
            id: LocationID(recoveryOperation.locationID)
        )
        let initial = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            registry: LocalRootIORegistry()
        )
        let source = try #require(
            (await initial.scan(.entireDrive)).observations.byPath["/Legacy.txt"]
        )

        let destinationPath: SyncPath = "/Recovered.txt"
        if recoveryOperation == .relocate {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: root.appendingPathComponent("Recovered.txt")
            )
        }
        let artifact = root
            .appendingPathComponent(".aetherloom", isDirectory: true)
            .appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("Legacy.txt")
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: sourceURL, to: artifact)
        try writeLegacyTrashReceipt(
            root: root,
            observation: source,
            method: .quarantine,
            recoveryPath: artifact.path
        )

        let operationID = OperationID(recoveryOperation.operationID)
        let operationKind: OperationKind = recoveryOperation == .trash
            ? .trash(itemRef: ItemRef(source))
            : .relocate(itemRef: ItemRef(source), to: destinationPath)
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: operationKind,
            precondition: .versionMatches(source.version)
        )
        let runID = recoveryOperation.runID
        let receipt = ProviderMutationReceipt(
            id: recoveryOperation.receiptID,
            provider: location.id,
            kind: recoveryOperation == .trash ? .trash : .relocate,
            affectedPaths: recoveryOperation == .trash
                ? [source.path]
                : [source.path, destinationPath],
            startedAt: Date(timeIntervalSince1970: 1_800_000_500),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            ),
            rootIdentity: mutationRootIdentity(for: root)
        )
        let stores = EngineStores.inMemory()
        try await stores.journal.begin(
            runID: runID,
            syncSetID: recoveryOperation.syncSetID,
            fingerprint: PlanFingerprint(rawValue: recoveryOperation.rawValue)
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_501)
            ),
            runID: runID
        )
        let recoveryHook = RecordingLocalMutationHook()
        let recoveryProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: recoveryHook,
            registry: LocalRootIORegistry()
        )
        let replay = try #require(
            try await stores.journal.unfinishedRun(
                for: recoveryOperation.syncSetID
            )
        )

        let report = try await RunRecovery(
            providers: [location.id: recoveryProvider],
            stores: stores
        ).recover(replay)

        #expect(report.reconciledOperations == [operationID])
        #expect(
            try await stores.journal.unfinishedRun(
                for: recoveryOperation.syncSetID
            ) == nil
        )
        #expect(recoveryHook.kinds().isEmpty)
        #expect(try Data(contentsOf: artifact) == contents)
        if recoveryOperation == .relocate {
            #expect(
                try Data(
                    contentsOf: root.appendingPathComponent("Recovered.txt")
                ) == contents
            )
        }
        guard case .complete = (await recoveryProvider.scan(.entireDrive)).status else {
            Issue.record("Legacy recovery did not release its exact owner.")
            return
        }
    }

    @Test(arguments: LegacyTrashFailureMode.allCases)
    func legacyTrashWithoutExactArtifactProofFailsClosed(
        _ failureMode: LegacyTrashFailureMode
    ) async throws {
        let world = try makeRoot("legacy-receipt-failure-\(failureMode.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Legacy.txt")
        try Data("legacy original".utf8).write(to: sourceURL)
        let location = localLocation(id: LocationID(failureMode.locationID))
        let initial = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            registry: LocalRootIORegistry()
        )
        let source = try #require(
            (await initial.scan(.entireDrive)).observations.byPath["/Legacy.txt"]
        )
        let holding = world.appendingPathComponent("Holding.txt")
        try FileManager.default.moveItem(at: sourceURL, to: holding)

        let artifact = root
            .appendingPathComponent(".aetherloom", isDirectory: true)
            .appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("Legacy.txt")
        let method: LegacyTrashReceiptMethod
        let recoveryPath: String?
        switch failureMode {
        case .missingArtifact:
            method = .quarantine
            recoveryPath = artifact.path
        case .unavailableArtifact:
            method = .quarantine
            recoveryPath = artifact.path
            try FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: holding, to: artifact)
        case .mismatchedArtifact:
            method = .quarantine
            recoveryPath = artifact.path
            try FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("different artifact".utf8).write(to: artifact)
        case .nativeWithoutArtifactPath:
            method = .nativeTrash
            recoveryPath = nil
        }
        try writeLegacyTrashReceipt(
            root: root,
            observation: source,
            method: method,
            recoveryPath: recoveryPath
        )

        let quarantine: any LocalQuarantinePerforming
        if failureMode == .unavailableArtifact {
            quarantine = UnavailableLegacyQuarantinePerformer()
        } else {
            quarantine = SystemLocalQuarantinePerformer()
        }
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            quarantine: quarantine,
            registry: LocalRootIORegistry()
        )
        let operationID = OperationID(failureMode.operationID)
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .trash(itemRef: ItemRef(source)),
            precondition: .versionMatches(source.version)
        )
        let runID = failureMode.runID
        let receipt = ProviderMutationReceipt(
            id: failureMode.receiptID,
            provider: location.id,
            kind: .trash,
            affectedPaths: [source.path],
            startedAt: Date(timeIntervalSince1970: 1_800_000_510),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            ),
            rootIdentity: mutationRootIdentity(for: root)
        )
        let stores = EngineStores.inMemory()
        try await stores.journal.begin(
            runID: runID,
            syncSetID: failureMode.syncSetID,
            fingerprint: PlanFingerprint(rawValue: failureMode.rawValue)
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_511)
            ),
            runID: runID
        )
        let replay = try #require(
            try await stores.journal.unfinishedRun(for: failureMode.syncSetID)
        )

        await #expect(throws: RunRecoveryError.self) {
            _ = try await RunRecovery(
                providers: [location.id: provider],
                stores: stores
            ).recover(replay)
        }

        #expect(
            try await stores.journal.unfinishedRun(for: failureMode.syncSetID)
                != nil
        )
        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("Unproven legacy trash evidence released its owner.")
            return
        }
        #expect(try Data(contentsOf: holding) == Data("legacy original".utf8))
    }

    @Test func nativeTrashProducesRecoverableArtifact() async throws {
        let root = try makeRoot("native-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Native.txt")
        let contents = Data("native recovery".utf8)
        try contents.write(to: sourceURL)
        let systemVolumes = SystemVolumeInspector()
        let location = SyncLocation(
            kind: .localFolder,
            configuration: [
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                    await systemVolumes.volumeIdentity(for: root) ?? "",
            ]
        )
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root
        )
        guard provider.capabilities.hasNativeTrash else {
            withKnownIssue("The temporary volume does not expose native Trash.") {
                Issue.record("Native trash is unavailable on this test host.")
            }
            return
        }
        let observation = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/Native.txt"]
        )
        try await provider.trash(observation)
        let recoveryURL = try #require(
            await provider.recoveryURL(for: observation.path)
        )
        defer {
            // Test-only containment exception: this removes only the artifact
            // created by this test after native trash moved it outside the root.
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        #expect(try Data(contentsOf: recoveryURL) == contents)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func everyProductionMutationRouteUsesOwnedCoordinator() async throws {
        let root = try makeRoot("owned-mutation-routes")
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = RecordingLocalMutationHook()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: hook
        )
        let staging = root.appendingPathComponent("Staging.bin")
        try Data("first".utf8).write(to: staging)

        let first = try await provider.store(
            from: staging,
            at: "/Owned.txt",
            options: StoreOptions()
        )
        try Data("second".utf8).write(to: staging)
        let replaced = try await provider.store(
            from: staging,
            at: first.path,
            options: StoreOptions(overwrite: .ifVersionMatches(first.version))
        )
        _ = try await provider.makeFolder(at: "/Folder")
        let fetched = root.appendingPathComponent("Owned.fetch")
        try await provider.fetch(replaced, to: fetched)
        let relocated = try await provider.relocate(replaced, to: "/Moved.txt")
        try await provider.trash(relocated)

        #expect(
            hook.kinds()
                == [.store, .store, .makeFolder, .fetch, .relocate, .trash]
        )
        #expect(try await provider.currentState(of: relocated).isTrashed)
        #expect(await provider.recoveryURL(for: relocated.path) != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".aetherloom/trash-receipts").path
            )
        )
    }

    @Test func sameRootReadLeaseSerializesReconstructedProviderMutation() async throws {
        let root = try makeRoot("same-root-read-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = LocalRootIORegistry()
        let inspector = BlockingReadVolumeInspector()
        let clock = ProviderMutationManualClock()
        let location = localLocation()
        let first = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: inspector,
            registry: registry
        )
        let hook = RecordingLocalMutationHook()
        let reconstructed = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(ioNanoseconds: 1, clock: clock),
            mutationHook: hook,
            registry: registry
        )
        await clock.waitUntilIdle()
        await inspector.blockNextMountInspection()

        let scan = Task { await first.scan(.entireDrive) }
        await inspector.waitUntilBlocked()
        let mutation = Task {
            try await reconstructed.makeFolder(at: "/AfterRead")
        }
        await clock.waitUntilSleeping()

        let laterScan = await reconstructed.scan(.entireDrive)
        guard case .unavailable = laterScan.status else {
            Issue.record("A read crossed queued mutation admission.")
            await inspector.release()
            _ = try? await mutation.value
            return
        }
        #expect(hook.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AfterRead").path
            )
        )

        await inspector.release()
        guard case .complete = (await scan.value).status else {
            Issue.record("The admitted scan did not finish after release.")
            return
        }
        _ = try await mutation.value
        #expect(hook.kinds() == [.makeFolder])
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AfterRead").path
            )
        )
    }

    @Test func fullScanTimeoutRetainsLeaseThroughFinalValidation() async throws {
        let root = try makeRoot("final-scan-validation-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = LocalRootIORegistry()
        let inspector = BlockingReadVolumeInspector()
        let scanClock = ProviderMutationManualClock()
        let writerClock = ProviderMutationManualClock()
        let location = localLocation()
        let scanner = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(
                scanNanoseconds: 1,
                clock: scanClock
            ),
            registry: registry
        )
        let hook = RecordingLocalMutationHook()
        let writer = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: writerClock
            ),
            mutationHook: hook,
            registry: registry
        )
        await scanClock.waitUntilIdle()
        await writerClock.waitUntilIdle()
        await inspector.blockMountInspection(number: 2)

        let scan = Task { await scanner.scan(.entireDrive) }
        await inspector.waitUntilBlocked()
        await scanClock.waitUntilSleeping()
        await scanClock.fireAll()
        guard case .incomplete = (await scan.value).status else {
            Issue.record("The caller did not receive the scan deadline.")
            await inspector.release()
            return
        }

        let mutation = Task {
            try await writer.makeFolder(at: "/AfterFinalValidation")
        }
        await writerClock.waitUntilSleeping()
        #expect(hook.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AfterFinalValidation").path
            )
        )
        guard case .unavailable = (await writer.scan(.entireDrive)).status else {
            Issue.record("A later read crossed writer-preferred admission.")
            await inspector.release()
            _ = try? await mutation.value
            return
        }

        await inspector.release()
        _ = try await mutation.value
        #expect(hook.kinds() == [.makeFolder])
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("AfterFinalValidation").path
            )
        )
    }

    @Test func sameRootRegistryRetainsLateOwnerAcrossProviderReconstruction() async throws {
        let root = try makeRoot("same-root-owner-reconstruction")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = LocalRootIORegistry()
        let staging = root.appendingPathComponent("Staging.bin")
        let bytes = Data("retained owner".utf8)
        try bytes.write(to: staging)
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let location = localLocation()
        let receiptID = UUID(uuidString: "a2000000-0000-0000-0000-000000000013")!
        let first = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                makeMutationID: { receiptID }
            ),
            mutationHook: hook,
            registry: registry
        )
        await clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a2000000-0000-0000-0000-000000000015")!,
            operationID: OperationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000014")!
            )
        )
        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await first.store(
                            from: staging,
                            at: "/Late.txt",
                            options: StoreOptions()
                        )
                    }
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected store error: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await call.value)

        let reconstructed = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            registry: registry
        )
        #expect(
            await reconstructed.indeterminateMutationState(for: receipt)
                == .inFlight
        )
        guard case .unavailable = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("Reconstruction escaped the live same-root barrier.")
            hook.release()
            return
        }

        let operationID = OperationID(
            UUID(uuidString: "a2000000-0000-0000-0000-000000000014")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .transfer(
                content: ContentRef(
                    sourceLocation: .googleDrive,
                    itemID: nil,
                    path: "/Source.txt",
                    kind: .file,
                    expectedVersion: ItemVersion(size: Int64(bytes.count))
                ),
                to: "/Late.txt",
                overwrite: .neverOverwrite
            ),
            precondition: .pathAbsent
        )
        let stores = EngineStores.inMemory()
        let runID = UUID(uuidString: "a2000000-0000-0000-0000-000000000015")!
        let syncSetID = UUID(uuidString: "a2000000-0000-0000-0000-000000000016")!
        var durableReceipt = receipt
        durableReceipt.correlation = ProviderMutationCorrelation(
            runID: runID,
            operationID: operationID
        )
        try await stores.journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "same-root-reconstruction")
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: durableReceipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_100)
            ),
            runID: runID
        )

        hook.release()
        await waitForProviderMutationQuiescence(reconstructed, receipt: receipt)
        let replay = try #require(
            try await stores.journal.unfinishedRun(for: syncSetID)
        )
        let report = try await RunRecovery(
            providers: [location.id: reconstructed],
            stores: stores,
            environment: ExecutionEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_101) }
            )
        ).recover(replay)

        #expect(report.reconciledOperations == [operationID])
        #expect(try await stores.journal.unfinishedRun(for: syncSetID) == nil)
        guard case .complete = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("Reconstructed provider did not resume after durable recovery.")
            return
        }
        _ = try await reconstructed.makeFolder(at: "/FreshPlan")
    }

    @Test func initiallyUnavailableRootPromotesItsOriginalOwnerWhenRestored() async throws {
        let world = try makeRoot("initially-unavailable-owner-promotion")
        defer { try? FileManager.default.removeItem(at: world) }
        let target = world.appendingPathComponent(
            "Initially Missing Root",
            isDirectory: true
        )
        let root = world.appendingPathComponent("Enrolled Alias", isDirectory: true)
        let unrelated = world.appendingPathComponent("Unrelated Root", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.path,
            withDestinationPath: target.path
        )
        let registry = LocalRootIORegistry()
        let location = localLocation()
        let first = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            registry: registry
        )
        let originalOwner = await registry.ownership(
            configuredRootPath: root.standardizedFileURL.path,
            resolvedCanonicalRootPath: nil,
            expectedVolumeIdentity: "scripted-volume"
        )
        #expect(originalOwner.canonicalRootPath == nil)
        guard case .unavailable = await first.checkAvailability() else {
            Issue.record("An initially absent root was reported available.")
            return
        }

        try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(
            atPath: root.path,
            withDestinationPath: unrelated.path
        )
        let rejectedHook = RecordingLocalMutationHook()
        let rejected = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: rejectedHook,
            registry: registry
        )
        guard case .unavailable = await rejected.checkAvailability() else {
            Issue.record("An unresolved symlink adopted an unrelated root.")
            return
        }
        await #expect(throws: ProviderError.self) {
            _ = try await rejected.makeFolder(at: "/Escaped")
        }
        #expect(rejectedHook.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: unrelated.appendingPathComponent("Escaped").path
            )
        )

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(
            atPath: root.path,
            withDestinationPath: target.path
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let hook = RecordingLocalMutationHook()
        let reconstructed = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: hook,
            registry: registry
        )
        let canonicalPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let promotedOwner = await registry.ownership(
            configuredRootPath: root.standardizedFileURL.path,
            resolvedCanonicalRootPath: canonicalPath,
            expectedVolumeIdentity: "scripted-volume"
        )
        #expect(promotedOwner.canonicalRootPath == canonicalPath)
        #expect(promotedOwner.mutations === originalOwner.mutations)
        #expect(promotedOwner.artifacts === originalOwner.artifacts)

        let canonicalProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: target,
            volumes: ScriptedVolumeInspector(),
            registry: registry
        )
        let aliasOwner = await registry.ownership(
            configuredRootPath: target.standardizedFileURL.path,
            resolvedCanonicalRootPath: canonicalPath,
            expectedVolumeIdentity: "scripted-volume"
        )
        let canonicalOwner = await registry.ownership(
            canonicalRootPath: canonicalPath,
            expectedVolumeIdentity: "scripted-volume"
        )
        #expect(aliasOwner.mutations === originalOwner.mutations)
        #expect(aliasOwner.artifacts === originalOwner.artifacts)
        #expect(canonicalOwner.mutations === originalOwner.mutations)
        #expect(canonicalOwner.artifacts === originalOwner.artifacts)

        // Providers pin the ownership returned at construction. The original
        // unavailable instance stays fail-closed, while reconstruction binds
        // the same owner to the restored physical root.
        guard case .unavailable = await first.checkAvailability() else {
            Issue.record("The unbound provider changed roots after construction.")
            return
        }
        #expect(await reconstructed.checkAvailability() == .available)
        guard case .complete = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("The reconstructed provider did not resume scanning.")
            return
        }
        let created = try await reconstructed.makeFolder(at: "/Recovered")
        #expect(hook.kinds() == [.makeFolder])

        let recoveryReceipt = ProviderMutationReceipt(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000031")!,
            provider: location.id,
            kind: .makeFolder,
            affectedPaths: [created.path],
            startedAt: Date(timeIntervalSince1970: 1_800_000_300),
            correlation: ProviderMutationCorrelation(
                runID: UUID(
                    uuidString: "a2000000-0000-0000-0000-000000000032"
                )!,
                operationID: OperationID(
                    UUID(
                        uuidString: "a2000000-0000-0000-0000-000000000033"
                    )!
                )
            ),
            rootIdentity: mutationRootIdentity(for: target)
        )
        guard case let .claimed(claim) = await reconstructed
            .beginIndeterminateMutationRecovery(for: recoveryReceipt) else {
            Issue.record("The promoted owner could not begin recovery.")
            return
        }
        guard case .unavailable = (await canonicalProvider.scan(.entireDrive)).status else {
            Issue.record("A compatible alias escaped the promoted recovery owner.")
            return
        }
        let recovered = try await canonicalProvider.currentStateForRecovery(
            of: created,
            claim: claim
        )
        #expect(recovered.path == created.path)
        #expect(recovered.kind == .folder)
        await canonicalProvider.finishIndeterminateMutationRecovery(claim)
        guard case .complete = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("The promoted owner did not resume after recovery.")
            return
        }
    }

    @Test func rootRegistrySeparatesPathsButUnifiesReplacementVolumes() async {
        let registry = LocalRootIORegistry()
        let first = await registry.ownership(
            canonicalRootPath: "/Volumes/One/Root",
            expectedVolumeIdentity: "volume-one"
        )
        let same = await registry.ownership(
            canonicalRootPath: "/Volumes/One/Root",
            expectedVolumeIdentity: "volume-one"
        )
        let differentRoot = await registry.ownership(
            canonicalRootPath: "/Volumes/One/Other",
            expectedVolumeIdentity: "volume-one"
        )
        let differentVolume = await registry.ownership(
            canonicalRootPath: "/Volumes/One/Root",
            expectedVolumeIdentity: "volume-two"
        )
        let resolvedAlias = await registry.ownership(
            configuredRootPath: "/Volumes/One/Root Alias",
            resolvedCanonicalRootPath: "/Volumes/One/Root",
            expectedVolumeIdentity: "volume-one"
        )
        let unavailableReplacement = await registry.ownership(
            configuredRootPath: "/Volumes/One/Root",
            resolvedCanonicalRootPath: nil,
            expectedVolumeIdentity: "volume-three",
            unresolvedCanonicalRootPathHint: "/Volumes/One/Root"
        )

        #expect(first.mutations === same.mutations)
        #expect(first.artifacts === same.artifacts)
        #expect(first.mutations === resolvedAlias.mutations)
        #expect(first.mutations !== differentRoot.mutations)
        #expect(first.mutations === differentVolume.mutations)
        #expect(first.artifacts === differentVolume.artifacts)
        #expect(first.mutations === unavailableReplacement.mutations)

        let unresolvedUnknownAlias = await registry.ownership(
            configuredRootPath: "/Volumes/One/BrokenAlias",
            resolvedCanonicalRootPath: nil,
            expectedVolumeIdentity: "volume-one"
        )
        #expect(unresolvedUnknownAlias.admissionIssue != nil)
    }

    @Test func replacementVolumeCannotEscapeLiveOwnerOrResumeOldMutation() async throws {
        let world = try makeRoot("replacement-volume-live-owner")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Mounted Root", isDirectory: true)
        let detachedV1 = world.appendingPathComponent("Detached V1", isDirectory: true)
        let alias = world.appendingPathComponent("Mounted Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: root.path
        )

        let registry = LocalRootIORegistry()
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("volume-v1")
        let v1Clock = ProviderMutationManualClock()
        let v1Hook = BlockingLocalMutationHook()
        let v1Location = localLocation(
            id: LocationID(
                UUID(uuidString: "a7000000-0000-0000-0000-000000000001")!
            ),
            expectedVolumeIdentity: "volume-v1"
        )
        let receiptID = UUID(
            uuidString: "a7000000-0000-0000-0000-000000000002"
        )!
        let v1 = await LocalFolderStorageProvider.make(
            location: v1Location,
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: v1Clock,
                makeMutationID: { receiptID }
            ),
            mutationHook: v1Hook,
            registry: registry
        )
        await v1Clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(
                uuidString: "a7000000-0000-0000-0000-000000000003"
            )!,
            operationID: OperationID(
                UUID(uuidString: "a7000000-0000-0000-0000-000000000004")!
            )
        )
        let liveV1 = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await v1.makeFolder(at: "/MustNotReachV2")
                    }
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected V1 caller result: \(error)")
                return nil
            }
        }
        await v1Hook.waitUntilStarted(count: 1)
        await v1Clock.waitUntilSleeping()
        await v1Clock.fireAll()
        let receipt = try #require(await liveV1.value)

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.moveItem(at: root, to: detachedV1)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("replacement-volume".utf8).write(
            to: root.appendingPathComponent("Preserve.txt")
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: root.path
        )
        await inspector.setVolumeIdentity("volume-v2")

        let v2Hook = RecordingLocalMutationHook()
        let v2Location = localLocation(
            id: LocationID(
                UUID(uuidString: "a7000000-0000-0000-0000-000000000005")!
            ),
            expectedVolumeIdentity: "volume-v2"
        )
        let v2 = await LocalFolderStorageProvider.make(
            location: v2Location,
            rootURL: alias,
            volumes: inspector,
            mutationHook: v2Hook,
            registry: registry
        )
        guard case .unavailable = (await v2.scan(.entireDrive)).status else {
            Issue.record("Replacement alias escaped the live V1 owner.")
            v1Hook.release()
            return
        }

        let v2Attempt = Task { () -> Bool in
            do {
                _ = try await v2.makeFolder(at: "/MustNotStartOnV2")
                return false
            } catch let error as ProviderError {
                if case .mutationDeadlineExpiredBeforeStart = error {
                    return true
                }
                Issue.record("Unexpected V2 admission result: \(error)")
                return false
            } catch {
                Issue.record("Unexpected V2 admission result: \(error)")
                return false
            }
        }
        #expect(await v2Attempt.value)
        #expect(v2Hook.kinds().isEmpty)

        v1Hook.release()
        await waitForProviderMutationQuiescence(v1, receipt: receipt)
        guard case .quiescent(.failed) = await v1
            .indeterminateMutationState(for: receipt) else {
            Issue.record("V1 replacement detection did not retain recovery ownership.")
            return
        }
        guard case .unavailable = (await v2.scan(.entireDrive)).status else {
            Issue.record("Replacement root escaped the retained V1 receipt.")
            return
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("MustNotReachV2").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("MustNotStartOnV2").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: detachedV1.appendingPathComponent("MustNotReachV2").path
            )
        )
        #expect(
            try Data(contentsOf: root.appendingPathComponent("Preserve.txt"))
                == Data("replacement-volume".utf8)
        )

        #expect(
            await v1.beginIndeterminateMutationRecovery(for: receipt)
                == .inFlight
        )
        guard case .unavailable = (await v2.scan(.entireDrive)).status else {
            Issue.record("Replacement V2 borrowed V1 recovery authority.")
            return
        }
    }

    @Test func sharedRegistryUnifiesCanonicalAndSymlinkAliasesAcrossLocations() async throws {
        let world = try makeRoot("shared-registry-aliases")
        defer { try? FileManager.default.removeItem(at: world) }
        let target = world.appendingPathComponent("Target", isDirectory: true)
        let alias = world.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: target.path
        )
        let aliasLocation = localLocation(
            id: LocationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000021")!
            )
        )
        let canonicalLocation = localLocation(
            id: LocationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000022")!
            )
        )
        let aliasProvider = await LocalFolderStorageProvider.make(
            location: aliasLocation,
            rootURL: alias,
            volumes: ScriptedVolumeInspector()
        )
        let canonicalProvider = await LocalFolderStorageProvider.make(
            location: canonicalLocation,
            rootURL: target,
            volumes: ScriptedVolumeInspector()
        )
        let receipt = ProviderMutationReceipt(
            id: UUID(
                uuidString: "a2000000-0000-0000-0000-000000000023"
            )!,
            provider: aliasLocation.id,
            kind: .makeFolder,
            affectedPaths: ["/ClaimedAlias"],
            startedAt: Date(timeIntervalSince1970: 1_800_000_103),
            correlation: ProviderMutationCorrelation(
                runID: UUID(
                    uuidString: "a2000000-0000-0000-0000-000000000024"
                )!,
                operationID: OperationID(
                    UUID(
                        uuidString: "a2000000-0000-0000-0000-000000000025"
                    )!
                )
            ),
            rootIdentity: mutationRootIdentity(for: target)
        )

        let wrongAliasClaim = await canonicalProvider
            .beginIndeterminateMutationRecovery(for: receipt)
        #expect(
            wrongAliasClaim == .inFlight
        )
        guard case let .claimed(claim) = await aliasProvider
            .beginIndeterminateMutationRecovery(for: receipt) else {
            Issue.record("Alias receipt could not establish recovery ownership.")
            return
        }
        guard case .unavailable = (await canonicalProvider.scan(.entireDrive)).status else {
            Issue.record("Canonical alias escaped the shared recovery owner.")
            return
        }

        await canonicalProvider.finishIndeterminateMutationRecovery(claim)
        guard case .unavailable = (await canonicalProvider.scan(.entireDrive)).status else {
            Issue.record("A differently attributed alias released the recovery claim.")
            return
        }
        await aliasProvider.finishIndeterminateMutationRecovery(claim)
        guard case .complete = (await canonicalProvider.scan(.entireDrive)).status else {
            Issue.record("Canonical alias stayed blocked after reconciliation.")
            return
        }
    }

    @Test(arguments: MultiAliasRecoveryScenario.allCases)
    func multiAliasWALPrefixRecoversUnderOneExactOwner(
        _ scenario: MultiAliasRecoveryScenario
    ) async throws {
        let world = try makeRoot("multi-alias-recovery-\(scenario.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let alias = world.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("AppliedByA"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: root.path
        )

        let locationA = localLocation(
            id: LocationID(
                UUID(uuidString: "a8000000-0000-0000-0000-000000000001")!
            )
        )
        let locationB = localLocation(
            id: LocationID(
                UUID(uuidString: "a8000000-0000-0000-0000-000000000002")!
            )
        )
        let operationA = AetherloomCore.Operation(
            id: scenario.receiptOperationID,
            location: locationA.id,
            kind: .makeFolder(at: "/AppliedByA"),
            precondition: .pathAbsent
        )
        let operationB = AetherloomCore.Operation(
            id: scenario.intentOnlyOperationID,
            location: locationB.id,
            kind: .makeFolder(at: "/UnappliedByB"),
            precondition: .pathAbsent
        )
        let syncSetID = UUID(
            uuidString: "a8000000-0000-0000-0000-000000000003"
        )!
        let runID = UUID(
            uuidString: "a8000000-0000-0000-0000-000000000004"
        )!
        let receipt = ProviderMutationReceipt(
            id: UUID(
                uuidString: "a8000000-0000-0000-0000-000000000005"
            )!,
            provider: locationA.id,
            kind: .makeFolder,
            affectedPaths: ["/AppliedByA"],
            startedAt: Date(timeIntervalSince1970: 1_800_000_400),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationA.id
            ),
            rootIdentity: mutationRootIdentity(for: root)
        )

        let journalRoot = world.appendingPathComponent("Journal")
        let writerJournal: any RunJournalStore
        if scenario.restartsProcess {
            writerJournal = try FileRunJournalStore(rootURL: journalRoot)
        } else {
            writerJournal = InMemoryRunJournalStore()
        }
        try await writerJournal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: scenario.rawValue)
        )
        try await writerJournal.append(.intent(operationA), runID: runID)
        try await writerJournal.append(.intent(operationB), runID: runID)
        try await writerJournal.append(
            .mutationIndeterminate(
                operationID: operationA.id,
                receipt: receipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_401)
            ),
            runID: runID
        )
        let activeJournal: any RunJournalStore
        if scenario.restartsProcess {
            activeJournal = try FileRunJournalStore(rootURL: journalRoot)
        } else {
            activeJournal = writerJournal
        }
        let stores = EngineStores(
            baseRecords: InMemoryBaseRecordStore(),
            journal: activeJournal,
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )

        let registry = LocalRootIORegistry()
        let hookA = RecordingLocalMutationHook()
        let hookB = RecordingLocalMutationHook()
        let providerA = await LocalFolderStorageProvider.make(
            location: locationA,
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            mutationHook: hookA,
            registry: registry
        )
        let providerB = await LocalFolderStorageProvider.make(
            location: locationB,
            rootURL: alias,
            volumes: ScriptedVolumeInspector(),
            mutationHook: hookB,
            registry: registry
        )
        if !scenario.restartsProcess {
            guard case let .claimed(claim) = await providerA
                .beginIndeterminateMutationRecovery(for: receipt) else {
                Issue.record("Same-process receipt could not establish its owner.")
                return
            }
            await providerA.abandonIndeterminateMutationRecovery(claim)
            guard case .unavailable = (await providerB.scan(.entireDrive)).status else {
                Issue.record("Alias B crossed A's same-process recovery barrier.")
                return
            }
        }

        let syncSet = SyncSet(
            id: syncSetID,
            name: "Alias recovery",
            locations: [locationA.id, locationB.id],
            createdAt: Date(timeIntervalSince1970: 1_800_000_400),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_400)
        )
        let idSequence = LockedUUIDSequence(
            (0 ..< 64).map {
                DeterministicID.uuid(
                    "multi-alias-recovery",
                    scenario.rawValue,
                    String($0)
                )
            }
        )
        let orchestrator = SyncOrchestrator(
            locations: [locationA.id: locationA, locationB.id: locationB],
            providers: [locationA.id: providerA, locationB.id: providerB],
            stores: stores,
            stage: ContentStage(
                rootDirectory: world.appendingPathComponent("Stage"),
                byteLimit: 1_000_000
            ),
            environment: EngineEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_402) },
                makeID: idSequence.next
            )
        )
        let preparation = try await orchestrator.prepare(syncSet)

        #expect(preparation.outcome.planValue != nil)
        #expect(try await activeJournal.unfinishedRun(for: syncSetID) == nil)
        #expect(hookA.kinds().isEmpty)
        #expect(hookB.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("UnappliedByB").path
            )
        )
        guard case .complete = (await providerA.scan(.entireDrive)).status,
              case .complete = (await providerB.scan(.entireDrive)).status else {
            Issue.record("Aliases did not reopen after exact WAL reconciliation.")
            return
        }
    }

    @Test func liveSymlinkRetargetFailsClosedWithoutMutatingNewTarget() async throws {
        let world = try makeRoot("live-symlink-retarget")
        defer { try? FileManager.default.removeItem(at: world) }
        let firstRoot = world.appendingPathComponent("First", isDirectory: true)
        let secondRoot = world.appendingPathComponent("Second", isDirectory: true)
        let alias = world.appendingPathComponent("Enrolled Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: firstRoot.path
        )

        let registry = LocalRootIORegistry()
        let aliasHook = RecordingLocalMutationHook()
        let aliasLocation = localLocation(
            id: LocationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000024")!
            )
        )
        let secondLocation = localLocation(
            id: LocationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000025")!
            )
        )
        let aliasProvider = await LocalFolderStorageProvider.make(
            location: aliasLocation,
            rootURL: alias,
            volumes: ScriptedVolumeInspector(),
            mutationHook: aliasHook,
            registry: registry
        )
        let secondOwner = await LocalFolderStorageProvider.make(
            location: secondLocation,
            rootURL: secondRoot,
            volumes: ScriptedVolumeInspector(),
            registry: registry
        )

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: secondRoot.path
        )

        guard case .unavailable = await aliasProvider.checkAvailability() else {
            Issue.record("A retargeted enrolled symlink remained available.")
            return
        }
        guard case .unavailable = (await aliasProvider.scan(.entireDrive)).status else {
            Issue.record("A retargeted enrolled symlink produced scan truth.")
            return
        }
        await #expect(throws: ProviderError.self) {
            _ = try await aliasProvider.makeFolder(at: "/Escaped")
        }

        #expect(aliasHook.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: secondRoot.appendingPathComponent("Escaped").path
            )
        )
        _ = try await secondOwner.makeFolder(at: "/OwnedBySecondRoot")
        #expect(
            FileManager.default.fileExists(
                atPath: secondRoot.appendingPathComponent("OwnedBySecondRoot").path
            )
        )
    }

    @Test func brokenSymlinkReconstructionRetainsLiveCanonicalRootOwner() async throws {
        let world = try makeRoot("broken-symlink-owner")
        defer { try? FileManager.default.removeItem(at: world) }
        let target = world.appendingPathComponent("Target", isDirectory: true)
        let unavailableTarget = world.appendingPathComponent(
            "Target Unavailable",
            isDirectory: true
        )
        let alias = world.appendingPathComponent("Enrolled Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: target.path
        )

        let registry = LocalRootIORegistry()
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let location = localLocation()
        let receiptID = UUID(
            uuidString: "a2000000-0000-0000-0000-000000000017"
        )!
        let first = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: alias,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                makeMutationID: { receiptID }
            ),
            mutationHook: hook,
            registry: registry
        )
        await clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a2000000-0000-0000-0000-000000000019")!,
            operationID: OperationID(
                UUID(uuidString: "a2000000-0000-0000-0000-000000000018")!
            )
        )

        let mutation = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await first.makeFolder(at: "/LateFolder")
                    }
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected symlink-root mutation error: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await mutation.value)

        try FileManager.default.moveItem(at: target, to: unavailableTarget)
        let reconstructed = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: alias,
            volumes: ScriptedVolumeInspector(),
            registry: registry
        )
        #expect(
            await reconstructed.indeterminateMutationState(for: receipt)
                == .inFlight
        )
        guard case .unavailable = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("A broken symlink reconstruction escaped its live owner.")
            try FileManager.default.moveItem(at: unavailableTarget, to: target)
            hook.release()
            return
        }

        try FileManager.default.moveItem(at: unavailableTarget, to: target)
        hook.release()
        await waitForProviderMutationQuiescence(reconstructed, receipt: receipt)

        let operationID = OperationID(
            UUID(uuidString: "a2000000-0000-0000-0000-000000000018")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .makeFolder(at: "/LateFolder"),
            precondition: .pathAbsent
        )
        let stores = EngineStores.inMemory()
        let runID = UUID(uuidString: "a2000000-0000-0000-0000-000000000019")!
        let syncSetID = UUID(
            uuidString: "a2000000-0000-0000-0000-000000000020"
        )!
        var durableReceipt = receipt
        durableReceipt.correlation = ProviderMutationCorrelation(
            runID: runID,
            operationID: operationID
        )
        try await stores.journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "broken-symlink-owner")
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: durableReceipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_102)
            ),
            runID: runID
        )
        let replay = try #require(
            try await stores.journal.unfinishedRun(for: syncSetID)
        )
        let report = try await RunRecovery(
            providers: [location.id: reconstructed],
            stores: stores
        ).recover(replay)

        #expect(report.reconciledOperations == [operationID])
        #expect(try await stores.journal.unfinishedRun(for: syncSetID) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("LateFolder").path
            )
        )
        guard case .complete = (await reconstructed.scan(.entireDrive)).status else {
            Issue.record("The restored symlink root did not resume after recovery.")
            return
        }
    }

    @Test(arguments: DurableRootMismatchMode.allCases)
    func durableReceiptCannotAuthorizeAReplacementPhysicalRoot(
        _ mode: DurableRootMismatchMode
    ) async throws {
        let world = try makeRoot("durable-root-mismatch-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: world) }
        let rootA = world.appendingPathComponent("Root A", isDirectory: true)
        let rootB = world.appendingPathComponent("Root B", isDirectory: true)
        let detachedA = world.appendingPathComponent("Detached A", isDirectory: true)
        let alias = world.appendingPathComponent("Enrolled Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootA.appendingPathComponent("Applied"),
            withIntermediateDirectories: false
        )
        try Data("preserve replacement".utf8).write(
            to: rootA.appendingPathComponent("Preserve.txt")
        )
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try Data("preserve replacement".utf8).write(
            to: rootB.appendingPathComponent("Preserve.txt")
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: rootA.path
        )

        let configuredRoot = mode == .symlinkRetarget ? alias : rootA
        let originalCanonicalPath = rootA.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let location = localLocation(
            id: LocationID(
                UUID(uuidString: "ab000000-0000-0000-0000-000000000001")!
            ),
            expectedVolumeIdentity: mode.currentVolumeIdentity
        )
        let operationID = OperationID(
            UUID(uuidString: "ab000000-0000-0000-0000-000000000002")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .makeFolder(at: "/Applied"),
            precondition: .pathAbsent
        )
        let runID = UUID(uuidString: "ab000000-0000-0000-0000-000000000003")!
        let syncSetID = UUID(
            uuidString: "ab000000-0000-0000-0000-000000000004"
        )!
        let receipt = ProviderMutationReceipt(
            id: UUID(uuidString: "ab000000-0000-0000-0000-000000000005")!,
            provider: location.id,
            kind: .makeFolder,
            affectedPaths: ["/Applied"],
            startedAt: Date(timeIntervalSince1970: 1_800_000_600),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            ),
            rootIdentity: mode.receiptVolumeIdentity.map {
                ProviderMutationRootIdentity(
                    canonicalRootPath: originalCanonicalPath,
                    volumeIdentity: $0
                )
            }
        )
        let journalRoot = world.appendingPathComponent("Journal", isDirectory: true)
        let writer = try FileRunJournalStore(rootURL: journalRoot)
        try await writer.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: mode.rawValue)
        )
        try await writer.append(.intent(operation), runID: runID)
        try await writer.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_601)
            ),
            runID: runID
        )

        if mode == .replacementVolume {
            try FileManager.default.moveItem(at: rootA, to: detachedA)
            try FileManager.default.moveItem(at: rootB, to: rootA)
        } else if mode == .symlinkRetarget {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(
                atPath: alias.path,
                withDestinationPath: rootB.path
            )
        }

        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity(mode.currentVolumeIdentity)
        let hook = RecordingLocalMutationHook()
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: configuredRoot,
            volumes: inspector,
            mutationHook: hook,
            registry: LocalRootIORegistry()
        )
        let journal = try FileRunJournalStore(rootURL: journalRoot)
        let stores = recoveryStores(journal: journal)
        let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

        await #expect(
            throws: RunRecoveryError.indeterminateMutationStillRunning(
                operationID: operationID,
                receiptID: receipt.id
            )
        ) {
            _ = try await RunRecovery(
                providers: [location.id: provider],
                stores: stores
            ).recover(replay)
        }
        #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("A mismatched durable receipt did not retain its barrier.")
            return
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.makeFolder(at: "/MustNotMutate")
        }
        #expect(hook.kinds().isEmpty)
        let currentRoot = mode == .symlinkRetarget ? rootB : rootA
        #expect(
            !FileManager.default.fileExists(
                atPath: currentRoot.appendingPathComponent("MustNotMutate").path
            )
        )
        #expect(
            try Data(contentsOf: currentRoot.appendingPathComponent("Preserve.txt"))
                == Data("preserve replacement".utf8)
        )
    }

    @Test func durableReceiptRecoversThroughSameRootAliasAfterRestart() async throws {
        let world = try makeRoot("durable-root-alias-restart")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        let alias = world.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Applied"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: root.path
        )
        let location = localLocation(
            id: LocationID(
                UUID(uuidString: "ac000000-0000-0000-0000-000000000001")!
            )
        )
        let operationID = OperationID(
            UUID(uuidString: "ac000000-0000-0000-0000-000000000002")!
        )
        let operation = AetherloomCore.Operation(
            id: operationID,
            location: location.id,
            kind: .makeFolder(at: "/Applied"),
            precondition: .pathAbsent
        )
        let runID = UUID(uuidString: "ac000000-0000-0000-0000-000000000003")!
        let syncSetID = UUID(
            uuidString: "ac000000-0000-0000-0000-000000000004"
        )!
        let receipt = ProviderMutationReceipt(
            id: UUID(uuidString: "ac000000-0000-0000-0000-000000000005")!,
            provider: location.id,
            kind: .makeFolder,
            affectedPaths: ["/Applied"],
            startedAt: Date(timeIntervalSince1970: 1_800_000_610),
            correlation: ProviderMutationCorrelation(
                runID: runID,
                operationID: operationID
            ),
            rootIdentity: mutationRootIdentity(for: root)
        )
        let journalRoot = world.appendingPathComponent("Journal", isDirectory: true)
        let writer = try FileRunJournalStore(rootURL: journalRoot)
        try await writer.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "same-root-alias-restart")
        )
        try await writer.append(.intent(operation), runID: runID)
        try await writer.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_611)
            ),
            runID: runID
        )

        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: alias,
            volumes: ScriptedVolumeInspector(),
            registry: LocalRootIORegistry()
        )
        let journal = try FileRunJournalStore(rootURL: journalRoot)
        let report = try await RunRecovery(
            providers: [location.id: provider],
            stores: recoveryStores(journal: journal)
        ).recover(try #require(try await journal.unfinishedRun(for: syncSetID)))

        #expect(report.reconciledOperations == [operationID])
        #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
        guard case .complete = (await provider.scan(.entireDrive)).status else {
            Issue.record("The same physical root alias did not resume after recovery.")
            return
        }
    }

    @Test(arguments: RootIdentitySwapPoint.allCases)
    func identitySwapAfterAwaitedProbeStopsReadAndMutation(
        _ point: RootIdentitySwapPoint
    ) async throws {
        let root = try makeRoot("identity-swap-after-\(point.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preserve".utf8).write(to: root.appendingPathComponent("Present.txt"))
        let inspector = BlockingRootIdentityInspector()
        let hook = RecordingLocalMutationHook()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector,
            mutationHook: hook,
            registry: LocalRootIORegistry()
        )

        await inspector.arm(point)
        let scan = Task { await provider.scan(.entireDrive) }
        await inspector.waitUntilBlocked()
        await inspector.setVolumeIdentity("replacement-volume")
        await inspector.release()
        let snapshot = await scan.value
        guard case .unavailable = snapshot.status else {
            Issue.record("A read returned truth after the physical root changed.")
            return
        }
        #expect(snapshot.observations.all.isEmpty)

        await inspector.setVolumeIdentity("scripted-volume")
        await inspector.arm(point)
        let mutation = Task { () -> Bool in
            do {
                _ = try await provider.makeFolder(at: "/MustNotMutate")
                return false
            } catch is ProviderError {
                return true
            } catch {
                return false
            }
        }
        await inspector.waitUntilBlocked()
        await inspector.setVolumeIdentity("replacement-volume")
        await inspector.release()
        #expect(await mutation.value)
        #expect(hook.kinds().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("MustNotMutate").path
            )
        )

        await inspector.setVolumeIdentity("scripted-volume")
        await inspector.arm(point)
        let control = Task {
            try await provider.makeFolder(at: "/UnchangedControl")
        }
        await inspector.waitUntilBlocked()
        await inspector.release()
        let controlled = try await control.value
        #expect(controlled.path == "/UnchangedControl")
        #expect(hook.kinds() == [.makeFolder])
    }

    @Test func symlinkRetargetBeforeCrossVolumeTrashRetainsExactReceipt() async throws {
        let world = try makeRoot("cross-volume-pre-trash-retarget")
        defer { try? FileManager.default.removeItem(at: world) }
        let rootA = world.appendingPathComponent("Root A", isDirectory: true)
        let rootB = world.appendingPathComponent("Root B", isDirectory: true)
        let alias = world.appendingPathComponent("Alias", isDirectory: true)
        let destinationFolder = rootA.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let sourceURL = rootA.appendingPathComponent("Source.txt")
        try Data("cross-volume".utf8).write(to: sourceURL)
        try Data("preserve-b".utf8).write(to: rootB.appendingPathComponent("Preserve.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: rootA.path
        )
        let inspector = ScriptedVolumeInspector()
        await inspector.setVolumeIdentity("scripted-volume", at: sourceURL)
        await inspector.setVolumeIdentity("destination-volume", at: destinationFolder)
        let relocation = RetargetingBeforeSourceTrashRelocationPerformer(
            alias: alias,
            replacementRoot: rootB
        )
        let quarantine = RecordingQuarantinePerformer()
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: alias,
            volumes: inspector,
            relocation: relocation,
            quarantine: quarantine,
            registry: LocalRootIORegistry()
        )
        let source = try #require(
            (await provider.scan(.entireDrive)).observations.byPath["/Source.txt"]
        )

        let receipt: ProviderMutationReceipt
        do {
            _ = try await provider.relocate(source, to: "/Destination/Moved.txt")
            Issue.record("Retargeted relocation unexpectedly completed.")
            return
        } catch let ProviderError.mutationIndeterminate(value) {
            receipt = value
        }
        #expect(
            receipt.rootIdentity == ProviderMutationRootIdentity(
                canonicalRootPath: rootA.resolvingSymlinksInPath()
                    .standardizedFileURL.path,
                volumeIdentity: "scripted-volume"
            )
        )
        #expect(relocation.sourceTrashChecks() == 1)
        #expect(quarantine.moveCount() == 0)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: destinationFolder.appendingPathComponent("Moved.txt").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: rootA.appendingPathComponent(".aetherloom").path
            )
        )
        #expect(
            try Data(contentsOf: rootB.appendingPathComponent("Preserve.txt"))
                == Data("preserve-b".utf8)
        )
        guard case .unavailable = (await provider.scan(.entireDrive)).status else {
            Issue.record("The retargeted relocation did not retain its barrier.")
            return
        }
    }

    @Test func mutationDeadlineBeforeStartHasNoFilesystemSideEffect() async throws {
        let root = try makeRoot("mutation-pre-start-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging.bin")
        try Data("never copied".utf8).write(to: staging)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(ioNanoseconds: 0)
        )

        await #expect(
            throws: ProviderError.mutationDeadlineExpiredBeforeStart(
                provider: provider.locationID,
                path: "/Never.txt"
            )
        ) {
            _ = try await provider.store(
                from: staging,
                at: "/Never.txt",
                options: StoreOptions()
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Never.txt").path
            )
        )
    }

    @Test func postStartStoreTimeoutBlocksScansUntilLateSuccessIsReconciled() async throws {
        let root = try makeRoot("mutation-late-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging.bin")
        try Data("late success".utf8).write(to: staging)
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook()
        let receiptID = UUID(uuidString: "a2000000-0000-0000-0000-000000000001")!
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(
                ioNanoseconds: 1,
                clock: clock,
                makeMutationID: { receiptID }
            ),
            mutationHook: hook
        )
        await clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a5000000-0000-0000-0000-000000000003")!,
            operationID: OperationID(
                UUID(uuidString: "a5000000-0000-0000-0000-000000000004")!
            )
        )

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await provider.store(
                            from: staging,
                            at: "/Late.txt",
                            options: StoreOptions()
                        )
                    }
                Issue.record("Store unexpectedly completed before its deadline.")
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected store error: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await call.value)
        #expect(receipt.id == receiptID)

        let blockedScan = await provider.scan(.entireDrive)
        guard case .unavailable = blockedScan.status else {
            Issue.record("Scan was allowed to race an indeterminate mutation.")
            hook.release()
            return
        }

        hook.release()
        await waitForProviderMutationQuiescence(provider, receipt: receipt)
        #expect(
            await provider.indeterminateMutationState(for: receipt)
                == .quiescent(.succeeded)
        )
        #expect(await provider.indeterminateMutationReceipt() == receipt)
        guard case let .claimed(claim) = await provider
            .beginIndeterminateMutationRecovery(for: receipt) else {
            Issue.record("Store recovery could not claim the receipt.")
            return
        }
        let recovered = try await provider.currentStateForRecovery(
            of: ItemObservation(
                location: provider.locationID,
                path: "/Late.txt",
                kind: .file
            ),
            claim: claim
        )
        #expect(recovered.path == "/Late.txt")
        await provider.finishIndeterminateMutationRecovery(claim)
        #expect(await provider.indeterminateMutationReceipt() == nil)

        guard case .complete = (await provider.scan(.entireDrive)).status else {
            Issue.record("Provider did not resume after reconciliation.")
            return
        }
        _ = try await provider.makeFolder(at: "/AfterRecovery")
    }

    @Test func postStartStoreTimeoutRetainsLateFailure() async throws {
        let root = try makeRoot("mutation-late-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging.bin")
        try Data("late failure".utf8).write(to: staging)
        let clock = ProviderMutationManualClock()
        let hook = BlockingLocalMutationHook(failsWhenReleased: true)
        let provider = await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: ScriptedVolumeInspector(),
            deadlines: ProviderDeadlines(ioNanoseconds: 1, clock: clock),
            mutationHook: hook
        )
        await clock.waitUntilIdle()
        let correlation = ProviderMutationCorrelation(
            runID: UUID(uuidString: "a5000000-0000-0000-0000-000000000005")!,
            operationID: OperationID(
                UUID(uuidString: "a5000000-0000-0000-0000-000000000006")!
            )
        )

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await ProviderMutationExecutionContext.$correlation
                    .withValue(correlation) {
                        try await provider.store(
                            from: staging,
                            at: "/Failure.txt",
                            options: StoreOptions()
                        )
                    }
                return nil
            } catch let ProviderError.mutationIndeterminate(receipt) {
                return receipt
            } catch {
                Issue.record("Unexpected store error: \(error)")
                return nil
            }
        }
        await hook.waitUntilStarted(count: 1)
        await clock.waitUntilSleeping()
        await clock.fireAll()
        let receipt = try #require(await call.value)
        hook.release()
        await waitForProviderMutationQuiescence(provider, receipt: receipt)

        guard case .quiescent(.failed) = await provider
            .indeterminateMutationState(for: receipt) else {
            Issue.record("Provider discarded the late failure.")
            return
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Failure.txt").path
            )
        )
        guard case let .claimed(claim) = await provider
            .beginIndeterminateMutationRecovery(for: receipt) else {
            Issue.record("Failed store recovery could not claim the receipt.")
            return
        }
        await provider.finishIndeterminateMutationRecovery(claim)
    }

    private func makeRoot(_ name: String) throws -> URL {
        try TestTemporaryDirectory.make(
            suite: "LocalFolderStorageProviderTests",
            name: name
        )
    }

    private func makeProvider(
        root: URL,
        inspector: ScriptedVolumeInspector
    ) async -> LocalFolderStorageProvider {
        await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector
        )
    }

    private func recoveryStores(journal: any RunJournalStore) -> EngineStores {
        EngineStores(
            baseRecords: InMemoryBaseRecordStore(),
            journal: journal,
            conflicts: InMemoryConflictStore(),
            adviceCache: InMemoryAdviceCacheStore(),
            activity: InMemoryActivityStore(),
            locations: InMemoryLocationRegistry()
        )
    }

    private func mutationRootIdentity(
        for root: URL,
        volumeIdentity: String = "scripted-volume"
    ) -> ProviderMutationRootIdentity {
        ProviderMutationRootIdentity(
            canonicalRootPath: root.resolvingSymlinksInPath()
                .standardizedFileURL.path,
            volumeIdentity: volumeIdentity
        )
    }

    private func writeLegacyTrashReceipt(
        root: URL,
        observation: ItemObservation,
        method: LegacyTrashReceiptMethod,
        recoveryPath: String?
    ) throws {
        let receiptDirectory = root
            .appendingPathComponent(".aetherloom", isDirectory: true)
            .appendingPathComponent("trash-receipts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: receiptDirectory,
            withIntermediateDirectories: true
        )
        let key = LegacyTrashReceiptKey(
            location: observation.location,
            path: observation.path,
            kind: observation.kind
        )
        let keyData = try CanonicalCoding.encoder().encode(key)
        let receipt = LegacyTrashReceiptFixture(
            observation: observation,
            method: method,
            recoveryPath: recoveryPath,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try CanonicalCoding.encoder().encode(receipt).write(
            to: receiptDirectory.appendingPathComponent(
                CanonicalCoding.sha256Hex(keyData) + ".json"
            ),
            options: .atomic
        )
    }

    private func localLocation(
        id: LocationID = LocationID(),
        kind: ProviderKind = .localFolder,
        expectedVolumeIdentity: String = "scripted-volume"
    ) -> SyncLocation {
        SyncLocation(
            id: id,
            kind: kind,
            configuration: [
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                    expectedVolumeIdentity,
            ]
        )
    }
}

enum PostMoveTrashMode: String, CaseIterable, Sendable {
    case nativeTrash
    case nativeTrashMoveThenThrow
    case nativeTrashNilResult
    case nativeTrashSourceChanged
    case nativeTrashSourceUnavailable
    case nativeTrashArtifactMissing
    case nativeTrashArtifactUnavailable
    case quarantine
    case quarantineMissingArtifact
    case quarantineUnavailableArtifact

    var receiptID: UUID {
        switch self {
        case .nativeTrash:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000011")!
        case .nativeTrashMoveThenThrow:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000022")!
        case .nativeTrashNilResult:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000023")!
        case .nativeTrashSourceChanged:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000024")!
        case .nativeTrashSourceUnavailable:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000025")!
        case .nativeTrashArtifactMissing:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000026")!
        case .nativeTrashArtifactUnavailable:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000027")!
        case .quarantine:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000012")!
        case .quarantineMissingArtifact:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000020")!
        case .quarantineUnavailableArtifact:
            UUID(uuidString: "a3000000-0000-0000-0000-000000000021")!
        }
    }

    var usesNativeTrash: Bool {
        switch self {
        case .nativeTrash,
             .nativeTrashMoveThenThrow,
             .nativeTrashNilResult,
             .nativeTrashSourceChanged,
             .nativeTrashSourceUnavailable,
             .nativeTrashArtifactMissing,
             .nativeTrashArtifactUnavailable:
            true
        case .quarantine,
             .quarantineMissingArtifact,
             .quarantineUnavailableArtifact:
            false
        }
    }
}

enum DurableRootMismatchMode: String, CaseIterable, Sendable {
    case replacementVolume
    case symlinkRetarget
    case legacyMissingIdentity

    var currentVolumeIdentity: String {
        switch self {
        case .replacementVolume:
            "volume-b"
        case .symlinkRetarget:
            "shared-volume"
        case .legacyMissingIdentity:
            "scripted-volume"
        }
    }

    var receiptVolumeIdentity: String? {
        switch self {
        case .replacementVolume:
            "volume-a"
        case .symlinkRetarget:
            "shared-volume"
        case .legacyMissingIdentity:
            nil
        }
    }
}

enum RootIdentitySwapPoint: String, CaseIterable, Sendable {
    case responsiveness
    case directoryInspection
}

enum PostPhysicalCommitMode: String, CaseIterable, Sendable {
    case newStore
    case replacementStore
    case makeFolder
    case sameVolumeRelocate
    case crossVolumePostCopy
    case crossVolumePostTrash

    var targetPath: SyncPath {
        switch self {
        case .newStore:
            "/NewStore.txt"
        case .replacementStore:
            "/Replacement.txt"
        case .makeFolder:
            "/CreatedFolder"
        case .sameVolumeRelocate:
            "/Relocated.txt"
        case .crossVolumePostCopy, .crossVolumePostTrash:
            "/Destination/Relocated.txt"
        }
    }

    var receiptID: UUID {
        switch self {
        case .newStore:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000021")!
        case .replacementStore:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000022")!
        case .makeFolder:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000023")!
        case .sameVolumeRelocate:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000024")!
        case .crossVolumePostCopy:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000025")!
        case .crossVolumePostTrash:
            UUID(uuidString: "a4000000-0000-0000-0000-000000000026")!
        }
    }

    var isRelocate: Bool {
        switch self {
        case .sameVolumeRelocate,
             .crossVolumePostCopy,
             .crossVolumePostTrash:
            true
        case .newStore, .replacementStore, .makeFolder:
            false
        }
    }

    var isCrossVolume: Bool {
        switch self {
        case .crossVolumePostCopy, .crossVolumePostTrash:
            true
        case .newStore,
             .replacementStore,
             .makeFolder,
             .sameVolumeRelocate:
            false
        }
    }

    var physicalCommitFailureCall: Int {
        self == .crossVolumePostTrash ? 2 : 1
    }

    var expectedMutationKind: ProviderMutationKind {
        switch self {
        case .newStore, .replacementStore:
            .store
        case .makeFolder:
            .makeFolder
        case .sameVolumeRelocate,
             .crossVolumePostCopy,
             .crossVolumePostTrash:
            .relocate
        }
    }
}

enum CrossVolumeCopyFailureMode: String, CaseIterable, Sendable {
    case noMutation
    case destinationInspectionUnavailable
    case cleanupArtifactInspectionUnavailable

    var receiptID: UUID {
        switch self {
        case .noMutation:
            UUID(uuidString: "a6000000-0000-0000-0000-000000000021")!
        case .destinationInspectionUnavailable:
            UUID(uuidString: "a6000000-0000-0000-0000-000000000022")!
        case .cleanupArtifactInspectionUnavailable:
            UUID(uuidString: "a6000000-0000-0000-0000-000000000023")!
        }
    }
}

enum MultiAliasRecoveryScenario: String, CaseIterable, Sendable {
    case sameProcessReceiptFirst
    case sameProcessReceiptLast
    case restartReceiptFirst
    case restartReceiptLast

    var restartsProcess: Bool {
        self == .restartReceiptFirst || self == .restartReceiptLast
    }

    var receiptOperationID: OperationID {
        OperationID(
            UUID(
                uuidString: self == .sameProcessReceiptFirst
                    || self == .restartReceiptFirst
                    ? "a8000000-0000-0000-0000-000000000010"
                    : "a8000000-0000-0000-0000-000000000012"
            )!
        )
    }

    var intentOnlyOperationID: OperationID {
        OperationID(
            UUID(
                uuidString: self == .sameProcessReceiptFirst
                    || self == .restartReceiptFirst
                    ? "a8000000-0000-0000-0000-000000000011"
                    : "a8000000-0000-0000-0000-000000000009"
            )!
        )
    }
}

enum LegacyTrashRecoveryOperation: String, CaseIterable, Sendable {
    case trash
    case relocate

    private var tail: String {
        self == .trash ? "1" : "2"
    }

    var locationID: UUID {
        UUID(uuidString: "a9000000-0000-0000-0000-00000000000\(tail)")!
    }

    var operationID: UUID {
        UUID(uuidString: "a9000000-0000-0000-0000-00000000001\(tail)")!
    }

    var receiptID: UUID {
        UUID(uuidString: "a9000000-0000-0000-0000-00000000002\(tail)")!
    }

    var runID: UUID {
        UUID(uuidString: "a9000000-0000-0000-0000-00000000003\(tail)")!
    }

    var syncSetID: UUID {
        UUID(uuidString: "a9000000-0000-0000-0000-00000000004\(tail)")!
    }
}

enum LegacyTrashFailureMode: String, CaseIterable, Sendable {
    case missingArtifact
    case unavailableArtifact
    case mismatchedArtifact
    case nativeWithoutArtifactPath

    private var tail: String {
        switch self {
        case .missingArtifact: "1"
        case .unavailableArtifact: "2"
        case .mismatchedArtifact: "3"
        case .nativeWithoutArtifactPath: "4"
        }
    }

    var locationID: UUID {
        UUID(uuidString: "aa000000-0000-0000-0000-00000000000\(tail)")!
    }

    var operationID: UUID {
        UUID(uuidString: "aa000000-0000-0000-0000-00000000001\(tail)")!
    }

    var receiptID: UUID {
        UUID(uuidString: "aa000000-0000-0000-0000-00000000002\(tail)")!
    }

    var runID: UUID {
        UUID(uuidString: "aa000000-0000-0000-0000-00000000003\(tail)")!
    }

    var syncSetID: UUID {
        UUID(uuidString: "aa000000-0000-0000-0000-00000000004\(tail)")!
    }
}

private enum LegacyTrashReceiptMethod: String, Codable, Sendable {
    case nativeTrash
    case quarantine
}

private struct LegacyTrashReceiptFixture: Codable, Sendable {
    var observation: ItemObservation
    var method: LegacyTrashReceiptMethod
    var recoveryPath: String?
    var startedAt: Date
}

private struct LegacyTrashReceiptKey: Codable, Sendable {
    var location: LocationID
    var path: SyncPath
    var kind: ItemKind
}

private actor BlockingReadVolumeInspector: VolumeInspecting {
    private var mountCallCount = 0
    private var blockedMountCall: Int?
    private var mountIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockNextMountInspection() {
        blockedMountCall = mountCallCount + 1
    }

    func blockMountInspection(number: Int) {
        blockedMountCall = number
    }

    func waitUntilBlocked() async {
        if mountIsBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        mountIsBlocked = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func mountState(for _: URL) async -> VolumeMountState {
        mountCallCount += 1
        if blockedMountCall == mountCallCount {
            blockedMountCall = nil
            mountIsBlocked = true
            let observers = blockedWaiters
            blockedWaiters.removeAll()
            for observer in observers {
                observer.resume()
            }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .mounted
    }

    func responsiveness(for _: URL) async -> VolumeResponsiveness { .responsive }
    func properties(for _: URL) async -> VolumeProperties? {
        VolumeProperties(
            isCaseSensitive: false,
            supportsNativeTrash: false,
            isNetwork: false
        )
    }
    func directoryState(at _: URL) async -> InspectedDirectoryState {
        .present(isReadable: true)
    }
    func volumeIdentity(for _: URL) async -> String? { "scripted-volume" }
}

private actor BlockingRootIdentityInspector: VolumeInspecting {
    private var volumeIdentity = "scripted-volume"
    private var armedPoint: RootIdentitySwapPoint?
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(_ point: RootIdentitySwapPoint) {
        armedPoint = point
    }

    func setVolumeIdentity(_ identity: String) {
        volumeIdentity = identity
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        isBlocked = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func mountState(for _: URL) async -> VolumeMountState { .mounted }

    func responsiveness(for _: URL) async -> VolumeResponsiveness {
        await blockIfArmed(.responsiveness)
        return .responsive
    }

    func properties(for _: URL) async -> VolumeProperties? {
        VolumeProperties(
            isCaseSensitive: false,
            supportsNativeTrash: false,
            isNetwork: false
        )
    }

    func directoryState(at _: URL) async -> InspectedDirectoryState {
        await blockIfArmed(.directoryInspection)
        return .present(isReadable: true)
    }

    func volumeIdentity(for _: URL) async -> String? { volumeIdentity }

    private func blockIfArmed(_ point: RootIdentitySwapPoint) async {
        guard armedPoint == point else { return }
        armedPoint = nil
        isBlocked = true
        let observers = blockedWaiters
        blockedWaiters.removeAll()
        for observer in observers {
            observer.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private struct SourceMutatingFetchPerformer: LocalFetchPerforming {
    let replacement: Data
    let modifiedAt: Date

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try replacement.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: source.path
        )
    }
}

private struct CorruptingFetchPerformer: LocalFetchPerforming {
    let replacement: Data

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try replacement.write(to: destination)
    }
}

private struct AlwaysFailingNativeTrashPerformer: LocalNativeTrashPerforming {
    struct ExpectedFailure: Error {}

    func trashItem(at _: URL) throws -> URL? {
        throw ExpectedFailure()
    }
}

private struct FailingNativeTrashThatBlocksQuarantine:
    LocalNativeTrashPerforming
{
    struct ExpectedFailure: Error {}

    let root: URL
    let outside: URL

    func trashItem(at _: URL) throws -> URL? {
        let internalRoot = root.appendingPathComponent(
            ".aetherloom",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: internalRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: internalRoot.appendingPathComponent("trash"),
            withDestinationURL: outside
        )
        throw ExpectedFailure()
    }
}

private struct MoveThenThrowNativeTrashPerformer: LocalNativeTrashPerforming {
    struct ExpectedFailure: Error {}
    let destination: URL

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: destination)
        throw ExpectedFailure()
    }
}

private struct MoveThenReturnNilNativeTrashPerformer:
    LocalNativeTrashPerforming
{
    let destination: URL

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: destination)
        return nil
    }
}

private struct ChangeSourceThenThrowNativeTrashPerformer:
    LocalNativeTrashPerforming
{
    struct ExpectedFailure: Error {}
    let holdingURL: URL

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: holdingURL)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        throw ExpectedFailure()
    }
}

private struct HideRootThenThrowNativeTrashPerformer:
    LocalNativeTrashPerforming
{
    struct ExpectedFailure: Error {}
    let root: URL
    let hiddenRoot: URL
    let holdingURL: URL

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: holdingURL)
        try FileManager.default.moveItem(at: root, to: hiddenRoot)
        throw ExpectedFailure()
    }
}

private struct ScriptedArtifactNativeTrashPerformer:
    LocalNativeTrashPerforming
{
    let holdingURL: URL
    let reportedURL: URL
    let scriptedArtifactState: LocalRecoveryArtifactState

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: holdingURL)
        return reportedURL
    }

    func artifactState(at _: URL) -> LocalRecoveryArtifactState {
        scriptedArtifactState
    }
}

private struct MovingNativeTrashPerformer: LocalNativeTrashPerforming {
    let destination: URL

    func trashItem(at source: URL) throws -> URL? {
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

private struct MoveThenThrowQuarantinePerformer: LocalQuarantinePerforming {
    struct ExpectedFailure: Error {}

    let holdingURL: URL
    let scriptedArtifactState: LocalRecoveryArtifactState

    func moveItem(at source: URL, to _: URL) throws {
        try FileManager.default.moveItem(at: source, to: holdingURL)
        throw ExpectedFailure()
    }

    func artifactState(at _: URL) -> LocalRecoveryArtifactState {
        scriptedArtifactState
    }
}

private struct ThrowWithoutMovingQuarantinePerformer: LocalQuarantinePerforming {
    struct ExpectedFailure: Error {}

    func moveItem(at _: URL, to _: URL) throws {
        throw ExpectedFailure()
    }

    func artifactState(at _: URL) -> LocalRecoveryArtifactState {
        .unavailable(detail: "Inspection must not matter while the source remains.")
    }
}

private struct UnavailableLegacyQuarantinePerformer:
    LocalQuarantinePerforming
{
    struct UnexpectedMove: Error {}

    func moveItem(at _: URL, to _: URL) throws {
        throw UnexpectedMove()
    }

    func artifactState(at _: URL) -> LocalRecoveryArtifactState {
        .unavailable(detail: "Scripted legacy artifact inspection failure.")
    }
}

private final class FailAfterFirstTrashReceiptPersister:
    LocalTrashReceiptPersisting,
    @unchecked Sendable
{
    struct ExpectedFailure: Error {}

    private let lock = NSLock()
    private var writes = 0

    func persist(_ data: Data, at url: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            writes += 1
            return writes > 1
        }
        if shouldFail {
            throw ExpectedFailure()
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class PartialCopyOnceRelocationPerformer:
    LocalRelocationPerforming,
    @unchecked Sendable
{
    struct ExpectedFailure: Error {}
    private let lock = NSLock()
    private var shouldFail = true

    func copyItem(at source: URL, to destination: URL) throws {
        lock.lock()
        let failsThisCall = shouldFail
        shouldFail = false
        lock.unlock()
        if failsThisCall {
            try Data("partial".utf8).write(to: destination)
            throw ExpectedFailure()
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func beforeSourceTrash(at _: URL) throws {}
}

private final class TrashFailureOnceRelocationPerformer:
    LocalRelocationPerforming,
    @unchecked Sendable
{
    struct ExpectedFailure: Error {}
    private let lock = NSLock()
    private var shouldFail = true

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func beforeSourceTrash(at _: URL) throws {
        lock.lock()
        let failsThisCall = shouldFail
        shouldFail = false
        lock.unlock()
        if failsThisCall {
            throw ExpectedFailure()
        }
    }
}

private final class ScriptedCrossVolumeCopyFailurePerformer:
    LocalRelocationPerforming,
    @unchecked Sendable
{
    struct ExpectedFailure: Error {}

    let mode: CrossVolumeCopyFailureMode
    let destination: URL

    init(mode: CrossVolumeCopyFailureMode, destination: URL) {
        self.mode = mode
        self.destination = destination.standardizedFileURL
    }

    func copyItem(at source: URL, to destination: URL) throws {
        switch mode {
        case .noMutation:
            break
        case .destinationInspectionUnavailable,
             .cleanupArtifactInspectionUnavailable:
            try FileManager.default.copyItem(at: source, to: destination)
        }
        throw ExpectedFailure()
    }

    func beforeSourceTrash(at _: URL) throws {}

    func moveItemToRecovery(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
        if mode == .cleanupArtifactInspectionUnavailable {
            throw ExpectedFailure()
        }
    }

    func artifactState(at url: URL) -> LocalRecoveryArtifactState {
        let standardized = url.standardizedFileURL
        if mode == .destinationInspectionUnavailable,
           standardized == destination {
            return .unavailable(detail: "Destination inspection unavailable.")
        }
        if mode == .cleanupArtifactInspectionUnavailable,
           standardized != destination {
            return .unavailable(detail: "Cleanup artifact inspection unavailable.")
        }
        return FileManager.default.fileExists(atPath: standardized.path)
            ? .present
            : .missing
    }
}

private final class RetargetingBeforeSourceTrashRelocationPerformer:
    LocalRelocationPerforming,
    @unchecked Sendable
{
    private let alias: URL
    private let replacementRoot: URL
    private let lock = NSLock()
    private var checks = 0

    init(alias: URL, replacementRoot: URL) {
        self.alias = alias
        self.replacementRoot = replacementRoot
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func beforeSourceTrash(at _: URL) throws {
        lock.withLock { checks += 1 }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: replacementRoot.path
        )
    }

    func sourceTrashChecks() -> Int {
        lock.withLock { checks }
    }
}

private final class RecordingQuarantinePerformer:
    LocalQuarantinePerforming,
    @unchecked Sendable
{
    struct UnexpectedMove: Error {}
    private let lock = NSLock()
    private var moves = 0

    func moveItem(at _: URL, to _: URL) throws {
        lock.withLock { moves += 1 }
        throw UnexpectedMove()
    }

    func moveCount() -> Int {
        lock.withLock { moves }
    }

    func artifactState(at _: URL) -> LocalRecoveryArtifactState { .missing }
}

private final class RecordingLocalMutationHook:
    LocalMutationStarting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recorded: [ProviderMutationKind] = []

    func beforeMutation(_ receipt: ProviderMutationReceipt) throws {
        lock.withLock {
            recorded.append(receipt.kind)
        }
    }

    func kinds() -> [ProviderMutationKind] {
        lock.withLock { recorded }
    }
}

private final class BlockingLocalMutationHook:
    LocalMutationStarting,
    @unchecked Sendable
{
    struct ScriptedFailure: Error {}

    private let condition = NSCondition()
    private let failsWhenReleased: Bool
    private let failingPhysicalCommitCall: Int?
    private var startedCount = 0
    private var startedKinds: [ProviderMutationKind] = []
    private var physicalCommitCount = 0
    private var released = false

    init(
        failsWhenReleased: Bool = false,
        failsAfterPhysicalCommit: Bool = false,
        failsAfterPhysicalCommitCall: Int? = nil
    ) {
        self.failsWhenReleased = failsWhenReleased
        self.failingPhysicalCommitCall = failsAfterPhysicalCommitCall
            ?? (failsAfterPhysicalCommit ? 1 : nil)
    }

    func afterPhysicalCommit(_: ProviderMutationReceipt) throws {
        condition.lock()
        physicalCommitCount += 1
        let shouldFail = failingPhysicalCommitCall.map {
            $0 == physicalCommitCount
        } ?? false
        condition.unlock()
        if shouldFail {
            throw ScriptedFailure()
        }
    }

    func beforeMutation(_ receipt: ProviderMutationReceipt) throws {
        condition.lock()
        startedCount += 1
        startedKinds.append(receipt.kind)
        condition.broadcast()
        while !released {
            condition.wait()
        }
        let shouldFail = failsWhenReleased
        condition.unlock()
        if shouldFail {
            throw ScriptedFailure()
        }
    }

    func waitUntilStarted(count: Int) async {
        while currentStartedCount() < count {
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func kinds() -> [ProviderMutationKind] {
        condition.lock()
        defer { condition.unlock() }
        return startedKinds
    }

    private func currentStartedCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return startedCount
    }
}

private actor ProviderMutationManualClock: ProviderDeadlineClock {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiterDurations: [UUID: UInt64] = [:]
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                waiterDurations[id] = nanoseconds
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

    func waitUntilSleeping(nanoseconds: UInt64, count: Int) async {
        while waiterDurations.values.filter({ $0 == nanoseconds }).count < count {
            await Task.yield()
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
        waiterDurations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        waiterDurations[id] = nil
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class LockedUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(
                !values.isEmpty,
                "The deterministic UUID sequence was exhausted."
            )
            return values.removeFirst()
        }
    }
}

private func waitForProviderMutationQuiescence(
    _ provider: LocalFolderStorageProvider,
    receipt: ProviderMutationReceipt
) async {
    while await provider.indeterminateMutationState(for: receipt) == .inFlight {
        await Task.yield()
    }
}
