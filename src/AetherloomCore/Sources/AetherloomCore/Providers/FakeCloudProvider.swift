import Foundation

public actor FakeCloudProvider: CloudProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName: String

    private var itemsByID: [String: CloudItem]
    private var contentsByID: [String: Data]
    private var revisionCountersByID: [String: Int]
    private var unavailableReason: String?
    private var incompleteScanReason: String?

    public init(id: ProviderID, displayName: String? = nil, items: [CloudItem] = []) {
        self.id = id
        self.displayName = displayName ?? id.displayName
        self.itemsByID = [:]
        self.contentsByID = [:]
        self.revisionCountersByID = [:]

        for item in items {
            let normalized = Self.normalizedItem(item, provider: id)
            guard let itemID = normalized.providerItemID else { continue }
            self.itemsByID[itemID] = normalized
            self.contentsByID[itemID] = Data()
            self.revisionCountersByID[itemID] = Self.revisionNumber(from: normalized.revisionID)
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
        path: CloudPath,
        contents: Data = Data(),
        modifiedAt: Date = Date(),
        providerItemID: String? = nil,
        isPlaceholder: Bool = false
    ) -> CloudItem {
        let itemID = providerItemID ?? existingItem(at: path)?.providerItemID ?? makeItemID(for: path)
        let revision = (revisionCountersByID[itemID] ?? 0) + 1
        revisionCountersByID[itemID] = revision

        let item = CloudItem(
            provider: id,
            providerItemID: itemID,
            path: path,
            isFolder: false,
            size: Int64(contents.count),
            modifiedAt: modifiedAt,
            contentHash: Self.hash(contents),
            revisionID: "rev-\(revision)",
            eTag: "etag-\(revision)",
            cTag: nil,
            isTrashed: false,
            isPlaceholder: isPlaceholder
        )
        itemsByID[itemID] = item
        contentsByID[itemID] = contents
        return item
    }

    @discardableResult
    public func putFolder(
        path: CloudPath,
        modifiedAt: Date = Date(),
        providerItemID: String? = nil,
        isPlaceholder: Bool = false
    ) -> CloudItem {
        let itemID = providerItemID ?? existingItem(at: path)?.providerItemID ?? makeItemID(for: path)
        let revision = (revisionCountersByID[itemID] ?? 0) + 1
        revisionCountersByID[itemID] = revision

        let item = CloudItem(
            provider: id,
            providerItemID: itemID,
            path: path,
            isFolder: true,
            modifiedAt: modifiedAt,
            revisionID: "rev-\(revision)",
            cTag: "ctag-\(revision)",
            isTrashed: false,
            isPlaceholder: isPlaceholder
        )
        itemsByID[itemID] = item
        contentsByID[itemID] = Data()
        return item
    }

    public func remove(path: CloudPath) {
        guard let item = existingItem(at: path), let itemID = item.providerItemID else { return }
        itemsByID.removeValue(forKey: itemID)
        contentsByID.removeValue(forKey: itemID)
        revisionCountersByID.removeValue(forKey: itemID)
    }

    public func item(at path: CloudPath, includeTrashed: Bool = false) -> CloudItem? {
        existingItem(at: path, includeTrashed: includeTrashed)
    }

    public func allItems(includeTrashed: Bool = false) -> [CloudItem] {
        itemsByID.values
            .filter { includeTrashed || !$0.isTrashed }
            .sorted { $0.path < $1.path }
    }

    public func snapshot(scope: SyncScope = .entireDrive) -> ProviderSnapshot {
        if let unavailableReason {
            return ProviderSnapshot(
                provider: id,
                scope: scope,
                items: [],
                status: .unavailable(reason: unavailableReason)
            )
        }

        let scopedItems = scopedActiveItems(in: scope)
        if let incompleteScanReason {
            return ProviderSnapshot(
                provider: id,
                scope: scope,
                items: scopedItems,
                status: .incomplete(reason: incompleteScanReason)
            )
        }

        return ProviderSnapshot(provider: id, scope: scope, items: scopedItems)
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

    public func listItems(in scope: SyncScope) async throws -> [CloudItem] {
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
        return ChangePage(changes: items.map { .created(provider: id, item: $0) })
    }

    public func download(_ item: CloudItem, to localURL: URL) async throws {
        if item.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: id, path: item.path)
        }
        let current = try await metadata(for: item)
        guard !current.isFolder else {
            throw ProviderError.unsupported(provider: id, reason: "Folders cannot be downloaded as files.")
        }
        guard let itemID = current.providerItemID, let data = contentsByID[itemID] else {
            throw ProviderError.notFound(provider: id, path: item.path)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
    }

    public func upload(localURL: URL, to remotePath: CloudPath, options: UploadOptions) async throws -> CloudItem {
        let data = try Data(contentsOf: localURL)

        if let existing = existingItem(at: remotePath) {
            if !options.allowOverwrite {
                if existing.contentHash == Self.hash(data) {
                    return existing
                }
                throw ProviderError.itemAlreadyExists(provider: id, path: remotePath)
            }
            if let expected = options.expectedDestinationRevisionID,
               expected != existing.revisionID,
               expected != existing.eTag,
               expected != existing.cTag {
                throw ProviderError.preconditionFailed(provider: id, path: remotePath)
            }
            return putFile(path: remotePath, contents: data, providerItemID: existing.providerItemID)
        }

        return putFile(path: remotePath, contents: data)
    }

    public func createFolder(path: CloudPath) async throws -> CloudItem {
        if let existing = existingItem(at: path) {
            if existing.isFolder {
                return existing
            }
            throw ProviderError.itemAlreadyExists(provider: id, path: path)
        }
        return putFolder(path: path)
    }

    public func move(item: CloudItem, to newPath: CloudPath) async throws -> CloudItem {
        let current = try await metadata(for: item)
        if current.path == newPath {
            return current
        }
        if existingItem(at: newPath) != nil {
            throw ProviderError.itemAlreadyExists(provider: id, path: newPath)
        }
        return update(current) { updated, revision in
            updated.path = newPath
            updated.name = newPath.name
            updated.revisionID = "rev-\(revision)"
            updated.eTag = "etag-\(revision)"
            if updated.isFolder {
                updated.cTag = "ctag-\(revision)"
            }
        }
    }

    public func rename(item: CloudItem, to newName: String) async throws -> CloudItem {
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

    public func trash(item: CloudItem) async throws {
        let current = try await metadata(for: item)
        guard !current.isTrashed else { return }
        _ = update(current) { updated, revision in
            updated.isTrashed = true
            updated.revisionID = "rev-\(revision)"
            updated.eTag = "etag-\(revision)"
            if updated.isFolder {
                updated.cTag = "ctag-\(revision)"
            }
        }
    }

    public func metadata(for item: CloudItem) async throws -> CloudItem {
        if let itemID = item.providerItemID, let current = itemsByID[itemID] {
            return current
        }
        if let current = existingItem(at: item.path, includeTrashed: true) {
            return current
        }
        throw ProviderError.notFound(provider: id, path: item.path)
    }

    private func scopedActiveItems(in scope: SyncScope) -> [CloudItem] {
        itemsByID.values
            .filter { !$0.isTrashed && $0.path.isDescendant(of: scope.rootPath) }
            .sorted { $0.path < $1.path }
    }

    private func existingItem(at path: CloudPath, includeTrashed: Bool = false) -> CloudItem? {
        itemsByID.values.first { item in
            item.path == path && (includeTrashed || !item.isTrashed)
        }
    }

    private func makeItemID(for path: CloudPath) -> String {
        "\(id.rawValue):\(path.rawValue):\(UUID().uuidString)"
    }

    private func update(_ item: CloudItem, mutation: (inout CloudItem, Int) -> Void) -> CloudItem {
        guard let itemID = item.providerItemID else { return item }
        var updated = item
        let revision = (revisionCountersByID[itemID] ?? 0) + 1
        revisionCountersByID[itemID] = revision
        mutation(&updated, revision)
        itemsByID[itemID] = updated
        return updated
    }

    private static func normalizedItem(_ item: CloudItem, provider: ProviderID) -> CloudItem {
        var normalized = item
        normalized.provider = provider
        normalized.name = item.path.name
        normalized.providerItemID = item.providerItemID ?? "\(provider.rawValue):\(item.path.rawValue):\(UUID().uuidString)"
        return normalized
    }

    private static func revisionNumber(from revisionID: String?) -> Int {
        guard let revisionID,
              let value = revisionID.split(separator: "-").last,
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

