import Foundation

public protocol ConflictAdvisor: Sendable {
    var descriptor: AdvisorDescriptor { get }

    func advise(on request: ConflictAdvisoryRequest) async -> ConflictAdvice?
    func triage(_ request: HoldTriageRequest) async -> HoldTriageNote?
}

public extension ConflictAdvisor {
    func triage(_: HoldTriageRequest) async -> HoldTriageNote? {
        nil
    }
}

public struct AdvisorDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var backend: String
    public var modelIdentifier: String?

    public init(name: String, backend: String, modelIdentifier: String? = nil) {
        self.name = name
        self.backend = backend
        self.modelIdentifier = modelIdentifier
    }

    public static let heuristic = AdvisorDescriptor(
        name: "Aetherloom Heuristic Advisor",
        backend: "heuristic",
        modelIdentifier: nil
    )
}

public enum AdviceConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum ConflictResolutionOption: Codable, Hashable, Sendable {
    case keepBoth
    case makeCanonical(LocationID)

    public init(_ resolution: ConflictDecision.Resolution) {
        switch resolution {
        case .preserveAll:
            self = .keepBoth
        case let .makeCanonical(location):
            self = .makeCanonical(location)
        }
    }

    public var resolution: ConflictDecision.Resolution {
        switch self {
        case .keepBoth:
            return .preserveAll
        case let .makeCanonical(location):
            return .makeCanonical(location)
        }
    }

    public static func options(for conflict: ConflictDecision) -> [ConflictResolutionOption] {
        [.keepBoth] + conflict.locations.map { .makeCanonical($0) }
    }
}

public struct ConflictAdvisoryRequest: Codable, Hashable, Sendable {
    public var conflict: ConflictDecision
    public var options: [ConflictResolutionOption]
    public var locationNames: [LocationID: String]
    public var contentExcerpts: [LocationID: String]?

    public init(
        conflict: ConflictDecision,
        options: [ConflictResolutionOption]? = nil,
        locationNames: [LocationID: String] = [:],
        contentExcerpts: [LocationID: String]? = nil
    ) {
        self.conflict = conflict
        self.options = Self.normalizedOptions(options ?? ConflictResolutionOption.options(for: conflict))
        self.locationNames = locationNames
        self.contentExcerpts = contentExcerpts
    }

    private static func normalizedOptions(_ options: [ConflictResolutionOption]) -> [ConflictResolutionOption] {
        var result: [ConflictResolutionOption] = [.keepBoth]
        for option in options where option != .keepBoth && !result.contains(option) {
            result.append(option)
        }
        return result
    }
}

public struct ConflictAdvice: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { conflictID }

    public var conflictID: UUID
    public var recommended: ConflictResolutionOption
    public var confidence: AdviceConfidence
    public var rationale: String
    public var perVersionNotes: [LocationID: String]?
    public var generatedBy: AdvisorDescriptor
    public var generatedAt: Date

    public init(
        conflictID: UUID,
        recommended: ConflictResolutionOption,
        confidence: AdviceConfidence,
        rationale: String,
        perVersionNotes: [LocationID: String]? = nil,
        generatedBy: AdvisorDescriptor,
        generatedAt: Date
    ) {
        self.conflictID = conflictID
        self.recommended = recommended
        self.confidence = confidence
        self.rationale = rationale
        self.perVersionNotes = perVersionNotes
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }
}

public struct HoldTriageRequest: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var holdReason: HoldReason
    public var evidence: MassChangeEvidence
    public var locationNames: [LocationID: String]

    public init?(
        syncSetID: UUID,
        holdReason: HoldReason,
        locationNames: [LocationID: String] = [:]
    ) {
        guard let evidence = holdReason.massChangeEvidence else {
            return nil
        }
        self.syncSetID = syncSetID
        self.holdReason = holdReason
        self.evidence = evidence
        self.locationNames = locationNames
    }
}

public struct HoldTriageNote: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var holdReason: HoldReason
    public var summary: String
    public var generatedBy: AdvisorDescriptor
    public var generatedAt: Date

    public init(
        syncSetID: UUID,
        holdReason: HoldReason,
        summary: String,
        generatedBy: AdvisorDescriptor,
        generatedAt: Date
    ) {
        self.syncSetID = syncSetID
        self.holdReason = holdReason
        self.summary = summary
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }
}

extension HoldReason {
    var massChangeEvidence: MassChangeEvidence? {
        switch self {
        case let .massDeletion(evidence), let .massEdit(evidence):
            return evidence
        case .conflicts, .deletionsNeedReview:
            return nil
        }
    }
}
