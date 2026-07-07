import Foundation

public struct PlanApproval: Codable, Hashable, Sendable {
    public var planFingerprint: PlanFingerprint
    public var approvedAt: Date
    public var expiresAt: Date
    public var acknowledgedTrashCount: Int
    public var acknowledgedConflictCount: Int

    public init(
        planFingerprint: PlanFingerprint,
        approvedAt: Date,
        expiresAt: Date? = nil,
        acknowledgedTrashCount: Int,
        acknowledgedConflictCount: Int
    ) {
        self.planFingerprint = planFingerprint
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt ?? approvedAt.addingTimeInterval(15 * 60)
        self.acknowledgedTrashCount = acknowledgedTrashCount
        self.acknowledgedConflictCount = acknowledgedConflictCount
    }

    public func validate(against plan: SyncPlan, at now: Date) -> ApprovalValidation {
        guard planFingerprint == plan.fingerprint else {
            return .rejected(.wrongFingerprint)
        }
        guard now <= expiresAt else {
            return .rejected(.expired)
        }
        let trashCount = plan.approvalTrashCount
        guard acknowledgedTrashCount == trashCount else {
            return .rejected(.trashCountMismatch(expected: trashCount, actual: acknowledgedTrashCount))
        }
        let conflictCount = plan.approvalConflictCount
        guard acknowledgedConflictCount == conflictCount else {
            return .rejected(.conflictCountMismatch(expected: conflictCount, actual: acknowledgedConflictCount))
        }
        return .accepted
    }
}

public enum ApprovalValidation: Codable, Hashable, Sendable {
    case accepted
    case rejected(ApprovalRejectionReason)
}

public enum ApprovalRejectionReason: Codable, Hashable, Sendable {
    case wrongFingerprint
    case expired
    case trashCountMismatch(expected: Int, actual: Int)
    case conflictCountMismatch(expected: Int, actual: Int)
}

extension SyncPlan {
    public var approvalTrashCount: Int {
        decisions.filter { decision in
            decision.operations.contains { operationID in
                schedule.operations.contains { operation in
                    operation.id == operationID && operation.kind.isTrash
                }
            }
        }.count
    }

    public var approvalConflictCount: Int {
        conflicts.count
    }
}
