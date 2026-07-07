import Foundation

public struct HeuristicConflictAdvisor: ConflictAdvisor {
    public var descriptor: AdvisorDescriptor
    private let generatedAt: Date
    private let validator: AdviceValidator

    public init(
        descriptor: AdvisorDescriptor = .heuristic,
        generatedAt: Date = Date(timeIntervalSince1970: 0),
        validator: AdviceValidator = AdviceValidator()
    ) {
        self.descriptor = descriptor
        self.generatedAt = generatedAt
        self.validator = validator
    }

    public func advise(on request: ConflictAdvisoryRequest) async -> ConflictAdvice? {
        let advice = rawAdvice(for: request)
        return validator.validate(advice, for: request).value
    }

    public func triage(_ request: HoldTriageRequest) async -> HoldTriageNote? {
        let note = HoldTriageNote(
            syncSetID: request.syncSetID,
            holdReason: request.holdReason,
            summary: triageSummary(for: request),
            generatedBy: descriptor,
            generatedAt: generatedAt
        )
        return validator.validate(note, for: request).value
    }

    private func rawAdvice(for request: ConflictAdvisoryRequest) -> ConflictAdvice {
        let versions = request.conflict.versions.sorted { $0.location < $1.location }
        if hasIdenticalKnownHashes(versions) {
            return makeAdvice(
                request: request,
                recommended: .keepBoth,
                confidence: .high,
                rationale: "Contents are identical, so keeping both versions preserves data while you review names or metadata."
            )
        }

        if let newer = newestVersionBeyondOneDay(versions) {
            return makeAdvice(
                request: request,
                recommended: .makeCanonical(newer.location),
                confidence: .medium,
                rationale: "The \(locationName(newer.location, request: request)) version was edited more than 24 hours later."
            )
        }

        if let nonEmpty = nonEmptyVersionWhenOthersAreZeroByte(versions) {
            return makeAdvice(
                request: request,
                recommended: .makeCanonical(nonEmpty.location),
                confidence: .medium,
                rationale: "The \(locationName(nonEmpty.location, request: request)) version has content while another version is zero bytes."
            )
        }

        return makeAdvice(
            request: request,
            recommended: .keepBoth,
            confidence: .low,
            rationale: "The metadata does not clearly identify a winner, so keeping both versions is safest."
        )
    }

    private func makeAdvice(
        request: ConflictAdvisoryRequest,
        recommended: ConflictResolutionOption,
        confidence: AdviceConfidence,
        rationale: String
    ) -> ConflictAdvice {
        ConflictAdvice(
            conflictID: request.conflict.id,
            recommended: recommended,
            confidence: confidence,
            rationale: rationale,
            perVersionNotes: versionNotes(for: request.conflict.versions),
            generatedBy: descriptor,
            generatedAt: generatedAt
        )
    }

    private func versionNotes(for versions: [ConflictVersion]) -> [LocationID: String]? {
        let notes = Dictionary(uniqueKeysWithValues: versions.map { version in
            (version.location, note(for: version.observation.version))
        })
        return notes.isEmpty ? nil : notes
    }

    private func note(for version: ItemVersion) -> String {
        var parts: [String] = []
        if let size = version.size {
            parts.append("\(size) bytes")
        }
        if let modifiedAt = version.modifiedAt {
            parts.append("modified \(CanonicalCoding.dateString(modifiedAt))")
        }
        if let contentHash = version.contentHash {
            parts.append("hash \(contentHash)")
        }
        return parts.isEmpty ? "Metadata is limited." : parts.joined(separator: ", ")
    }

    private func triageSummary(for request: HoldTriageRequest) -> String {
        let groupText = request.evidence.groups
            .map { "all \($0.intentCount) under \($0.ancestor.rawValue)" }
            .joined(separator: ", ")
        let shape = groupText.isEmpty ? "\(request.evidence.intentCount) items" : groupText
        switch request.holdReason {
        case .massDeletion:
            return "\(shape) changed together. This may be intentional, but review is still required before any trash moves."
        case .massEdit:
            return "\(shape) were edited together. This may be intentional, but review is still required before syncing them."
        case .conflicts, .deletionsNeedReview:
            return "\(request.evidence.intentCount) changes need review."
        }
    }

    private func hasIdenticalKnownHashes(_ versions: [ConflictVersion]) -> Bool {
        let hashes = versions.compactMap(\.observation.version.contentHash)
        return hashes.count == versions.count && Set(hashes).count == 1
    }

    private func newestVersionBeyondOneDay(_ versions: [ConflictVersion]) -> ConflictVersion? {
        let dated = versions.compactMap { version -> (ConflictVersion, Date)? in
            guard let modifiedAt = version.observation.version.modifiedAt else {
                return nil
            }
            return (version, modifiedAt)
        }
        guard dated.count >= 2,
              let oldest = dated.map(\.1).min(),
              let newest = dated.max(by: { lhs, rhs in
                  if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                  return lhs.0.location < rhs.0.location
              }),
              newest.1.timeIntervalSince(oldest) > 24 * 60 * 60 else {
            return nil
        }
        return newest.0
    }

    private func nonEmptyVersionWhenOthersAreZeroByte(_ versions: [ConflictVersion]) -> ConflictVersion? {
        let sized = versions.filter { $0.observation.kind == .file && $0.observation.version.size != nil }
        let nonEmpty = sized.filter { ($0.observation.version.size ?? 0) > 0 }
        let zeroByte = sized.filter { $0.observation.version.size == 0 }
        guard nonEmpty.count == 1, !zeroByte.isEmpty else {
            return nil
        }
        return nonEmpty.first
    }

    private func locationName(_ location: LocationID, request: ConflictAdvisoryRequest) -> String {
        request.locationNames[location] ?? location.displayName
    }
}
