import Foundation

public struct SyncPlan: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var generatedAt: Date
    public var decisions: [ItemDecision]
    public var schedule: OperationSchedule
    public var conflicts: [ConflictDecision]
    public var waiting: [WaitingItem]
    public private(set) var gate: ExecutionGate
    public var fingerprint: PlanFingerprint

    public var legacyActions: [SyncAction]
    public var legacyWarnings: [SyncWarning]

    public init(
        syncSetID: UUID,
        generatedAt: Date,
        decisions: [ItemDecision],
        schedule: OperationSchedule,
        conflicts: [ConflictDecision] = [],
        waiting: [WaitingItem] = [],
        gate: ExecutionGate,
        fingerprint: PlanFingerprint,
        legacyActions: [SyncAction] = [],
        legacyWarnings: [SyncWarning] = []
    ) {
        self.syncSetID = syncSetID
        self.generatedAt = generatedAt
        self.decisions = decisions
        self.schedule = schedule
        self.conflicts = conflicts
        self.waiting = waiting
        self.gate = gate
        self.fingerprint = fingerprint
        self.legacyActions = legacyActions
        self.legacyWarnings = legacyWarnings

        assert((try? schedule.validate(decisions: decisions)) != nil)
    }

    public var isAutoExecutable: Bool {
        gate.isClear
    }

    public func addingHolds(_ reasons: [HoldReason]) -> SyncPlan {
        var copy = self
        copy.gate = gate.addingHolds(reasons)
        return copy
    }
}

public struct ItemDecision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: SyncPath
    public var verdict: ItemVerdict
    public var operations: [OperationID]
    public var explanation: String

    public init(
        id: UUID,
        path: SyncPath,
        verdict: ItemVerdict,
        operations: [OperationID],
        explanation: String
    ) {
        self.id = id
        self.path = path
        self.verdict = verdict
        self.operations = operations
        self.explanation = explanation
    }
}

public struct WaitingItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: SyncPath
    public var reason: WaitingReason
    public var locations: [LocationID]

    public init(id: UUID, path: SyncPath, reason: WaitingReason, locations: [LocationID]) {
        self.id = id
        self.path = path
        self.reason = reason
        self.locations = locations.sorted()
    }
}
