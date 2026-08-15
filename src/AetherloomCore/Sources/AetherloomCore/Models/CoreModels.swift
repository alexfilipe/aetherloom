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
    public private(set) var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = Self.normalized(rawValue)
    }

    public init(rawValue: String) {
        self.rawValue = Self.normalized(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
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

    /// Component-aware equality/ancestry used by joins, collision handling,
    /// and positive subtree exclusions. The default is deliberately the
    /// conservative case/diacritic-insensitive relation used when a provider
    /// cannot prove case sensitivity.
    public func isEqualOrDescendant(
        of ancestor: SyncPath,
        caseSensitive: Bool = false
    ) -> Bool {
        let candidate = comparableComponents(caseSensitive: caseSensitive)
        let prefix = ancestor.comparableComponents(caseSensitive: caseSensitive)
        guard prefix.count <= candidate.count else { return false }
        return zip(candidate, prefix).allSatisfy { $0.0 == $0.1 }
    }

    public func isDescendant(of ancestor: SyncPath) -> Bool {
        isEqualOrDescendant(of: ancestor)
    }

    public static func < (lhs: SyncPath, rhs: SyncPath) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let parts = withLeadingSlash
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    private func comparableComponents(caseSensitive: Bool) -> [String] {
        components.map { component in
            let normalized = component.precomposedStringWithCanonicalMapping
            guard !caseSensitive else { return normalized }
            return normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
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
    case strong
    case weak
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
            return contentHash == otherHash ? .strong : .different
        }
        if contentHash != nil {
            if let size, let otherSize = other.size, size != otherSize {
                return .different
            }
            return .unknown
        }
        if other.contentHash != nil {
            if let size, let otherSize = other.size, size != otherSize {
                return .different
            }
            if let size,
               let modifiedAt,
               let otherSize = other.size,
               let otherModifiedAt = other.modifiedAt,
               size == otherSize,
               modifiedAt == otherModifiedAt {
                return .weak
            }
            return .unknown
        }
        if let revisionHash = sha256RevisionHash,
           let otherRevisionHash = other.sha256RevisionHash {
            return revisionHash == otherRevisionHash ? .strong : .different
        }
        if let revisionToken, let otherRevisionToken = other.revisionToken {
            let matches = revisionToken == otherRevisionToken
            return matches ? .weak : .different
        }
        if let size, let modifiedAt, let otherSize = other.size, let otherModifiedAt = other.modifiedAt {
            return size == otherSize && modifiedAt == otherModifiedAt ? .weak : .different
        }
        if let size, let otherSize = other.size, size != otherSize {
            return .different
        }
        return .unknown
    }

    public func itemChanged(vs base: ItemVersion) -> Bool {
        switch comparison(to: base) {
        case .strong, .weak:
            return false
        case .different, .unknown:
            return true
        }
    }

    public func isSameVersion(as other: ItemVersion) -> Bool {
        comparison(to: other) == .strong
    }

    public var hasStrongEvidence: Bool {
        contentHash != nil || sha256RevisionHash != nil
    }

    public var sha256RevisionHash: String? {
        guard let revisionToken,
              revisionToken.hasPrefix("sha256-") else {
            return nil
        }
        let digest = revisionToken.dropFirst("sha256-".count)
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }) else {
            return nil
        }
        return "sha256-" + digest.lowercased()
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

    /// Whether the complete scan that produced this location's base memory
    /// carried the same exact opaque subtree-root set. An unchanged set cannot
    /// explain a later absence: the record and every current root were already
    /// positively accounted for together in that earlier scan.
    public func matchesSubtreeExclusionBaseline(
        _ exclusions: [ScanExclusion],
        at location: LocationID
    ) -> Bool {
        guard let digest = perLocation[location]?
            .subtreeExclusionBaselineDigest else {
            return false
        }
        return digest == ScanExclusion.subtreeBaselineDigest(exclusions)
    }
}

public struct LocationMemory: Codable, Hashable, Sendable {
    public var itemID: String?
    public var revisionToken: String?
    public var lastSeenAt: Date?
    /// Digest of the exact subtree-root set positively excluded in the same
    /// complete scan as `lastSeenAt`. `nil` means legacy/unknown evidence.
    public var subtreeExclusionBaselineDigest: String?

    public init(
        itemID: String? = nil,
        revisionToken: String? = nil,
        lastSeenAt: Date? = nil,
        subtreeExclusionBaselineDigest: String? = nil
    ) {
        self.itemID = itemID
        self.revisionToken = revisionToken
        self.lastSeenAt = lastSeenAt
        self.subtreeExclusionBaselineDigest = subtreeExclusionBaselineDigest
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
    public var exclusions: [ScanExclusion]

    public init(
        location: LocationID,
        scope: SyncScope,
        observations: [ItemObservation],
        exclusions: [ScanExclusion] = [],
        status: ScanStatus = .complete,
        scannedAt: Date = Date()
    ) {
        self.location = location
        self.scope = scope
        self.status = status
        self.scannedAt = scannedAt
        self.observations = ObservationIndex(observations)
        self.exclusions = ScanExclusion.normalized(exclusions)
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
        path.isEqualOrDescendant(of: "/.aetherloom")
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
