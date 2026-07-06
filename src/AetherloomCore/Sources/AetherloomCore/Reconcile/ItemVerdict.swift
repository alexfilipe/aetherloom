import Foundation

public enum WaitingReason: String, Codable, Hashable, Sendable {
    case contentNotMaterialized
}

public enum ConflictKind: String, Codable, Hashable, Sendable {
    case editEdit
    case editDelete
    case createCreate
    case moveMove
    case caseCollision
    case typeClash
}

public struct ConflictVersion: Codable, Hashable, Sendable {
    public var location: LocationID
    public var observation: ItemObservation

    public init(location: LocationID, observation: ItemObservation) {
        self.location = location
        self.observation = observation
    }
}

public struct ConflictDecision: Codable, Hashable, Sendable, Identifiable {
    public enum Resolution: String, Codable, Hashable, Sendable {
        case preserveAll
    }

    public var id: UUID
    public var kind: ConflictKind
    public var path: SyncPath
    public var versions: [ConflictVersion]
    public var defaultResolution: Resolution
    public var message: String

    public init(
        id: UUID = UUID(),
        kind: ConflictKind = .editEdit,
        path: SyncPath,
        versions: [ConflictVersion] = [],
        defaultResolution: Resolution = .preserveAll,
        message: String
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.versions = versions
        self.defaultResolution = defaultResolution
        self.message = message
    }

    public var locations: [LocationID] {
        versions.map(\.location).sorted()
    }

    public var items: [ItemObservation] {
        versions.map(\.observation)
    }
}

public typealias SyncConflict = ConflictDecision

public enum ItemVerdict: Hashable, Sendable {
    case inSync
    case propagateContent(from: LocationID, to: Set<LocationID>)
    case propagateCreation(from: LocationID, to: Set<LocationID>)
    case propagatePath(to: Set<LocationID>, newPath: SyncPath)
    case propagateDeletion(to: Set<LocationID>, initiatedBy: LocationID)
    case conflict(ConflictDecision)
    case waiting(WaitingReason, locations: Set<LocationID>)
    case compound([ItemVerdict])
}

public struct ReconciledItem: Hashable, Sendable {
    public var item: ReconciliationItem
    public var verdict: ItemVerdict

    public init(item: ReconciliationItem, verdict: ItemVerdict) {
        self.item = item
        self.verdict = verdict
    }
}
