import Foundation
import Testing
@testable import AetherloomCore

@Suite("LocalFolderStorageProvider")
struct LocalFolderStorageProviderTests {
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
        #expect(await inspector.calls() == [.properties])
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
            location: SyncLocation(kind: .nasFolder),
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
            location: SyncLocation(kind: .localFolder),
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
                == [.mount, .responsiveness, .directory(root.standardizedFileURL.path)]
        )

        await inspector.setMountState(.notMounted(detail: "unplugged"))
        await inspector.clearCalls()
        #expect(
            await provider.checkAvailability()
                == .unavailable(.volumeNotMounted(detail: "unplugged"))
        )
        #expect(await inspector.calls() == [.mount])

        await inspector.setMountState(.mounted)
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
            location: SyncLocation(kind: .localFolder),
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
            location: SyncLocation(kind: .localFolder),
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
            throws: ProviderError.unavailable(
                provider: timedProvider.locationID,
                reason: "Filesystem fetch timed out."
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
        let failureObservation = ItemObservation(
            location: failureProvider.locationID,
            path: "/Source.txt",
            kind: .file
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
            location: SyncLocation(kind: .localFolder),
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
            location: SyncLocation(kind: .localFolder),
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
            location: SyncLocation(kind: .localFolder),
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
        #expect(second.version.isSameVersion(as: first.version))
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
            location: SyncLocation(kind: .localFolder),
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
        let provider = await LocalFolderStorageProvider.make(
            location: SyncLocation(kind: .localFolder),
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
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: movedURL) == contents)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".aetherloom").path
            )
        )
    }

    @Test func nativeTrashProducesRecoverableArtifact() async throws {
        let root = try makeRoot("native-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Native.txt")
        let contents = Data("native recovery".utf8)
        try contents.write(to: sourceURL)
        let provider = await LocalFolderStorageProvider.make(
            location: SyncLocation(kind: .localFolder),
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
            location: SyncLocation(kind: .localFolder),
            rootURL: root,
            volumes: inspector
        )
    }
}

private struct AlwaysFailingNativeTrashPerformer: LocalNativeTrashPerforming {
    struct ExpectedFailure: Error {}

    func trashItem(at _: URL) throws -> URL? {
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
