import Foundation

public enum ProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case iCloudDrive
    case googleDrive
    case oneDrive

    public var displayName: String {
        switch self {
        case .iCloudDrive:
            "iCloud Drive"
        case .googleDrive:
            "Google Drive"
        case .oneDrive:
            "OneDrive"
        }
    }
}

public struct CloudPath: Codable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = Self.normalized(rawValue)
    }

    public init(rawValue: String) {
        self.rawValue = Self.normalized(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public static let root = CloudPath("/")

    public var isRoot: Bool {
        rawValue == "/"
    }

    public var components: [String] {
        rawValue.split(separator: "/").map(String.init)
    }

    public var name: String {
        components.last ?? ""
    }

    public var parent: CloudPath {
        guard !isRoot else { return .root }
        var parts = components
        parts.removeLast()
        return parts.isEmpty ? .root : CloudPath("/" + parts.joined(separator: "/"))
    }

    public var pathExtension: String {
        (name as NSString).pathExtension
    }

    public var deletingPathExtensionName: String {
        let extensionValue = pathExtension
        guard !extensionValue.isEmpty else { return name }
        let suffix = "." + extensionValue
        return String(name.dropLast(suffix.count))
    }

    public var caseInsensitiveKey: String {
        rawValue
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public func appending(_ component: String) -> CloudPath {
        guard !component.isEmpty else { return self }
        if isRoot {
            return CloudPath("/" + component)
        }
        return CloudPath(rawValue + "/" + component)
    }

    public func replacingLastComponent(with component: String) -> CloudPath {
        parent.appending(component)
    }

    public func isDescendant(of ancestor: CloudPath) -> Bool {
        guard !ancestor.isRoot else { return true }
        return rawValue == ancestor.rawValue || rawValue.hasPrefix(ancestor.rawValue + "/")
    }

    public static func < (lhs: CloudPath, rhs: CloudPath) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let parts = withLeadingSlash.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.joined(separator: "/")
    }
}

public enum SyncScope: Codable, Hashable, Sendable {
    case selectedFolder(path: CloudPath)
    case entireDrive

    public var rootPath: CloudPath {
        switch self {
        case let .selectedFolder(path):
            path
        case .entireDrive:
            .root
        }
    }
}

public struct CloudItem: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var providerItemID: String?
    public var path: CloudPath
    public var name: String
    public var isFolder: Bool
    public var size: Int64?
    public var modifiedAt: Date?
    public var contentHash: String?
    public var revisionID: String?
    public var eTag: String?
    public var cTag: String?
    public var isTrashed: Bool
    public var isPlaceholder: Bool

    public init(
        provider: ProviderID,
        providerItemID: String? = nil,
        path: CloudPath,
        name: String? = nil,
        isFolder: Bool,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        contentHash: String? = nil,
        revisionID: String? = nil,
        eTag: String? = nil,
        cTag: String? = nil,
        isTrashed: Bool = false,
        isPlaceholder: Bool = false
    ) {
        self.provider = provider
        self.providerItemID = providerItemID
        self.path = path
        self.name = name ?? path.name
        self.isFolder = isFolder
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.revisionID = revisionID
        self.eTag = eTag
        self.cTag = cTag
        self.isTrashed = isTrashed
        self.isPlaceholder = isPlaceholder
    }
}

public struct SyncSet: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var providers: [ProviderID: SyncScope]
    public var mode: SyncMode
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        providers: [ProviderID: SyncScope],
        mode: SyncMode = .balancedMirror,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.providers = providers
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SyncMode: String, Codable, Hashable, Sendable {
    case balancedMirror
    case askBeforeDeleting
    case noDeletePropagation
}

public struct SyncRecord: Codable, Hashable, Sendable {
    public var syncID: UUID
    public var syncSetID: UUID
    public var canonicalPath: CloudPath
    public var isFolder: Bool
    public var googleDriveItemID: String?
    public var oneDriveItemID: String?
    public var iCloudBookmarkData: Data?
    public var lastKnownHash: String?
    public var lastKnownSize: Int64?
    public var lastKnownModifiedAt: Date?
    public var googleRevisionID: String?
    public var oneDriveETag: String?
    public var oneDriveCTag: String?
    public var iCloudFileResourceIdentifier: String?
    public var lastSyncedAt: Date?
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        syncID: UUID = UUID(),
        syncSetID: UUID,
        canonicalPath: CloudPath,
        isFolder: Bool,
        googleDriveItemID: String? = nil,
        oneDriveItemID: String? = nil,
        iCloudBookmarkData: Data? = nil,
        lastKnownHash: String? = nil,
        lastKnownSize: Int64? = nil,
        lastKnownModifiedAt: Date? = nil,
        googleRevisionID: String? = nil,
        oneDriveETag: String? = nil,
        oneDriveCTag: String? = nil,
        iCloudFileResourceIdentifier: String? = nil,
        lastSyncedAt: Date? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.syncID = syncID
        self.syncSetID = syncSetID
        self.canonicalPath = canonicalPath
        self.isFolder = isFolder
        self.googleDriveItemID = googleDriveItemID
        self.oneDriveItemID = oneDriveItemID
        self.iCloudBookmarkData = iCloudBookmarkData
        self.lastKnownHash = lastKnownHash
        self.lastKnownSize = lastKnownSize
        self.lastKnownModifiedAt = lastKnownModifiedAt
        self.googleRevisionID = googleRevisionID
        self.oneDriveETag = oneDriveETag
        self.oneDriveCTag = oneDriveCTag
        self.iCloudFileResourceIdentifier = iCloudFileResourceIdentifier
        self.lastSyncedAt = lastSyncedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func itemID(for provider: ProviderID) -> String? {
        switch provider {
        case .iCloudDrive:
            iCloudFileResourceIdentifier
        case .googleDrive:
            googleDriveItemID
        case .oneDrive:
            oneDriveItemID
        }
    }

    public func providerRevision(for provider: ProviderID) -> String? {
        switch provider {
        case .iCloudDrive:
            iCloudFileResourceIdentifier
        case .googleDrive:
            googleRevisionID
        case .oneDrive:
            oneDriveETag ?? oneDriveCTag
        }
    }
}

public enum SyncEvent: Codable, Hashable, Sendable {
    case created(provider: ProviderID, item: CloudItem)
    case edited(provider: ProviderID, item: CloudItem)
    case moved(provider: ProviderID, item: CloudItem, oldPath: CloudPath, newPath: CloudPath)
    case renamed(provider: ProviderID, item: CloudItem, oldPath: CloudPath, newPath: CloudPath)
    case trashed(provider: ProviderID, item: CloudItem)
    case unavailable(provider: ProviderID, reason: String)
}

public enum SyncAction: Codable, Hashable, Sendable {
    case upload(source: ProviderID, destination: ProviderID, sourceItem: CloudItem, destinationPath: CloudPath)
    case overwrite(source: ProviderID, destination: ProviderID, sourceItem: CloudItem, destinationItem: CloudItem)
    case createFolder(destination: ProviderID, path: CloudPath)
    case move(destination: ProviderID, item: CloudItem, newPath: CloudPath)
    case rename(destination: ProviderID, item: CloudItem, newName: String)
    case trash(destination: ProviderID, item: CloudItem)
    case createConflictCopy(source: ProviderID, destination: ProviderID, sourceItem: CloudItem, conflictPath: CloudPath)
    case pause(reason: String)

    public var destinationProvider: ProviderID? {
        switch self {
        case let .upload(_, destination, _, _),
             let .overwrite(_, destination, _, _),
             let .createFolder(destination, _),
             let .move(destination, _, _),
             let .rename(destination, _, _),
             let .trash(destination, _),
             let .createConflictCopy(_, destination, _, _):
            destination
        case .pause:
            nil
        }
    }
}

public struct SyncPlan: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var actions: [SyncAction]
    public var warnings: [SyncWarning]
    public var conflicts: [SyncConflict]
    public var riskLevel: SyncRiskLevel
    public var isAutoExecutable: Bool

    public init(
        syncSetID: UUID,
        actions: [SyncAction],
        warnings: [SyncWarning] = [],
        conflicts: [SyncConflict] = [],
        riskLevel: SyncRiskLevel = .safe,
        isAutoExecutable: Bool = true
    ) {
        self.syncSetID = syncSetID
        self.actions = actions
        self.warnings = warnings
        self.conflicts = conflicts
        self.riskLevel = riskLevel
        self.isAutoExecutable = isAutoExecutable
    }
}

public enum SyncRiskLevel: String, Codable, Hashable, Sendable, Comparable {
    case safe
    case needsReview
    case paused

    public static func < (lhs: SyncRiskLevel, rhs: SyncRiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .safe:
            0
        case .needsReview:
            1
        case .paused:
            2
        }
    }
}

public enum SyncWarningSeverity: String, Codable, Hashable, Sendable {
    case info
    case needsReview
    case pause
}

public struct SyncWarning: Codable, Hashable, Sendable {
    public var id: UUID
    public var severity: SyncWarningSeverity
    public var message: String
    public var provider: ProviderID?
    public var path: CloudPath?

    public init(
        id: UUID = UUID(),
        severity: SyncWarningSeverity,
        message: String,
        provider: ProviderID? = nil,
        path: CloudPath? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.provider = provider
        self.path = path
    }
}

public struct SyncConflict: Codable, Hashable, Sendable {
    public var id: UUID
    public var path: CloudPath
    public var providers: [ProviderID]
    public var items: [CloudItem]
    public var message: String

    public init(
        id: UUID = UUID(),
        path: CloudPath,
        providers: [ProviderID],
        items: [CloudItem],
        message: String
    ) {
        self.id = id
        self.path = path
        self.providers = providers
        self.items = items
        self.message = message
    }
}

public enum ProviderScopeStatus: Codable, Hashable, Sendable {
    case available
    case unavailable(reason: String)
    case incomplete(reason: String)
    case warning(message: String)
}

public struct ChangeCursor: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ChangePage: Codable, Hashable, Sendable {
    public var changes: [SyncEvent]
    public var nextCursor: ChangeCursor?
    public var isComplete: Bool

    public init(changes: [SyncEvent], nextCursor: ChangeCursor? = nil, isComplete: Bool = true) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.isComplete = isComplete
    }
}

public struct UploadOptions: Codable, Hashable, Sendable {
    public var allowOverwrite: Bool
    public var expectedDestinationRevisionID: String?

    public init(allowOverwrite: Bool = false, expectedDestinationRevisionID: String? = nil) {
        self.allowOverwrite = allowOverwrite
        self.expectedDestinationRevisionID = expectedDestinationRevisionID
    }
}

public enum ProviderScanStatus: Codable, Hashable, Sendable {
    case complete
    case unavailable(reason: String)
    case incomplete(reason: String)
}

public struct ProviderSnapshot: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var scope: SyncScope
    public var items: [CloudItem]
    public var status: ProviderScanStatus
    public var scannedAt: Date

    public init(
        provider: ProviderID,
        scope: SyncScope,
        items: [CloudItem],
        status: ProviderScanStatus = .complete,
        scannedAt: Date = Date()
    ) {
        self.provider = provider
        self.scope = scope
        self.items = items
        self.status = status
        self.scannedAt = scannedAt
    }
}

public struct SafetyThresholds: Codable, Hashable, Sendable {
    public var massDeleteAbsolute: Int
    public var massDeleteRatio: Double
    public var massEditAbsolute: Int
    public var massEditRatio: Double

    public init(
        massDeleteAbsolute: Int = 25,
        massDeleteRatio: Double = 0.25,
        massEditAbsolute: Int = 50,
        massEditRatio: Double = 0.5
    ) {
        self.massDeleteAbsolute = massDeleteAbsolute
        self.massDeleteRatio = massDeleteRatio
        self.massEditAbsolute = massEditAbsolute
        self.massEditRatio = massEditRatio
    }
}

public enum SyncExclusionMatchStyle: String, Codable, Hashable, Sendable {
    case exactPath
    case filename
    case suffix
    case prefix
    case contains
}

public struct SyncExclusion: Codable, Hashable, Sendable {
    public var pattern: String
    public var matchStyle: SyncExclusionMatchStyle
    public var isCaseSensitive: Bool

    public init(pattern: String, matchStyle: SyncExclusionMatchStyle, isCaseSensitive: Bool = false) {
        self.pattern = pattern
        self.matchStyle = matchStyle
        self.isCaseSensitive = isCaseSensitive
    }

    public func matches(_ path: CloudPath) -> Bool {
        let candidate: String
        switch matchStyle {
        case .exactPath, .suffix, .prefix, .contains:
            candidate = path.rawValue
        case .filename:
            candidate = path.name
        }

        let lhs = isCaseSensitive ? candidate : candidate.lowercased()
        let rhs = isCaseSensitive ? pattern : pattern.lowercased()

        switch matchStyle {
        case .exactPath:
            return CloudPath(lhs).rawValue == CloudPath(rhs).rawValue
        case .filename:
            return lhs == rhs
        case .suffix:
            return lhs.hasSuffix(rhs)
        case .prefix:
            return lhs.hasPrefix(rhs)
        case .contains:
            return lhs.contains(rhs)
        }
    }
}

public struct SyncPlannerSettings: Codable, Hashable, Sendable {
    public var exclusions: [SyncExclusion]
    public var safetyThresholds: SafetyThresholds

    public init(exclusions: [SyncExclusion] = [], safetyThresholds: SafetyThresholds = SafetyThresholds()) {
        self.exclusions = exclusions
        self.safetyThresholds = safetyThresholds
    }

    public func isExcluded(_ path: CloudPath) -> Bool {
        exclusions.contains { $0.matches(path) }
    }
}

extension CloudItem {
    public var versionToken: String? {
        contentHash ?? revisionID ?? eTag ?? cTag
    }
}
