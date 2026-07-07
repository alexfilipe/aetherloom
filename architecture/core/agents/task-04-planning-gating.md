# Task 04 — Planning & Gating (Migration Phase 4)

## Role
Senior Swift engineer on `AetherloomCore`. You give the engine its outcome model — refusals, decision-shaped plans, operation schedules, gates, fingerprints — and delete the pause sentinel. **Requires Task 03 merged.**

## Read first
`architecture/core/00-overview.md`, `04-planning-and-gating.md` (your spec), `11-migration.md` (§2, §4 change 1); `Safety/SafetyAnalyzer.swift`, the Task-03 adapter, `Execution/SyncPlanExecutor.swift`, tests. Baseline green first.

## Invariants (override this prompt)
A refusal produces no executable plan and has no approval path. The gate is monotone — computed once, pure, never downgraded by anything. Thresholds can be tuned, never disabled. Schedule invariants ([04 §3] 1–4) hold for every constructible plan.

## Deliverables
1. `Plan/PlanOutcome.swift`: `PlanOutcome`, `SyncRefusal`, `RefusalReason` (`locationUnavailable`, `scanIncomplete`, `baseStateUnreadable`) per `04 §1`, with canonical sentences. The pre-reconciliation checks (missing/unavailable/incomplete snapshots; current whole-set placeholder pause) move here as refusal producers — reconciliation is only invoked on complete snapshots.
2. `Plan/SyncPlan.swift`: decisions + schedule + conflicts + waiting + gate + fingerprint per `04 §2`; `ItemDecision` with causal `explanation` strings.
3. `Plan/Operation.swift` + `OperationSchedule` + lowering per `04 §3`: `makeFolder`/`transfer(ContentRef,…)`/`relocate`/`trash` with typed `Precondition`s (`pathAbsent | versionMatches | folderPresent`); schedule builder + **validator** asserting: parents-first, global transfer-before-trash, per-item chains, no case-folded target collisions. Validator runs in tests and `assert` in debug.
4. `Plan/ExecutionGate.swift`: `clear | hold([HoldReason])`; `MassChangeEvidence` with **intent counting** (decisions vs tracked records — the sanctioned behavior change; update the two mass-change tests' expected counts and say so) and nearest-common-ancestor `ChangeGroup` attribution. `SyncMode` semantics: `askBeforeDeleting` ⇒ `deletionsNeedReview` hold; `noDeletePropagation` ⇒ informational decisions, zero trash operations. Delete `SafetyAnalyzer` after its math moves.
5. `Plan/PlanFingerprint.swift` per `04 §5`: SHA-256 (CryptoKit — Apple SDK, permitted) over the canonical encoding (one shared sorted-keys/ISO-8601 encoder factory — coordinate with Task 05's; if 05 hasn't landed, create it here in `Support/`).
6. Delete `SyncAction.pause` and `SyncRiskLevel`; map every consumer to refusal/hold checks (the compiler is your checklist).
7. **Adapter v2 (dies in Phase 6):** render `OperationSchedule` to the legacy executor's action list so executor tests keep passing.
8. Tests: refusal per unavailability/incomplete variant; corrupt-base-state refusal (stub store or precomputed flag if Task 05 pending); intent-counting topology test (same 30 deletions gate identically at 2 vs 4 locations); attribution groups; schedule-validator invariants (constructive + adversarial); fingerprint sensitivity/stability; gate monotonicity (no API can lower a hold).

## Prohibitions
No executor rebuild (Phase 6); no preview/approval (Phase 7) — but `PlanFingerprint` lands now; only behavior change allowed: threshold counting; only `src/AetherloomCore/`.

## Acceptance
Suite green (+ ≥ 10 new); `grep -rn "SyncRiskLevel\|case pause\|isPauseAction\|SafetyAnalyzer" src/AetherloomCore/Sources` → nothing; schedule validator passes for every plan any test constructs; zero new warnings. Report per `agents/README.md`.
