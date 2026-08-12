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

/// Public handle for process-wide stage-root ownership. Reconstructed
/// orchestrators using the same canonical root share one storage actor, so
/// startup cleanup, deterministic cache paths, pins, and receipt-bound late
/// writes cannot race each other.
public actor ContentStage {
    private let storage: ContentStageStorage

    public init(rootDirectory: URL, byteLimit: Int64) {
        self.storage = ContentStageRootRegistry.storage(
            for: rootDirectory,
            byteLimit: byteLimit
        )
    }

    public func materialize(
        _ ref: ContentRef,
        from provider: any StorageProvider
    ) async throws -> StagedContent {
        try await storage.materialize(ref, from: provider)
    }

    public func release(_ content: StagedContent) async {
        await storage.release(content)
    }

    func deferRelease(
        _ content: StagedContent,
        for receipt: ProviderMutationReceipt
    ) async {
        await storage.deferRelease(content, for: receipt)
    }

    func releaseDeferredArtifacts(
        for receipt: ProviderMutationReceipt
    ) async {
        await storage.releaseDeferredArtifacts(for: receipt)
    }

    func retainedArtifactCount(
        for receipt: ProviderMutationReceipt
    ) async -> Int {
        await storage.retainedArtifactCount(for: receipt)
    }
}

private enum ContentStageRootRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storageByCanonicalRoot: [
        String: ContentStageStorage
    ] = [:]

    static func storage(
        for rootDirectory: URL,
        byteLimit: Int64
    ) -> ContentStageStorage {
        let canonicalRoot = rootDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let key = canonicalRoot.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = storageByCanonicalRoot[key] {
            return existing
        }
        let created = ContentStageStorage(
            rootDirectory: canonicalRoot,
            byteLimit: byteLimit
        )
        storageByCanonicalRoot[key] = created
        return created
    }
}

private actor ContentStageStorage {
    private let rootDirectory: URL
    private let byteLimit: Int64
    private var entries: [StageKey: StageEntry] = [:]
    private var keysByURL: [URL: StageKey] = [:]
    private var inFlight: [StageKey: Task<StageEntry, Error>] = [:]
    private var deferredContentsByReceipt: [
        ProviderMutationIdentity: [StagedContent]
    ] = [:]
    private var deferredTemporaryURLsByReceipt: [
        ProviderMutationIdentity: Set<URL>
    ] = [:]
    private var accessCounter: UInt64 = 0
    private var currentBytes: Int64 = 0

    init(rootDirectory: URL, byteLimit: Int64) {
        self.rootDirectory = rootDirectory
        self.byteLimit = max(byteLimit, 0)
        Self.reclaimAbandonedTemporaryFiles(in: rootDirectory)
    }

    func materialize(_ ref: ContentRef, from provider: any StorageProvider) async throws -> StagedContent {
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

        let stagingURL = rootDirectory.appendingPathComponent(
            key.filename,
            isDirectory: false
        )
        let task = Task<StageEntry, Error> {
            try await materializeEntry(ref, from: provider, at: stagingURL)
        }
        inFlight[key] = task

        do {
            let entry = try await task.value
            inFlight[key] = nil
            return pin(entry, for: key)
        } catch let lateWrite as IndeterminateStageWrite {
            inFlight[key] = nil
            deferredTemporaryURLsByReceipt[lateWrite.receipt.identity, default: []]
                .insert(lateWrite.temporaryURL)
            try? FileManager.default.removeItem(at: stagingURL)
            throw ProviderError.mutationIndeterminate(lateWrite.receipt)
        } catch {
            inFlight[key] = nil
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    func release(_ content: StagedContent) {
        releasePinnedContent(content)
    }

    /// Keeps a materialized source pinned while a destination provider may
    /// still be reading it after the caller's deadline.
    func deferRelease(
        _ content: StagedContent,
        for receipt: ProviderMutationReceipt
    ) {
        deferredContentsByReceipt[receipt.identity, default: []].append(content)
    }

    /// Called only after the journal has been reconciled and the owned late
    /// operation is quiescent. It releases both destination-store pins and
    /// fetch temporary files without racing blocking filesystem work.
    func releaseDeferredArtifacts(for receipt: ProviderMutationReceipt) {
        let contents = deferredContentsByReceipt.removeValue(
            forKey: receipt.identity
        ) ?? []
        for content in contents {
            releasePinnedContent(content)
        }
        let temporaryURLs = deferredTemporaryURLsByReceipt
            .removeValue(forKey: receipt.identity) ?? []
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        evictIfNeeded()
    }

    func retainedArtifactCount(for receipt: ProviderMutationReceipt) -> Int {
        (deferredContentsByReceipt[receipt.identity]?.count ?? 0)
            + (deferredTemporaryURLsByReceipt[receipt.identity]?.count ?? 0)
    }

    private func releasePinnedContent(_ content: StagedContent) {
        guard let key = keysByURL[content.url], var entry = entries[key] else { return }
        entry.pinCount = max(0, entry.pinCount - 1)
        entry.lastAccess = nextAccess()
        if entry.pinCount == 0, !key.isReusable {
            entries.removeValue(forKey: key)
            keysByURL.removeValue(forKey: content.url)
            currentBytes -= entry.content.size
            try? FileManager.default.removeItem(at: entry.content.url)
            return
        }
        entries[key] = entry
        evictIfNeeded()
    }

    private nonisolated static func reclaimAbandonedTemporaryFiles(
        in rootDirectory: URL
    ) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files
        where file.pathExtension == "tmp"
            && UUID(
                uuidString: file.deletingPathExtension().lastPathComponent
            ) != nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func pinCachedEntry(for key: StageKey) -> StagedContent? {
        guard var entry = entries[key] else { return nil }
        guard key.isReusable || entry.pinCount > 0 else { return nil }
        entry.pinCount += 1
        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.content
    }

    private func pin(_ entry: StageEntry, for key: StageKey) -> StagedContent {
        if var cached = entries[key] {
            if !key.isReusable, cached.pinCount == 0 {
                entries.removeValue(forKey: key)
                keysByURL.removeValue(forKey: cached.content.url)
                currentBytes -= cached.content.size
                try? FileManager.default.removeItem(at: cached.content.url)
            } else {
                cached.pinCount += 1
                cached.lastAccess = nextAccess()
                entries[key] = cached
                return cached.content
            }
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
    var weakNonce: UUID?

    init(_ ref: ContentRef) {
        self.sourceLocation = ref.sourceLocation
        self.itemID = ref.itemID
        self.path = ref.path
        self.version = ref.expectedVersion
        self.weakNonce = ref.expectedVersion.hasStrongEvidence ? nil : UUID()
    }

    var isReusable: Bool {
        version.hasStrongEvidence
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
                version.revisionToken ?? "",
                weakNonce?.uuidString ?? ""
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

private struct IndeterminateStageWrite: Error, Sendable {
    var receipt: ProviderMutationReceipt
    var temporaryURL: URL
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
        let evidence = try ContentHashing.hashFile(at: temporaryURL)
        let actualHash = evidence.hash
        if let expectedHash = ref.expectedVersion.contentHash, expectedHash != actualHash {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ContentStageError.hashMismatch(path: ref.path, expected: expectedHash, actual: actualHash)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
        return StageEntry(
            content: StagedContent(url: stagingURL, verifiedHash: actualHash, size: evidence.size),
            pinCount: 0,
            lastAccess: 0
        )
    } catch let ProviderError.mutationIndeterminate(receipt) {
        // The provider still owns a late write to `temporaryURL`. Removing it
        // here would race that blocking syscall. The stage actor retains the
        // URL by receipt until recovery observes quiescence; startup cleanup
        // handles a process that exited before reconciliation.
        throw IndeterminateStageWrite(
            receipt: receipt,
            temporaryURL: temporaryURL
        )
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: stagingURL)
        throw error
    }
}
