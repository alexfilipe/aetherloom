import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case localFolder
    case nasFolder
    case iCloudDrive
    case googleDrive
    case oneDrive
    case dropbox

    public var displayName: String {
        switch self {
        case .localFolder:
            "Local Folder"
        case .nasFolder:
            "NAS Folder"
        case .iCloudDrive:
            "iCloud Drive"
        case .googleDrive:
            "Google Drive"
        case .oneDrive:
            "OneDrive"
        case .dropbox:
            "Dropbox"
        }
    }
}

public struct LocationID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: LocationID, rhs: LocationID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

extension LocationID {
    public static let localFolder = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    public static let nasFolder = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    public static let iCloudDrive = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    public static let googleDrive = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    public static let oneDrive = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    public static let dropbox = LocationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)

    public var displayName: String {
        switch self {
        case .localFolder:
            ProviderKind.localFolder.displayName
        case .nasFolder:
            ProviderKind.nasFolder.displayName
        case .iCloudDrive:
            ProviderKind.iCloudDrive.displayName
        case .googleDrive:
            ProviderKind.googleDrive.displayName
        case .oneDrive:
            ProviderKind.oneDrive.displayName
        case .dropbox:
            ProviderKind.dropbox.displayName
        default:
            rawValue.uuidString
        }
    }

    public var defaultKind: ProviderKind {
        switch self {
        case .localFolder:
            .localFolder
        case .nasFolder:
            .nasFolder
        case .iCloudDrive:
            .iCloudDrive
        case .googleDrive:
            .googleDrive
        case .oneDrive:
            .oneDrive
        case .dropbox:
            .dropbox
        default:
            .localFolder
        }
    }
}

public struct SyncLocation: Codable, Hashable, Sendable, Identifiable {
    public var id: LocationID
    public var kind: ProviderKind
    public var displayName: String
    public var scope: SyncScope
    public var configuration: [String: String]

    public init(
        id: LocationID = LocationID(),
        kind: ProviderKind,
        displayName: String? = nil,
        scope: SyncScope = .entireDrive,
        configuration: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName ?? kind.displayName
        self.scope = scope
        self.configuration = configuration
    }
}

public struct SyncPath: Codable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral {
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

    public static let root = SyncPath("/")

    public var isRoot: Bool {
        rawValue == "/"
    }

    public var components: [String] {
        rawValue.split(separator: "/").map(String.init)
    }

    public var name: String {
        components.last ?? ""
    }

    public var parent: SyncPath {
        guard !isRoot else { return .root }
        var parts = components
        parts.removeLast()
        return parts.isEmpty ? .root : SyncPath("/" + parts.joined(separator: "/"))
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

    public func appending(_ component: String) -> SyncPath {
        guard !component.isEmpty else { return self }
        if isRoot {
            return SyncPath("/" + component)
        }
        return SyncPath(rawValue + "/" + component)
    }

    public func replacingLastComponent(with component: String) -> SyncPath {
        parent.appending(component)
    }

    public func isDescendant(of ancestor: SyncPath) -> Bool {
        guard !ancestor.isRoot else { return true }
        return rawValue == ancestor.rawValue || rawValue.hasPrefix(ancestor.rawValue + "/")
    }

    public static func < (lhs: SyncPath, rhs: SyncPath) -> Bool {
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
    case selectedFolder(path: SyncPath)
    case entireDrive

    public var rootPath: SyncPath {
        switch self {
        case let .selectedFolder(path):
            path
        case .entireDrive:
            .root
        }
    }
}

public enum ItemKind: Codable, Hashable, Sendable {
    case file
    case folder
    case symlink(target: String)
}

public enum VersionComparison: Codable, Hashable, Sendable {
    case same
    case different
    case unknown
}

public struct ItemVersion: Codable, Hashable, Sendable {
    public var contentHash: String?
    public var size: Int64?
    public var modifiedAt: Date?
    public var revisionToken: String?

    public init(
        contentHash: String? = nil,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        revisionToken: String? = nil
    ) {
        self.contentHash = contentHash
        self.size = size
        self.modifiedAt = modifiedAt
        self.revisionToken = revisionToken
    }

    public func comparison(to other: ItemVersion) -> VersionComparison {
        if let contentHash, let otherHash = other.contentHash {
            return contentHash == otherHash ? .same : .different
        }
        if let size, let modifiedAt, let otherSize = other.size, let otherModifiedAt = other.modifiedAt {
            return size == otherSize && modifiedAt == otherModifiedAt ? .same : .different
        }
        if let revisionToken, let otherRevisionToken = other.revisionToken {
            return revisionToken == otherRevisionToken ? .same : .different
        }
        return .unknown
    }

    public func itemChanged(vs base: ItemVersion) -> Bool {
        comparison(to: base) != .same
    }

    public func isSameVersion(as other: ItemVersion) -> Bool {
        comparison(to: other) == .same
    }
}

public struct ItemObservation: Codable, Hashable, Sendable {
    public var location: LocationID
    public var itemID: String?
    public var path: SyncPath
    public var kind: ItemKind
    public var version: ItemVersion
    public var isPlaceholder: Bool
    public var isTrashed: Bool

    public init(
        location: LocationID,
        itemID: String? = nil,
        path: SyncPath,
        kind: ItemKind,
        version: ItemVersion = ItemVersion(),
        isPlaceholder: Bool = false,
        isTrashed: Bool = false
    ) {
        self.location = location
        self.itemID = itemID
        self.path = path
        self.kind = kind
        self.version = version
        self.isPlaceholder = isPlaceholder
        self.isTrashed = isTrashed
    }

    public var name: String {
        path.name
    }

    public var isFolder: Bool {
        kind == .folder
    }
}

public struct BaseRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var syncSetID: UUID
    public var path: SyncPath
    public var kind: ItemKind
    public var version: ItemVersion
    public var perLocation: [LocationID: LocationMemory]
    public var tombstone: Tombstone?
    public var lastConvergedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        syncSetID: UUID,
        path: SyncPath,
        kind: ItemKind,
        version: ItemVersion = ItemVersion(),
        perLocation: [LocationID: LocationMemory] = [:],
        tombstone: Tombstone? = nil,
        lastConvergedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.syncSetID = syncSetID
        self.path = path
        self.kind = kind
        self.version = version
        self.perLocation = perLocation
        self.tombstone = tombstone
        self.lastConvergedAt = lastConvergedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func itemID(for location: LocationID) -> String? {
        perLocation[location]?.itemID
    }

    public func revisionToken(for location: LocationID) -> String? {
        perLocation[location]?.revisionToken
    }
}

public struct LocationMemory: Codable, Hashable, Sendable {
    public var itemID: String?
    public var revisionToken: String?
    public var lastSeenAt: Date?

    public init(itemID: String? = nil, revisionToken: String? = nil, lastSeenAt: Date? = nil) {
        self.itemID = itemID
        self.revisionToken = revisionToken
        self.lastSeenAt = lastSeenAt
    }
}

public struct Tombstone: Codable, Hashable, Sendable {
    public var deletedAt: Date
    public var initiatedBy: LocationID?

    public init(deletedAt: Date, initiatedBy: LocationID? = nil) {
        self.deletedAt = deletedAt
        self.initiatedBy = initiatedBy
    }
}

public struct SyncSet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var locations: [LocationID]
    public var mode: SyncMode
    public var settings: SyncSettings
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        locations: [LocationID],
        mode: SyncMode = .balancedMirror,
        settings: SyncSettings = SyncSettings(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.locations = locations
        self.mode = mode
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SyncMode: String, Codable, Hashable, Sendable {
    case balancedMirror
    case askBeforeDeleting
    case noDeletePropagation
}

public enum SyncEvent: Codable, Hashable, Sendable {
    case created(location: LocationID, item: ItemObservation)
    case edited(location: LocationID, item: ItemObservation)
    case moved(location: LocationID, item: ItemObservation, oldPath: SyncPath, newPath: SyncPath)
    case renamed(location: LocationID, item: ItemObservation, oldPath: SyncPath, newPath: SyncPath)
    case trashed(location: LocationID, item: ItemObservation)
    case unavailable(location: LocationID, reason: String)
}

public enum SyncAction: Codable, Hashable, Sendable {
    case upload(source: LocationID, destination: LocationID, sourceItem: ItemObservation, destinationPath: SyncPath)
    case overwrite(source: LocationID, destination: LocationID, sourceItem: ItemObservation, destinationItem: ItemObservation)
    case createFolder(destination: LocationID, path: SyncPath)
    case move(destination: LocationID, item: ItemObservation, newPath: SyncPath)
    case rename(destination: LocationID, item: ItemObservation, newName: String)
    case trash(destination: LocationID, item: ItemObservation)
    case createConflictCopy(source: LocationID, destination: LocationID, sourceItem: ItemObservation, conflictPath: SyncPath)
    case pause(reason: String)

    public var destinationLocation: LocationID? {
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
    public var location: LocationID?
    public var path: SyncPath?

    public init(
        id: UUID = UUID(),
        severity: SyncWarningSeverity,
        message: String,
        location: LocationID? = nil,
        path: SyncPath? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.location = location
        self.path = path
    }
}

public struct SyncConflict: Codable, Hashable, Sendable {
    public var id: UUID
    public var path: SyncPath
    public var locations: [LocationID]
    public var items: [ItemObservation]
    public var message: String

    public init(
        id: UUID = UUID(),
        path: SyncPath,
        locations: [LocationID],
        items: [ItemObservation],
        message: String
    ) {
        self.id = id
        self.path = path
        self.locations = locations
        self.items = items
        self.message = message
    }
}

public struct ChangeCursor: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ScanStatus: Codable, Hashable, Sendable {
    case complete
    case unavailable(reason: LocationUnavailabilityReason)
    case incomplete(reason: String)
}

public struct ObservationIndex: Codable, Hashable, Sendable {
    public var all: [ItemObservation]
    public var byPath: [SyncPath: ItemObservation]
    public var byItemID: [String: ItemObservation]
    public var byCaseFoldedPath: [String: ItemObservation]

    public init(_ observations: [ItemObservation]) {
        self.all = observations
        self.byPath = Dictionary(uniqueKeysWithValues: observations.map { ($0.path, $0) })
        self.byItemID = Dictionary(uniqueKeysWithValues: observations.compactMap { observation in
            observation.itemID.map { ($0, observation) }
        })
        self.byCaseFoldedPath = Dictionary(observations.map { ($0.path.caseInsensitiveKey, $0) }) { first, _ in first }
    }
}

public struct LocationSnapshot: Codable, Hashable, Sendable {
    public var location: LocationID
    public var scope: SyncScope
    public var status: ScanStatus
    public var scannedAt: Date
    public var observations: ObservationIndex

    public init(
        location: LocationID,
        scope: SyncScope,
        observations: [ItemObservation],
        status: ScanStatus = .complete,
        scannedAt: Date = Date()
    ) {
        self.location = location
        self.scope = scope
        self.status = status
        self.scannedAt = scannedAt
        self.observations = ObservationIndex(observations)
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

    public func matches(_ path: SyncPath) -> Bool {
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
            return SyncPath(lhs).rawValue == SyncPath(rhs).rawValue
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

public struct SyncSettings: Codable, Hashable, Sendable {
    public var exclusions: [SyncExclusion]
    public var thresholds: SafetyThresholds

    public init(exclusions: [SyncExclusion] = [], thresholds: SafetyThresholds = SafetyThresholds()) {
        self.exclusions = exclusions
        self.thresholds = thresholds
    }

    public func isExcluded(_ path: SyncPath) -> Bool {
        isBuiltInExcludedPath(path) || exclusions.contains { $0.matches(path) }
    }

    public func isExcluded(_ observation: ItemObservation) -> Bool {
        if case .symlink = observation.kind {
            return true
        }
        return isExcluded(observation.path)
    }

    public func isExcluded(path: SyncPath, kind: ItemKind) -> Bool {
        if case .symlink = kind {
            return true
        }
        return isExcluded(path)
    }

    private func isBuiltInExcludedPath(_ path: SyncPath) -> Bool {
        path.rawValue == "/.aetherloom" || path.rawValue.hasPrefix("/.aetherloom/")
    }
}

public struct PlanningEnvironment: Sendable {
    public var now: Date
    public var makeID: @Sendable () -> UUID
    public var locationNames: [LocationID: String]

    public init(
        now: Date,
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        locationNames: [LocationID: String] = [:]
    ) {
        self.now = now
        self.makeID = makeID
        self.locationNames = locationNames
    }
}

extension ItemObservation {
    public var contentHash: String? {
        version.contentHash
    }

    public var size: Int64? {
        version.size
    }

    public var modifiedAt: Date? {
        version.modifiedAt
    }

    public var revisionToken: String? {
        version.revisionToken
    }
}
