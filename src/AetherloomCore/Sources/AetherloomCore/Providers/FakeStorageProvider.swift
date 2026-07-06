import Foundation

public enum FakeProviderOperation: String, Codable, Hashable, Sendable {
    case checkAvailability
    case scan
    case changedSubtrees
    case fetch
    case store
    case makeFolder
    case relocate
    case trash
    case currentState
}

public struct FakeProviderCall: Codable, Hashable, Sendable {
    public var operation: FakeProviderOperation
    public var path: SyncPath?
    public var order: Int

    public init(operation: FakeProviderOperation, path: SyncPath?, order: Int) {
        self.operation = operation
        self.path = path
        self.order = order
    }
}

public actor FakeStorageProvider: StorageProvider {
    public nonisolated let locationID: LocationID
    public nonisolated let displayName: String
    public nonisolated let capabilities: ProviderCapabilities

    private var itemsByID: [String: ItemObservation]
    private var contentsByID: [String: Data]
    private var revisionCountersByID: [String: Int]
    private var availability: LocationAvailability
    private var incompleteScanReason: String?
    private var faultsByOperation: [FakeProviderOperation: [ProviderError]]
    private var latencyNanoseconds: UInt64
    private var recordedCalls: [FakeProviderCall]
    private var nextCallOrder: Int

    public init(
        location: SyncLocation,
        capabilities: ProviderCapabilities = .fullFidelity,
        items: [ItemObservation] = []
    ) {
        self.locationID = location.id
        self.displayName = location.displayName
        self.capabilities = capabilities
        self.itemsByID = [:]
        self.contentsByID = [:]
        self.revisionCountersByID = [:]
        self.availability = .available
        self.incompleteScanReason = nil
        self.faultsByOperation = [:]
        self.latencyNanoseconds = 0
        self.recordedCalls = []
        self.nextCallOrder = 0

        for item in items {
            let normalized = Self.normalizedItem(item, location: location.id, capabilities: capabilities)
            guard let itemID = normalized.itemID else { continue }
            self.itemsByID[itemID] = normalized
            self.contentsByID[itemID] = Data()
            self.revisionCountersByID[itemID] = Self.revisionNumber(from: normalized.version.revisionToken)
        }
    }

    public init(
        locationID: LocationID,
        displayName: String? = nil,
        capabilities: ProviderCapabilities = .fullFidelity,
        items: [ItemObservation] = []
    ) {
        self.init(
            location: SyncLocation(
                id: locationID,
                kind: locationID.defaultKind,
                displayName: displayName,
                scope: .entireDrive
            ),
            capabilities: capabilities,
            items: items
        )
    }

    public func setAvailability(_ availability: LocationAvailability) {
        self.availability = availability
    }

    public func setIncompleteScan(reason: String?) {
        incompleteScanReason = reason
    }

    public func failNext(_ operation: FakeProviderOperation, with error: ProviderError) {
        faultsByOperation[operation, default: []].append(error)
    }

    public func setLatency(nanoseconds: UInt64) {
        latencyNanoseconds = nanoseconds
    }

    public func callLog() -> [FakeProviderCall] {
        recordedCalls
    }

    public func clearCallLog() {
        recordedCalls.removeAll()
        nextCallOrder = 0
    }

    @discardableResult
    public func putFile(
        path: SyncPath,
        contents: Data = Data(),
        modifiedAt: Date = Date(),
        itemID: String? = nil,
        isPlaceholder: Bool = false
    ) -> ItemObservation {
        let resolvedItemID = itemID ?? existingItem(at: path)?.itemID ?? makeItemID(for: path)
        let revision = (revisionCountersByID[resolvedItemID] ?? 0) + 1
        revisionCountersByID[resolvedItemID] = revision

        let item = ItemObservation(
            location: locationID,
            itemID: resolvedItemID,
            path: path,
            kind: .file,
            version: itemVersion(contents: contents, modifiedAt: modifiedAt, revision: revision),
            isPlaceholder: isPlaceholder,
            isTrashed: false
        )
        itemsByID[resolvedItemID] = item
        contentsByID[resolvedItemID] = contents
        return item
    }

    @discardableResult
    public func putFolder(
        path: SyncPath,
        modifiedAt: Date = Date(),
        itemID: String? = nil,
        isPlaceholder: Bool = false
    ) -> ItemObservation {
        let resolvedItemID = itemID ?? existingItem(at: path)?.itemID ?? makeItemID(for: path)
        let revision = (revisionCountersByID[resolvedItemID] ?? 0) + 1
        revisionCountersByID[resolvedItemID] = revision

        let item = ItemObservation(
            location: locationID,
            itemID: resolvedItemID,
            path: path,
            kind: .folder,
            version: ItemVersion(modifiedAt: modifiedAt, revisionToken: "rev-\(revision)"),
            isPlaceholder: isPlaceholder,
            isTrashed: false
        )
        itemsByID[resolvedItemID] = item
        contentsByID[resolvedItemID] = Data()
        return item
    }

    @discardableResult
    public func putSymlink(
        path: SyncPath,
        target: String,
        modifiedAt: Date = Date(),
        itemID: String? = nil
    ) -> ItemObservation {
        let resolvedItemID = itemID ?? existingItem(at: path)?.itemID ?? makeItemID(for: path)
        let revision = (revisionCountersByID[resolvedItemID] ?? 0) + 1
        revisionCountersByID[resolvedItemID] = revision

        let item = ItemObservation(
            location: locationID,
            itemID: resolvedItemID,
            path: path,
            kind: .symlink(target: target),
            version: ItemVersion(size: 0, modifiedAt: modifiedAt, revisionToken: "rev-\(revision)"),
            isPlaceholder: false,
            isTrashed: false
        )
        itemsByID[resolvedItemID] = item
        contentsByID[resolvedItemID] = Data()
        return item
    }

    public func remove(path: SyncPath) {
        guard let item = existingItem(at: path), let itemID = item.itemID else { return }
        itemsByID.removeValue(forKey: itemID)
        contentsByID.removeValue(forKey: itemID)
        revisionCountersByID.removeValue(forKey: itemID)
    }

    public func item(at path: SyncPath, includeTrashed: Bool = false) -> ItemObservation? {
        existingItem(at: path, includeTrashed: includeTrashed)
    }

    public func allItems(includeTrashed: Bool = false) -> [ItemObservation] {
        itemsByID.values
            .filter { includeTrashed || !$0.isTrashed }
            .sorted { $0.path < $1.path }
    }

    public func trashedItems() -> [ItemObservation] {
        itemsByID.values
            .filter(\.isTrashed)
            .sorted { $0.path < $1.path }
    }

    public func checkAvailability() async -> LocationAvailability {
        await prepareForCall(.checkAvailability, path: nil)
        if let fault = popFault(for: .checkAvailability) {
            return .unavailable(.unknown(detail: fault.localizedDescription))
        }
        return availability
    }

    public func scan(_ scope: SyncScope) async -> LocationSnapshot {
        await prepareForCall(.scan, path: scope.rootPath)
        if let fault = popFault(for: .scan) {
            return LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: [],
                status: .unavailable(reason: .unknown(detail: fault.localizedDescription))
            )
        }
        if case let .unavailable(reason) = availability {
            return LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: [],
                status: .unavailable(reason: reason)
            )
        }

        let scopedItems = scopedActiveItems(in: scope)
        if let incompleteScanReason {
            return LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: scopedItems,
                status: .incomplete(reason: incompleteScanReason)
            )
        }

        return LocationSnapshot(location: locationID, scope: scope, observations: scopedItems)
    }

    public func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint {
        try await prepareForThrowingCall(.changedSubtrees, path: scope.rootPath)
        return ChangeHint(changedRoots: scopedActiveItems(in: scope).map(\.path), nextCursor: cursor)
    }

    public func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try await prepareForThrowingCall(.fetch, path: observation.path)
        if observation.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: locationID, path: observation.path)
        }
        let current = try await currentStateWithoutLogging(of: observation)
        guard !current.isFolder else {
            throw ProviderError.unsupported(provider: locationID, reason: "Folders cannot be fetched as files.")
        }
        guard let itemID = current.itemID, let data = contentsByID[itemID] else {
            throw ProviderError.notFound(provider: locationID, path: observation.path)
        }
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: stagingURL, options: .atomic)
    }

    public func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation {
        try await prepareForThrowingCall(.store, path: path)
        let data = try Data(contentsOf: stagingURL)

        if let existing = existingItem(at: path) {
            switch options.overwrite {
            case .neverOverwrite:
                if existing.contentHash == Self.hash(data) {
                    return existing
                }
                throw ProviderError.itemAlreadyExists(provider: locationID, path: path)
            case let .ifVersionMatches(expected):
                guard existing.version.isSameVersion(as: expected) else {
                    throw ProviderError.preconditionFailed(provider: locationID, path: path)
                }
            }
            return putFile(path: path, contents: data, itemID: existing.itemID)
        }

        return putFile(path: path, contents: data)
    }

    public func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try await prepareForThrowingCall(.makeFolder, path: path)
        if let existing = existingItem(at: path) {
            if existing.isFolder {
                return existing
            }
            throw ProviderError.itemAlreadyExists(provider: locationID, path: path)
        }
        return putFolder(path: path)
    }

    public func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        try await prepareForThrowingCall(.relocate, path: observation.path)
        let current = try await currentStateWithoutLogging(of: observation)
        if current.path == newPath {
            return current
        }
        if existingItem(at: newPath) != nil {
            throw ProviderError.itemAlreadyExists(provider: locationID, path: newPath)
        }
        return update(current) { updated, revision in
            updated.path = newPath
            updated.version.revisionToken = "rev-\(revision)"
        }
    }

    public func trash(_ observation: ItemObservation) async throws {
        try await prepareForThrowingCall(.trash, path: observation.path)
        let current = try await currentStateWithoutLogging(of: observation)
        guard !current.isTrashed else { return }
        _ = update(current) { updated, revision in
            updated.isTrashed = true
            updated.version.revisionToken = "rev-\(revision)"
        }
    }

    public func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try await prepareForThrowingCall(.currentState, path: observation.path)
        return try await currentStateWithoutLogging(of: observation)
    }

    private func prepareForThrowingCall(_ operation: FakeProviderOperation, path: SyncPath?) async throws {
        await prepareForCall(operation, path: path)
        if let fault = popFault(for: operation) {
            throw fault
        }
        if case let .unavailable(reason) = availability {
            throw ProviderError.unavailable(provider: locationID, reason: reason.detail)
        }
    }

    private func prepareForCall(_ operation: FakeProviderOperation, path: SyncPath?) async {
        recordedCalls.append(FakeProviderCall(operation: operation, path: path, order: nextCallOrder))
        nextCallOrder += 1
        if latencyNanoseconds > 0, #available(macOS 10.15, *) {
            try? await Task.sleep(nanoseconds: latencyNanoseconds)
        }
    }

    private func popFault(for operation: FakeProviderOperation) -> ProviderError? {
        guard var faults = faultsByOperation[operation], !faults.isEmpty else {
            return nil
        }
        let fault = faults.removeFirst()
        faultsByOperation[operation] = faults
        return fault
    }

    private func currentStateWithoutLogging(of observation: ItemObservation) async throws -> ItemObservation {
        if let itemID = observation.itemID, let current = itemsByID[itemID] {
            return current
        }
        if let current = existingItem(at: observation.path, includeTrashed: true) {
            return current
        }
        throw ProviderError.notFound(provider: locationID, path: observation.path)
    }

    private func scopedActiveItems(in scope: SyncScope) -> [ItemObservation] {
        itemsByID.values
            .filter { !$0.isTrashed && $0.path.isDescendant(of: scope.rootPath) }
            .sorted { $0.path < $1.path }
    }

    private func existingItem(at path: SyncPath, includeTrashed: Bool = false) -> ItemObservation? {
        itemsByID.values.first { item in
            item.path == path && (includeTrashed || !item.isTrashed)
        }
    }

    private func makeItemID(for path: SyncPath) -> String {
        "\(locationID.rawValue.uuidString):\(path.rawValue):\(UUID().uuidString)"
    }

    private func itemVersion(contents: Data, modifiedAt: Date, revision: Int) -> ItemVersion {
        ItemVersion(
            contentHash: capabilities.hasContentHashes ? Self.hash(contents) : nil,
            size: Int64(contents.count),
            modifiedAt: modifiedAt,
            revisionToken: "rev-\(revision)"
        )
    }

    private func update(_ item: ItemObservation, mutation: (inout ItemObservation, Int) -> Void) -> ItemObservation {
        guard let itemID = item.itemID else { return item }
        var updated = item
        let revision = (revisionCountersByID[itemID] ?? 0) + 1
        revisionCountersByID[itemID] = revision
        mutation(&updated, revision)
        itemsByID[itemID] = updated
        return updated
    }

    private static func normalizedItem(
        _ item: ItemObservation,
        location: LocationID,
        capabilities: ProviderCapabilities
    ) -> ItemObservation {
        var normalized = item
        normalized.location = location
        normalized.itemID = item.itemID ?? "\(location.rawValue.uuidString):\(item.path.rawValue):\(UUID().uuidString)"
        if !capabilities.hasContentHashes {
            normalized.version.contentHash = nil
        }
        return normalized
    }

    private static func revisionNumber(from revisionToken: String?) -> Int {
        guard let revisionToken,
              let value = revisionToken.split(separator: "-").last,
              let number = Int(value) else {
            return 1
        }
        return number
    }

    public static func hash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "fnv1a64-%016llx", hash)
    }
}
