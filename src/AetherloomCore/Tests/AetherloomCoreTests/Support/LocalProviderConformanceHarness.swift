import Foundation
@testable import AetherloomCore

struct LocalProviderConformanceHarness: ProviderConformanceHarness {
    let testDescription = "LocalFolderStorageProvider"
    let declaredCapabilities = ProviderCapabilities(
        hasNativeTrash: false,
        hasStableItemIDs: false,
        hasContentHashes: false,
        hasChangeHints: false,
        supportsVersionCheckedStore: false,
        isCaseSensitive: false
    )
    let runsMutationConformance = true
    let runsPreservationConformance = true
    let preservesSeededUnicodeScalars = false

    func makeProvider(seeded: [ConformanceSeedItem]) async throws -> any StorageProvider {
        let root = try TestTemporaryDirectory.make(
            suite: "LocalProviderConformance",
            name: UUID().uuidString
        )
        try seed(seeded, at: root)
        let inspector = ScriptedVolumeInspector(
            properties: VolumeProperties(
                isCaseSensitive: false,
                supportsNativeTrash: false,
                isNetwork: false
            ),
            lease: TestDirectoryLease(rootURL: root)
        )
        return await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector
        )
    }

    func makeUnavailableProvider(
        reason: LocationUnavailabilityReason
    ) async throws -> (any StorageProvider)? {
        let root = try TestTemporaryDirectory.make(
            suite: "LocalProviderConformance",
            name: UUID().uuidString
        )
        let lease = TestDirectoryLease(rootURL: root)
        let inspector: ScriptedVolumeInspector
        switch reason {
        case let .volumeNotMounted(detail):
            inspector = ScriptedVolumeInspector(
                mountState: .notMounted(detail: detail),
                lease: lease
            )
        case let .volumeUnreachable(detail):
            inspector = ScriptedVolumeInspector(
                responsiveness: .unreachable(detail: detail),
                lease: lease
            )
        case .scopeMissing:
            inspector = ScriptedVolumeInspector(
                directoryState: .missing,
                lease: lease
            )
        case let .unknown(detail):
            inspector = ScriptedVolumeInspector(
                directoryState: .unknown(detail: detail),
                lease: lease
            )
        case .notAuthenticated, .networkUnreachable, .rateLimited:
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        return await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector
        )
    }

    func makeIncompleteProvider(
        seeded: [ConformanceSeedItem],
        reason _: String
    ) async throws -> any StorageProvider {
        let root = try TestTemporaryDirectory.make(
            suite: "LocalProviderConformance",
            name: UUID().uuidString
        )
        try seed(seeded, at: root)
        let inspector = ScriptedVolumeInspector(
            lease: TestDirectoryLease(rootURL: root)
        )
        return await LocalFolderStorageProvider.make(
            location: localLocation(),
            rootURL: root,
            volumes: inspector,
            deadlines: ProviderDeadlines(scanNanoseconds: 0)
        )
    }

    func recoverableContents(
        for observation: ItemObservation,
        from provider: any StorageProvider
    ) async throws -> Data {
        guard let local = provider as? LocalFolderStorageProvider,
              let recoveryURL = await local.recoveryURL(for: observation.path) else {
            throw ProviderError.itemUnavailable(
                provider: observation.location,
                path: observation.path
            )
        }
        return try Data(contentsOf: recoveryURL)
    }

    private func localLocation() -> SyncLocation {
        SyncLocation(
            id: LocationID(),
            kind: .localFolder,
            scope: .entireDrive
        )
    }

    private func seed(_ items: [ConformanceSeedItem], at root: URL) throws {
        for item in items {
            let url = item.path.components.reduce(root) {
                $0.appendingPathComponent($1)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch item.kind {
            case .file:
                try item.contents.write(to: url)
            case .folder:
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            case let .symlink(target):
                try FileManager.default.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: target
                )
            }
            try? FileManager.default.setAttributes(
                [.modificationDate: item.modifiedAt],
                ofItemAtPath: url.path
            )
        }
    }
}
