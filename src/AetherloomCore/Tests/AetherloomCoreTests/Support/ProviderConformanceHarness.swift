import Foundation
import Testing
@testable import AetherloomCore

public struct ConformanceSeedItem: Hashable, Sendable {
    public var path: SyncPath
    public var kind: ItemKind
    public var contents: Data
    public var modifiedAt: Date
    public var isPlaceholder: Bool

    public init(
        path: SyncPath,
        kind: ItemKind,
        contents: Data = Data(),
        modifiedAt: Date,
        isPlaceholder: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.contents = contents
        self.modifiedAt = modifiedAt
        self.isPlaceholder = isPlaceholder
    }
}

public protocol ProviderConformanceHarness: Sendable, CustomTestStringConvertible {
    var declaredCapabilities: ProviderCapabilities { get }
    var runsMutationConformance: Bool { get }
    var runsPreservationConformance: Bool { get }
    var preservesSeededUnicodeScalars: Bool { get }

    func makeProvider(seeded: [ConformanceSeedItem]) async throws -> any StorageProvider
    func makeUnavailableProvider(
        reason: LocationUnavailabilityReason
    ) async throws -> (any StorageProvider)?

    /// Produces a provider whose next scan proves an enumeration failure
    /// without misreporting the resulting partial view as complete.
    func makeIncompleteProvider(
        seeded: [ConformanceSeedItem],
        reason: String
    ) async throws -> any StorageProvider

    /// Test-only recovery inspection. StorageProvider does not promise that
    /// stale source paths remain fetchable after trashing.
    func recoverableContents(
        for observation: ItemObservation,
        from provider: any StorageProvider
    ) async throws -> Data
}

extension ProviderConformanceHarness {
    public var runsMutationConformance: Bool { true }
    public var runsPreservationConformance: Bool { true }
    public var preservesSeededUnicodeScalars: Bool { true }
}

struct FakeProviderConformanceHarness: ProviderConformanceHarness {
    enum Wrapping: String, Sendable {
        case direct
        case flaky
    }

    let testDescription: String
    let declaredCapabilities: ProviderCapabilities
    let wrapping: Wrapping

    func makeProvider(seeded: [ConformanceSeedItem]) async throws -> any StorageProvider {
        let base = FakeStorageProvider(
            locationID: LocationID(),
            displayName: testDescription,
            capabilities: declaredCapabilities
        )
        await seed(seeded, into: base)
        return wrap(base)
    }

    func makeUnavailableProvider(
        reason: LocationUnavailabilityReason
    ) async throws -> (any StorageProvider)? {
        let base = FakeStorageProvider(
            locationID: LocationID(),
            displayName: testDescription,
            capabilities: declaredCapabilities
        )

        switch wrapping {
        case .direct:
            await base.setAvailability(.unavailable(reason))
            return base
        case .flaky:
            guard case .unknown = reason else {
                return nil
            }
            let provider = FlakyStorageProvider(wrapping: base)
            let fault = ProviderError.unavailable(provider: base.locationID, reason: reason.detail)
            await provider.failNext(.checkAvailability, with: fault)
            await provider.failNext(.scan, with: fault)
            return provider
        }
    }

    func makeIncompleteProvider(
        seeded: [ConformanceSeedItem],
        reason: String
    ) async throws -> any StorageProvider {
        let base = FakeStorageProvider(
            locationID: LocationID(),
            displayName: testDescription,
            capabilities: declaredCapabilities
        )
        await seed(seeded, into: base)
        await base.setIncompleteScan(reason: reason)
        return wrap(base)
    }

    func recoverableContents(
        for observation: ItemObservation,
        from provider: any StorageProvider
    ) async throws -> Data {
        let directory = try TestTemporaryDirectory.make(
            suite: "ProviderConformanceRecovery",
            name: UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("content")
        try await provider.fetch(observation, to: url)
        return try Data(contentsOf: url)
    }

    private func wrap(_ base: FakeStorageProvider) -> any StorageProvider {
        switch wrapping {
        case .direct:
            base
        case .flaky:
            FlakyStorageProvider(wrapping: base)
        }
    }

    private func seed(
        _ items: [ConformanceSeedItem],
        into provider: FakeStorageProvider
    ) async {
        for item in items {
            switch item.kind {
            case .file:
                await provider.putFile(
                    path: item.path,
                    contents: item.contents,
                    modifiedAt: item.modifiedAt,
                    isPlaceholder: item.isPlaceholder
                )
            case .folder:
                await provider.putFolder(
                    path: item.path,
                    modifiedAt: item.modifiedAt,
                    isPlaceholder: item.isPlaceholder
                )
            case let .symlink(target):
                await provider.putSymlink(
                    path: item.path,
                    target: target,
                    modifiedAt: item.modifiedAt
                )
            }
        }
    }
}

let providerConformanceHarnesses: [any ProviderConformanceHarness] = {
    var degradedHashes = ProviderCapabilities.fullFidelity
    degradedHashes.hasContentHashes = false

    return [
        FakeProviderConformanceHarness(
            testDescription: "FakeStorageProvider.fullFidelity",
            declaredCapabilities: .fullFidelity,
            wrapping: .direct
        ),
        FakeProviderConformanceHarness(
            testDescription: "FakeStorageProvider.degradedHashes",
            declaredCapabilities: degradedHashes,
            wrapping: .direct
        ),
        FakeProviderConformanceHarness(
            testDescription: "FlakyStorageProvider.fullFidelity",
            declaredCapabilities: .fullFidelity,
            wrapping: .flaky
        ),
        LocalProviderConformanceHarness(),
    ]
}()
