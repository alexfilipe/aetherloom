import Foundation

public protocol CloudProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }

    func authenticateIfNeeded() async throws
    func validateScope(_ scope: SyncScope) async throws -> ProviderScopeStatus

    func listItems(in scope: SyncScope) async throws -> [CloudItem]
    func listChanges(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangePage

    func download(_ item: CloudItem, to localURL: URL) async throws
    func upload(localURL: URL, to remotePath: CloudPath, options: UploadOptions) async throws -> CloudItem

    func createFolder(path: CloudPath) async throws -> CloudItem
    func move(item: CloudItem, to newPath: CloudPath) async throws -> CloudItem
    func rename(item: CloudItem, to newName: String) async throws -> CloudItem

    /// Must move to trash/recycle bin where supported.
    /// Must not permanently delete in normal operation.
    func trash(item: CloudItem) async throws

    func metadata(for item: CloudItem) async throws -> CloudItem
}

public enum ProviderError: Error, Equatable, Sendable {
    case authenticationFailed(provider: ProviderID, reason: String)
    case unavailable(provider: ProviderID, reason: String)
    case incompleteScan(provider: ProviderID, reason: String)
    case itemUnavailable(provider: ProviderID, path: CloudPath)
    case placeholderOnly(provider: ProviderID, path: CloudPath)
    case notFound(provider: ProviderID, path: CloudPath)
    case itemAlreadyExists(provider: ProviderID, path: CloudPath)
    case preconditionFailed(provider: ProviderID, path: CloudPath)
    case unsupported(provider: ProviderID, reason: String)
}

