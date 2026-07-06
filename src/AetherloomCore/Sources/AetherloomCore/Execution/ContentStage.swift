import Foundation

public struct StagedContent: Hashable, Sendable {
    public var url: URL
    public var verifiedHash: String?
    public var size: Int64

    public init(url: URL, verifiedHash: String?, size: Int64) {
        self.url = url
        self.verifiedHash = verifiedHash
        self.size = size
    }
}

public enum ContentStageError: Error, Equatable, Sendable {
    case unsupportedContentKind(ItemKind)
    case hashMismatch(path: SyncPath, expected: String, actual: String)
    case cannotCreateRoot(String)
}

public actor ContentStage {
    private let rootDirectory: URL
    private let byteLimit: Int64
    private var entries: [StageKey: StageEntry] = [:]
    private var keysByURL: [URL: StageKey] = [:]
    private var inFlight: [StageKey: Task<StageEntry, Error>] = [:]
    private var accessCounter: UInt64 = 0
    private var currentBytes: Int64 = 0

    public init(rootDirectory: URL, byteLimit: Int64) {
        self.rootDirectory = rootDirectory
        self.byteLimit = max(byteLimit, 0)
    }

    public func materialize(_ ref: ContentRef, from provider: any StorageProvider) async throws -> StagedContent {
        guard ref.kind == .file else {
            throw ContentStageError.unsupportedContentKind(ref.kind)
        }

        let key = StageKey(ref)
        if let content = pinCachedEntry(for: key) {
            return content
        }

        if let task = inFlight[key] {
            let entry = try await task.value
            return pin(entry, for: key)
        }

        let stagingURL = rootDirectory.appendingPathComponent(key.filename, isDirectory: false)
        let task = Task<StageEntry, Error> {
            try await materializeEntry(ref, from: provider, at: stagingURL)
        }
        inFlight[key] = task

        do {
            let entry = try await task.value
            inFlight[key] = nil
            return pin(entry, for: key)
        } catch {
            inFlight[key] = nil
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    public func release(_ content: StagedContent) async {
        guard let key = keysByURL[content.url], var entry = entries[key] else { return }
        entry.pinCount = max(0, entry.pinCount - 1)
        entry.lastAccess = nextAccess()
        entries[key] = entry
        evictIfNeeded()
    }

    private func pinCachedEntry(for key: StageKey) -> StagedContent? {
        guard var entry = entries[key] else { return nil }
        entry.pinCount += 1
        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.content
    }

    private func pin(_ entry: StageEntry, for key: StageKey) -> StagedContent {
        if var cached = entries[key] {
            cached.pinCount += 1
            cached.lastAccess = nextAccess()
            entries[key] = cached
            return cached.content
        }

        var pinned = entry
        pinned.pinCount = 1
        pinned.lastAccess = nextAccess()
        entries[key] = pinned
        keysByURL[pinned.content.url] = key
        currentBytes += pinned.content.size
        evictIfNeeded()
        return pinned.content
    }

    private func evictIfNeeded() {
        guard currentBytes > byteLimit else { return }
        let candidates = entries
            .filter { $0.value.pinCount == 0 }
            .sorted { lhs, rhs in
                if lhs.value.lastAccess != rhs.value.lastAccess {
                    return lhs.value.lastAccess < rhs.value.lastAccess
                }
                return lhs.key.filename < rhs.key.filename
            }

        for (key, entry) in candidates {
            guard currentBytes > byteLimit else { break }
            entries.removeValue(forKey: key)
            keysByURL.removeValue(forKey: entry.content.url)
            currentBytes -= entry.content.size
            try? FileManager.default.removeItem(at: entry.content.url)
        }
    }

    private func nextAccess() -> UInt64 {
        accessCounter += 1
        return accessCounter
    }
}

private struct StageKey: Hashable, Sendable {
    var sourceLocation: LocationID
    var itemID: String?
    var path: SyncPath
    var version: ItemVersion

    init(_ ref: ContentRef) {
        self.sourceLocation = ref.sourceLocation
        self.itemID = ref.itemID
        self.path = ref.path
        self.version = ref.expectedVersion
    }

    var filename: String {
        let digest = CanonicalCoding.sha256Hex(
            [
                sourceLocation.rawValue.uuidString,
                itemID ?? "",
                path.rawValue,
                version.contentHash ?? "",
                version.size.map(String.init) ?? "",
                version.modifiedAt.map(CanonicalCoding.dateString) ?? "",
                version.revisionToken ?? ""
            ].joined(separator: "\u{1f}")
        )
        return "\(digest).stage"
    }
}

private struct StageEntry: Sendable {
    var content: StagedContent
    var pinCount: Int
    var lastAccess: UInt64
}

private func materializeEntry(
    _ ref: ContentRef,
    from provider: any StorageProvider,
    at stagingURL: URL
) async throws -> StageEntry {
    do {
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    } catch {
        throw ContentStageError.cannotCreateRoot(String(describing: error))
    }

    let temporaryURL = stagingURL.deletingLastPathComponent()
        .appendingPathComponent("\(UUID().uuidString).tmp", isDirectory: false)
    try? FileManager.default.removeItem(at: temporaryURL)
    try? FileManager.default.removeItem(at: stagingURL)

    do {
        try await provider.fetch(ref.observation, to: temporaryURL)
        let data = try Data(contentsOf: temporaryURL)
        let actualHash = ContentHashing.hash(data)
        if let expectedHash = ref.expectedVersion.contentHash, expectedHash != actualHash {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ContentStageError.hashMismatch(path: ref.path, expected: expectedHash, actual: actualHash)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
        return StageEntry(
            content: StagedContent(url: stagingURL, verifiedHash: actualHash, size: Int64(data.count)),
            pinCount: 0,
            lastAccess: 0
        )
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: stagingURL)
        throw error
    }
}
