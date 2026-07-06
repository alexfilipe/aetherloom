import Foundation

public protocol StorageProvider: Sendable {
    var locationID: LocationID { get }
    var capabilities: ProviderCapabilities { get }

    func checkAvailability() async -> LocationAvailability
    func scan(_ scope: SyncScope) async -> LocationSnapshot
    func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint

    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws
    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation

    func makeFolder(at path: SyncPath) async throws -> ItemObservation
    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation
    func trash(_ observation: ItemObservation) async throws
    func currentState(of observation: ItemObservation) async throws -> ItemObservation
}

public enum LocationAvailability: Codable, Hashable, Sendable {
    case available
    case unavailable(LocationUnavailabilityReason)
}

public enum LocationUnavailabilityReason: Codable, Hashable, Sendable {
    case notAuthenticated(detail: String)
    case networkUnreachable(detail: String)
    case volumeNotMounted(detail: String)
    case volumeUnreachable(detail: String)
    case scopeMissing(detail: String)
    case rateLimited(retryAfter: Date?)
    case unknown(detail: String)

    public var detail: String {
        switch self {
        case let .notAuthenticated(detail),
             let .networkUnreachable(detail),
             let .volumeNotMounted(detail),
             let .volumeUnreachable(detail),
             let .scopeMissing(detail),
             let .unknown(detail):
            return detail
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return "Rate limited until \(retryAfter)."
            }
            return "Rate limited."
        }
    }
}

public struct ProviderCapabilities: Codable, Hashable, Sendable {
    public var hasNativeTrash: Bool
    public var hasStableItemIDs: Bool
    public var hasContentHashes: Bool
    public var hasChangeHints: Bool
    public var supportsVersionCheckedStore: Bool
    public var isCaseSensitive: Bool?

    public init(
        hasNativeTrash: Bool,
        hasStableItemIDs: Bool,
        hasContentHashes: Bool,
        hasChangeHints: Bool,
        supportsVersionCheckedStore: Bool,
        isCaseSensitive: Bool?
    ) {
        self.hasNativeTrash = hasNativeTrash
        self.hasStableItemIDs = hasStableItemIDs
        self.hasContentHashes = hasContentHashes
        self.hasChangeHints = hasChangeHints
        self.supportsVersionCheckedStore = supportsVersionCheckedStore
        self.isCaseSensitive = isCaseSensitive
    }

    public static let fullFidelity = ProviderCapabilities(
        hasNativeTrash: true,
        hasStableItemIDs: true,
        hasContentHashes: true,
        hasChangeHints: true,
        supportsVersionCheckedStore: true,
        isCaseSensitive: false
    )
}

public struct StoreOptions: Codable, Hashable, Sendable {
    public var overwrite: OverwritePolicy

    public init(overwrite: OverwritePolicy = .neverOverwrite) {
        self.overwrite = overwrite
    }

    public enum OverwritePolicy: Codable, Hashable, Sendable {
        case neverOverwrite
        case ifVersionMatches(ItemVersion)
    }
}

public struct ChangeHint: Codable, Hashable, Sendable {
    public var changedRoots: [SyncPath]
    public var nextCursor: ChangeCursor?
    public var isComplete: Bool

    public init(changedRoots: [SyncPath], nextCursor: ChangeCursor? = nil, isComplete: Bool = true) {
        self.changedRoots = changedRoots
        self.nextCursor = nextCursor
        self.isComplete = isComplete
    }
}

public enum ProviderError: Error, Equatable, Sendable {
    case unavailable(provider: LocationID, reason: String)
    case itemUnavailable(provider: LocationID, path: SyncPath)
    case placeholderOnly(provider: LocationID, path: SyncPath)
    case notFound(provider: LocationID, path: SyncPath)
    case itemAlreadyExists(provider: LocationID, path: SyncPath)
    case preconditionFailed(provider: LocationID, path: SyncPath)
    case unsupported(provider: LocationID, reason: String)
}
