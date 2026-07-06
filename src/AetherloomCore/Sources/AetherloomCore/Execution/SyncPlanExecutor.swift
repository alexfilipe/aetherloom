import Foundation

public enum SyncExecutionError: Error, Equatable, Sendable {
    case missingProvider(ProviderID)
    case planPaused(reason: String)
    case planNeedsReview
    case destinationChangedRequiresReplan(provider: ProviderID, path: CloudPath)
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
    private let providers: [ProviderID: any CloudProvider]
    private let fileManager: FileManager

    public init(providers: [ProviderID: any CloudProvider], fileManager: FileManager = .default) {
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
                expectedDestinationRevisionID: nil
            )

        case let .overwrite(source, destination, sourceItem, destinationItem):
            let destinationProvider = try provider(destination)
            let currentDestination = try await destinationProvider.metadata(for: destinationItem)
            if sameContent(currentDestination, sourceItem) {
                return false
            }
            guard sameVersion(currentDestination, destinationItem) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: destinationItem.path)
            }
            return try await upload(
                source: source,
                destination: destination,
                sourceItem: sourceItem,
                destinationPath: destinationItem.path,
                allowOverwrite: true,
                expectedDestinationRevisionID: destinationRevisionToken(destinationItem)
            )

        case let .createFolder(destination, path):
            let destinationProvider = try provider(destination)
            do {
                let existing = try await destinationProvider.metadata(
                    for: CloudItem(provider: destination, path: path, isFolder: true)
                )
                if existing.isFolder && !existing.isTrashed {
                    return false
                }
            } catch ProviderError.notFound {
                // Missing is the normal create-folder path.
            }
            _ = try await destinationProvider.createFolder(path: path)
            return true

        case let .move(destination, item, newPath):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.metadata(for: item)
            if current.path == newPath {
                return false
            }
            guard sameVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            _ = try await destinationProvider.move(item: current, to: newPath)
            return true

        case let .rename(destination, item, newName):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.metadata(for: item)
            let newPath = current.path.replacingLastComponent(with: newName)
            if current.path == newPath {
                return false
            }
            guard sameVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            _ = try await destinationProvider.rename(item: current, to: newName)
            return true

        case let .trash(destination, item):
            let destinationProvider = try provider(destination)
            let current = try await destinationProvider.metadata(for: item)
            if current.isTrashed {
                return false
            }
            guard sameVersion(current, item) else {
                throw SyncExecutionError.destinationChangedRequiresReplan(provider: destination, path: item.path)
            }
            try await destinationProvider.trash(item: current)
            return true

        case let .createConflictCopy(source, destination, sourceItem, conflictPath):
            return try await upload(
                source: source,
                destination: destination,
                sourceItem: sourceItem,
                destinationPath: conflictPath,
                allowOverwrite: false,
                expectedDestinationRevisionID: nil
            )

        case .pause:
            return false
        }
    }

    private func upload(
        source: ProviderID,
        destination: ProviderID,
        sourceItem: CloudItem,
        destinationPath: CloudPath,
        allowOverwrite: Bool,
        expectedDestinationRevisionID: String?
    ) async throws -> Bool {
        let sourceProvider = try provider(source)
        let destinationProvider = try provider(destination)

        do {
            let existing = try await destinationProvider.metadata(
                for: CloudItem(provider: destination, path: destinationPath, isFolder: false)
            )
            if sameContent(existing, sourceItem) {
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

        try await sourceProvider.download(sourceItem, to: tempURL)
        do {
            _ = try await destinationProvider.upload(
                localURL: tempURL,
                to: destinationPath,
                options: UploadOptions(
                    allowOverwrite: allowOverwrite,
                    expectedDestinationRevisionID: expectedDestinationRevisionID
                )
            )
            return true
        } catch ProviderError.itemAlreadyExists {
            let existing = try await destinationProvider.metadata(
                for: CloudItem(provider: destination, path: destinationPath, isFolder: false)
            )
            if sameContent(existing, sourceItem) {
                return false
            }
            throw ProviderError.itemAlreadyExists(provider: destination, path: destinationPath)
        }
    }

    private func provider(_ id: ProviderID) throws -> any CloudProvider {
        guard let provider = providers[id] else {
            throw SyncExecutionError.missingProvider(id)
        }
        return provider
    }

    private func temporaryURL(for item: CloudItem) -> URL {
        let filename = item.providerItemID?
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            ?? UUID().uuidString
        return fileManager.temporaryDirectory
            .appendingPathComponent("AetherloomCore", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func sameVersion(_ lhs: CloudItem, _ rhs: CloudItem) -> Bool {
        if lhs.providerItemID != nil && rhs.providerItemID != nil && lhs.providerItemID != rhs.providerItemID {
            return false
        }
        if let lhsHash = lhs.contentHash, let rhsHash = rhs.contentHash {
            return lhsHash == rhsHash
        }
        if let lhsToken = destinationRevisionToken(lhs), let rhsToken = destinationRevisionToken(rhs) {
            return lhsToken == rhsToken
        }
        return lhs.size == rhs.size && lhs.modifiedAt == rhs.modifiedAt
    }

    private func sameContent(_ lhs: CloudItem, _ rhs: CloudItem) -> Bool {
        guard lhs.isFolder == rhs.isFolder else { return false }
        if lhs.isFolder { return true }
        if let lhsHash = lhs.contentHash, let rhsHash = rhs.contentHash {
            return lhsHash == rhsHash
        }
        return lhs.size == rhs.size && lhs.modifiedAt == rhs.modifiedAt
    }

    private func destinationRevisionToken(_ item: CloudItem) -> String? {
        item.revisionID ?? item.eTag ?? item.cTag
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
