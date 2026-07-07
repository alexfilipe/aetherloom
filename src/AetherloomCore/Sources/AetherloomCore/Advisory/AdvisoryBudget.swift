import Foundation

public struct AdvisoryBudget: Codable, Hashable, Sendable {
    public var perConflictSeconds: TimeInterval
    public var perPreparationSeconds: TimeInterval
    public var timeoutMode: AdvisoryTimeoutMode

    public init(
        perConflictSeconds: TimeInterval = 3,
        perPreparationSeconds: TimeInterval = 10,
        timeoutMode: AdvisoryTimeoutMode = .wallClock
    ) {
        self.perConflictSeconds = perConflictSeconds
        self.perPreparationSeconds = perPreparationSeconds
        self.timeoutMode = timeoutMode
    }

    public static let `default` = AdvisoryBudget()
}

public enum AdvisoryTimeoutMode: String, Codable, Hashable, Sendable {
    case wallClock
    case immediateAfterYield
}
