import Foundation

public struct ChangePreview: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var planFingerprint: PlanFingerprint?
    public var headline: String
    public var refusals: [RefusalNotice]
    public var holds: [HoldNotice]
    public var sections: [PreviewSection]
    public var conflicts: [ConflictDecision]
    public var advice: [ConflictAdvice]
    public var generatedAt: Date

    public init(
        syncSetID: UUID,
        planFingerprint: PlanFingerprint?,
        headline: String,
        refusals: [RefusalNotice] = [],
        holds: [HoldNotice] = [],
        sections: [PreviewSection] = [],
        conflicts: [ConflictDecision] = [],
        advice: [ConflictAdvice] = [],
        generatedAt: Date
    ) {
        self.syncSetID = syncSetID
        self.planFingerprint = planFingerprint
        self.headline = headline
        self.refusals = refusals
        self.holds = holds
        self.sections = sections
        self.conflicts = conflicts
        self.advice = advice
        self.generatedAt = generatedAt
    }
}

public struct RefusalNotice: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var reason: RefusalReason
    public var locationID: LocationID?
    public var message: String
    public var detail: String?

    public init(id: UUID, reason: RefusalReason, locationID: LocationID? = nil, message: String, detail: String? = nil) {
        self.id = id
        self.reason = reason
        self.locationID = locationID
        self.message = message
        self.detail = detail
    }
}

public struct HoldNotice: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var reason: HoldReason
    public var message: String
    public var evidence: MassChangeEvidence?
    public var advisoryNote: HoldTriageNote?

    public init(
        id: UUID,
        reason: HoldReason,
        message: String,
        evidence: MassChangeEvidence? = nil,
        advisoryNote: HoldTriageNote? = nil
    ) {
        self.id = id
        self.reason = reason
        self.message = message
        self.evidence = evidence
        self.advisoryNote = advisoryNote
    }
}

public enum PreviewSectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case additions
    case updates
    case movesAndRenames
    case waiting
    case movesToTrash
    case bothVersionsPreserved

    public var title: String {
        switch self {
        case .additions:
            return "Additions"
        case .updates:
            return "Updates"
        case .movesAndRenames:
            return "Moves and renames"
        case .waiting:
            return "Waiting"
        case .movesToTrash:
            return "Move to trash"
        case .bothVersionsPreserved:
            return "Both versions preserved"
        }
    }
}

public struct PreviewSection: Codable, Hashable, Sendable, Identifiable {
    public var id: PreviewSectionKind { kind }
    public var kind: PreviewSectionKind
    public var title: String
    public var entries: [PreviewEntry]

    public init(kind: PreviewSectionKind, title: String? = nil, entries: [PreviewEntry] = []) {
        self.kind = kind
        self.title = title ?? kind.title
        self.entries = entries
    }
}

public struct PreviewEntry: Codable, Hashable, Sendable {
    public var decisionID: UUID
    public var path: SyncPath
    public var summary: String
    public var causality: String?
    public var destinations: [LocationID]
    public var byteSize: Int64?
    public var isTrash: Bool

    public init(
        decisionID: UUID,
        path: SyncPath,
        summary: String,
        causality: String? = nil,
        destinations: [LocationID] = [],
        byteSize: Int64? = nil,
        isTrash: Bool = false
    ) {
        self.decisionID = decisionID
        self.path = path
        self.summary = summary
        self.causality = causality
        self.destinations = destinations.sorted()
        self.byteSize = byteSize
        self.isTrash = isTrash
    }
}

public struct ChangePreviewRenderer: Sendable {
    public init() {}

    public func render(
        outcome: PlanOutcome,
        locations: LocationDirectory,
        base: [BaseRecord],
        advice: [ConflictAdvice] = [],
        triageNotes: [HoldTriageNote] = [],
        generatedAt: Date
    ) -> ChangePreview {
        switch outcome {
        case let .refusal(refusal):
            return ChangePreview(
                syncSetID: refusal.syncSetID,
                planFingerprint: nil,
                headline: "Paused for safety",
                refusals: refusal.reasons.enumerated().map { index, reason in
                    RefusalNotice(
                        id: noticeID("refusal", refusal.syncSetID, index, generatedAt),
                        reason: reason,
                        locationID: reason.locationID,
                        message: reason.message,
                        detail: detail(for: reason, locations: locations)
                    )
                },
                generatedAt: generatedAt
            )

        case let .plan(plan):
            let sectionEntries = entriesBySection(plan: plan, locations: locations, base: base)
            let sections = PreviewSectionKind.allCases.map { kind in
                PreviewSection(kind: kind, entries: sectionEntries[kind] ?? [])
            }
            let notesByHold = Dictionary(uniqueKeysWithValues: triageNotes.map { ($0.holdReason, $0) })
            return ChangePreview(
                syncSetID: plan.syncSetID,
                planFingerprint: plan.fingerprint,
                headline: headline(for: plan),
                holds: plan.gate.holdReasons.enumerated().map { index, reason in
                    HoldNotice(
                        id: noticeID("hold", plan.syncSetID, index, generatedAt),
                        reason: reason,
                        message: reason.message,
                        evidence: reason.evidence,
                        advisoryNote: notesByHold[reason]
                    )
                },
                sections: sections,
                conflicts: plan.conflicts,
                advice: advice.sorted(by: adviceSort),
                generatedAt: generatedAt
            )
        }
    }

    private func headline(for plan: SyncPlan) -> String {
        if !plan.gate.isClear {
            return "Needs review"
        }
        let count = plan.decisions.count
        return count == 1 ? "1 change ready to sync" : "\(count) changes ready to sync"
    }

    private func entriesBySection(
        plan: SyncPlan,
        locations: LocationDirectory,
        base: [BaseRecord]
    ) -> [PreviewSectionKind: [PreviewEntry]] {
        let operationsByID = Dictionary(uniqueKeysWithValues: plan.schedule.operations.map { ($0.id, $0) })
        var result: [PreviewSectionKind: [PreviewEntry]] = [:]

        for decision in plan.decisions.sorted(by: decisionSort) {
            let operations = decision.operations.compactMap { operationsByID[$0] }
            let section = sectionKind(for: decision, operations: operations)
            result[section, default: []].append(
                PreviewEntry(
                    decisionID: decision.id,
                    path: decision.path,
                    summary: summary(for: decision, operations: operations, locations: locations),
                    causality: causality(for: decision, operations: operations, locations: locations, base: base),
                    destinations: destinations(for: decision, operations: operations),
                    byteSize: byteSize(for: operations),
                    isTrash: operations.contains { $0.kind.isTrash }
                )
            )
        }

        return result
    }

    private func sectionKind(for decision: ItemDecision, operations: [Operation]) -> PreviewSectionKind {
        if decision.hasConflictIntent {
            return .bothVersionsPreserved
        }
        if isWaiting(decision.verdict) {
            return .waiting
        }
        if operations.contains(where: { $0.kind.isTrash }) {
            return .movesToTrash
        }
        if operations.contains(where: { operation in
            if case .relocate = operation.kind { return true }
            return false
        }) {
            return .movesAndRenames
        }
        if operations.contains(where: { operation in
            switch operation.kind {
            case .makeFolder:
                return true
            case let .transfer(_, _, overwrite):
                return overwrite == .neverOverwrite
            case .relocate, .trash:
                return false
            }
        }) {
            return .additions
        }
        return .updates
    }

    private func summary(for decision: ItemDecision, operations: [Operation], locations: LocationDirectory) -> String {
        if isWaiting(decision.verdict) {
            let names = waitingLocations(decision.verdict).map { locationName($0, locations: locations) }.joined(separator: ", ")
            return "Waiting for \"\(decision.path.name)\" to download from \(names)."
        }
        if decision.hasConflictIntent {
            return "Both versions preserved for \"\(decision.path.rawValue)\"."
        }
        if operations.isEmpty {
            return decision.explanation
        }
        if operations.count == 1, let operation = operations.first {
            return summary(for: operation, locations: locations)
        }
        if operations.allSatisfy({ $0.kind.isTrash }) {
            return "Move \"\(decision.path.rawValue)\" to \(operations.count) locations' trash."
        }
        return decision.explanation
    }

    private func summary(for operation: Operation, locations: LocationDirectory) -> String {
        switch operation.kind {
        case let .makeFolder(path):
            return "Create folder \"\(path.rawValue)\" in \(locationName(operation.location, locations: locations))."
        case let .transfer(content, path, overwrite):
            switch overwrite {
            case .neverOverwrite:
                if path == content.path {
                    return "Create \"\(path.rawValue)\" in \(locationName(operation.location, locations: locations)) from \(locationName(content.sourceLocation, locations: locations))."
                }
                return "Preserve \"\(content.path.rawValue)\" as \"\(path.rawValue)\" in \(locationName(operation.location, locations: locations))."
            case .ifVersionMatches:
                return "Update \"\(path.rawValue)\" in \(locationName(operation.location, locations: locations)) from \(locationName(content.sourceLocation, locations: locations))."
            }
        case let .relocate(itemRef, newPath):
            if itemRef.path.parent == newPath.parent {
                return "Rename \"\(itemRef.path.rawValue)\" to \"\(newPath.rawValue)\" in \(locationName(operation.location, locations: locations))."
            }
            return "Move \"\(itemRef.path.rawValue)\" to \"\(newPath.rawValue)\" in \(locationName(operation.location, locations: locations))."
        case let .trash(itemRef):
            return "Move \"\(itemRef.path.rawValue)\" to \(locationName(operation.location, locations: locations)) trash."
        }
    }

    private func causality(
        for decision: ItemDecision,
        operations: [Operation],
        locations: LocationDirectory,
        base: [BaseRecord]
    ) -> String? {
        guard operations.contains(where: { $0.kind.isTrash }),
              let initiator = decision.verdict.deletionInitiator else {
            return nil
        }
        let record = base.first { $0.path == decision.path }
        let lastSync = record.flatMap { $0.lastConvergedAt ?? $0.updatedAt }.map(CanonicalCoding.dateString) ?? "an earlier sync"
        return "Deleted from \(locationName(initiator, locations: locations)) since last sync on \(lastSync). Copies at other locations move to trash."
    }

    private func destinations(for decision: ItemDecision, operations: [Operation]) -> [LocationID] {
        if isWaiting(decision.verdict) {
            return waitingLocations(decision.verdict)
        }
        return operations.map(\.location).sorted()
    }

    private func byteSize(for operations: [Operation]) -> Int64? {
        operations.compactMap { operation -> Int64? in
            if case let .transfer(content, _, _) = operation.kind {
                return content.expectedVersion.size
            }
            return nil
        }.first
    }

    private func detail(for reason: RefusalReason, locations: LocationDirectory) -> String? {
        switch reason {
        case let .locationUnavailable(location, reason):
            return "\(locationName(location, locations: locations)): \(reason.detail)"
        case let .scanIncomplete(location, detail):
            return "\(locationName(location, locations: locations)): \(detail)"
        case let .baseStateUnreadable(detail):
            return detail
        }
    }

    private func locationName(_ id: LocationID, locations: LocationDirectory) -> String {
        locations[id]?.displayName ?? id.displayName
    }

    private func decisionSort(_ lhs: ItemDecision, _ rhs: ItemDecision) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func adviceSort(_ lhs: ConflictAdvice, _ rhs: ConflictAdvice) -> Bool {
        lhs.conflictID.uuidString < rhs.conflictID.uuidString
    }
}

private extension RefusalReason {
    var locationID: LocationID? {
        switch self {
        case let .locationUnavailable(location, _), let .scanIncomplete(location, _):
            return location
        case .baseStateUnreadable:
            return nil
        }
    }
}

private extension HoldReason {
    var evidence: MassChangeEvidence? {
        switch self {
        case let .massDeletion(evidence), let .massEdit(evidence):
            return evidence
        case .conflicts, .deletionsNeedReview:
            return nil
        }
    }
}

private extension ItemVerdict {
    var deletionInitiator: LocationID? {
        switch self {
        case let .propagateDeletion(_, initiatedBy):
            return initiatedBy
        case let .compound(verdicts):
            return verdicts.compactMap(\.deletionInitiator).first
        case .inSync, .propagateContent, .propagateCreation, .propagatePath, .conflict, .waiting:
            return nil
        }
    }
}

private func isWaiting(_ verdict: ItemVerdict) -> Bool {
    switch verdict {
    case .waiting:
        return true
    case let .compound(verdicts):
        return verdicts.contains(where: isWaiting)
    case .inSync, .propagateContent, .propagateCreation, .propagatePath, .propagateDeletion, .conflict:
        return false
    }
}

private func waitingLocations(_ verdict: ItemVerdict) -> [LocationID] {
    switch verdict {
    case let .waiting(_, locations):
        return locations.sorted()
    case let .compound(verdicts):
        return Array(Set(verdicts.flatMap(waitingLocations))).sorted()
    case .inSync, .propagateContent, .propagateCreation, .propagatePath, .propagateDeletion, .conflict:
        return []
    }
}

private func noticeID(_ prefix: String, _ syncSetID: UUID, _ index: Int, _ generatedAt: Date) -> UUID {
    DeterministicID.uuid(prefix, syncSetID.uuidString, String(index), CanonicalCoding.dateString(generatedAt))
}
