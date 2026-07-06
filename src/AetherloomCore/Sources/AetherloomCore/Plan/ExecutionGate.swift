import Foundation

public enum ExecutionGate: Codable, Hashable, Sendable {
    case clear
    case hold([HoldReason])

    public var isClear: Bool {
        if case .clear = self {
            return true
        }
        return false
    }

    public var holdReasons: [HoldReason] {
        if case let .hold(reasons) = self {
            return reasons
        }
        return []
    }

    public func addingHolds(_ reasons: [HoldReason]) -> ExecutionGate {
        guard !reasons.isEmpty else {
            return self
        }

        switch self {
        case .clear:
            return .hold(reasons)
        case let .hold(existing):
            return .hold(existing + reasons)
        }
    }

    public static func evaluate(
        decisions: [ItemDecision],
        trackedCount: Int,
        settings: SyncSettings,
        mode: SyncMode
    ) -> ExecutionGate {
        var holds: [HoldReason] = []
        let denominator = max(trackedCount, 1)
        let conflictCount = decisions.filter(\.hasConflictIntent).count
        if conflictCount > 0 {
            holds.append(.conflicts(count: conflictCount))
        }

        let deletionDecisions = mode == .noDeletePropagation ? [] : decisions.filter(\.hasDeletionIntent)
        if !deletionDecisions.isEmpty {
            if mode == .askBeforeDeleting {
                holds.append(.deletionsNeedReview(count: deletionDecisions.count))
            }
            if exceeds(
                count: deletionDecisions.count,
                denominator: denominator,
                absoluteThreshold: settings.thresholds.massDeleteAbsolute,
                ratioThreshold: settings.thresholds.massDeleteRatio
            ) {
                holds.append(.massDeletion(MassChangeEvidence(decisions: deletionDecisions, trackedCount: denominator)))
            }
        }

        let editDecisions = decisions.filter(\.hasEditIntent)
        if exceeds(
            count: editDecisions.count,
            denominator: denominator,
            absoluteThreshold: settings.thresholds.massEditAbsolute,
            ratioThreshold: settings.thresholds.massEditRatio
        ) {
            holds.append(.massEdit(MassChangeEvidence(decisions: editDecisions, trackedCount: denominator)))
        }

        return holds.isEmpty ? .clear : .hold(holds)
    }

    private static func exceeds(
        count: Int,
        denominator: Int,
        absoluteThreshold: Int,
        ratioThreshold: Double
    ) -> Bool {
        guard count > 0 else { return false }
        return count >= absoluteThreshold
            || (denominator >= absoluteThreshold && Double(count) / Double(denominator) >= ratioThreshold)
    }
}

public enum HoldReason: Codable, Hashable, Sendable {
    case conflicts(count: Int)
    case massDeletion(MassChangeEvidence)
    case massEdit(MassChangeEvidence)
    case deletionsNeedReview(count: Int)

    public var message: String {
        switch self {
        case .conflicts:
            return ActivityMessageCatalog.conflictPreserved
        case .massDeletion:
            return ActivityMessageCatalog.manyDeletions
        case .massEdit:
            return ActivityMessageCatalog.manyEdits
        case .deletionsNeedReview:
            return ActivityMessageCatalog.deletionsNeedReview
        }
    }
}

public struct MassChangeEvidence: Codable, Hashable, Sendable {
    public var intentCount: Int
    public var trackedCount: Int
    public var groups: [ChangeGroup]

    public init(intentCount: Int, trackedCount: Int, groups: [ChangeGroup]) {
        self.intentCount = intentCount
        self.trackedCount = trackedCount
        self.groups = groups
    }

    public init(decisions: [ItemDecision], trackedCount: Int) {
        self.intentCount = decisions.count
        self.trackedCount = trackedCount
        self.groups = ChangeGroup.groups(for: decisions)
    }
}

public struct ChangeGroup: Codable, Hashable, Sendable {
    public var ancestor: SyncPath
    public var intentCount: Int

    public init(ancestor: SyncPath, intentCount: Int) {
        self.ancestor = ancestor
        self.intentCount = intentCount
    }

    static func groups(for decisions: [ItemDecision]) -> [ChangeGroup] {
        guard !decisions.isEmpty else { return [] }
        return [ChangeGroup(ancestor: nearestCommonAncestor(decisions.map(\.path)), intentCount: decisions.count)]
    }

    private static func nearestCommonAncestor(_ paths: [SyncPath]) -> SyncPath {
        guard let first = paths.first else { return .root }
        var common = first.components
        for path in paths.dropFirst() {
            common = Array(zip(common, path.components).prefix { $0 == $1 }.map(\.0))
        }
        return common.isEmpty ? .root : SyncPath("/" + common.joined(separator: "/"))
    }
}

extension ItemDecision {
    public var hasDeletionIntent: Bool {
        verdict.containsDeletionIntent
    }

    public var hasEditIntent: Bool {
        verdict.containsEditIntent
    }

    public var hasConflictIntent: Bool {
        verdict.containsConflictIntent
    }
}

extension ItemVerdict {
    var containsDeletionIntent: Bool {
        switch self {
        case .propagateDeletion:
            return true
        case let .compound(verdicts):
            return verdicts.contains(where: \.containsDeletionIntent)
        case .inSync, .propagateContent, .propagateCreation, .propagatePath, .conflict, .waiting:
            return false
        }
    }

    var containsEditIntent: Bool {
        switch self {
        case .propagateContent:
            return true
        case let .compound(verdicts):
            return verdicts.contains(where: \.containsEditIntent)
        case .inSync, .propagateCreation, .propagatePath, .propagateDeletion, .conflict, .waiting:
            return false
        }
    }

    var containsConflictIntent: Bool {
        switch self {
        case .conflict:
            return true
        case let .compound(verdicts):
            return verdicts.contains(where: \.containsConflictIntent)
        case .inSync, .propagateContent, .propagateCreation, .propagatePath, .propagateDeletion, .waiting:
            return false
        }
    }
}
