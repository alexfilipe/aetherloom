import Foundation

public enum PlanOutcome: Codable, Hashable, Sendable {
    case refusal(SyncRefusal)
    case plan(SyncPlan)

    public var planValue: SyncPlan? {
        if case let .plan(plan) = self {
            return plan
        }
        return nil
    }

    public var refusalValue: SyncRefusal? {
        if case let .refusal(refusal) = self {
            return refusal
        }
        return nil
    }
}

public struct SyncRefusal: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var reasons: [RefusalReason]
    public var occurredAt: Date

    public init(syncSetID: UUID, reasons: [RefusalReason], occurredAt: Date) {
        self.syncSetID = syncSetID
        self.reasons = reasons
        self.occurredAt = occurredAt
    }

    public var messages: [String] {
        reasons.map(\.message)
    }
}

public enum RefusalReason: Codable, Hashable, Sendable {
    case locationUnavailable(LocationID, LocationUnavailabilityReason)
    case scanIncomplete(LocationID, detail: String)
    case baseStateUnreadable(detail: String)

    public var message: String {
        switch self {
        case .locationUnavailable:
            return ActivityMessageCatalog.providerUnavailable
        case .scanIncomplete:
            return ActivityMessageCatalog.scanIncomplete
        case .baseStateUnreadable:
            return ActivityMessageCatalog.baseStateUnreadable
        }
    }
}
