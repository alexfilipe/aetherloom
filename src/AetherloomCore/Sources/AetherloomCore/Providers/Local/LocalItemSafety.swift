import AetherloomSystemSupport
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum LocalProvenanceSyncIntentResult: String, Hashable, Sendable {
    case ignored
    case preserve
    case unavailable
    case callFailed
    case ambiguous
}

public protocol LocalProvenanceSyncIntentClassifying: Sendable {
    func classify() -> LocalProvenanceSyncIntentResult
}

public struct SystemLocalProvenanceSyncIntentClassifier:
    LocalProvenanceSyncIntentClassifying
{
    public init() {}

    public func classify() -> LocalProvenanceSyncIntentResult {
        var nativeResult: Int32 = 0
        let status = LocalItemSafetyClassifier.provenanceName.withCString { name in
            aetherloom_provenance_sync_intent(name, &nativeResult)
        }
        return Self.classification(
            wrapperStatus: status,
            nativeResult: nativeResult
        )
    }

    static func classification(
        wrapperStatus: Int32,
        nativeResult: Int32
    ) -> LocalProvenanceSyncIntentResult {
        switch wrapperStatus {
        case 0:
            return nativeResult == 0 ? .ignored : .preserve
        case 1:
            return .unavailable
        default:
            return .callFailed
        }
    }
}

public struct LocalItemSafetyMetadata: Hashable, Sendable {
    public var filesystemKind: LocalFilesystemKind
    public var isPackage: Bool
    public var posixMode: UInt16
    public var ownerID: UInt32
    public var groupID: UInt32
    public var hasAccessControlList: Bool
    public var extendedAttributeSizes: [String: Int]
    public var provenanceSyncIntentResult: LocalProvenanceSyncIntentResult?

    public init(
        filesystemKind: LocalFilesystemKind,
        isPackage: Bool = false,
        posixMode: UInt16,
        ownerID: UInt32,
        groupID: UInt32,
        hasAccessControlList: Bool = false,
        extendedAttributeSizes: [String: Int] = [:],
        provenanceSyncIntentResult: LocalProvenanceSyncIntentResult? = nil
    ) {
        self.filesystemKind = filesystemKind
        self.isPackage = isPackage
        self.posixMode = posixMode
        self.ownerID = ownerID
        self.groupID = groupID
        self.hasAccessControlList = hasAccessControlList
        self.extendedAttributeSizes = extendedAttributeSizes
        self.provenanceSyncIntentResult = provenanceSyncIntentResult
    }

    public var isDirectory: Bool { filesystemKind == .directory }
    public var isRegularFile: Bool { filesystemKind == .regularFile }
    public var isSymbolicLink: Bool { filesystemKind == .symbolicLink }
}

public protocol LocalItemSafetyInspecting: Sendable {
    func metadata(at url: URL) throws -> LocalItemSafetyMetadata
    func volumeRoot(for url: URL) throws -> URL
}

public enum LocalPackageAncestryValidationError: Error, Equatable, Sendable {
    case selectedRootIsPackage
    case selectedRootIsInsidePackage
    case selectedRootOutsideVolume
    case metadataUnavailable
}

/// Enrollment calls this while it already owns live security-scoped access.
/// The validator never opens, retains, or releases that capability itself.
public struct LocalPackageAncestryValidator: Sendable {
    private let inspector: any LocalItemSafetyInspecting

    public init(inspector: any LocalItemSafetyInspecting = SystemLocalItemSafetyInspector()) {
        self.inspector = inspector
    }

    public func validate(canonicalSelectedRoot: URL) throws {
        let selected = canonicalSelectedRoot.standardizedFileURL
        let volumeRoot: URL
        do {
            volumeRoot = try inspector.volumeRoot(for: selected).standardizedFileURL
        } catch {
            throw LocalPackageAncestryValidationError.metadataUnavailable
        }
        guard Self.contains(selected, in: volumeRoot) else {
            throw LocalPackageAncestryValidationError.selectedRootOutsideVolume
        }

        var candidate = selected
        var visited: Set<[String]> = []
        while true {
            let candidateKey = Self.comparableComponents(candidate)
            guard visited.insert(candidateKey).inserted else {
                throw LocalPackageAncestryValidationError.metadataUnavailable
            }
            let metadata: LocalItemSafetyMetadata
            do {
                metadata = try inspector.metadata(at: candidate)
            } catch {
                throw LocalPackageAncestryValidationError.metadataUnavailable
            }
            if metadata.isPackage {
                throw Self.pathsEqual(candidate, selected)
                    ? LocalPackageAncestryValidationError.selectedRootIsPackage
                    : LocalPackageAncestryValidationError.selectedRootIsInsidePackage
            }
            if Self.pathsEqual(candidate, volumeRoot) { return }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard !Self.pathsEqual(parent, candidate) else {
                throw LocalPackageAncestryValidationError.selectedRootOutsideVolume
            }
            candidate = parent
        }
    }

    private static func contains(_ selected: URL, in volumeRoot: URL) -> Bool {
        let candidate = comparableComponents(selected)
        let prefix = comparableComponents(volumeRoot)
        guard prefix.count <= candidate.count else { return false }
        return zip(candidate, prefix).allSatisfy { $0.0 == $0.1 }
    }

    private static func pathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        comparableComponents(lhs) == comparableComponents(rhs)
    }

    private static func comparableComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.map {
            $0.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}

public struct SystemLocalItemSafetyInspector: LocalItemSafetyInspecting {
    private let provenanceClassifier: any LocalProvenanceSyncIntentClassifying

    public init(
        provenanceClassifier: any LocalProvenanceSyncIntentClassifying =
            SystemLocalProvenanceSyncIntentClassifier()
    ) {
        self.provenanceClassifier = provenanceClassifier
    }

    public func metadata(at url: URL) throws -> LocalItemSafetyMetadata {
        let identity = try posixIdentity(at: url)
        let filesystemKind = identity.filesystemKind
        guard filesystemKind != .indeterminate else {
            throw CocoaError(.fileReadUnknown)
        }

        // Settings exclude symbolic links, and known special kinds are typed
        // exclusions. Do not perform metadata probes intended for regular
        // files or directories against either category.
        guard filesystemKind == .regularFile || filesystemKind == .directory else {
            return LocalItemSafetyMetadata(
                filesystemKind: filesystemKind,
                posixMode: identity.mode,
                ownerID: identity.owner,
                groupID: identity.group
            )
        }

        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isPackageKey])
        let extendedAttributeSizes = try extendedAttributeSizes(at: url)
        let provenanceResult = Self.provenanceResult(
            forExtendedAttributeNames: Set(extendedAttributeSizes.keys),
            classifier: provenanceClassifier
        )
        return LocalItemSafetyMetadata(
            filesystemKind: filesystemKind,
            isPackage: values.isPackage == true,
            posixMode: identity.mode,
            ownerID: identity.owner,
            groupID: identity.group,
            hasAccessControlList: try hasExtendedACL(at: url),
            extendedAttributeSizes: extendedAttributeSizes,
            provenanceSyncIntentResult: provenanceResult
        )
    }

    static func provenanceResult(
        forExtendedAttributeNames names: Set<String>,
        classifier: any LocalProvenanceSyncIntentClassifying
    ) -> LocalProvenanceSyncIntentResult? {
        guard names.contains(LocalItemSafetyClassifier.provenanceName) else {
            return nil
        }
        return classifier.classify()
    }

    private func posixIdentity(
        at url: URL
    ) throws -> (
        mode: UInt16,
        owner: UInt32,
        group: UInt32,
        filesystemKind: LocalFilesystemKind
    ) {
#if canImport(Darwin)
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &status) } ?? -1
        }
        guard result == 0 else { throw posixError() }
        return (
            UInt16(status.st_mode & mode_t(0o7777)),
            UInt32(status.st_uid),
            UInt32(status.st_gid),
            filesystemKind(from: status.st_mode)
        )
#else
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value else {
            throw CocoaError(.fileReadUnknown)
        }
        let kind: LocalFilesystemKind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: kind = .regularFile
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symbolicLink
        case .typeSocket: kind = .socket
        case .typeCharacterSpecial: kind = .characterDevice
        case .typeBlockSpecial: kind = .blockDevice
        default: kind = .indeterminate
        }
        return (permissions & 0o7777, owner, group, kind)
#endif
    }

#if canImport(Darwin)
    private func filesystemKind(from mode: mode_t) -> LocalFilesystemKind {
        let modeType = mode & mode_t(S_IFMT)
        switch modeType {
        case mode_t(S_IFREG): return .regularFile
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symbolicLink
        case mode_t(S_IFIFO): return .fifo
        case mode_t(S_IFSOCK): return .socket
        case mode_t(S_IFCHR): return .characterDevice
        case mode_t(S_IFBLK): return .blockDevice
        case 0: return .indeterminate
        default: return .other(modeType: UInt16(modeType))
        }
    }
#endif

    public func volumeRoot(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.volumeURLKey])
        guard let volume = values.volume else {
            throw CocoaError(.fileReadUnknown)
        }
        return volume
    }

    private func extendedAttributeSizes(at url: URL) throws -> [String: Int] {
#if canImport(Darwin)
        let required = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return listxattr(path, nil, 0, XATTR_NOFOLLOW)
        }
        guard required >= 0 else { throw posixError() }
        guard required > 0 else { return [:] }
        var bytes = [CChar](repeating: 0, count: required)
        let read = bytes.withUnsafeMutableBufferPointer { buffer in
            url.withUnsafeFileSystemRepresentation { path -> Int in
                guard let path, let base = buffer.baseAddress else { return -1 }
                return listxattr(path, base, buffer.count, XATTR_NOFOLLOW)
            }
        }
        guard read >= 0 else { throw posixError() }
        var result: [String: Int] = [:]
        var start = 0
        for index in 0..<read where bytes[index] == 0 {
            let name = bytes[start..<index].map { UInt8(bitPattern: $0) }
            guard let value = String(bytes: name, encoding: .utf8) else {
                throw CocoaError(.fileReadUnknown)
            }
            // Presence is sufficient for the bounded predicate. Do not read
            // or retain the opaque provenance payload length.
            if value == LocalItemSafetyClassifier.provenanceName {
                result[value] = 0
                start = index + 1
                continue
            }
            let size = url.withUnsafeFileSystemRepresentation { path -> Int in
                guard let path else { return -1 }
                return value.withCString { name in
                    getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard size >= 0 else { throw posixError() }
            result[value] = size
            start = index + 1
        }
        return result
#else
        throw CocoaError(.fileReadUnknown)
#endif
    }

    private func hasExtendedACL(at url: URL) throws -> Bool {
#if canImport(Darwin)
        errno = 0
        let acl = url.withUnsafeFileSystemRepresentation { path in
            path.map { acl_get_link_np($0, ACL_TYPE_EXTENDED) } ?? nil
        }
        guard let acl else {
            if errno == ENOENT || errno == ENOATTR { return false }
            throw posixError()
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(
            acl,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        )
        guard result >= 0 else { throw posixError() }
        return result == 1
#else
        throw CocoaError(.fileReadUnknown)
#endif
    }

    private func posixError() -> Error {
#if canImport(Darwin)
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
#else
        return CocoaError(.fileReadUnknown)
#endif
    }
}

enum LocalItemSafetyClassificationError: Error, Equatable, Sendable {
    case indeterminateFilesystemKind
}

enum LocalItemSafetyClassifier {
    static let provenanceName = "com.apple.provenance"
    static let finderTagsName = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfoName = "com.apple.FinderInfo"
    static let resourceForkName = "com.apple.ResourceFork"

    static func exclusion(
        for path: SyncPath,
        metadata: LocalItemSafetyMetadata,
        effectiveUserID: UInt32 = currentEffectiveUserID,
        effectiveGroupID: UInt32 = currentEffectiveGroupID
    ) throws -> ScanExclusion? {
        // Symlinks are excluded by SyncSettings after observation. Their
        // lstat identity describes the link, while Foundation's file-kind
        // resource values may describe the target, so applying file or
        // directory baselines here would manufacture a misleading reason.
        if metadata.isSymbolicLink { return nil }
        switch metadata.filesystemKind {
        case .regularFile, .directory:
            break
        case .indeterminate:
            throw LocalItemSafetyClassificationError.indeterminateFilesystemKind
        case .fifo, .socket, .characterDevice, .blockDevice, .other:
            return ScanExclusion(
                path: path,
                scope: .item,
                reason: .unsupportedFilesystemKind(metadata.filesystemKind)
            )
        case .symbolicLink:
            return nil
        }
        let scope: ScanExclusion.Scope = metadata.isDirectory ? .subtree : .item
        if metadata.isDirectory, metadata.isPackage {
            return ScanExclusion(path: path, scope: .subtree, reason: .packageDirectory)
        }

        let nonempty = metadata.extendedAttributeSizes.filter { $0.value > 0 }
        let ignorableWhenEmpty = Set([finderInfoName, resourceForkName])
        let unsupportedAttributes = metadata.extendedAttributeSizes.filter {
            if $0.key == provenanceName,
               metadata.provenanceSyncIntentResult == .ignored {
                return false
            }
            return $0.value > 0 || !ignorableWhenEmpty.contains($0.key)
        }
        var metadataKinds: Set<MetadataKind> = []
        if !unsupportedAttributes.isEmpty {
            metadataKinds.insert(.extendedAttributes)
        }
        if (nonempty[finderTagsName] ?? 0) > 0 { metadataKinds.insert(.finderTags) }
        if (nonempty[finderInfoName] ?? 0) > 0 { metadataKinds.insert(.finderInfo) }
        if (nonempty[resourceForkName] ?? 0) > 0 { metadataKinds.insert(.resourceFork) }
        if !metadataKinds.isEmpty {
            return ScanExclusion(
                path: path,
                scope: scope,
                reason: .unsupportedMetadata(metadataKinds)
            )
        }

        if metadata.isRegularFile || metadata.isDirectory {
            let required: UInt16 = metadata.isDirectory ? 0o755 : 0o644
            if metadata.posixMode != required {
                return ScanExclusion(
                    path: path,
                    scope: scope,
                    reason: .unsupportedPOSIXPermissions(
                        actual: metadata.posixMode,
                        required: required
                    )
                )
            }
            if metadata.hasAccessControlList {
                return ScanExclusion(path: path, scope: scope, reason: .accessControlList)
            }
            if metadata.ownerID != effectiveUserID || metadata.groupID != effectiveGroupID {
                return ScanExclusion(path: path, scope: scope, reason: .unsupportedOwnership)
            }
        }
        return nil
    }

    static var currentEffectiveUserID: UInt32 {
#if canImport(Darwin)
        UInt32(geteuid())
#else
        0
#endif
    }

    static var currentEffectiveGroupID: UInt32 {
#if canImport(Darwin)
        UInt32(getegid())
#else
        0
#endif
    }
}
