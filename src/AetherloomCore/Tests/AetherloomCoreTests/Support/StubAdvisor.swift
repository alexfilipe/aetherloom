import Foundation
@testable import AetherloomCore

actor StubAdvisor: ConflictAdvisor {
    nonisolated let descriptor: AdvisorDescriptor

    private let adviceHandler: @Sendable (ConflictAdvisoryRequest, AdvisorDescriptor) async -> ConflictAdvice?
    private let triageHandler: @Sendable (HoldTriageRequest, AdvisorDescriptor) async -> HoldTriageNote?
    private var adviceCallCount = 0
    private var triageCallCount = 0
    private var capturedRequests: [ConflictAdvisoryRequest] = []
    private var capturedTriageRequests: [HoldTriageRequest] = []

    init(
        descriptor: AdvisorDescriptor = AdvisorDescriptor(name: "Stub Advisor", backend: "stub"),
        advice: @escaping @Sendable (ConflictAdvisoryRequest, AdvisorDescriptor) async -> ConflictAdvice?,
        triage: @escaping @Sendable (HoldTriageRequest, AdvisorDescriptor) async -> HoldTriageNote? = { _, _ in nil }
    ) {
        self.descriptor = descriptor
        self.adviceHandler = advice
        self.triageHandler = triage
    }

    static func canned(
        rationale: String = "Keeping both versions is safest.",
        recommendation: ConflictResolutionOption = .keepBoth,
        confidence: AdviceConfidence = .low,
        generatedAt: Date
    ) -> StubAdvisor {
        StubAdvisor { request, descriptor in
            ConflictAdvice(
                conflictID: request.conflict.id,
                recommended: recommendation,
                confidence: confidence,
                rationale: rationale,
                generatedBy: descriptor,
                generatedAt: generatedAt
            )
        }
    }

    static func unavailable() -> StubAdvisor {
        StubAdvisor { _, _ in nil }
    }

    static func slow() -> StubAdvisor {
        StubAdvisor { _, _ in
            while !Task.isCancelled {
                await Task.yield()
            }
            return nil
        }
    }

    func advise(on request: ConflictAdvisoryRequest) async -> ConflictAdvice? {
        adviceCallCount += 1
        capturedRequests.append(request)
        return await adviceHandler(request, descriptor)
    }

    func triage(_ request: HoldTriageRequest) async -> HoldTriageNote? {
        triageCallCount += 1
        capturedTriageRequests.append(request)
        return await triageHandler(request, descriptor)
    }

    func adviceCalls() -> Int {
        adviceCallCount
    }

    func triageCalls() -> Int {
        triageCallCount
    }

    func requests() -> [ConflictAdvisoryRequest] {
        capturedRequests
    }

    func triageRequests() -> [HoldTriageRequest] {
        capturedTriageRequests
    }
}
