import Foundation

public struct AdviceCacheKey: Codable, Hashable, Sendable {
    public var conflictID: UUID
    public var signatures: [ConflictVersionSignature]
    public var advisor: AdvisorDescriptor

    public init(conflict: ConflictDecision, advisor: AdvisorDescriptor) {
        self.conflictID = conflict.id
        self.signatures = conflict.versions.map(ConflictVersionSignature.init).sorted()
        self.advisor = advisor
    }

    public var rawValue: String {
        let data = (try? CanonicalCoding.encoder().encode(self)) ?? Data()
        return CanonicalCoding.sha256Hex(data)
    }
}

public struct ConflictVersionSignature: Codable, Hashable, Sendable, Comparable {
    public var location: LocationID
    public var itemID: String?
    public var path: SyncPath
    public var kind: ItemKind
    public var contentHash: String?
    public var size: Int64?
    public var modifiedAt: Date?
    public var revisionToken: String?
    public var isPlaceholder: Bool
    public var isTrashed: Bool

    public init(_ version: ConflictVersion) {
        let observation = version.observation
        self.location = version.location
        self.itemID = observation.itemID
        self.path = observation.path
        self.kind = observation.kind
        self.contentHash = observation.version.contentHash
        self.size = observation.version.size
        self.modifiedAt = observation.version.modifiedAt
        self.revisionToken = observation.version.revisionToken
        self.isPlaceholder = observation.isPlaceholder
        self.isTrashed = observation.isTrashed
    }

    public static func < (lhs: ConflictVersionSignature, rhs: ConflictVersionSignature) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return (lhs.itemID ?? "") < (rhs.itemID ?? "")
    }
}
