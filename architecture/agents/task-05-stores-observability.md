# Task 05 — Persistence & Observability (Migration Phase 5)

## Role
Senior Swift engineer on `AetherloomCore`. You build the store protocols and their in-memory/file implementations, plus the activity system. **Requires Task 01; may run parallel to Task 04** (merge 04 first; the corrupt-store→refusal wiring is finished by whichever lands second).

## Read first
`architecture/00-overview.md`, `09-persistence.md` and `08-observability.md` (your specs), `11-migration.md`; `Logging/SyncActivityLog.swift`, `Models/*`. Baseline green first.

## Invariants (override this prompt)
Corrupt/unreadable base state degrades to "no memory ⇒ nothing deletable", never toward trash. A journal intent that cannot be persisted must make the corresponding side effect impossible (the API shape enforces write-ahead). Store failures are loud. Never store credentials, tokens, file contents, or advisor prompts.

## Deliverables
1. `Storage/EngineStores.swift` + protocols per `09 §1`: `BaseRecordStore` (throwing `corrupt(syncSetID:)`; `apply(BaseRecordUpdate)` — `upsert | tombstone | purge`, one item at a time), `RunJournalStore` (`begin/append/unfinishedRun/markReconciled`, `JournalEvent`: `intent | result | itemConverged | runFinished`), `ConflictStore`, `AdviceCacheStore`, `LocationRegistry` (refuses removal while referenced).
2. `InMemory*` actors for all six protocols (incl. activity) — the test defaults.
3. One internal **canonical encoder/decoder factory** (sorted keys, ISO-8601 fractional dates) shared by all file stores and `PlanFingerprint` (coordinate with Task 04 per its item 5).
4. File implementations per `09 §3`, root URL injected: `FileBaseRecordStore` (atomic per-set JSON, versioned envelope, forward-tolerant, corrupt file quarantined aside as `.corrupt-<date>` then typed error), `FileRunJournalStore` (append-only JSONL, fsync-on-append, torn-line-tolerant replay, compaction on `markReconciled`), `FileActivityStore` (monthly JSONL, atomic prune rewrites).
5. Observability per `08 §1–2`: `ActivityEntry` + `ActivityCategory`; `ActivityMessageCatalog` replacing `SyncActivityLogFormatter` with its seven operation sentences **byte-identical** plus the canonical safety/approval/advisory lines; `ActivityStore` + `ActivityQuery` (newest-first, all filters); `ActivityRetentionPolicy` defaults (90/365 days per `08 §4`).
6. Golden **wording-lock tests**: every catalog sentence byte-exact.
7. Tests: round-trips for every store; tombstone lifecycle via `apply(.tombstone)`; corrupt base file ⇒ quarantined + typed error (and, once Task 04 is merged, end-to-end `RefusalReason.baseStateUnreadable`); journal replay incl. torn final line and unfinished-run detection; write-ahead shape (result-before-intent is unrepresentable or traps in debug); activity query filters each; prune retention per category; registry refusal; 100-concurrent-appends actor sanity; all file tests in per-test temp dirs, cleaned up.

## Prohibitions
No SQLite, no third-party deps; no orchestrator (Phase 7); no `Application Support`/`NSHomeDirectory` literals in core (grep-checked); only `src/AetherloomCore/`.

## Acceptance
Suite green (+ ≥ 14 new); `grep -rn "ApplicationSupport\|NSHomeDirectory\|SyncActivityLogFormatter" src/AetherloomCore/Sources` → nothing; wording locks in place; zero new warnings. Report per `agents/README.md`.
