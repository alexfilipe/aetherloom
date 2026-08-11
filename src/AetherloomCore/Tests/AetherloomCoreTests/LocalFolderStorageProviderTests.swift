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
                    .directory(root.standardizedFileURL.path),
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

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                try await provider.fetch(observation, to: staging)
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
            startedAt: Date(timeIntervalSince1970: 1_800_000_050)
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
        #expect(records.count == 1)
        #expect(records.first?.path == original.path)
        #expect(records.first?.tombstone != nil)
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

    @Test func nativeTrashMoveThenThrowConfirmsAbsenceWithoutQuarantine() async throws {
        let world = try makeRoot("native-trash-move-throw")
        defer { try? FileManager.default.removeItem(at: world) }
        let root = world.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("MovedThenThrew.txt")
        let movedURL = world.appendingPathComponent("NativeRecovery.txt")
        let contents = Data("moved before error".utf8)
        try contents.write(to: sourceURL)
        let location = localLocation()
        let provider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: false,
                    supportsNativeTrash: true,
                    isNetwork: false
                )
            ),
            nativeTrash: MoveThenThrowNativeTrashPerformer(destination: movedURL)
        )
        let observation = try #require(
            (await provider.scan(.entireDrive))
                .observations.byPath["/MovedThenThrew.txt"]
        )

        try await provider.trash(observation)
        try await provider.trash(observation)
        let restartedProvider = await LocalFolderStorageProvider.make(
            location: location,
            rootURL: root,
            volumes: ScriptedVolumeInspector(
                properties: VolumeProperties(
                    isCaseSensitive: false,
                    supportsNativeTrash: true,
                    isNetwork: false
                )
            )
        )
        #expect(try await restartedProvider.currentState(of: observation).isTrashed)
        try await restartedProvider.trash(observation)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: movedURL) == contents)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".aetherloom/trash").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".aetherloom/trash-receipts").path
            )
        )
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
        await #expect(
            throws: ProviderError.notFound(
                provider: provider.locationID,
                path: observation.path
            )
        ) {
            _ = try await provider.currentState(of: observation)
        }
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
        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await first.store(
                    from: staging,
                    at: "/Late.txt",
                    options: StoreOptions()
                )
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
        try await stores.journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "same-root-reconstruction")
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
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

    @Test func rootRegistrySeparatesDifferentRootsAndVolumeIdentities() async {
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

        #expect(first.mutations === same.mutations)
        #expect(first.artifacts === same.artifacts)
        #expect(first.mutations === resolvedAlias.mutations)
        #expect(first.mutations !== differentRoot.mutations)
        #expect(first.mutations !== differentVolume.mutations)

        let unresolvedUnknownAlias = await registry.ownership(
            configuredRootPath: "/Volumes/One/BrokenAlias",
            resolvedCanonicalRootPath: nil,
            expectedVolumeIdentity: "volume-one"
        )
        #expect(unresolvedUnknownAlias.admissionIssue != nil)
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
            startedAt: Date(timeIntervalSince1970: 1_800_000_103)
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

        let mutation = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await first.makeFolder(at: "/LateFolder")
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
        try await stores.journal.begin(
            runID: runID,
            syncSetID: syncSetID,
            fingerprint: PlanFingerprint(rawValue: "broken-symlink-owner")
        )
        try await stores.journal.append(.intent(operation), runID: runID)
        try await stores.journal.append(
            .mutationIndeterminate(
                operationID: operationID,
                receipt: receipt,
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

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await provider.store(
                    from: staging,
                    at: "/Late.txt",
                    options: StoreOptions()
                )
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

        let call = Task { () -> ProviderMutationReceipt? in
            do {
                _ = try await provider.store(
                    from: staging,
                    at: "/Failure.txt",
                    options: StoreOptions()
                )
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

    private func localLocation(
        id: LocationID = LocationID(),
        kind: ProviderKind = .localFolder
    ) -> SyncLocation {
        SyncLocation(
            id: id,
            kind: kind,
            configuration: [
                LocalFolderStorageProvider.expectedVolumeIdentityConfigurationKey:
                    "scripted-volume",
            ]
        )
    }
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
    private var startedCount = 0
    private var released = false

    init(failsWhenReleased: Bool = false) {
        self.failsWhenReleased = failsWhenReleased
    }

    func beforeMutation(_: ProviderMutationReceipt) throws {
        condition.lock()
        startedCount += 1
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

    private func currentStartedCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return startedCount
    }
}

private actor ProviderMutationManualClock: ProviderDeadlineClock {
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

private func waitForProviderMutationQuiescence(
    _ provider: LocalFolderStorageProvider,
    receipt: ProviderMutationReceipt
) async {
    while await provider.indeterminateMutationState(for: receipt) == .inFlight {
        await Task.yield()
    }
}
