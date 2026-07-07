import AetherloomCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
public struct FoundationModelConflictAdvisor: ConflictAdvisor {
    public var descriptor: AdvisorDescriptor
    private let generatedAt: @Sendable () -> Date
    private let validator: AdviceValidator

    public init(
        descriptor: AdvisorDescriptor = AdvisorDescriptor(
            name: "Apple Foundation Models",
            backend: "FoundationModels",
            modelIdentifier: "SystemLanguageModel.default"
        ),
        generatedAt: @escaping @Sendable () -> Date,
        validator: AdviceValidator = AdviceValidator()
    ) {
        self.descriptor = descriptor
        self.generatedAt = generatedAt
        self.validator = validator
    }

    public func advise(on request: ConflictAdvisoryRequest) async -> ConflictAdvice? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: prompt(for: request),
                generating: FoundationModelAdviceResponse.self,
                options: GenerationOptions(temperature: 0.1)
            )
            guard request.options.indices.contains(response.content.recommendedOptionIndex) else {
                return nil
            }
            let advice = ConflictAdvice(
                conflictID: request.conflict.id,
                recommended: request.options[response.content.recommendedOptionIndex],
                confidence: AdviceConfidence(rawValue: response.content.confidence) ?? .low,
                rationale: response.content.rationale,
                perVersionNotes: response.content.notes?.reduce(into: [LocationID: String]()) { result, note in
                    if request.conflict.locations.indices.contains(note.locationIndex) {
                        result[request.conflict.locations[note.locationIndex]] = note.text
                    }
                },
                generatedBy: descriptor,
                generatedAt: generatedAt()
            )
            return validator.validate(advice, for: request).value
        } catch {
            return nil
        }
    }

    public func triage(_ request: HoldTriageRequest) async -> HoldTriageNote? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(
                to: triagePrompt(for: request),
                generating: FoundationModelTriageResponse.self,
                options: GenerationOptions(temperature: 0.1)
            )
            let note = HoldTriageNote(
                syncSetID: request.syncSetID,
                holdReason: request.holdReason,
                summary: response.content.summary,
                generatedBy: descriptor,
                generatedAt: generatedAt()
            )
            return validator.validate(note, for: request).value
        } catch {
            return nil
        }
    }

    private static let instructions = """
    You are Aetherloom's on-device conflict advisor. Recommend only one of the numbered options provided by the engine. Keep both versions when uncertain. Use calm, concise language. Never recommend approval, deletion, network access, or any action outside the provided options.
    """

    private func prompt(for request: ConflictAdvisoryRequest) -> String {
        let options = request.options.enumerated().map { index, option in
            "\(index): \(optionText(option, locationNames: request.locationNames))"
        }.joined(separator: "\n")
        let versions = request.conflict.versions.enumerated().map { index, version in
            "\(index): \(request.locationNames[version.location] ?? version.location.displayName), size \(version.observation.version.size.map(String.init) ?? "unknown"), modified \(version.observation.version.modifiedAt.map(Self.dateString) ?? "unknown"), hash \(version.observation.version.contentHash ?? "unknown")"
        }.joined(separator: "\n")
        return """
        Conflict ID: \(request.conflict.id.uuidString)
        Path: \(request.conflict.path.rawValue)
        Options:
        \(options)
        Versions:
        \(versions)
        Choose the option index only from the numbered options.
        """
    }

    private func triagePrompt(for request: HoldTriageRequest) -> String {
        let groups = request.evidence.groups.map { "all \($0.intentCount) under \($0.ancestor.rawValue)" }.joined(separator: ", ")
        return """
        A sync plan is held for review.
        Changed item count: \(request.evidence.intentCount)
        Tracked item count: \(request.evidence.trackedCount)
        Groups: \(groups)
        Summarize the shape of this hold. Do not recommend approval.
        """
    }

    private func optionText(_ option: ConflictResolutionOption, locationNames: [LocationID: String]) -> String {
        switch option {
        case .keepBoth:
            return "Keep both versions"
        case let .makeCanonical(location):
            return "Make \(locationNames[location] ?? location.displayName) canonical"
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationModelAdviceResponse {
    @Guide(description: "The zero-based index of the recommended engine-provided option.")
    var recommendedOptionIndex: Int

    @Guide(description: "One of: low, medium, high.")
    var confidence: String

    @Guide(description: "One to three calm sentences, at most 280 characters, with no markdown or URLs.")
    var rationale: String

    @Guide(description: "Optional notes keyed by zero-based version index.")
    var notes: [FoundationModelVersionNote]?
}

@available(macOS 26.0, *)
@Generable
private struct FoundationModelVersionNote {
    @Guide(description: "The zero-based index of the conflict version.")
    var locationIndex: Int

    @Guide(description: "A short metadata-only note with no markdown or URLs.")
    var text: String
}

@available(macOS 26.0, *)
@Generable
private struct FoundationModelTriageResponse {
    @Guide(description: "A calm metadata-only summary of the hold shape. Do not recommend approval.")
    var summary: String
}
#endif
