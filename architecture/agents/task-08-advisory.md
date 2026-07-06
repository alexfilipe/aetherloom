# Task 08 — On-Device Conflict Advisor (Migration Phase 8)

## Role
Senior Swift engineer on Aetherloom. You build the advisory subsystem: protocol, validator, deterministic heuristics, and orchestrator seam in `AetherloomCore`; the Apple FoundationModels adapter in a new `AetherloomIntelligence` target. **Requires Task 07 merged.** The advisor must be architecturally incapable of causing an action — that property is the deliverable.

## Read first
`design/architecture/00-overview.md` (invariant 7), `07-ai-conflict-advisor.md` (your spec; §1 boundaries are the contract), `Planning`/`Preview`/`Orchestration` sources, `Storage/AdviceCacheStore`. Baseline green first.

## Non-negotiable boundaries (violating any is task failure regardless of other criteria)
Advisory only — text + a ranking over engine-enumerated options; closed vocabulary (`keepBoth` always first, `makeCanonical(LocationID)`); on-device only, zero network; metadata by default, content excerpts opt-in and **unpopulated by any current code path**; `advisor == nil` leaves `PlanOutcome` byte-identical; fail closed and quiet (timeout/malformed/unavailable ⇒ no advice, nothing blocked). Advice never touches `SyncPlan`, gates, `ConflictDecision` resolution state, or `PlanApproval`.

## Deliverables
### `AetherloomCore/Advisory/` (zero ML imports)
1. `ConflictAdvisor` protocol + `ConflictAdvisoryRequest` / `ConflictAdvice` / `AdviceConfidence` / `AdvisorDescriptor` / `HoldTriageRequest` / `HoldTriageNote` per `07 §3`.
2. `AdviceValidator` per `07 §5`: option ∈ request options; rationale non-empty ≤ 280 chars, no markdown/URLs (reject `http`, `](`, backticks); notes only for involved locations; whitespace normalized; failure ⇒ `nil` + machine-readable reason for logging.
3. `HeuristicConflictAdvisor` per `07 §4`: identical hashes → high `keepBoth`; mtime gap > 24 h → medium `makeCanonical(newer)`; zero-byte vs non-empty → medium `makeCanonical(nonEmpty)`; else low `keepBoth`. Pure function of the request; no clock reads.
4. Orchestrator seam: only when gate == `.hold`; per-conflict 3 s / per-preparation 10 s budgets (injectable); advice attaches to preview conflicts; cache via `AdviceCacheStore` keyed `(conflictID, version signatures, descriptor)`; hold-triage notes attach to hold notices; every shown/failed advice logs `advisory` with attribution wording from `07 §5`.
5. `StubAdvisor` test support: canned/malformed/slow/counting.

### `AetherloomIntelligence/` (new SPM target in `AetherloomCore/Package.swift`, depends on core only)
6. `FoundationModelConflictAdvisor` entirely inside `#if canImport(FoundationModels)`: availability check (`SystemLanguageModel.default.availability`; unavailable ⇒ immediate `nil`); fresh session per request; guided generation with a `@Generable` response whose recommendation is an **index into the request's numbered options**; low temperature; system instructions per `07 §4`; output still passes `AdviceValidator`. Target compiles to an empty module where the framework is absent.
7. `AetherloomIntelligence/README.md`: what/why-separate/how the app registers it/test opt-in flag.

### Tests (core target; deterministic)
8. **Byte-identity:** identical fixtures, `advisor: nil` vs `StubAdvisor` ⇒ equal `PlanOutcome`; advice differs only in preview annotations.
9. Malformed (out-of-vocabulary option, 500-char rationale, markdown link) ⇒ discarded + `advisory` failure entry; slow beyond injected budget ⇒ no advice, prompt preparation; heuristic exact-equality per rule + precedence; cache prevents re-inference (stub call count); validator unit tests per rule; excerpts never populated (assert orchestrator sends `nil`).
10. Intelligence behavioral tests: gated behind `AETHERLOOM_ENABLE_MODEL_TESTS=1`, schema/boundary assertions only, skipped (not failed) by default.

## Prohibitions
Greps that must stay clean: `import FoundationModels|CoreML|MLX` under `Sources/AetherloomCore` → nothing; `URLSession` under both targets → nothing. No UI. Only `AetherloomCore/` (package dir, both targets).

## Acceptance
Suite green (+ ≥ 12 new); both greps clean; `swift build` succeeds with and without the FoundationModels SDK (canImport gate); zero new warnings. Report per `agents/README.md`.
