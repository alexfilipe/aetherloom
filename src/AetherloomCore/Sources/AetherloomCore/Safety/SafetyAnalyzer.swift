import Foundation

public struct SafetyAnalyzer: Sendable {
    public init() {}

    public func analyze(
        plan: SyncPlan,
        trackedItemCount: Int,
        settings: SyncSettings
    ) -> SyncPlan {
        var updated = plan
        let trashCount = updated.actions.filter(\.isTrashAction).count
        let overwriteCount = updated.actions.filter(\.isOverwriteAction).count
        let denominator = max(trackedItemCount, 1)

        if exceeds(
            count: trashCount,
            denominator: denominator,
            absoluteThreshold: settings.thresholds.massDeleteAbsolute,
            ratioThreshold: settings.thresholds.massDeleteRatio
        ) {
            updated.warnings.append(
                SyncWarning(
                    severity: .pause,
                    message: "Aetherloom found many deletions. This may be intentional, but sync is paused until you review it."
                )
            )
            updated.actions.insert(.pause(reason: "Paused for safety after detecting \(trashCount) delete actions."), at: 0)
        }

        if exceeds(
            count: overwriteCount,
            denominator: denominator,
            absoluteThreshold: settings.thresholds.massEditAbsolute,
            ratioThreshold: settings.thresholds.massEditRatio
        ) {
            updated.warnings.append(
                SyncWarning(
                    severity: .pause,
                    message: "Aetherloom found many edits. This may be intentional, but sync is paused until you review it."
                )
            )
            updated.actions.insert(.pause(reason: "Paused for safety after detecting \(overwriteCount) edit actions."), at: 0)
        }

        updated.riskLevel = Self.riskLevel(for: updated)
        updated.isAutoExecutable = Self.isAutoExecutable(updated)
        return updated
    }

    public static func riskLevel(for plan: SyncPlan) -> SyncRiskLevel {
        if plan.actions.contains(where: \.isPauseAction) || plan.warnings.contains(where: { $0.severity == .pause }) {
            return .paused
        }
        if !plan.conflicts.isEmpty || plan.warnings.contains(where: { $0.severity == .needsReview }) {
            return .needsReview
        }
        return .safe
    }

    public static func isAutoExecutable(_ plan: SyncPlan) -> Bool {
        riskLevel(for: plan) == .safe
    }

    private func exceeds(
        count: Int,
        denominator: Int,
        absoluteThreshold: Int,
        ratioThreshold: Double
    ) -> Bool {
        guard count > 0 else { return false }
        let exceedsAbsoluteThreshold = count >= absoluteThreshold
        let exceedsRatioThreshold = denominator >= absoluteThreshold && Double(count) / Double(denominator) >= ratioThreshold
        return exceedsAbsoluteThreshold || exceedsRatioThreshold
    }
}

extension SyncAction {
    public var isPauseAction: Bool {
        if case .pause = self { return true }
        return false
    }

    public var isTrashAction: Bool {
        if case .trash = self { return true }
        return false
    }

    public var isOverwriteAction: Bool {
        if case .overwrite = self { return true }
        return false
    }
}
