import Foundation

public protocol CloudProvider: Sendable {
    var id: LocationID { get }
    var displayName: String { get }

    func authenticateIfNeeded() async throws
    func validateScope(_ scope: SyncScope) async throws -> ProviderScopeStatus

    func listItems(in scope: SyncScope) async throws -> [ItemObservation]
    func listChanges(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangePage

    func download(_ item: ItemObservation, to localURL: URL) async throws
    func upload(localURL: URL, to remotePath: SyncPath, options: UploadOptions) async throws -> ItemObservation

    func createFolder(path: SyncPath) async throws -> ItemObservation
    func move(item: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation
    func rename(item: ItemObservation, to newName: String) async throws -> ItemObservation

    /// Must move to trash/recycle bin where supported.
    /// Must not permanently delete in normal operation.
    func trash(item: ItemObservation) async throws

    func metadata(for item: ItemObservation) async throws -> ItemObservation
}

public enum ProviderError: Error, Equatable, Sendable {
    case authenticationFailed(provider: LocationID, reason: String)
    case unavailable(provider: LocationID, reason: String)
    case incompleteScan(provider: LocationID, reason: String)
    case itemUnavailable(provider: LocationID, path: SyncPath)
    case placeholderOnly(provider: LocationID, path: SyncPath)
    case notFound(provider: LocationID, path: SyncPath)
    case itemAlreadyExists(provider: LocationID, path: SyncPath)
    case preconditionFailed(provider: LocationID, path: SyncPath)
    case unsupported(provider: LocationID, reason: String)
}

