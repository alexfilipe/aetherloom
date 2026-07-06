import Foundation

public struct Reconciler: Sendable {
    public var environment: PlanningEnvironment

    public init(environment: PlanningEnvironment) {
        self.environment = environment
    }

    public func reconcile(base: BaseRecord?, facts: [LocationID: LocationFact]) -> ItemVerdict {
        reconcile(base: base, facts: facts, observations: [:], locations: facts.keys.sorted(), primaryPath: base?.path ?? .root)
    }

    public func reconcile(_ item: ReconciliationItem) -> ItemVerdict {
        reconcile(
            base: item.base,
            facts: item.facts,
            observations: item.observations,
            locations: item.locations,
            primaryPath: item.primaryPath
        )
    }

    public func reconcile(
        base: BaseRecord?,
        facts: [LocationID: LocationFact],
        observations: [LocationID: ItemObservation],
        locations: [LocationID],
        primaryPath: SyncPath
    ) -> ItemVerdict {
        if let base {
            return reconcileTrackedItem(
                base: base,
                facts: facts,
                observations: observations,
                locations: locations,
                primaryPath: primaryPath
            )
        }
        return reconcileAppearedItem(
            facts: facts,
            observations: observations,
            locations: locations,
            primaryPath: primaryPath
        )
    }

    private func reconcileTrackedItem(
        base: BaseRecord,
        facts: [LocationID: LocationFact],
        observations: [LocationID: ItemObservation],
        locations: [LocationID],
        primaryPath: SyncPath
    ) -> ItemVerdict {
        if hasTypeClash(base: base, observations: observations) {
            return conflict(.typeClash, path: primaryPath, observations: observations)
        }

        let missingLocations = locations.filter { facts[$0]?.isMissing == true }
        let waitingLocations = locations.filter { facts[$0]?.isWaiting == true }
        let changedLocations = locations.filter { isChanged(facts[$0]) }
        let relocatedLocations = locations.filter { facts[$0]?.relocatedPath != nil }

        if !waitingLocations.isEmpty && contentDecisionNeeded(changedLocations: changedLocations, relocatedLocations: relocatedLocations, missingLocations: missingLocations) {
            return .waiting(.contentNotMaterialized, locations: Set(waitingLocations))
        }

        if missingLocations.count == locations.count {
            return .inSync
        }

        if !missingLocations.isEmpty && !changedLocations.isEmpty {
            return conflict(.editDelete, path: primaryPath, observations: observations, locations: changedLocations)
        }

        if !missingLocations.isEmpty && !relocatedLocations.isEmpty {
            guard let source = relocatedLocations.sorted().first,
                  let newPath = facts[source]?.relocatedPath else {
                return conflict(.moveMove, path: primaryPath, observations: observations, locations: relocatedLocations)
            }
            let pathTargets = locations.filter { location in
                guard location != source else { return false }
                return isUnchangedPresence(facts[location])
            }
            let creationTargets = missingLocations.filter { $0 != source }
            return compound([
                .propagatePath(to: Set(pathTargets), newPath: newPath),
                .propagateCreation(from: source, to: Set(creationTargets))
            ])
        }

        if !missingLocations.isEmpty {
            let presentUnchanged = locations
                .filter { !missingLocations.contains($0) }
                .allSatisfy { isUnchangedPresence(facts[$0]) }
            if presentUnchanged {
                return .propagateDeletion(to: Set(locations.filter { !missingLocations.contains($0) }), initiatedBy: missingLocations.sorted().first!)
            }
            return conflict(.editDelete, path: primaryPath, observations: observations, locations: changedLocations)
        }

        let changedAndRelocatedLocations = locations.filter { isChangedAndRelocated(facts[$0]) }
        if changedAndRelocatedLocations.count == 1,
           changedLocations.count == 1,
           relocatedLocations.count == 1,
           let source = changedAndRelocatedLocations.first,
           let newPath = facts[source]?.relocatedPath,
            restUnchanged(except: source, facts: facts, locations: locations) {
            if isUnknownChange(facts[source], comparedTo: base.version) {
                return conflict(.editEdit, path: primaryPath, observations: observations, locations: [source])
            }
            let destinations = Set(locations.filter { $0 != source })
            return compound([
                .propagateContent(from: source, to: destinations),
                .propagatePath(to: destinations, newPath: newPath)
            ])
        }

        if relocatedLocations.count >= 2 {
            let paths = Set(relocatedLocations.compactMap { facts[$0]?.relocatedPath })
            if paths.count == 1 {
                return .inSync
            }
            return conflict(.moveMove, path: primaryPath, observations: observations, locations: relocatedLocations)
        }

        if relocatedLocations.count == 1,
           let source = relocatedLocations.first,
           let newPath = facts[source]?.relocatedPath,
           restUnchanged(except: source, facts: facts, locations: locations) {
            return .propagatePath(to: Set(locations.filter { $0 != source }), newPath: newPath)
        }

        if changedLocations.count >= 2 {
            if changedVersionsConverged(changedLocations, facts: facts) {
                return .inSync
            }
            return conflict(.editEdit, path: primaryPath, observations: observations, locations: changedLocations)
        }

        if changedLocations.count == 1,
           let source = changedLocations.first,
            restUnchanged(except: source, facts: facts, locations: locations) {
            if isUnknownChange(facts[source], comparedTo: base.version) {
                return conflict(.editEdit, path: primaryPath, observations: observations, locations: [source])
            }
            return .propagateContent(from: source, to: Set(locations.filter { $0 != source }))
        }

        if locations.allSatisfy({ isUnchangedPresence(facts[$0]) }) {
            return .inSync
        }

        return conflict(.editEdit, path: primaryPath, observations: observations)
    }

    private func reconcileAppearedItem(
        facts: [LocationID: LocationFact],
        observations: [LocationID: ItemObservation],
        locations: [LocationID],
        primaryPath: SyncPath
    ) -> ItemVerdict {
        let appearedLocations = locations.filter {
            if case .appeared = facts[$0] { return true }
            return false
        }
        let appearedObservations = appearedLocations.compactMap { location in
            appearedObservation(facts[location], observations: observations, location: location)
        }

        if hasCaseCollision(appearedObservations) {
            return conflict(.caseCollision, path: primaryPath, observations: observations)
        }

        if hasTypeClash(observations: appearedObservations) {
            return conflict(.typeClash, path: primaryPath, observations: observations)
        }

        if appearedLocations.count == 1,
           let source = appearedLocations.first {
            return .propagateCreation(from: source, to: Set(locations.filter { $0 != source }))
        }

        if appearedLocations.count >= 2 {
            if appearedVersionsConverged(appearedObservations) {
                return .inSync
            }
            return conflict(.createCreate, path: primaryPath, observations: observations)
        }

        return .inSync
    }

    private func conflict(
        _ kind: ConflictKind,
        path: SyncPath,
        observations: [LocationID: ItemObservation],
        locations: [LocationID]? = nil
    ) -> ItemVerdict {
        let scopedObservations = locations.map { selected in
            observations.filter { selected.contains($0.key) }
        } ?? observations
        let versions = scopedObservations
            .sorted { $0.key < $1.key }
            .map { ConflictVersion(location: $0.key, observation: $0.value) }
        return .conflict(
            ConflictDecision(
                id: environment.makeID(),
                kind: kind,
                path: path,
                versions: versions,
                message: message(for: kind)
            )
        )
    }

    private func message(for kind: ConflictKind) -> String {
        switch kind {
        case .editEdit:
            return "This file changed in more than one place. Aetherloom preserved both versions."
        case .editDelete:
            return "This file changed in one place and was missing in another. Aetherloom preserved the edited version."
        case .createCreate:
            return "Different files appeared at the same path before sync. Aetherloom preserved each version."
        case .moveMove:
            return "This file moved to more than one place. Aetherloom preserved every version."
        case .caseCollision:
            return "A filename collision was found. Aetherloom preserved both names."
        case .typeClash:
            return "A file and folder appeared at the same path. Aetherloom preserved the file and left the folder untouched."
        }
    }
}

public func foldSubtreeMoves(_ items: [ReconciledItem]) -> [ReconciledItem] {
    let folderMoves = items.compactMap { item -> (oldPath: SyncPath, newPath: SyncPath, targets: Set<LocationID>)? in
        guard item.item.base?.kind == .folder,
              item.item.base?.perLocation.values.contains(where: { $0.itemID != nil }) == true,
              case let .propagatePath(targets, newPath) = item.verdict else {
            return nil
        }
        return (item.item.base?.path ?? item.item.primaryPath, newPath, targets)
    }

    guard !folderMoves.isEmpty else { return items }

    return items.filter { item in
        guard item.item.base?.kind != .folder,
              case let .propagatePath(targets, newPath) = item.verdict else {
            return true
        }

        let oldPath = item.item.base?.path ?? item.item.primaryPath
        return !folderMoves.contains { folder in
            oldPath.isDescendant(of: folder.oldPath)
                && oldPath != folder.oldPath
                && newPath.isDescendant(of: folder.newPath)
                && targets == folder.targets
        }
    }
}

private func compound(_ verdicts: [ItemVerdict]) -> ItemVerdict {
    let nonEmpty = verdicts.filter { verdict in
        switch verdict {
        case let .propagateContent(_, targets),
             let .propagateCreation(_, targets),
             let .propagatePath(targets, _),
             let .propagateDeletion(targets, _),
             let .waiting(_, targets):
            return !targets.isEmpty
        case .inSync:
            return false
        case .conflict, .compound:
            return true
        }
    }

    if nonEmpty.isEmpty {
        return .inSync
    }
    if nonEmpty.count == 1, let only = nonEmpty.first {
        return only
    }
    return .compound(nonEmpty)
}

private func isChanged(_ fact: LocationFact?) -> Bool {
    switch fact {
    case .changed, .changedAndRelocated:
        return true
    case .matchesBase, .relocated, .missing, .waiting, .appeared, nil:
        return false
    }
}

private func isChangedAndRelocated(_ fact: LocationFact?) -> Bool {
    switch fact {
    case .changedAndRelocated:
        return true
    case .matchesBase, .changed, .relocated, .missing, .waiting, .appeared, nil:
        return false
    }
}

private func isUnchangedPresence(_ fact: LocationFact?) -> Bool {
    switch fact {
    case .matchesBase, .waiting:
        return true
    case .changed, .relocated, .changedAndRelocated, .missing, .appeared, nil:
        return false
    }
}

private func restUnchanged(
    except source: LocationID,
    facts: [LocationID: LocationFact],
    locations: [LocationID]
) -> Bool {
    locations
        .filter { $0 != source }
        .allSatisfy { isUnchangedPresence(facts[$0]) }
}

private func contentDecisionNeeded(
    changedLocations: [LocationID],
    relocatedLocations: [LocationID],
    missingLocations: [LocationID]
) -> Bool {
    !changedLocations.isEmpty || (!relocatedLocations.isEmpty && missingLocations.isEmpty)
}

private func isUnknownChange(_ fact: LocationFact?, comparedTo baseVersion: ItemVersion) -> Bool {
    guard let version = fact?.changedVersion else { return false }
    return version.comparison(to: baseVersion) == .unknown
}

private func changedVersionsConverged(_ locations: [LocationID], facts: [LocationID: LocationFact]) -> Bool {
    let versions = locations.compactMap { facts[$0]?.changedVersion }
    guard versions.count > 1 else { return true }
    for lhsIndex in versions.indices {
        for rhsIndex in versions.index(after: lhsIndex)..<versions.endIndex {
            if versions[lhsIndex].comparison(to: versions[rhsIndex]) != .same {
                return false
            }
        }
    }
    return true
}

private func appearedVersionsConverged(_ observations: [ItemObservation]) -> Bool {
    let fileObservations = observations.filter { !$0.isFolder }
    guard fileObservations.count > 1 else { return true }
    for lhsIndex in fileObservations.indices {
        for rhsIndex in fileObservations.index(after: lhsIndex)..<fileObservations.endIndex {
            if fileObservations[lhsIndex].version.comparison(to: fileObservations[rhsIndex].version) != .same {
                return false
            }
        }
    }
    return true
}

private func hasCaseCollision(_ observations: [ItemObservation]) -> Bool {
    let exactPaths = Set(observations.map(\.path))
    let foldedPaths = Set(observations.map { $0.path.caseInsensitiveKey })
    return exactPaths.count > foldedPaths.count
}

private func hasTypeClash(base: BaseRecord, observations: [LocationID: ItemObservation]) -> Bool {
    observations.values.contains { $0.kind != base.kind }
}

private func hasTypeClash(observations: [ItemObservation]) -> Bool {
    let grouped = Dictionary(grouping: observations) { $0.path }
    return grouped.values.contains { group in
        Set(group.map(\.kind)).count > 1
    }
}

private func appearedObservation(
    _ fact: LocationFact?,
    observations: [LocationID: ItemObservation],
    location: LocationID
) -> ItemObservation? {
    switch fact {
    case let .appeared(observation):
        return observation
    case .matchesBase, .changed, .relocated, .changedAndRelocated, .missing, .waiting, nil:
        return observations[location]
    }
}
