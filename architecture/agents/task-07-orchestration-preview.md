# Task 07 — Orchestration, Preview & Approval (Migration Phase 7)

## Role
Senior Swift engineer on `AetherloomCore`. You compose the whole pipeline into `SyncOrchestrator`, build the change preview and approval contract, and flip placeholder handling to item-level `waiting`. **Requires Tasks 01–06 merged.**

## Read first
`architecture/00-overview.md` (pipeline), `05-execution-and-orchestration.md` §1+§5, `06-preview-and-approval.md` (your specs), `11-migration.md §4.3`; all `Sources/`. Baseline green first.

## Invariants (override this prompt)
`prepare` mutates nothing at any provider. Refusals are unexecutable by type; held plans run only with a valid approval; approval never bypasses per-operation preconditions. Every decision appears exactly once in the preview. Gates never downgrade.

## Deliverables
1. `Orchestration/SyncOrchestrator.swift` per `05 §1`: actor; `init(locations:providers:stores:stage:advisor:environment:)` (declare the advisor seam as `(any ConflictAdvisor)?` only if Task 08 landed first; otherwise isolate the stage-5 hook in one private method with a `// Task 08 seam` note); `prepare(_:) -> SyncPreparation`; `execute(_:approval:) -> SyncRunSummary`. Stage checklist exactly as specified: recovery → availability (concurrent; any unavailable ⇒ refusal, **no scans run**) → scans (concurrent, per-location timeout default 120 s ⇒ synthesized unavailability) → pure reconcile/plan/gate → preview (+ persist conflicts) → execute → summary. Overlap guard (typed error, no queueing); cooperative cancellation; every stage bracketed by activity entries sharing `runID`; the full `08 §3` checklist emitted.
2. `Preview/ChangePreview.swift` + `ChangePreviewRenderer` per `06 §1`: fixed section order, decision-partition, trash-causality strings from `BaseRecord` (`"Deleted from ⟨location⟩ since last sync on ⟨date⟩…"`), waiting section, refusal/hold notices with canonical sentences and `MassChangeEvidence` groups. Pure and golden-testable.
3. `Preview/PlanApproval.swift` per `06 §3`: fingerprint binding, expiry (default +15 min), acknowledged trash/conflict counts; `validate(against:at:)`; enforcement at the executor's single gate choke point; acceptance logged as `safety` ("You approved N items to move to trash for '⟨set⟩'.").
4. Conflict resolution as **planning input** per `06 §2`: resolving `makeCanonical` records the choice via `ConflictStore`; the *next* `prepare` plans the winner's propagation; losers remain conflict copies.
5. **Placeholder flip** (`11-migration.md §4.3`): remove the whole-set placeholder refusal; row-13 `waiting` verdicts now flow through to the preview's waiting section. The old placeholder test keeps its no-trash assertion; its pause expectation becomes "item excluded and reported as waiting".
6. Tests: prepare-is-read-only (fake call logs); unavailable short-circuits before scan; timeout ⇒ refusal; end-to-end safe run (prepare → execute → records converge → second prepare plans zero decisions); held plan refuses without approval, runs with valid approval, **approved-but-drifted still aborts**; approval matrix (wrong fingerprint / expired / wrong counts / stray-ignored); preview partition property + golden previews incl. a refusal preview and a mass-delete hold with attribution; waiting-item run (placeholder present: rest syncs, waiting reported, zero trash); tombstone re-appearance ⇒ new file; overlap guard; activity checklist end-to-end.

## Prohibitions
No SwiftUI, no wiring the demo app; no advisory implementation (Phase 8) beyond the seam; the only behavior change allowed is the placeholder flip; only `src/AetherloomCore/`.

## Acceptance
Suite green (+ ≥ 14 new); `grep -n "Date()" src/AetherloomCore/Sources/AetherloomCore/Orchestration src/AetherloomCore/Sources/AetherloomCore/Preview` → nothing; a held plan cannot reach `apply` without validated approval (single choke point, test-asserted); zero new warnings. Report per `agents/README.md`, stating how the advisor seam was left.
