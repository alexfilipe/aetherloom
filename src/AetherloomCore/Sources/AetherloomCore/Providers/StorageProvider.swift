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

public struct ProviderMutationIdentity: Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: LocationID
    public var kind: ProviderMutationKind
    public var affectedPaths: [SyncPath]
    public var rootIdentity: ProviderMutationRootIdentity?

    public init(
        id: UUID,
        provider: LocationID,
        kind: ProviderMutationKind,
        affectedPaths: [SyncPath],
        rootIdentity: ProviderMutationRootIdentity? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.affectedPaths = affectedPaths
        self.rootIdentity = rootIdentity
    }
}

/// Durable physical-root evidence for local filesystem mutation recovery.
/// The canonical path admits aliases of one directory while the persistent
/// volume identity prevents a replacement volume from borrowing old authority.
public struct ProviderMutationRootIdentity: Codable, Hashable, Sendable {
    public var canonicalRootPath: String
    public var volumeIdentity: String

    public init(canonicalRootPath: String, volumeIdentity: String) {
        self.canonicalRootPath = canonicalRootPath
        self.volumeIdentity = volumeIdentity
    }
}

/// Durable engine correlation for repairing a failed indeterminate-event WAL
/// append. Shape alone is not enough: two sync sets can authorize identical
/// provider operations against one root.
public struct ProviderMutationCorrelation: Codable, Hashable, Sendable {
    public var runID: UUID
    public var operationID: OperationID

    public init(runID: UUID, operationID: OperationID) {
        self.runID = runID
        self.operationID = operationID
    }
}

enum ProviderMutationExecutionContext {
    @TaskLocal static var correlation: ProviderMutationCorrelation?
}

/// A durable identity for a provider mutation whose caller-visible deadline
/// expired after the provider had allowed blocking work to start.
///
/// Equality and hashing intentionally use `identity` only. `startedAt` is
/// timestamp evidence and canonical JSON may round it at sub-millisecond
/// precision; `correlation` proves which engine intent authorized the call but
/// does not change the provider mutation's stable identity.
public struct ProviderMutationReceipt: Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: LocationID
    public var kind: ProviderMutationKind
    public var affectedPaths: [SyncPath]
    public var startedAt: Date
    /// Optional only so legacy/unbound diagnostic receipts remain decodable.
    /// A nil value never authorizes WAL recovery or releases an I/O owner.
    public var correlation: ProviderMutationCorrelation?
    /// Local providers require this exact durable binding for recovery. It is
    /// optional only so non-local and legacy receipts remain decodable.
    public var rootIdentity: ProviderMutationRootIdentity?

    public init(
        id: UUID,
        provider: LocationID,
        kind: ProviderMutationKind,
        affectedPaths: [SyncPath],
        startedAt: Date,
        correlation: ProviderMutationCorrelation? = nil,
        rootIdentity: ProviderMutationRootIdentity? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.affectedPaths = affectedPaths
        self.startedAt = startedAt
        self.correlation = correlation
        self.rootIdentity = rootIdentity
    }

    public var identity: ProviderMutationIdentity {
        ProviderMutationIdentity(
            id: id,
            provider: provider,
            kind: kind,
            affectedPaths: affectedPaths,
            rootIdentity: rootIdentity
        )
    }

    public static func == (
        lhs: ProviderMutationReceipt,
        rhs: ProviderMutationReceipt
    ) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
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

/// An unforgeable in-process claim spanning every recovery probe, durable
/// reconciliation, and barrier release for one receipt.
public struct ProviderMutationRecoveryClaim: Hashable, Sendable {
    public var token: UUID
    public var receipt: ProviderMutationReceipt

    public init(token: UUID = UUID(), receipt: ProviderMutationReceipt) {
        self.token = token
        self.receipt = receipt
    }
}

public enum ProviderMutationRecoveryClaimResult: Hashable, Sendable {
    case inFlight
    case claimed(ProviderMutationRecoveryClaim)
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

    /// Atomically claims recovery ownership for a journaled receipt. A claim
    /// remains exclusive across every truth probe and the journal commit.
    func beginIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderMutationRecoveryClaimResult

    /// Recovery-only metadata read. The provider must keep ordinary scans,
    /// probes, and mutations blocked until `finishIndeterminateMutationRecovery`
    /// is called.
    func currentStateForRecovery(
        of observation: ItemObservation,
        claim: ProviderMutationRecoveryClaim
    ) async throws -> ItemObservation

    /// Returns true only when this provider can perform a recovery read under
    /// the exact claim's ownership domain. Local aliases use this to reconcile
    /// one WAL prefix without opening ordinary read admission; unrelated
    /// providers must never authorize another provider's claim.
    func canPerformRecoveryRead(
        with claim: ProviderMutationRecoveryClaim
    ) async -> Bool

    func finishIndeterminateMutationRecovery(
        _ claim: ProviderMutationRecoveryClaim
    ) async

    /// Releases only the recovery-session claim after a failed probe or WAL
    /// commit. The receipt barrier remains and a later recovery may retry.
    func abandonIndeterminateMutationRecovery(
        _ claim: ProviderMutationRecoveryClaim
    ) async
}

public extension IndeterminateMutationRecovering {
    func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        nil
    }

    func canPerformRecoveryRead(
        with claim: ProviderMutationRecoveryClaim
    ) async -> Bool {
        claim.receipt.provider == locationID
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
    /// Blocking work may still be running, or a completed physical mutation
    /// may lack durable recovery evidence. This is not a confirmed failure and
    /// must remain recoverable until the receipt is reconciled.
    case mutationIndeterminate(ProviderMutationReceipt)
}
