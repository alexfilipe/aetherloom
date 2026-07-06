import Foundation

public enum SyncExecutionError: Error, Equatable, Sendable {
    case missingProvider(LocationID)
    case planPaused(reason: String)
    case planNeedsReview
    case destinationChangedRequiresReplan(provider: LocationID, path: SyncPath)
}

public struct SyncExecutionReport: Codable, Hashable, Sendable {
    public var appliedActions: [SyncAction]
    public var skippedActions: [SyncAction]

    public init(appliedActions: [SyncAction] = [], skippedActions: [SyncAction] = []) {
        self.appliedActions = appliedActions
        self.skippedActions = skippedActions
    }
}

public actor SyncPlanExecutor {
    private let providers: [LocationID: any StorageProvider]
    private let fileManager: FileManager

    public init(providers: [LocationID: any StorageProvider], fileManager: FileManager = .default) {
        self.providers = providers
        self.fileManager = fileManager
    }

    public func execute(_ plan: SyncPlan) async throws -> SyncExecutionReport {
        if let pauseReason = plan.actions.compactMap(\.pauseReason).first {
            throw SyncExecutionError.planPaused(reason: pauseReason)
        }
        guard plan.riskLevel == .safe, plan.isAutoExecutable else {
            throw SyncExecutionError.planNeedsReview
        }

        var report = SyncExecutionReport()
        for action in plan.actions {
            let didApply = try await apply(action)
            if didApply {
                report.appliedActions.append(action)
            } else {
                report.skippedActions.append(action)
            }
        }
        return report
    }

    private func apply(_ action: SyncAction) async throws -> Bool {
        switch action {
        case let .upload(source, destination, sourceItem, destinationPath):
            return try await upload(
                source: source,
                destination: destination,
                sourceItem: sourceItem,
                destinationPath: destinationPath,
                allowOverwrite: false,
                expectedDestinationVersion: nil
            )

        case let .overwrite(source, destination, sourceItem, destinationItem):
            let destinationProvider = try provider(destination)
            let currentDestination = try await destinationProvider.currentState(of: destinationItem)
            if matchingContent(currentDestination, sourceItem) {
                return false
            }
            guard matchingObservationVersion(currentDestination, destinationItem) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: destinationItem.path)
            }
            return try await upload(
                source: source,
                destination: destination,
                sourceItem: sourceItem,
                destinationPath: destinationItem.path,
                allowOverwrite: true,
                expectedDestinationVersion: destinationItem.version
            )

        case let .createFolder(destination, path):
            let destinationProvider = try provider(destination)
            do {
                let existing = try await destinationProvider.currentState(
                    of: ItemObservation(location: destination, path: path, kind: .folder)
                )
                if existing.isFolder && !existing.isTrashed {
                    return false
                }
            } catch ProviderError.notFound {
                // Missing is the normal create-folder path.
            }
            _ = try await destinationProvider.makeFolder(at: path)
            return true

        case let .move(destination, item, newPath):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.currentState(of: item)
            if current.path == newPath {
                return false
            }
            guard matchingObservationVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            _ = try await destinationProvider.relocate(current, to: newPath)
            return true

        case let .rename(destination, item, newName):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.currentState(of: item)
            let newPath = current.path.replacingLastComponent(with: newName)
            if current.path == newPath {
                return false
            }
            guard matchingObservationVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            _ = try await destinationProvider.relocate(current, to: newPath)
            return true

        case let .trash(destination, item):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.currentState(of: item)
            if current.isTrashed {
                return false
            }
            guard matchingObservationVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            try await destinationProvider.trash(current)
            return true

        case let .createConflictCopy(source, destination, sourceItem, conflictPath):
            return try await upload(
                source: source,
                destination: destination,
                sourceItem: sourceItem,
                destinationPath: conflictPath,
                allowOverwrite: false,
                expectedDestinationVersion: nil
            )

        case .pause:
            return false
        }
    }

    private func upload(
        source: LocationID,
        destination: LocationID,
        sourceItem: ItemObservation,
        destinationPath: SyncPath,
        allowOverwrite: Bool,
        expectedDestinationVersion: ItemVersion?
    ) async throws -> Bool {
        let sourceProvider = try provider(source)
        let destinationProvider = try provider(destination)

        do {
            let existing = try await destinationProvider.currentState(
                of: ItemObservation(location: destination, path: destinationPath, kind: .file)
            )
            if matchingContent(existing, sourceItem) {
                return false
            }
            if !allowOverwrite {
                throw ProviderError.itemAlreadyExists(provider: destination, path: destinationPath)
            }
        } catch ProviderError.notFound {
            // Missing is the normal upload path.
        }

        let tempURL = temporaryURL(for: sourceItem)
        defer { try? fileManager.removeItem(at: tempURL) }

        try await sourceProvider.fetch(sourceItem, to: tempURL)
        do {
            _ = try await destinationProvider.store(
                from: tempURL,
                at: destinationPath,
                options: storeOptions(
                    allowOverwrite: allowOverwrite,
                    expectedDestinationVersion: expectedDestinationVersion
                )
            )
            return true
        } catch ProviderError.itemAlreadyExists {
            let existing = try await destinationProvider.currentState(
                of: ItemObservation(location: destination, path: destinationPath, kind: .file)
            )
            if matchingContent(existing, sourceItem) {
                return false
            }
            throw ProviderError.itemAlreadyExists(provider: destination, path: destinationPath)
        }
    }

    private func provider(_ id: LocationID) throws -> any StorageProvider {
        guard let provider = providers[id] else {
            throw SyncExecutionError.missingProvider(id)
        }
        return provider
    }

    private func temporaryURL(for item: ItemObservation) -> URL {
        let filename = item.itemID?
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            ?? UUID().uuidString
        return fileManager.temporaryDirectory
            .appendingPathComponent("AetherloomCore", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func matchingObservationVersion(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        if lhs.itemID != nil && rhs.itemID != nil && lhs.itemID != rhs.itemID {
            return false
        }
        return lhs.version.isSameVersion(as: rhs.version)
    }

    private func matchingContent(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.isFolder { return true }
        return lhs.version.isSameVersion(as: rhs.version)
    }

    private func storeOptions(
        allowOverwrite: Bool,
        expectedDestinationVersion: ItemVersion?
    ) -> StoreOptions {
        guard allowOverwrite else {
            return StoreOptions(overwrite: .neverOverwrite)
        }
        return StoreOptions(overwrite: .ifVersionMatches(expectedDestinationVersion ?? ItemVersion()))
    }
}

extension SyncAction {
    public var pauseReason: String? {
        if case let .pause(reason) = self {
            return reason
        }
        return nil
    }
}
