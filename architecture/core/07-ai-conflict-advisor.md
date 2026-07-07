# 07 — On-Device AI Conflict Advisor

When a plan is held, the user's real question is *which version do I keep?* The advisor answers it faster using **local, Apple-Silicon, on-device** inference — inside an architecture that makes harming data impossible rather than merely discouraged.

## 1. Hard boundaries (the feature's definition; violating any is a design bug)

1. **Advisory only.** Output is text plus a ranking over options the engine already enumerated as safe. It cannot create/modify/reorder operations, change a gate, resolve a `ConflictDecision`, or satisfy/substitute a `PlanApproval`. The type system enforces this: advisory types simply do not appear in planning or execution signatures.
2. **Closed option vocabulary.** The advisor picks among engine-provided options (`keepBoth`, `makeCanonical(LocationID)`). Never free-form actions or paths. Malformed output is discarded.
3. **On-device only.** No network. If no local model is available, degrade to deterministic heuristics or to nothing.
4. **Metadata by default; content by consent.** Default evidence: names, sizes, dates, hashes, location names. Text excerpts (≤ 4 KB, UTF-8) require an explicit per-feature opt-in that no current code path sets — the field exists, nothing populates it yet.
5. **Optional everywhere.** `advisor == nil` leaves the engine byte-identically functional; core tests never load a model.
6. **Fail closed and quiet.** Timeout, unavailability, low confidence, schema violation ⇒ no advice. Absence of advice is a supported state, not an error.

## 2. Module layout

```text
src/AetherloomCore/Sources/AetherloomCore/Advisory/   zero ML imports — protocol, types, validator, heuristics
src/AetherloomCore/Sources/AetherloomIntelligence/     separate SPM target, depends on AetherloomCore;
                                  the ONLY place FoundationModels (or later MLX) is imported;
                                  compiles to an empty module where unavailable (#if canImport)
```

## 3. Contract

```swift
public protocol ConflictAdvisor: Sendable {
    var descriptor: AdvisorDescriptor { get }                       // name, backend, model id — for attribution
    func advise(on request: ConflictAdvisoryRequest) async -> ConflictAdvice?
    func triage(_ request: HoldTriageRequest) async -> HoldTriageNote?
}

public struct ConflictAdvisoryRequest: Codable, Hashable, Sendable {
    public var conflict: ConflictDecision                           // [03 §4] — metadata only
    public var options: [ConflictResolutionOption]                  // closed; keepBoth always first
    public var locationNames: [LocationID: String]
    public var contentExcerpts: [LocationID: String]?               // opt-in; nil today by construction
}

public struct ConflictAdvice: Codable, Hashable, Sendable {
    public var conflictID: UUID
    public var recommended: ConflictResolutionOption
    public var confidence: AdviceConfidence                         // low | medium | high
    public var rationale: String                                    // 1–3 calm sentences, ≤ 280 chars
    public var perVersionNotes: [LocationID: String]?               // "Edited 2 days later", "Larger by 40 KB"
    public var generatedBy: AdvisorDescriptor
    public var generatedAt: Date
}
```

`HoldTriageRequest` wraps a hold's `MassChangeEvidence` ([04 §4]); the note explains shape, never recommends approval: "All 312 deletions are inside /Photos/2019, removed together on Google Drive — consistent with deleting one folder on purpose."

## 4. Backends

- **`HeuristicConflictAdvisor`** (core; deterministic; ships first; always available). Ordered rules: identical hashes → high `keepBoth` ("contents identical; names or metadata differ"); mtime gap > 24 h → medium `makeCanonical(newer)`; zero-byte vs non-empty → medium `makeCanonical(nonEmpty)`; else low `keepBoth`. Pure function of the request — exact-equality testable, and the reference implementation for pipeline tests.
- **`FoundationModelConflictAdvisor`** (`AetherloomIntelligence`; primary AI backend). Apple FoundationModels, macOS 26+: availability-checked (`SystemLanguageModel.default.availability`); fresh session per request (no cross-conflict leakage); **guided generation** with a `@Generable` response whose recommendation is an *index into the request's numbered options* — the model can't name paths or invent actions even syntactically; low temperature; system instructions demand calm tone, honesty about uncertainty, and keep-both-when-unsure. Output still passes the validator.
- **`MLXConflictAdvisor`** (later; user-supplied local models on machines without FoundationModels). Documented so the protocol stays backend-neutral; out of scope now.

## 5. Validation, budget, cache, logging

- **`AdviceValidator`** (core; applied to every backend): recommendation ∈ request options; rationale non-empty, ≤ 280 chars, no markdown/URLs; notes only for involved locations; whitespace normalized. Failure ⇒ `nil` + one `advisory` log entry.
- **Budget:** per-conflict 3 s, per-preparation 10 s (both injectable); advice runs strictly after plan/preview exist, so it can delay nothing on the safety path; over-budget conflicts get no advice.
- **Cache:** keyed `(conflictID, version signatures, advisor descriptor)` via `AdviceCacheStore` ([09]) — reopening a preview never re-runs inference.
- **Logging:** every shown suggestion logs `advisory` with attribution: "Aetherloom suggested keeping the version from ⟨location⟩ (edited most recently). Both versions remain preserved." UI labels advice as a suggestion and never preselects destructive follow-ups from it.

## 6. Testing

- Pipeline invariant test: with `advisor == nil` vs a `StubAdvisor`, the `PlanOutcome` is byte-identical; advice changes preview annotations only.
- Malformed / slow / unavailable stub responses ⇒ discarded / timed out / silent, each with the right `advisory` log entry.
- Heuristics: exact-equality per rule + precedence.
- `AetherloomIntelligence` behavioral tests: opt-in via `AETHERLOOM_ENABLE_MODEL_TESTS=1`; assert schema and boundary compliance only, never specific prose; skipped (not failed) by default.

## 7. Changing the current code

Phase 8 of [11-migration.md](11-migration.md): all-new code; `Package.swift` gains the `AetherloomIntelligence` target. Two greps stay clean forever: `import FoundationModels|CoreML|MLX` in `src/AetherloomCore/Sources/AetherloomCore` → nothing; `URLSession` in both targets → nothing.
