import Foundation

public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var occurredAt: Date
    public var syncSetID: UUID?
    public var runID: UUID?
    public var category: ActivityCategory
    public var locationID: LocationID?
    public var path: SyncPath?
    public var message: String
    public var detail: String?
    public var relatedConflictID: UUID?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        syncSetID: UUID? = nil,
        runID: UUID? = nil,
        category: ActivityCategory,
        locationID: LocationID? = nil,
        path: SyncPath? = nil,
        message: String,
        detail: String? = nil,
        relatedConflictID: UUID? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.syncSetID = syncSetID
        self.runID = runID
        self.category = category
        self.locationID = locationID
        self.path = path
        self.message = message
        self.detail = detail
        self.relatedConflictID = relatedConflictID
    }
}

public enum ActivityCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case sync
    case safety
    case conflict
    case advisory
    case provider
    case error
}

public struct ActivityQuery: Codable, Hashable, Sendable {
    public var syncSetID: UUID?
    public var runID: UUID?
    public var categories: Set<ActivityCategory>?
    public var pathPrefix: SyncPath?
    public var dateRange: ClosedRange<Date>?
    public var limit: Int

    public init(
        syncSetID: UUID? = nil,
        runID: UUID? = nil,
        categories: Set<ActivityCategory>? = nil,
        pathPrefix: SyncPath? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int = 100
    ) {
        self.syncSetID = syncSetID
        self.runID = runID
        self.categories = categories
        self.pathPrefix = pathPrefix
        self.dateRange = dateRange
        self.limit = limit
    }
}

public struct ActivityRetentionPolicy: Codable, Hashable, Sendable {
    public var syncDays: Int
    public var providerDays: Int
    public var advisoryDays: Int
    public var safetyDays: Int
    public var conflictDays: Int
    public var errorDays: Int

    public init(
        syncDays: Int = 90,
        providerDays: Int = 90,
        advisoryDays: Int = 90,
        safetyDays: Int = 365,
        conflictDays: Int = 365,
        errorDays: Int = 365
    ) {
        self.syncDays = syncDays
        self.providerDays = providerDays
        self.advisoryDays = advisoryDays
        self.safetyDays = safetyDays
        self.conflictDays = conflictDays
        self.errorDays = errorDays
    }

    public static let `default` = ActivityRetentionPolicy()

    public func daysToKeep(_ category: ActivityCategory) -> Int {
        switch category {
        case .sync:
            return syncDays
        case .provider:
            return providerDays
        case .advisory:
            return advisoryDays
        case .safety:
            return safetyDays
        case .conflict:
            return conflictDays
        case .error:
            return errorDays
        }
    }

    public func cutoffDate(for category: ActivityCategory, now: Date) -> Date {
        now.addingTimeInterval(-Double(daysToKeep(category)) * 24 * 60 * 60)
    }
}

public struct ActivityMessageCatalog: Sendable {
    public init() {}

    public static let providerUnavailable = "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable."
    public static let scanIncomplete = "Sync paused because this provider returned an incomplete scan. No files will be deleted from an incomplete scan."
    public static let baseStateUnreadable = "Sync paused because the base state is unreadable. No files will be deleted while sync memory is unreadable."
    public static let manyDeletions = "Aetherloom found many deletions. This may be intentional, but sync is paused until you review it."
    public static let manyEdits = "Aetherloom found many edits. This may be intentional, but sync is paused until you review it."
    public static let deletionsNeedReview = "Aetherloom found deletions. Review before moving matching files to trash."
    public static let conflictPreserved = "This file changed in more than one place. Aetherloom preserved both versions."
    public static let approvalAccepted = "Plan approval accepted. Aetherloom will apply the reviewed changes."
    public static let adviceShown = "Aetherloom showed conflict advice."
    public static let adviceUnavailable = "Aetherloom could not generate advice."
    public static let holdTriageShown = "Aetherloom summarized why this hold needs review."
    public static let recoveryPerformed = "Aetherloom checked an unfinished sync run and preserved the safest state."
    public static let stoppedForReplan = "Sync stopped because a file changed after planning. Preview changes again before continuing."
    public static let verificationFailed = "Sync could not verify a completed write."
    public static let runFinished = "Sync finished."

    public static func runStarted(locationCount: Int) -> String {
        "Sync started for \(locationCount) locations."
    }

    public static func stageStarted(_ name: String) -> String {
        "\(name) started."
    }

    public static func stageFinished(_ name: String) -> String {
        "\(name) finished."
    }

    public static func approvalAccepted(trashCount: Int, syncSetName: String) -> String {
        "You approved \(trashCount) items to move to trash for '\(syncSetName)'."
    }

    public static func preparationSummary(
        additions: Int,
        updates: Int,
        moves: Int,
        trash: Int,
        conflicts: Int,
        waiting: Int,
        gate: ExecutionGate
    ) -> String {
        let gateText = gate.isClear ? "clear" : "needs review"
        return "Prepared \(additions) additions, \(updates) updates, \(moves) moves, \(trash) trash moves, \(conflicts) conflicts, and \(waiting) waiting items; gate is \(gateText)."
    }

    public static func adviceShown(recommendation: ConflictResolutionOption, locationName: String? = nil) -> String {
        switch recommendation {
        case .keepBoth:
            return "Aetherloom suggested keeping both versions. Both versions remain preserved."
        case .makeCanonical:
            let name = locationName ?? "the selected location"
            return "Aetherloom suggested keeping the version from \(name). Both versions remain preserved."
        }
    }

    public static func adviceFailure(reason: AdviceValidationRejection) -> String {
        "\(Self.adviceUnavailable) Reason: \(reason.rawValue)."
    }

    public func message(for operation: Operation) -> String {
        switch operation.kind {
        case let .makeFolder(path):
            return Self.createdFolder(path: path, destination: operation.location)

        case let .transfer(content, path, overwrite):
            switch overwrite {
            case .neverOverwrite:
                if path != content.path {
                    return Self.createdConflictCopy(path: path, destination: operation.location, source: content.sourceLocation)
                }
                return Self.created(path: path, destination: operation.location, source: content.sourceLocation)
            case .ifVersionMatches:
                return Self.updated(path: path, destination: operation.location, source: content.sourceLocation)
            }

        case let .relocate(itemRef, newPath):
            if itemRef.path.parent == newPath.parent {
                return Self.renamed(from: itemRef.path, to: newPath, destination: operation.location)
            }
            return Self.moved(path: newPath, destination: operation.location)

        case let .trash(itemRef):
            return Self.movedToTrash(path: itemRef.path, destination: operation.location)
        }
    }

    public func entry(
        for operation: Operation,
        syncSetID: UUID? = nil,
        runID: UUID? = nil,
        occurredAt: Date = Date()
    ) -> ActivityEntry {
        ActivityEntry(
            occurredAt: occurredAt,
            syncSetID: syncSetID,
            runID: runID,
            category: .sync,
            locationID: operation.location,
            path: operation.activityPath,
            message: message(for: operation)
        )
    }

    public static func created(path: SyncPath, destination: LocationID, source: LocationID) -> String {
        "Created \"\(path.rawValue)\" in \(destination.displayName) from \(source.displayName)."
    }

    public static func updated(path: SyncPath, destination: LocationID, source: LocationID) -> String {
        "Updated \"\(path.rawValue)\" in \(destination.displayName) from \(source.displayName)."
    }

    public static func createdFolder(path: SyncPath, destination: LocationID) -> String {
        "Created folder \"\(path.rawValue)\" in \(destination.displayName)."
    }

    public static func moved(path: SyncPath, destination: LocationID) -> String {
        "Moved \"\(path.rawValue)\" in \(destination.displayName)."
    }

    public static func renamed(from oldPath: SyncPath, to newPath: SyncPath, destination: LocationID) -> String {
        "Renamed \"\(oldPath.rawValue)\" to \"\(newPath.rawValue)\" in \(destination.displayName)."
    }

    public static func movedToTrash(path: SyncPath, destination: LocationID) -> String {
        "Moved \"\(path.rawValue)\" to \(destination.displayName) trash."
    }

    public static func createdConflictCopy(path: SyncPath, destination: LocationID, source: LocationID) -> String {
        "Created conflict copy \"\(path.rawValue)\" in \(destination.displayName) from \(source.displayName)."
    }
}

private extension Operation {
    var activityPath: SyncPath? {
        switch kind {
        case let .makeFolder(path):
            return path
        case let .transfer(_, path, _):
            return path
        case let .relocate(_, path):
            return path
        case let .trash(itemRef):
            return itemRef.path
        }
    }
}
