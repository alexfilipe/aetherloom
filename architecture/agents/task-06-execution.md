# Task 06 — Execution Engine (Migration Phase 6)

## Role
Senior Swift engineer on `AetherloomCore`. You rebuild execution around content staging, the write-ahead journal, and post-write verification — then delete the legacy executor and the Phase-4 adapter. **Requires Tasks 04 and 05 merged.**

## Read first
`design/architecture/00-overview.md`, `05-execution-and-orchestration.md` §2–§4 (your spec), `11-migration.md`; `Execution/SyncPlanExecutor.swift` **and its tests** — its precondition-abort and skip-if-satisfied behaviors are the scaffold's crown jewels and must transfer intact. Baseline green first.

## Invariants (override this prompt)
Journal intent before any side effect. Precondition mismatch aborts the remainder of the run (`stoppedForReplan`) and is never retried internally. Already-satisfied operations are skipped (idempotent re-runs). All transfers complete before any trash begins, globally. Corrupt staged content never propagates.

## Deliverables
1. `Execute/ContentStage.swift` per `05 §2`: actor, injected root + byte limit; `materialize(ContentRef, from:)` fetches once per distinct content, hashes staged bytes, fails the item on advertised-hash mismatch, passes engine-computed hashes forward when the source has none; LRU eviction with in-flight pinning; `release`.
2. `Execute/ScheduleExecutor.swift` per `05 §3`: wave execution (topological over `dependsOn`), global transfer-before-trash barrier, per-location serial / cross-location bounded parallelism (default 3, injected); per-operation sequence exactly: `journal.intent → precondition probe (currentState/absence) → mismatch ⇒ stoppedForReplan → satisfied ⇒ .skipped → apply → post-write verify (size, hash where available; capture destination revision token) → journal.result`; verification failure ⇒ `.failed` + `error` activity, run continues to a truthful summary but the item does not converge.
3. Per-item convergence: when all of a decision's operations are `applied|skipped`, emit `journal.itemConverged(decisionID, BaseRecord)` and `baseRecords.apply(.upsert)` / `.tombstone` for fully-trashed items — per item, never bulk-at-end.
4. `Execute/RunRecovery.swift` per `05 §4`: given an unfinished `JournalReplay`, probe providers for each intent-without-result, fold confirmed outcomes into base records, `markReconciled`. **Never resumes the old schedule.**
5. Cancellation: cooperative between operations, never mid-commit; truthful `skippedOperations` in the summary.
6. Port the legacy executor's tests to the new stack (same assertions: precondition drift aborts; re-run idempotence; already-trashed/existing skips), then delete `SyncPlanExecutor` and the Phase-4 schedule→actions adapter.
7. New tests: stage fan-out (call log: 1 fetch, 3 stores); hash-mismatch quarantine; post-write verification failure path; barrier ordering observable in call log; parallelism bound respected; journal kill-matrix (scripted fault after each event type ⇒ recovery establishes truth, ≤ 1 item's record loss, next plan is fresh); write-ahead order asserted; per-item record updates land as items finish, not at run end.

## Prohibitions
No orchestrator (Phase 7) — tests drive the executor directly with in-memory stores and fakes; no preview/approval enforcement yet beyond refusing non-`clear` gates (full approval validation arrives with Phase 7); only `AetherloomCore/`.

## Acceptance
Suite green (ported executor behaviors + ≥ 10 new); `grep -rn "SyncPlanExecutor" AetherloomCore` → nothing; the Phase-4 adapter is gone; zero new warnings. Report per `agents/README.md`.
