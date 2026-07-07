import Foundation

public enum AdviceValidationRejection: String, Codable, Hashable, Sendable {
    case conflictIDMismatch
    case recommendedOptionUnavailable
    case emptyRationale
    case rationaleTooLong
    case disallowedRationaleContent
    case noteForUninvolvedLocation
    case emptyLocationNote
    case locationNoteTooLong
    case disallowedLocationNoteContent
    case holdReasonMismatch
    case emptyTriageSummary
    case triageSummaryTooLong
    case disallowedTriageContent
    case triageRecommendsApproval
}

public enum AdviceValidationResult<Value: Sendable>: Sendable {
    case accepted(Value)
    case rejected(AdviceValidationRejection)

    public var value: Value? {
        if case let .accepted(value) = self {
            return value
        }
        return nil
    }

    public var rejection: AdviceValidationRejection? {
        if case let .rejected(reason) = self {
            return reason
        }
        return nil
    }
}

public struct AdviceValidator: Sendable {
    public static let rationaleLimit = 280
    public static let locationNoteLimit = 160

    public init() {}

    public func validate(
        _ advice: ConflictAdvice,
        for request: ConflictAdvisoryRequest
    ) -> AdviceValidationResult<ConflictAdvice> {
        guard advice.conflictID == request.conflict.id else {
            return .rejected(.conflictIDMismatch)
        }
        guard request.options.contains(advice.recommended) else {
            return .rejected(.recommendedOptionUnavailable)
        }

        switch validateText(advice.rationale, limit: Self.rationaleLimit) {
        case let .accepted(rationale):
            var normalized = advice
            normalized.rationale = rationale

            let noteResult = validateNotes(advice.perVersionNotes, for: request)
            switch noteResult {
            case let .accepted(notes):
                normalized.perVersionNotes = notes
                return .accepted(normalized)
            case let .rejected(reason):
                return .rejected(reason)
            }

        case .rejected(.emptyLocationNote):
            return .rejected(.emptyRationale)
        case .rejected(.locationNoteTooLong):
            return .rejected(.rationaleTooLong)
        case .rejected(.disallowedLocationNoteContent):
            return .rejected(.disallowedRationaleContent)
        case let .rejected(reason):
            return .rejected(reason)
        }
    }

    public func validate(
        _ note: HoldTriageNote,
        for request: HoldTriageRequest
    ) -> AdviceValidationResult<HoldTriageNote> {
        guard note.syncSetID == request.syncSetID, note.holdReason == request.holdReason else {
            return .rejected(.holdReasonMismatch)
        }

        let normalizedSummary = normalizedWhitespace(note.summary)
        guard !normalizedSummary.isEmpty else {
            return .rejected(.emptyTriageSummary)
        }
        guard normalizedSummary.count <= Self.rationaleLimit else {
            return .rejected(.triageSummaryTooLong)
        }
        guard !containsDisallowedMarkup(normalizedSummary) else {
            return .rejected(.disallowedTriageContent)
        }
        guard !recommendsApproval(normalizedSummary) else {
            return .rejected(.triageRecommendsApproval)
        }

        var normalized = note
        normalized.summary = normalizedSummary
        return .accepted(normalized)
    }

    public func normalizedWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func validateNotes(
        _ notes: [LocationID: String]?,
        for request: ConflictAdvisoryRequest
    ) -> AdviceValidationResult<[LocationID: String]?> {
        guard let notes else {
            return .accepted(nil)
        }
        let involvedLocations = Set(request.conflict.locations)
        var normalized: [LocationID: String] = [:]
        for (location, note) in notes {
            guard involvedLocations.contains(location) else {
                return .rejected(.noteForUninvolvedLocation)
            }
            switch validateText(note, limit: Self.locationNoteLimit) {
            case let .accepted(text):
                normalized[location] = text
            case let .rejected(reason):
                return .rejected(reason)
            }
        }
        return .accepted(normalized.isEmpty ? nil : normalized)
    }

    private func validateText(_ text: String, limit: Int) -> AdviceValidationResult<String> {
        let normalized = normalizedWhitespace(text)
        guard !normalized.isEmpty else {
            return .rejected(.emptyLocationNote)
        }
        guard normalized.count <= limit else {
            return .rejected(.locationNoteTooLong)
        }
        guard !containsDisallowedMarkup(normalized) else {
            return .rejected(.disallowedLocationNoteContent)
        }
        return .accepted(normalized)
    }

    private func containsDisallowedMarkup(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("http") || text.contains("](") || text.contains("`")
    }

    private func recommendsApproval(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("approve")
            || lowercased.contains("approval")
            || lowercased.contains("sync now")
    }
}
