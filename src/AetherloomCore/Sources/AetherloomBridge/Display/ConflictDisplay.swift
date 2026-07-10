import AetherloomCore
import Foundation

public struct VersionDisplay: Sendable, Hashable, Identifiable {
    public var id: LocationID { location.id }
    public var location: LocationDisplay
    public var modifiedAt: Date?
    public var byteSize: Int64?
    public var isMostRecent: Bool

    public init(
        location: LocationDisplay,
        modifiedAt: Date?,
        byteSize: Int64?,
        isMostRecent: Bool
    ) {
        self.location = location
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
        self.isMostRecent = isMostRecent
    }
}

public struct AdviceVersionNoteDisplay: Sendable, Hashable, Identifiable {
    public var id: LocationID { location.id }
    public var location: LocationDisplay
    public var note: String

    public init(location: LocationDisplay, note: String) {
        self.location = location
        self.note = note
    }
}

public struct AdviceDisplay: Sendable, Hashable {
    public var recommendation: ConflictResolutionOption
    public var recommendationLabel: String
    public var confidence: AdviceConfidence
    public var rationale: String
    public var generatedByName: String
    public var generatedByBackend: String
    public var attribution: String
    public var perVersionNotes: [AdviceVersionNoteDisplay]

    public init(
        recommendation: ConflictResolutionOption,
        recommendationLabel: String,
        confidence: AdviceConfidence,
        rationale: String,
        generatedByName: String,
        generatedByBackend: String,
        attribution: String,
        perVersionNotes: [AdviceVersionNoteDisplay]
    ) {
        self.recommendation = recommendation
        self.recommendationLabel = recommendationLabel
        self.confidence = confidence
        self.rationale = rationale
        self.generatedByName = generatedByName
        self.generatedByBackend = generatedByBackend
        self.attribution = attribution
        self.perVersionNotes = perVersionNotes
    }
}

public struct ResolutionOptionDisplay: Sendable, Hashable, Identifiable {
    public var id: ConflictResolutionOption { option }
    public var option: ConflictResolutionOption
    public var label: String
    public var location: LocationDisplay?

    public init(option: ConflictResolutionOption, label: String, location: LocationDisplay?) {
        self.option = option
        self.label = label
        self.location = location
    }

    public var resolution: ConflictDecision.Resolution {
        option.resolution
    }
}

public struct ConflictDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var path: SyncPath
    public var message: String
    public var versions: [VersionDisplay]
    public var preservedCopyName: String?
    public var advice: AdviceDisplay?
    public var options: [ResolutionOptionDisplay]

    public init(
        id: UUID,
        path: SyncPath,
        message: String,
        versions: [VersionDisplay],
        preservedCopyName: String?,
        advice: AdviceDisplay?,
        options: [ResolutionOptionDisplay]
    ) {
        self.id = id
        self.path = path
        self.message = message
        self.versions = versions
        self.preservedCopyName = preservedCopyName
        self.advice = advice
        self.options = options
    }
}

public func conflictDisplay(
    for conflict: ConflictDecision,
    advice: ConflictAdvice?,
    locations: [LocationState],
    plan: SyncPlan? = nil
) -> ConflictDisplay {
    let locationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
    let newestDate = conflict.versions.compactMap(\.observation.version.modifiedAt).max()
    let versions = conflict.versions.map { version in
        VersionDisplay(
            location: locationDisplay(for: version.location, states: locationsByID),
            modifiedAt: version.observation.version.modifiedAt,
            byteSize: version.observation.version.size,
            isMostRecent: newestDate != nil && version.observation.version.modifiedAt == newestDate
        )
    }
    let options = ConflictResolutionOption.options(for: conflict).map { option in
        switch option {
        case .keepBoth:
            return ResolutionOptionDisplay(option: option, label: "Keep Both", location: nil)
        case let .makeCanonical(locationID):
            let location = locationDisplay(for: locationID, states: locationsByID)
            return ResolutionOptionDisplay(
                option: option,
                label: "Choose \(location.displayName)",
                location: location
            )
        }
    }
    return ConflictDisplay(
        id: conflict.id,
        path: conflict.path,
        message: conflict.message,
        versions: versions,
        preservedCopyName: preservedCopyName(for: conflict, plan: plan),
        advice: advice.map { adviceDisplay($0, states: locationsByID) },
        options: options
    )
}

private func adviceDisplay(
    _ advice: ConflictAdvice,
    states: [LocationID: LocationState]
) -> AdviceDisplay {
    AdviceDisplay(
        recommendation: advice.recommended,
        recommendationLabel: recommendationLabel(advice.recommended, states: states),
        confidence: advice.confidence,
        rationale: advice.rationale,
        generatedByName: advice.generatedBy.name,
        generatedByBackend: advice.generatedBy.backend,
        attribution: "Suggested on-device by \(advice.generatedBy.name)",
        perVersionNotes: (advice.perVersionNotes ?? [:])
            .map { locationID, note in
                AdviceVersionNoteDisplay(
                    location: locationDisplay(for: locationID, states: states),
                    note: note
                )
            }
            .sorted { $0.location.id < $1.location.id }
    )
}

private func recommendationLabel(
    _ recommendation: ConflictResolutionOption,
    states: [LocationID: LocationState]
) -> String {
    switch recommendation {
    case .keepBoth:
        return "Keep Both"
    case let .makeCanonical(locationID):
        return "Choose \(locationDisplay(for: locationID, states: states).displayName)"
    }
}

private func preservedCopyName(for conflict: ConflictDecision, plan: SyncPlan?) -> String? {
    guard let plan,
          let decision = plan.decisions.first(where: { $0.path == conflict.path && $0.hasConflictIntent })
    else {
        return nil
    }
    let operationIDs = Set(decision.operations)
    return plan.schedule.operations
        .filter { operationIDs.contains($0.id) }
        .compactMap { operation -> SyncPath? in
            guard case let .transfer(content, path, .neverOverwrite) = operation.kind,
                  path != content.path
            else {
                return nil
            }
            return path
        }
        .sorted()
        .first?
        .name
}
