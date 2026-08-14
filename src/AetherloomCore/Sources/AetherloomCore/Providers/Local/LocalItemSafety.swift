import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct LocalItemSafetyMetadata: Hashable, Sendable {
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var isPackage: Bool
    public var posixMode: UInt16
    public var ownerID: UInt32
    public var groupID: UInt32
    public var hasAccessControlList: Bool
    public var extendedAttributeSizes: [String: Int]

    public init(
        isDirectory: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool = false,
        isPackage: Bool = false,
        posixMode: UInt16,
        ownerID: UInt32,
        groupID: UInt32,
        hasAccessControlList: Bool = false,
        extendedAttributeSizes: [String: Int] = [:]
    ) {
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
        self.posixMode = posixMode
        self.ownerID = ownerID
        self.groupID = groupID
        self.hasAccessControlList = hasAccessControlList
        self.extendedAttributeSizes = extendedAttributeSizes
    }
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
        var visited: Set<String> = []
        while true {
            guard visited.insert(candidate.path).inserted else {
                throw LocalPackageAncestryValidationError.metadataUnavailable
            }
            let metadata: LocalItemSafetyMetadata
            do {
                metadata = try inspector.metadata(at: candidate)
            } catch {
                throw LocalPackageAncestryValidationError.metadataUnavailable
            }
            if metadata.isPackage {
                throw candidate == selected
                    ? LocalPackageAncestryValidationError.selectedRootIsPackage
                    : LocalPackageAncestryValidationError.selectedRootIsInsidePackage
            }
            if candidate == volumeRoot { return }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else {
                throw LocalPackageAncestryValidationError.selectedRootOutsideVolume
            }
            candidate = parent
        }
    }

    private static func contains(_ selected: URL, in volumeRoot: URL) -> Bool {
        let volumePath = volumeRoot.path
        return volumePath == "/"
            || selected.path == volumePath
            || selected.path.hasPrefix(volumePath + "/")
    }
}

public struct SystemLocalItemSafetyInspector: LocalItemSafetyInspecting {
    public init() {}

    public func metadata(at url: URL) throws -> LocalItemSafetyMetadata {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
        ])
        let identity = try posixIdentity(at: url)
        return LocalItemSafetyMetadata(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true,
            isPackage: values.isPackage == true,
            posixMode: identity.mode,
            ownerID: identity.owner,
            groupID: identity.group,
            hasAccessControlList: try hasExtendedACL(at: url),
            extendedAttributeSizes: try extendedAttributeSizes(at: url)
        )
    }

    private func posixIdentity(
        at url: URL
    ) throws -> (mode: UInt16, owner: UInt32, group: UInt32) {
#if canImport(Darwin)
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &status) } ?? -1
        }
        guard result == 0 else { throw posixError() }
        return (
            UInt16(status.st_mode & mode_t(0o7777)),
            UInt32(status.st_uid),
            UInt32(status.st_gid)
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
        return (permissions & 0o7777, owner, group)
#endif
    }

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
        defer { acl_free(acl) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry)
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

enum LocalItemSafetyClassifier {
    static let finderTagsName = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfoName = "com.apple.FinderInfo"
    static let resourceForkName = "com.apple.ResourceFork"

    static func exclusion(
        for path: SyncPath,
        metadata: LocalItemSafetyMetadata,
        effectiveUserID: UInt32 = currentEffectiveUserID,
        effectiveGroupID: UInt32 = currentEffectiveGroupID
    ) -> ScanExclusion? {
        let scope: ScanExclusion.Scope = metadata.isDirectory ? .subtree : .item
        if metadata.isDirectory, metadata.isPackage {
            return ScanExclusion(path: path, scope: .subtree, reason: .packageDirectory)
        }

        let nonempty = metadata.extendedAttributeSizes.filter { $0.value > 0 }
        let ignorableWhenEmpty = Set([finderInfoName, resourceForkName])
        let unsupportedAttributes = metadata.extendedAttributeSizes.filter {
            $0.value > 0 || !ignorableWhenEmpty.contains($0.key)
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
