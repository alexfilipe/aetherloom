import Foundation

public struct OperationID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public static func < (lhs: OperationID, rhs: OperationID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public struct ContentRef: Codable, Hashable, Sendable {
    public var sourceLocation: LocationID
    public var itemID: String?
    public var path: SyncPath
    public var kind: ItemKind
    public var expectedVersion: ItemVersion

    public init(
        sourceLocation: LocationID,
        itemID: String?,
        path: SyncPath,
        kind: ItemKind,
        expectedVersion: ItemVersion
    ) {
        self.sourceLocation = sourceLocation
        self.itemID = itemID
        self.path = path
        self.kind = kind
        self.expectedVersion = expectedVersion
    }

    public init(_ observation: ItemObservation) {
        self.init(
            sourceLocation: observation.location,
            itemID: observation.itemID,
            path: observation.path,
            kind: observation.kind,
            expectedVersion: observation.version
        )
    }

    public var observation: ItemObservation {
        ItemObservation(
            location: sourceLocation,
            itemID: itemID,
            path: path,
            kind: kind,
            version: expectedVersion
        )
    }
}

public struct ItemRef: Codable, Hashable, Sendable {
    public var location: LocationID
    public var itemID: String?
    public var path: SyncPath
    public var kind: ItemKind
    public var expectedVersion: ItemVersion

    public init(
        location: LocationID,
        itemID: String?,
        path: SyncPath,
        kind: ItemKind,
        expectedVersion: ItemVersion
    ) {
        self.location = location
        self.itemID = itemID
        self.path = path
        self.kind = kind
        self.expectedVersion = expectedVersion
    }

    public init(_ observation: ItemObservation) {
        self.init(
            location: observation.location,
            itemID: observation.itemID,
            path: observation.path,
            kind: observation.kind,
            expectedVersion: observation.version
        )
    }

    public var observation: ItemObservation {
        ItemObservation(
            location: location,
            itemID: itemID,
            path: path,
            kind: kind,
            version: expectedVersion
        )
    }
}

public enum Precondition: Codable, Hashable, Sendable {
    case pathAbsent
    case versionMatches(ItemVersion)
    case folderPresent
}

public enum OperationKind: Codable, Hashable, Sendable {
    case makeFolder(at: SyncPath)
    case transfer(content: ContentRef, to: SyncPath, overwrite: StoreOptions.OverwritePolicy)
    case relocate(itemRef: ItemRef, to: SyncPath)
    case trash(itemRef: ItemRef)

    public var targetPath: SyncPath {
        switch self {
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

    public var collisionTargetPath: SyncPath? {
        switch self {
        case let .makeFolder(path):
            return path
        case let .transfer(_, path, _):
            return path
        case let .relocate(_, path):
            return path
        case .trash:
            return nil
        }
    }

    var isTransferOrRelocate: Bool {
        switch self {
        case .transfer, .relocate:
            return true
        case .makeFolder, .trash:
            return false
        }
    }

    var isTrash: Bool {
        if case .trash = self {
            return true
        }
        return false
    }
}

public struct Operation: Codable, Hashable, Sendable, Identifiable {
    public var id: OperationID
    public var location: LocationID
    public var kind: OperationKind
    public var precondition: Precondition
    public var dependsOn: [OperationID]

    public init(
        id: OperationID,
        location: LocationID,
        kind: OperationKind,
        precondition: Precondition,
        dependsOn: [OperationID] = []
    ) {
        self.id = id
        self.location = location
        self.kind = kind
        self.precondition = precondition
        self.dependsOn = dependsOn
    }
}

public struct OperationSchedule: Codable, Hashable, Sendable {
    public var operations: [Operation]

    public init(operations: [Operation] = []) {
        self.operations = operations
    }

    public func validate(decisions: [ItemDecision] = []) throws {
        try validateUniqueIDs()
        try validateDecisionOwnership(decisions: decisions)
        try validateDependenciesPrecedeOperations()
        try validateParentsBeforeChildren()
        try validateTransfersBeforeTrash()
        try validateDescendantsBeforeDirectoryTrash()
        try validatePerItemChains(decisions: decisions)
        try validateCaseFoldedTargetCollisions()
    }

    private func validateDecisionOwnership(decisions: [ItemDecision]) throws {
        guard !decisions.isEmpty || operations.isEmpty else { return }
        let scheduled = Set(operations.map(\.id))
        var owners: [OperationID: UUID] = [:]
        for decision in decisions {
            for operationID in decision.operations {
                guard scheduled.contains(operationID) else {
                    throw OperationScheduleValidationError.unknownDecisionOperation(
                        decision: decision.id
                    )
                }
                guard owners.updateValue(decision.id, forKey: operationID) == nil else {
                    throw OperationScheduleValidationError.operationOwnedByMultipleDecisions(
                        operationID
                    )
                }
            }
        }
        guard Set(owners.keys) == scheduled else {
            throw OperationScheduleValidationError.unownedScheduledOperation
        }
    }

    private func validateUniqueIDs() throws {
        var seen: Set<OperationID> = []
        for operation in operations {
            guard seen.insert(operation.id).inserted else {
                throw OperationScheduleValidationError.duplicateOperationID(operation.id)
            }
        }
    }

    private func validateDependenciesPrecedeOperations() throws {
        let indexes = operationIndexes()
        for (index, operation) in operations.enumerated() {
            for dependency in operation.dependsOn {
                guard let dependencyIndex = indexes[dependency] else {
                    throw OperationScheduleValidationError.unknownDependency(operation: operation.id, dependency: dependency)
                }
                guard dependencyIndex < index else {
                    throw OperationScheduleValidationError.dependencyAfterOperation(operation: operation.id, dependency: dependency)
                }
            }
        }
    }

    private func validateParentsBeforeChildren() throws {
        let folderMakes = operations.enumerated().compactMap { index, operation -> (index: Int, location: LocationID, path: SyncPath)? in
            guard case let .makeFolder(path) = operation.kind else { return nil }
            return (index, operation.location, path)
        }

        for (operationIndex, operation) in operations.enumerated() {
            let target = operation.kind.targetPath
            for folder in folderMakes where folder.location == operation.location {
                guard target != folder.path, target.isDescendant(of: folder.path) else { continue }
                if folder.index > operationIndex {
                    throw OperationScheduleValidationError.parentAfterChild(parent: folder.path, child: target, location: operation.location)
                }
            }
        }
    }

    private func validateTransfersBeforeTrash() throws {
        guard let firstTrashIndex = operations.firstIndex(where: { $0.kind.isTrash }) else { return }
        if let lateTransfer = operations[firstTrashIndex...].first(where: { $0.kind.isTransferOrRelocate }) {
            throw OperationScheduleValidationError.transferAfterTrash(lateTransfer.id)
        }
    }

    private func validateDescendantsBeforeDirectoryTrash() throws {
        let directoryTrashOperations = operations.enumerated().compactMap {
            index,
            operation -> (index: Int, location: LocationID, path: SyncPath)? in
            guard case let .trash(itemRef) = operation.kind,
                  itemRef.kind == .folder else {
                return nil
            }
            return (index, operation.location, itemRef.path)
        }

        for directory in directoryTrashOperations {
            for (descendantIndex, operation) in operations.enumerated()
            where operation.location == directory.location {
                let descendant = operation.kind.targetPath
                guard descendant != directory.path,
                      descendant.isDescendant(of: directory.path),
                      descendantIndex > directory.index else {
                    continue
                }
                throw OperationScheduleValidationError.directoryTrashBeforeDescendant(
                    directory: directory.path,
                    descendant: descendant,
                    location: directory.location
                )
            }
        }
    }

    private func validatePerItemChains(decisions: [ItemDecision]) throws {
        let indexes = operationIndexes()
        for decision in decisions where decision.operations.count > 1 {
            for pair in zip(decision.operations, decision.operations.dropFirst()) {
                guard let firstIndex = indexes[pair.0], let secondIndex = indexes[pair.1] else {
                    throw OperationScheduleValidationError.unknownDecisionOperation(decision: decision.id)
                }
                guard firstIndex < secondIndex else {
                    throw OperationScheduleValidationError.itemChainOutOfOrder(decision: decision.id)
                }
                guard operations[secondIndex].dependsOn.contains(pair.0) else {
                    throw OperationScheduleValidationError.itemChainMissingDependency(decision: decision.id, operation: pair.1)
                }
            }
        }
    }

    private func validateCaseFoldedTargetCollisions() throws {
        var targets: [TargetKey: OperationID] = [:]
        for operation in operations {
            guard let targetPath = operation.kind.collisionTargetPath else { continue }
            let key = TargetKey(location: operation.location, caseFoldedPath: targetPath.caseInsensitiveKey)
            if let existing = targets[key] {
                throw OperationScheduleValidationError.caseFoldedTargetCollision(location: operation.location, path: targetPath, first: existing, second: operation.id)
            }
            targets[key] = operation.id
        }
    }

    private func operationIndexes() -> [OperationID: Int] {
        Dictionary(uniqueKeysWithValues: operations.enumerated().map { ($0.element.id, $0.offset) })
    }

    private struct TargetKey: Hashable {
        var location: LocationID
        var caseFoldedPath: String
    }
}

public struct OperationPathTouch: Codable, Hashable, Sendable, Comparable {
    public var location: LocationID
    public var path: SyncPath

    public init(location: LocationID, path: SyncPath) {
        self.location = location
        self.path = path
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        return lhs.path < rhs.path
    }

    public func overlaps(_ other: Self) -> Bool {
        guard location == other.location else { return false }
        return path == other.path
            || path.isDescendant(of: other.path)
            || other.path.isDescendant(of: path)
    }
}

extension Operation {
    public var pathTouches: [OperationPathTouch] {
        let values: [OperationPathTouch]
        switch kind {
        case let .makeFolder(path):
            values = [.init(location: location, path: path)]
        case let .transfer(content, target, _):
            values = [
                .init(location: content.sourceLocation, path: content.path),
                .init(location: location, path: target),
            ]
        case let .relocate(itemRef, target):
            values = [
                .init(location: itemRef.location, path: itemRef.path),
                .init(location: location, path: itemRef.path),
                .init(location: location, path: target),
            ]
        case let .trash(itemRef):
            values = [
                .init(location: itemRef.location, path: itemRef.path),
                .init(location: location, path: itemRef.path),
            ]
        }
        return Array(Set(values)).sorted()
    }
}

extension ProviderClassificationRequest {
    static func forOperations(_ operations: [Operation]) -> [Self] {
        var scopes: [SyncPath: ScanExclusion.Scope] = [:]
        func add(_ path: SyncPath, scope: ScanExclusion.Scope) {
            guard !path.isRoot else { return }
            if scopes[path] != .subtree {
                scopes[path] = scope
            }
            var ancestor = path.parent
            while !ancestor.isRoot {
                if scopes[ancestor] == nil {
                    scopes[ancestor] = .item
                }
                ancestor = ancestor.parent
            }
        }
        func scope(for kind: ItemKind) -> ScanExclusion.Scope {
            kind == .folder ? .subtree : .item
        }

        for operation in operations {
            switch operation.kind {
            case let .makeFolder(path):
                add(path, scope: .subtree)
            case let .transfer(content, target, _):
                let coverage = scope(for: content.kind)
                add(content.path, scope: coverage)
                add(target, scope: coverage)
            case let .relocate(itemRef, target):
                let coverage = scope(for: itemRef.kind)
                add(itemRef.path, scope: coverage)
                add(target, scope: coverage)
            case let .trash(itemRef):
                add(itemRef.path, scope: scope(for: itemRef.kind))
            }
        }

        return scopes.map { path, scope in
            Self(path: path, scope: scope)
        }.sorted()
    }
}

public enum OperationScheduleValidationError: Error, Equatable, Sendable {
    case duplicateOperationID(OperationID)
    case unknownDependency(operation: OperationID, dependency: OperationID)
    case dependencyAfterOperation(operation: OperationID, dependency: OperationID)
    case parentAfterChild(parent: SyncPath, child: SyncPath, location: LocationID)
    case transferAfterTrash(OperationID)
    case directoryTrashBeforeDescendant(directory: SyncPath, descendant: SyncPath, location: LocationID)
    case unknownDecisionOperation(decision: UUID)
    case operationOwnedByMultipleDecisions(OperationID)
    case unownedScheduledOperation
    case itemChainOutOfOrder(decision: UUID)
    case itemChainMissingDependency(decision: UUID, operation: OperationID)
    case caseFoldedTargetCollision(location: LocationID, path: SyncPath, first: OperationID, second: OperationID)
}
