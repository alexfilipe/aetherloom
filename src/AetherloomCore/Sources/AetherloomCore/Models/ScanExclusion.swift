import Foundation

public enum LocalFilesystemKind: Codable, Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case fifo
    case socket
    case characterDevice
    case blockDevice
    case other(modeType: UInt16)
    case indeterminate

    var stableKey: String {
        switch self {
        case .regularFile: "regularFile"
        case .directory: "directory"
        case .symbolicLink: "symbolicLink"
        case .fifo: "fifo"
        case .socket: "socket"
        case .characterDevice: "characterDevice"
        case .blockDevice: "blockDevice"
        case let .other(modeType): "other:\(modeType)"
        case .indeterminate: "indeterminate"
        }
    }

    var displayName: String {
        switch self {
        case .regularFile: "regular file"
        case .directory: "directory"
        case .symbolicLink: "symbolic link"
        case .fifo: "FIFO"
        case .socket: "Unix socket"
        case .characterDevice: "character device"
        case .blockDevice: "block device"
        case .other: "special filesystem item"
        case .indeterminate: "item with an indeterminate filesystem kind"
        }
    }
}

public enum MetadataKind: String, Codable, Hashable, Sendable, CaseIterable {
    case extendedAttributes
    case finderTags
    case finderInfo
    case resourceFork

    public var displayName: String {
        switch self {
        case .extendedAttributes: "extended attributes"
        case .finderTags: "Finder tags"
        case .finderInfo: "Finder information"
        case .resourceFork: "resource fork"
        }
    }
}

/// Positive evidence that a present item cannot be represented safely by the
/// MVP. A subtree exclusion accounts for its root and every descendant without
/// fabricating observations or descendant exclusion rows.
public struct ScanExclusion: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Hashable, Sendable {
        case item
        case subtree
    }

    public enum Reason: Codable, Hashable, Sendable {
        case packageDirectory
        case unsupportedMetadata(Set<MetadataKind>)
        case unsupportedPOSIXPermissions(actual: UInt16, required: UInt16)
        case accessControlList
        case unsupportedOwnership
        case unsupportedFilesystemKind(LocalFilesystemKind)

        private enum CodingKeys: String, CodingKey {
            case kind
            case metadataKinds
            case actualMode
            case requiredMode
            case filesystemKind
        }

        private enum Kind: String, Codable {
            case packageDirectory
            case unsupportedMetadata
            case unsupportedPOSIXPermissions
            case accessControlList
            case unsupportedOwnership
            case unsupportedFilesystemKind
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .packageDirectory:
                self = .packageDirectory
            case .unsupportedMetadata:
                self = .unsupportedMetadata(Set(try container.decode(
                    [MetadataKind].self,
                    forKey: .metadataKinds
                )))
            case .unsupportedPOSIXPermissions:
                self = .unsupportedPOSIXPermissions(
                    actual: try container.decode(UInt16.self, forKey: .actualMode),
                    required: try container.decode(UInt16.self, forKey: .requiredMode)
                )
            case .accessControlList:
                self = .accessControlList
            case .unsupportedOwnership:
                self = .unsupportedOwnership
            case .unsupportedFilesystemKind:
                self = .unsupportedFilesystemKind(
                    try container.decode(
                        LocalFilesystemKind.self,
                        forKey: .filesystemKind
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .packageDirectory:
                try container.encode(Kind.packageDirectory, forKey: .kind)
            case let .unsupportedMetadata(kinds):
                try container.encode(Kind.unsupportedMetadata, forKey: .kind)
                try container.encode(
                    kinds.sorted { $0.rawValue < $1.rawValue },
                    forKey: .metadataKinds
                )
            case let .unsupportedPOSIXPermissions(actual, required):
                try container.encode(
                    Kind.unsupportedPOSIXPermissions,
                    forKey: .kind
                )
                try container.encode(actual, forKey: .actualMode)
                try container.encode(required, forKey: .requiredMode)
            case .accessControlList:
                try container.encode(Kind.accessControlList, forKey: .kind)
            case .unsupportedOwnership:
                try container.encode(Kind.unsupportedOwnership, forKey: .kind)
            case let .unsupportedFilesystemKind(filesystemKind):
                try container.encode(
                    Kind.unsupportedFilesystemKind,
                    forKey: .kind
                )
                try container.encode(
                    filesystemKind,
                    forKey: .filesystemKind
                )
            }
        }

        public var stableKey: String {
            switch self {
            case .packageDirectory:
                return "packageDirectory"
            case let .unsupportedMetadata(kinds):
                return "unsupportedMetadata:" + kinds.map(\.rawValue).sorted().joined(separator: ",")
            case let .unsupportedPOSIXPermissions(actual, required):
                return "unsupportedPOSIXPermissions:\(actual):\(required)"
            case .accessControlList:
                return "accessControlList"
            case .unsupportedOwnership:
                return "unsupportedOwnership"
            case let .unsupportedFilesystemKind(filesystemKind):
                return "unsupportedFilesystemKind:\(filesystemKind.stableKey)"
            }
        }

        public var message: String {
            switch self {
            case .packageDirectory:
                return "Aetherloom cannot yet preserve this package safely."
            case let .unsupportedMetadata(kinds):
                let names = kinds.map(\.displayName).sorted().joined(separator: ", ")
                return "Aetherloom cannot yet preserve this item's \(names) safely."
            case let .unsupportedPOSIXPermissions(actual, required):
                return "Aetherloom cannot yet preserve permissions \(Self.octal(actual)); this item requires exactly \(Self.octal(required))."
            case .accessControlList:
                return "Aetherloom cannot yet preserve this item's access control list safely."
            case .unsupportedOwnership:
                return "Aetherloom cannot yet preserve this item's user or group ownership safely."
            case let .unsupportedFilesystemKind(filesystemKind):
                return "Aetherloom cannot sync this \(filesystemKind.displayName) safely."
            }
        }

        private static func octal(_ value: UInt16) -> String {
            String(format: "%04o", value)
        }
    }

    public var path: SyncPath
    public var scope: Scope
    public var reason: Reason

    public init(path: SyncPath, scope: Scope, reason: Reason) {
        self.path = path
        self.scope = scope
        self.reason = reason
    }

    public func covers(_ candidate: SyncPath) -> Bool {
        switch scope {
        case .item:
            return candidate.caseInsensitiveKey == path.caseInsensitiveKey
        case .subtree:
            return candidate.isEqualOrDescendant(of: path)
        }
    }

    public static func normalized(_ values: [ScanExclusion]) -> [ScanExclusion] {
        var seen: Set<String> = []
        return values.sorted(by: stableSort).filter { exclusion in
            seen.insert(exclusion.stableKey).inserted
        }
    }

    public var stableKey: String {
        [
            path.caseInsensitiveKey,
            path.rawValue,
            scope.rawValue,
            reason.stableKey,
        ].joined(separator: "|")
    }

    private static func stableSort(_ lhs: ScanExclusion, _ rhs: ScanExclusion) -> Bool {
        lhs.stableKey < rhs.stableKey
    }
}

public struct LocatedScanExclusion: Codable, Hashable, Sendable, Comparable {
    public var location: LocationID
    public var exclusion: ScanExclusion

    public init(location: LocationID, exclusion: ScanExclusion) {
        self.location = location
        self.exclusion = exclusion
    }

    public static func < (lhs: LocatedScanExclusion, rhs: LocatedScanExclusion) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        return lhs.exclusion.stableKey < rhs.exclusion.stableKey
    }
}

/// The exact coverage a provider must reclassify immediately before a run or
/// recovery mutates anything. Directory operations require subtree coverage;
/// synchronized ancestors require only their own metadata.
public struct ProviderClassificationRequest: Codable, Hashable, Sendable, Comparable {
    public var path: SyncPath
    public var scope: ScanExclusion.Scope

    public init(path: SyncPath, scope: ScanExclusion.Scope) {
        self.path = path
        self.scope = scope
    }

    public static func < (
        lhs: ProviderClassificationRequest,
        rhs: ProviderClassificationRequest
    ) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.scope.rawValue < rhs.scope.rawValue
    }
}

public enum ProviderPathClassification: Codable, Hashable, Sendable {
    case supported
    case excluded([ScanExclusion])
    case unavailable(detail: String)
    case ambiguous(detail: String)

    public var exclusions: [ScanExclusion] {
        if case let .excluded(values) = self { return values }
        return []
    }

    public var permitsMutation: Bool {
        if case .supported = self { return true }
        return false
    }
}
