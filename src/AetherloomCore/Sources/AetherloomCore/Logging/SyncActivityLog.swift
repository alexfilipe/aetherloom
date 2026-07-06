import Foundation

public struct SyncActivityLogEntry: Codable, Hashable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var location: LocationID?
    public var path: SyncPath?
    public var message: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        location: LocationID? = nil,
        path: SyncPath? = nil,
        message: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.location = location
        self.path = path
        self.message = message
    }
}

public struct SyncActivityLogFormatter: Sendable {
    public init() {}

    public func entry(for action: SyncAction, occurredAt: Date = Date()) -> SyncActivityLogEntry {
        switch action {
        case let .upload(source, destination, _, destinationPath):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: destinationPath,
                message: "Created \"\(destinationPath.rawValue)\" in \(destination.displayName) from \(source.displayName)."
            )

        case let .overwrite(source, destination, _, destinationItem):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: destinationItem.path,
                message: "Updated \"\(destinationItem.path.rawValue)\" in \(destination.displayName) from \(source.displayName)."
            )

        case let .createFolder(destination, path):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: path,
                message: "Created folder \"\(path.rawValue)\" in \(destination.displayName)."
            )

        case let .move(destination, _, newPath):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: newPath,
                message: "Moved \"\(newPath.rawValue)\" in \(destination.displayName)."
            )

        case let .rename(destination, item, newName):
            let newPath = item.path.replacingLastComponent(with: newName)
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: newPath,
                message: "Renamed \"\(item.path.rawValue)\" to \"\(newPath.rawValue)\" in \(destination.displayName)."
            )

        case let .trash(destination, item):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: item.path,
                message: "Moved \"\(item.path.rawValue)\" to \(destination.displayName) trash."
            )

        case let .createConflictCopy(source, destination, _, conflictPath):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                location: destination,
                path: conflictPath,
                message: "Created conflict copy \"\(conflictPath.rawValue)\" in \(destination.displayName) from \(source.displayName)."
            )

        case let .pause(reason):
            return SyncActivityLogEntry(
                occurredAt: occurredAt,
                message: reason
            )
        }
    }
}
