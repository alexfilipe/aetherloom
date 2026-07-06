import Foundation

public struct RunRecoveryReport: Codable, Hashable, Sendable {
    public var runID: UUID
    public var reconciledOperations: [OperationID]
    public var restoredRecords: Int

    public init(runID: UUID, reconciledOperations: [OperationID] = [], restoredRecords: Int = 0) {
        self.runID = runID
        self.reconciledOperations = reconciledOperations
        self.restoredRecords = restoredRecords
    }
}

public struct RunRecovery: Sendable {
    private let providers: [LocationID: any StorageProvider]
    private let stores: EngineStores
    private let environment: ExecutionEnvironment

    public init(
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,
        environment: ExecutionEnvironment = ExecutionEnvironment()
    ) {
        self.providers = providers
        self.stores = stores
        self.environment = environment
    }

    public func recover(_ replay: JournalReplay) async throws -> RunRecoveryReport {
        var restoredRecords = 0
        for event in replay.events {
            guard case let .itemConverged(_, record) = event else { continue }
            try await stores.baseRecords.apply(.upsert(record))
            restoredRecords += 1
        }

        let pendingOperations = replay.events.compactMap { event -> Operation? in
            guard case let .intent(operation) = event, replay.pendingOperationIDs.contains(operation.id) else {
                return nil
            }
            return operation
        }

        var reconciled: [OperationID] = []
        for operation in pendingOperations.sorted(by: { $0.id < $1.id }) {
            if let record = try await confirmedRecord(for: operation, syncSetID: replay.syncSetID) {
                try await stores.baseRecords.apply(.upsert(record))
                restoredRecords += 1
                reconciled.append(operation.id)
            }
        }

        await stores.activity.append(
            ActivityEntry(
                occurredAt: environment.now(),
                syncSetID: replay.syncSetID,
                runID: replay.runID,
                category: .safety,
                message: ActivityMessageCatalog.recoveryPerformed,
                detail: "\(reconciled.count) operations reconciled."
            )
        )
        try await stores.journal.markReconciled(runID: replay.runID)
        return RunRecoveryReport(runID: replay.runID, reconciledOperations: reconciled, restoredRecords: restoredRecords)
    }

    private func confirmedRecord(for operation: Operation, syncSetID: UUID) async throws -> BaseRecord? {
        guard let provider = providers[operation.location] else { return nil }
        let now = environment.now()

        switch operation.kind {
        case let .makeFolder(path):
            let current = try? await provider.currentState(of: ItemObservation(location: operation.location, path: path, kind: .folder))
            guard let current, current.isFolder, !current.isTrashed else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [operation.location: LocationMemory(itemID: current.itemID, revisionToken: current.version.revisionToken, lastSeenAt: now)],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .transfer(content, path, _):
            let current = try? await provider.currentState(of: ItemObservation(location: operation.location, path: path, kind: content.kind))
            guard let current, matchingRecoveredContent(current.version, content.expectedVersion) else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [
                    content.sourceLocation: LocationMemory(
                        itemID: content.itemID,
                        revisionToken: content.expectedVersion.revisionToken,
                        lastSeenAt: now
                    ),
                    operation.location: LocationMemory(
                        itemID: current.itemID,
                        revisionToken: current.version.revisionToken,
                        lastSeenAt: now
                    )
                ],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .relocate(itemRef, newPath):
            let current = try? await provider.currentState(of: itemRef.observation)
            guard let current, current.path == newPath, !current.isTrashed else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: current.path,
                kind: current.kind,
                version: current.version,
                perLocation: [operation.location: LocationMemory(itemID: current.itemID, revisionToken: current.version.revisionToken, lastSeenAt: now)],
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )

        case let .trash(itemRef):
            let current = try? await provider.currentState(of: itemRef.observation)
            guard current?.isTrashed == true else { return nil }
            return BaseRecord(
                id: environment.makeID(),
                syncSetID: syncSetID,
                path: itemRef.path,
                kind: itemRef.kind,
                version: itemRef.expectedVersion,
                perLocation: [operation.location: LocationMemory(itemID: itemRef.itemID, revisionToken: itemRef.expectedVersion.revisionToken, lastSeenAt: now)],
                tombstone: Tombstone(deletedAt: now),
                lastConvergedAt: now,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}

private func matchingRecoveredContent(_ lhs: ItemVersion, _ rhs: ItemVersion) -> Bool {
    if lhs.isSameVersion(as: rhs) {
        return true
    }
    if let lhsSize = lhs.size, let rhsSize = rhs.size, lhsSize == rhsSize, rhs.contentHash == nil {
        return true
    }
    return false
}
