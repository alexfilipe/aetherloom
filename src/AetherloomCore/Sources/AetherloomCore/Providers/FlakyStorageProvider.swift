import Foundation

public typealias FlakyProviderMutation = @Sendable () async throws -> Void

public actor FlakyStorageProvider: StorageProvider {
    public nonisolated let locationID: LocationID
    public nonisolated let capabilities: ProviderCapabilities

    private let base: any StorageProvider
    private var faultsByOperation: [FakeProviderOperation: [ProviderError]]
    private var mutationsByOperation: [FakeProviderOperation: [FlakyProviderMutation]]

    public init(wrapping base: any StorageProvider) {
        self.base = base
        self.locationID = base.locationID
        self.capabilities = base.capabilities
        self.faultsByOperation = [:]
        self.mutationsByOperation = [:]
    }

    public func failNext(_ operation: FakeProviderOperation, with error: ProviderError) {
        faultsByOperation[operation, default: []].append(error)
    }

    public func mutateBeforeNext(_ operation: FakeProviderOperation, _ mutation: @escaping FlakyProviderMutation) {
        mutationsByOperation[operation, default: []].append(mutation)
    }

    public func checkAvailability() async -> LocationAvailability {
        do {
            try await prepare(for: .checkAvailability)
        } catch {
            return .unavailable(.unknown(detail: String(describing: error)))
        }
        return await base.checkAvailability()
    }

    public func scan(_ scope: SyncScope) async -> LocationSnapshot {
        do {
            try await prepare(for: .scan)
        } catch {
            return LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: [],
                status: .unavailable(reason: .unknown(detail: String(describing: error)))
            )
        }
        return await base.scan(scope)
    }

    public func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        try await prepare(for: .changedSubtrees)
        return try await base.changedSubtrees(in: scope, since: cursor)
    }

    public func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await prepare(for: .fetch)
        try await base.fetch(observation, to: stagingURL)
    }

    public func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        try await prepare(for: .store)
        return try await base.store(from: stagingURL, at: path, options: options)
    }

    public func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try await prepare(for: .makeFolder)
        return try await base.makeFolder(at: path)
    }

    public func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await prepare(for: .relocate)
        return try await base.relocate(observation, to: newPath)
    }

    public func trash(_ observation: ItemObservation) async throws {
        try await prepare(for: .trash)
        try await base.trash(observation)
    }

    public func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await prepare(for: .currentState)
        return try await base.currentState(of: observation)
    }

    private func prepare(for operation: FakeProviderOperation) async throws {
        if var mutations = mutationsByOperation[operation], !mutations.isEmpty {
            let mutation = mutations.removeFirst()
            mutationsByOperation[operation] = mutations
            try await mutation()
        }

        guard var faults = faultsByOperation[operation], !faults.isEmpty else {
            return
        }
        let fault = faults.removeFirst()
        faultsByOperation[operation] = faults
        throw fault
    }
}
