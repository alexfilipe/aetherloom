import Foundation
import Testing
@testable import AetherloomCore

@Test func reconciliationTrackedFactProductSweep_coversChangedRelocatedAndUnknown() {
    let factShapes: [LocationFact] = [
        .matchesBase,
        .changed(sweepVersion("different")),
        .changed(ItemVersion()),
        .relocated(to: "/Moved.txt"),
        .changedAndRelocated(sweepVersion("moved-edit"), to: "/Moved.txt"),
        .changedAndRelocated(ItemVersion(), to: "/MovedUnknown.txt"),
        .missing,
        .waiting
    ]

    for locations in sweepLocationSets {
        for facts in sweepProducts(factShapes, count: locations.count) {
            let factsByLocation = Dictionary(uniqueKeysWithValues: zip(locations, facts))
            let verdict = sweepReconciler.reconcile(
                base: sweepRecord(path: "/Tracked.txt", locations: locations),
                facts: factsByLocation,
                observations: sweepObservations(from: factsByLocation),
                locations: locations,
                primaryPath: "/Tracked.txt"
            )

            #expect(sweepDeletionMetaPropertyHolds(verdict: verdict, facts: factsByLocation, hasBase: true))
            #expect(sweepUnknownDoesNotPropagateContent(verdict: verdict, facts: factsByLocation))
            #expect(sweepPlaceholderDeletionPropertyHolds(verdict: verdict, facts: factsByLocation, locations: locations))
        }
    }
}

@Test func reconciliationAppearedFactProductSweep_hasNoDeletionWithoutBase() {
    let factShapes: [LocationFact] = [
        .missing,
        .waiting,
        .appeared(sweepItem(.localFolder, path: "/New.txt", version: sweepVersion("same"))),
        .appeared(sweepItem(.localFolder, path: "/New.txt", version: sweepVersion("different"))),
        .appeared(sweepItem(.localFolder, path: "/New.txt", version: ItemVersion()))
    ]

    for locations in sweepLocationSets {
        for facts in sweepProducts(factShapes, count: locations.count) {
            let normalizedFacts = Dictionary(uniqueKeysWithValues: zip(locations, facts).map { location, fact in
                (location, sweepReboundAppearedFact(fact, location: location))
            })
            let observations = sweepObservations(from: normalizedFacts)
            let verdict = sweepReconciler.reconcile(
                base: nil,
                facts: normalizedFacts,
                observations: observations,
                locations: locations,
                primaryPath: observations.values.map(\.path).sorted().first ?? "/New.txt"
            )

            #expect(sweepDeletionMetaPropertyHolds(verdict: verdict, facts: normalizedFacts, hasBase: false))
            #expect(sweepUnknownDoesNotPropagateContent(verdict: verdict, facts: normalizedFacts))
        }
    }
}

private let sweepDate = Date(timeIntervalSince1970: 1_770_000_000)
private let sweepEnvironment = PlanningEnvironment(now: sweepDate, makeID: {
    UUID(uuidString: "91000000-0000-0000-0000-000000000001")!
})
private let sweepReconciler = Reconciler(environment: sweepEnvironment)
private let sweepLocationSets: [[LocationID]] = [
    [.localFolder, .nasFolder],
    [.localFolder, .nasFolder, .googleDrive],
    [.localFolder, .nasFolder, .googleDrive, .oneDrive]
]

private func sweepProducts(_ facts: [LocationFact], count: Int) -> [[LocationFact]] {
    guard count > 0 else { return [[]] }
    return sweepProducts(facts, count: count - 1).flatMap { prefix in
        facts.map { prefix + [$0] }
    }
}

private func sweepRecord(path: SyncPath, locations: [LocationID]) -> BaseRecord {
    BaseRecord(
        syncSetID: UUID(uuidString: "91000000-0000-0000-0000-000000000002")!,
        path: path,
        kind: .file,
        version: sweepVersion("base"),
        perLocation: Dictionary(uniqueKeysWithValues: locations.map { location in
            (location, LocationMemory(itemID: "\(location.rawValue.uuidString):\(path.rawValue)", revisionToken: "base", lastSeenAt: sweepDate))
        }),
        lastConvergedAt: sweepDate,
        createdAt: sweepDate,
        updatedAt: sweepDate
    )
}

private func sweepObservations(from facts: [LocationID: LocationFact]) -> [LocationID: ItemObservation] {
    Dictionary(uniqueKeysWithValues: facts.compactMap { location, fact in
        switch fact {
        case let .appeared(observation):
            return (location, observation)
        case let .changed(version):
            return (location, sweepItem(location, path: "/Tracked.txt", version: version))
        case let .changedAndRelocated(version, path):
            return (location, sweepItem(location, path: path, version: version))
        case let .relocated(path):
            return (location, sweepItem(location, path: path, version: sweepVersion("base")))
        case .matchesBase:
            return (location, sweepItem(location, path: "/Tracked.txt", version: sweepVersion("base")))
        case .waiting:
            return (location, sweepItem(location, path: "/Tracked.txt", version: sweepVersion("base"), isPlaceholder: true))
        case .missing:
            return nil
        }
    })
}

private func sweepReboundAppearedFact(_ fact: LocationFact, location: LocationID) -> LocationFact {
    guard case let .appeared(observation) = fact else { return fact }
    var copy = observation
    copy.location = location
    copy.itemID = "\(location.rawValue.uuidString):\(copy.path.rawValue):appeared"
    return .appeared(copy)
}

private func sweepItem(
    _ location: LocationID,
    path: SyncPath,
    version: ItemVersion,
    isPlaceholder: Bool = false
) -> ItemObservation {
    ItemObservation(
        location: location,
        itemID: "\(location.rawValue.uuidString):\(path.rawValue)",
        path: path,
        kind: .file,
        version: version,
        isPlaceholder: isPlaceholder
    )
}

private func sweepVersion(_ hash: String) -> ItemVersion {
    ItemVersion(contentHash: hash, size: Int64(hash.count), modifiedAt: sweepDate, revisionToken: hash)
}

private func sweepContains(_ verdict: ItemVerdict, predicate: (ItemVerdict) -> Bool) -> Bool {
    if predicate(verdict) {
        return true
    }
    if case let .compound(children) = verdict {
        return children.contains { sweepContains($0, predicate: predicate) }
    }
    return false
}

private func sweepDeletionMetaPropertyHolds(
    verdict: ItemVerdict,
    facts: [LocationID: LocationFact],
    hasBase: Bool
) -> Bool {
    !sweepContains(verdict) {
        if case .propagateDeletion = $0 {
            return !(hasBase && facts.values.allSatisfy { fact in
                switch fact {
                case .matchesBase, .missing, .waiting:
                    return true
                case .changed, .relocated, .changedAndRelocated, .appeared:
                    return false
                }
            })
        }
        return false
    }
}

private func sweepUnknownDoesNotPropagateContent(verdict: ItemVerdict, facts: [LocationID: LocationFact]) -> Bool {
    let hasUnknown = facts.values.contains { fact in
        guard let version = fact.changedVersion else { return false }
        return version.comparison(to: sweepVersion("base")) == .unknown
    }
    guard hasUnknown else { return true }
    return !sweepContains(verdict) {
        if case .propagateContent = $0 { return true }
        return false
    }
}

private func sweepPlaceholderDeletionPropertyHolds(
    verdict: ItemVerdict,
    facts: [LocationID: LocationFact],
    locations: [LocationID]
) -> Bool {
    guard facts.values.contains(where: \.isWaiting) else { return true }
    guard sweepContains(verdict, predicate: { if case .propagateDeletion = $0 { return true }; return false }) else { return true }
    var withoutWaiting = facts
    for (location, fact) in facts where fact.isWaiting {
        withoutWaiting[location] = .matchesBase
    }
    let comparisonVerdict = sweepReconciler.reconcile(
        base: sweepRecord(path: "/Tracked.txt", locations: locations),
        facts: withoutWaiting,
        observations: sweepObservations(from: withoutWaiting),
        locations: locations,
        primaryPath: "/Tracked.txt"
    )
    return sweepContains(comparisonVerdict) {
        if case .propagateDeletion = $0 { return true }
        return false
    }
}
