import Foundation

public actor FakeCloudProvider: CloudProvider {
    public nonisolated let id: LocationID
    public nonisolated let displayName: String

    private var itemsByID: [String: ItemObservation]
    private var contentsByID: [String: Data]
    private var revisionCountersByID: [String: Int]
    private var unavailableReason: String?
    private var incompleteScanReason: String?

    public init(id: LocationID, displayName: String? = nil, items: [ItemObservation] = []) {
        self.id = id
        self.displayName = displayName ?? id.displayName
        self.itemsByID = [:]
        self.contentsByID = [:]
        self.revisionCountersByID = [:]

        for item in items {
            let normalized = Self.normalizedItem(item, location: id)
            guard let itemID = normalized.itemID else { continue }
            self.itemsByID[itemID] = normalized
            self.contentsByID[itemID] = Data()
            self.revisionCountersByID[itemID] = Self.revisionNumber(from: normalized.version.revisionToken)
        }
    }

    public func setUnavailable(reason: String?) {
        unavailableReason = reason
    }

    public func setIncompleteScan(reason: String?) {
        incompleteScanReason = reason
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
            location: id,
            itemID: resolvedItemID,
            path: path,
            kind: .file,
            version: ItemVersion(
                contentHash: Self.hash(contents),
                size: Int64(contents.count),
                modifiedAt: modifiedAt,
                revisionToken: "rev-\(revision)"
            ),
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
            location: id,
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

    public func snapshot(scope: SyncScope = .entireDrive) -> LocationSnapshot {
        if let unavailableReason {
            return LocationSnapshot(
                location: id,
                scope: scope,
                observations: [],
                status: .unavailable(reason: unavailableReason)
            )
        }

        let scopedItems = scopedActiveItems(in: scope)
        if let incompleteScanReason {
            return LocationSnapshot(
                location: id,
                scope: scope,
                observations: scopedItems,
                status: .incomplete(reason: incompleteScanReason)
            )
        }

        return LocationSnapshot(location: id, scope: scope, observations: scopedItems)
    }

    public func authenticateIfNeeded() async throws {
        if let unavailableReason {
            throw ProviderError.unavailable(provider: id, reason: unavailableReason)
        }
    }

    public func validateScope(_ scope: SyncScope) async throws -> ProviderScopeStatus {
        if let unavailableReason {
            return .unavailable(reason: unavailableReason)
        }
        if let incompleteScanReason {
            return .incomplete(reason: incompleteScanReason)
        }
        return .available
    }

    public func listItems(in scope: SyncScope) async throws -> [ItemObservation] {
        if let unavailableReason {
            throw ProviderError.unavailable(provider: id, reason: unavailableReason)
        }
        if let incompleteScanReason {
            throw ProviderError.incompleteScan(provider: id, reason: incompleteScanReason)
        }
        return scopedActiveItems(in: scope)
    }

    public func listChanges(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangePage {
        let items = try await listItems(in: scope)
        return ChangePage(changes: items.map { .created(location: id, item: $0) })
    }

    public func download(_ item: ItemObservation, to localURL: URL) async throws {
        if item.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: id, path: item.path)
        }
        let current = try await metadata(for: item)
        guard !current.isFolder else {
            throw ProviderError.unsupported(provider: id, reason: "Folders cannot be downloaded as files.")
        }
        guard let itemID = current.itemID, let data = contentsByID[itemID] else {
            throw ProviderError.notFound(provider: id, path: item.path)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
    }

    public func upload(localURL: URL, to remotePath: SyncPath, options: UploadOptions) async throws -> ItemObservation {
        let data = try Data(contentsOf: localURL)

        if let existing = existingItem(at: remotePath) {
            if !options.allowOverwrite {
                if existing.contentHash == Self.hash(data) {
                    return existing
                }
                throw ProviderError.itemAlreadyExists(provider: id, path: remotePath)
            }
            if let expected = options.expectedDestinationRevisionID,
               expected != existing.version.revisionToken {
                throw ProviderError.preconditionFailed(provider: id, path: remotePath)
            }
            return putFile(path: remotePath, contents: data, itemID: existing.itemID)
        }

        return putFile(path: remotePath, contents: data)
    }

    public func createFolder(path: SyncPath) async throws -> ItemObservation {
        if let existing = existingItem(at: path) {
            if existing.isFolder {
                return existing
            }
            throw ProviderError.itemAlreadyExists(provider: id, path: path)
        }
        return putFolder(path: path)
    }

    public func move(item: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation {
        let current = try await metadata(for: item)
        if current.path == newPath {
            return current
        }
        if existingItem(at: newPath) != nil {
            throw ProviderError.itemAlreadyExists(provider: id, path: newPath)
        }
        return update(current) { updated, revision in
            updated.path = newPath
            updated.version.revisionToken = "rev-\(revision)"
        }
    }

    public func rename(item: ItemObservation, to newName: String) async throws -> ItemObservation {
        let current = try await metadata(for: item)
        let newPath = current.path.replacingLastComponent(with: newName)
        if current.path == newPath {
            return current
        }
        if existingItem(at: newPath) != nil {
            throw ProviderError.itemAlreadyExists(provider: id, path: newPath)
        }
        return try await move(item: current, to: newPath)
    }

    public func trash(item: ItemObservation) async throws {
        let current = try await metadata(for: item)
        guard !current.isTrashed else { return }
        _ = update(current) { updated, revision in
            updated.isTrashed = true
            updated.version.revisionToken = "rev-\(revision)"
        }
    }

    public func metadata(for item: ItemObservation) async throws -> ItemObservation {
        if let itemID = item.itemID, let current = itemsByID[itemID] {
            return current
        }
        if let current = existingItem(at: item.path, includeTrashed: true) {
            return current
        }
        throw ProviderError.notFound(provider: id, path: item.path)
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
        "\(id.rawValue.uuidString):\(path.rawValue):\(UUID().uuidString)"
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

    private static func normalizedItem(_ item: ItemObservation, location: LocationID) -> ItemObservation {
        var normalized = item
        normalized.location = location
        normalized.itemID = item.itemID ?? "\(location.rawValue.uuidString):\(item.path.rawValue):\(UUID().uuidString)"
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
