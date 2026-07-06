import Foundation

public struct ReconciliationInput: Sendable {
    public var syncSet: SyncSet
    public var base: [BaseRecord]
    public var snapshots: [LocationID: LocationSnapshot]
    public var environment: PlanningEnvironment

    public init(
        syncSet: SyncSet,
        base: [BaseRecord],
        snapshots: [LocationID: LocationSnapshot],
        environment: PlanningEnvironment
    ) {
        self.syncSet = syncSet
        self.base = base
        self.snapshots = snapshots
        self.environment = environment
    }
}

public enum LocationFact: Hashable, Sendable {
    case matchesBase
    case changed(ItemVersion)
    case relocated(to: SyncPath)
    case changedAndRelocated(ItemVersion, to: SyncPath)
    case missing
    case waiting
    case appeared(ItemObservation)

    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    public var isPresent: Bool {
        !isMissing
    }

    public var changedVersion: ItemVersion? {
        switch self {
        case let .changed(version),
             let .changedAndRelocated(version, _):
            version
        case let .appeared(observation):
            observation.version
        case .matchesBase, .relocated, .missing, .waiting:
            nil
        }
    }

    public var relocatedPath: SyncPath? {
        switch self {
        case let .relocated(path),
             let .changedAndRelocated(_, path):
            path
        case .matchesBase, .changed, .missing, .waiting, .appeared:
            nil
        }
    }
}

public struct ReconciliationItem: Hashable, Sendable {
    public var base: BaseRecord?
    public var facts: [LocationID: LocationFact]
    public var observations: [LocationID: ItemObservation]
    public var locations: [LocationID]
    public var primaryPath: SyncPath

    public init(
        base: BaseRecord?,
        facts: [LocationID: LocationFact],
        observations: [LocationID: ItemObservation],
        locations: [LocationID],
        primaryPath: SyncPath
    ) {
        self.base = base
        self.facts = facts
        self.observations = observations
        self.locations = locations
        self.primaryPath = primaryPath
    }
}

private struct ObservationToken: Hashable {
    var location: LocationID
    var itemID: String?
    var path: SyncPath
}

public func deriveFacts(_ input: ReconciliationInput) -> [ReconciliationItem] {
    let locations = input.syncSet.locations.sorted()
    let settings = input.syncSet.settings
    let activeObservations = activeObservationsByLocation(
        snapshots: input.snapshots,
        locations: locations,
        settings: settings
    )
    let indexes = ObservationIndexes(activeObservations)
    var consumed: Set<ObservationToken> = []
    var items: [ReconciliationItem] = []

    let records = input.base
        .filter { $0.syncSetID == input.syncSet.id }
        .filter { !settings.isExcluded(path: $0.path, kind: $0.kind) }
        .sorted { $0.path < $1.path }

    for record in records {
        var facts: [LocationID: LocationFact] = [:]
        var observations: [LocationID: ItemObservation] = [:]

        for location in locations {
            if let observation = indexes.observation(for: record, at: location) {
                consumed.insert(token(for: observation))
                observations[location] = observation
                facts[location] = fact(for: record, observation: observation)
            } else {
                facts[location] = .missing
            }
        }

        items.append(
            ReconciliationItem(
                base: record,
                facts: facts,
                observations: observations,
                locations: locations,
                primaryPath: record.path
            )
        )
    }

    let unconsumed = locations.flatMap { location in
        (activeObservations[location] ?? []).filter { !consumed.contains(token(for: $0)) }
    }
    let appearedGroups = Dictionary(grouping: unconsumed) { $0.path.caseInsensitiveKey }

    for (_, observations) in appearedGroups.sorted(by: { $0.key < $1.key }) {
        var facts = Dictionary(uniqueKeysWithValues: locations.map { ($0, LocationFact.missing) })
        var observationsByLocation: [LocationID: ItemObservation] = [:]
        for observation in observations.sorted(by: itemSort) {
            facts[observation.location] = .appeared(observation)
            observationsByLocation[observation.location] = observation
        }

        let primaryPath = observations.map(\.path).sorted().first ?? .root
        items.append(
            ReconciliationItem(
                base: nil,
                facts: facts,
                observations: observationsByLocation,
                locations: locations,
                primaryPath: primaryPath
            )
        )
    }

    return applyHashBasedMoveMatching(to: items)
}

public func applyHashBasedMoveMatching(to items: [ReconciliationItem]) -> [ReconciliationItem] {
    var mutableItems = items
    var consumedAppearedIndexes: Set<Int> = []

    for baseIndex in mutableItems.indices {
        guard mutableItems[baseIndex].base != nil else { continue }
        let missingLocations = mutableItems[baseIndex].facts.compactMap { location, fact in
            fact.isMissing ? location : nil
        }
        guard !missingLocations.isEmpty else { continue }

        for location in missingLocations.sorted() {
            guard let baseHash = mutableItems[baseIndex].base?.version.contentHash else { continue }
            guard let matchIndex = mutableItems.indices.first(where: { candidateIndex in
                guard candidateIndex != baseIndex, !consumedAppearedIndexes.contains(candidateIndex) else { return false }
                guard case let .appeared(observation)? = mutableItems[candidateIndex].facts[location] else { return false }
                return observation.version.contentHash == baseHash
            }) else {
                continue
            }

            guard let appeared = mutableItems[matchIndex].observations[location] else { continue }
            mutableItems[baseIndex].facts[location] = .relocated(to: appeared.path)
            mutableItems[baseIndex].observations[location] = appeared
            mutableItems[baseIndex].primaryPath = mutableItems[baseIndex].base?.path ?? appeared.path
            consumedAppearedIndexes.insert(matchIndex)
        }
    }

    return mutableItems.enumerated()
        .filter { !consumedAppearedIndexes.contains($0.offset) }
        .map(\.element)
}

private func activeObservationsByLocation(
    snapshots: [LocationID: LocationSnapshot],
    locations: [LocationID],
    settings: SyncSettings
) -> [LocationID: [ItemObservation]] {
    Dictionary(uniqueKeysWithValues: locations.map { location in
        let observations = snapshots[location]?.observations.all.filter {
            !$0.isTrashed && !settings.isExcluded($0)
        } ?? []
        return (location, observations.sorted(by: itemSort))
    })
}

private struct ObservationIndexes {
    var byItemID: [LocationID: [String: ItemObservation]]
    var byPath: [LocationID: [SyncPath: ItemObservation]]
    var byCaseFoldedPath: [LocationID: [String: [ItemObservation]]]

    init(_ observationsByLocation: [LocationID: [ItemObservation]]) {
        self.byItemID = [:]
        self.byPath = [:]
        self.byCaseFoldedPath = [:]

        for (location, observations) in observationsByLocation {
            byItemID[location] = Dictionary(
                uniqueKeysWithValues: observations.compactMap { observation in
                    observation.itemID.map { ($0, observation) }
                }
            )
            byPath[location] = Dictionary(uniqueKeysWithValues: observations.map { ($0.path, $0) })
            byCaseFoldedPath[location] = Dictionary(grouping: observations) { $0.path.caseInsensitiveKey }
        }
    }

    func observation(for record: BaseRecord, at location: LocationID) -> ItemObservation? {
        if let itemID = record.itemID(for: location),
           let observation = byItemID[location]?[itemID] {
            return observation
        }
        if let observation = byPath[location]?[record.path] {
            return observation
        }
        return byCaseFoldedPath[location]?[record.path.caseInsensitiveKey]?
            .sorted(by: itemSort)
            .first
    }
}

private func fact(for record: BaseRecord, observation: ItemObservation) -> LocationFact {
    if observation.isPlaceholder {
        return .waiting
    }
    if observation.kind != record.kind {
        return .changed(observation.version)
    }
    if observation.isFolder {
        return observation.path == record.path ? .matchesBase : .relocated(to: observation.path)
    }

    let comparison = observation.version.comparison(to: record.version)
    switch (comparison, observation.path == record.path) {
    case (.same, true):
        return .matchesBase
    case (.same, false):
        return .relocated(to: observation.path)
    case (.different, true), (.unknown, true):
        return .changed(observation.version)
    case (.different, false), (.unknown, false):
        return .changedAndRelocated(observation.version, to: observation.path)
    }
}

private func token(for observation: ItemObservation) -> ObservationToken {
    ObservationToken(location: observation.location, itemID: observation.itemID, path: observation.path)
}

private func itemSort(_ lhs: ItemObservation, _ rhs: ItemObservation) -> Bool {
    if lhs.path != rhs.path {
        return lhs.path < rhs.path
    }
    return lhs.location < rhs.location
}
