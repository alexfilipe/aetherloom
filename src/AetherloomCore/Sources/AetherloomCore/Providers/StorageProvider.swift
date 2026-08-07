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

/// A durable identity for a provider mutation whose caller-visible deadline
/// expired after the provider had allowed blocking work to start.
public struct ProviderMutationReceipt: Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: LocationID
    public var kind: ProviderMutationKind
    public var affectedPaths: [SyncPath]
    public var startedAt: Date

    public init(
        id: UUID,
        provider: LocationID,
        kind: ProviderMutationKind,
        affectedPaths: [SyncPath],
        startedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.affectedPaths = affectedPaths
        self.startedAt = startedAt
    }
}

public enum ProviderMutationKind: String, Codable, Hashable, Sendable {
    case fetch
    case makeFolder
    case store
    case relocate
    case trash
}

public enum ProviderLateMutationOutcome: Codable, Hashable, Sendable {
    case succeeded
    case failed(detail: String)
}

public enum ProviderIndeterminateMutationState: Codable, Hashable, Sendable {
    case inFlight
    case quiescent(ProviderLateMutationOutcome)
    /// The process restarted after the journal persisted the receipt. The old
    /// blocking call no longer exists, so recovery must establish truth from
    /// the provider rather than trusting a missing in-memory result.
    case unknownAfterRestart
}

/// Optional refinement for providers that can retain blocking mutations past a
/// caller deadline. Recovery uses this seam only for a journaled indeterminate
/// mutation; normal planning continues to use `StorageProvider`.
public protocol IndeterminateMutationRecovering: StorageProvider {
    /// Returns the in-process receipt whose post-deadline result still needs
    /// reconciliation. This repairs the narrow case where the provider kept
    /// ownership but the journal's indeterminate-event append failed.
    func indeterminateMutationReceipt() async -> ProviderMutationReceipt?

    func indeterminateMutationState(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState

    /// Recovery-only metadata read. The provider must keep ordinary scans,
    /// probes, and mutations blocked until `finishIndeterminateMutationRecovery`
    /// is called.
    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt: ProviderMutationReceipt
    ) async throws -> ItemObservation

    func finishIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async
}

public extension IndeterminateMutationRecovering {
    func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        nil
    }
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
    /// The mutation never received permission to start, so no side effect is
    /// possible from this attempt.
    case mutationDeadlineExpiredBeforeStart(provider: LocationID, path: SyncPath)
    /// Blocking work may still be running. This is not a confirmed failure and
    /// must remain recoverable until the receipt is reconciled.
    case mutationIndeterminate(ProviderMutationReceipt)
}
