# 09 — Persistence

The engine's memory: base records, run journals, conflicts, advice cache, activity, locations. Everything sits behind small protocols. File-backed base-record, journal, and activity stores exist today; L3 adds file-backed conflict, advice-cache, and location stores. SQLite remains later behind the same interfaces. Stores serialize the domain model as-is — no parallel schemas.

## 1. Interfaces

```swift
public struct EngineStores: Sendable {
    public var baseRecords: any BaseRecordStore
    public var journal: any RunJournalStore
    public var conflicts: any ConflictStore
    public var adviceCache: any AdviceCacheStore
    public var activity: any ActivityStore          // [08]
    public var locations: any LocationRegistry
}

public protocol BaseRecordStore: Sendable {
    func records(for syncSetID: UUID) async throws -> [BaseRecord]     // throws BaseRecordStoreError.corrupt(syncSetID:) — impossible to ignore
    func apply(_ update: BaseRecordUpdate) async throws                // upsert | tombstone | purge — one item at a time, journal-driven [05 §4]
}

public protocol RunJournalStore: Sendable {
    func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws
    func append(_ event: JournalEvent, runID: UUID) async throws       // intent | mutationIndeterminate | result | itemConverged | runFinished
    func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay?
    func markReconciled(runID: UUID) async throws
}

public protocol ConflictStore: Sendable {
    func openConflicts(for syncSetID: UUID) async throws -> [ConflictDecision]
    func upsert(_ conflicts: [ConflictDecision]) async throws
    func resolve(_ id: UUID, as resolution: Resolution, at date: Date) async throws
}

public protocol AdviceCacheStore: Sendable {
    func cachedAdvice(forKey key: String) async -> ConflictAdvice?
    func store(_ advice: ConflictAdvice, forKey key: String) async
}

public protocol LocationRegistry: Sendable {
    func allLocations() async throws -> [SyncLocation]
    func upsert(_ location: SyncLocation) async throws
    func remove(_ id: LocationID, referencedBy: Set<UUID>) async throws   // refuses while referenced by any sync set
}
```

## 2. Failure semantics (safety-relevant)

- **Corrupt or unreadable base state ⇒ refusal to plan deletions.** `records(for:)` throwing `corrupt` maps to `RefusalReason.baseStateUnreadable` ([04 §1]). Degradation direction: no memory ⇒ everything looks *new* ⇒ worst case is redundant conflict copies — never a trash.
- **Journal append failure aborts the run before the side effect** — an intent that can't be journaled must not be applied (WAL discipline; [05 §3] order).
- **A post-start deadline is not a failure result.** Append `mutationIndeterminate(operationID, receipt, occurredAt)` and leave the operation pending and the run unfinished. The event is the durable evidence that a side effect may have occurred even when the originating process exits.
- **Failure to append that event is also non-terminal.** The provider continues retaining its in-process receipt and barrier. Recovery may rediscover only a receipt carrying the exact durable run/operation correlation, then repairs the missing event before any recovery claim, probe, or release; it never converts this persistence failure into a provider failure result.
- **Uncertain recovery never compacts the journal.** Provider unavailability, a still-running owned task, a failed truth probe, or a failed `markReconciled` leaves the WAL intact. Recovery abandons its exclusive session claim but retains the provider barrier and receipt-bound stage artifacts for retry. `markReconciled` happens before the provider releases its mutation barrier.
- Store failures are loud: `error` activity entry + surfaced in the run summary. Silence is the only forbidden behavior.
- **Never stored:** credentials/OAuth tokens (Keychain, app-side, later), file contents, advisor prompts.

## 3. File-backed implementations

Root directory is injected by the app (no `Application Support` literals in core). All JSON via one encoder/decoder factory: sorted keys, ISO-8601 dates with fractional seconds — the same canonical encoding fingerprints use.

- `FileBaseRecordStore`: one atomic file per sync set (`records-<id>.json`), versioned envelope `{"schemaVersion": 1, "records": […]}`, forward-tolerant decoding (unknown keys ignored), decode failure ⇒ `corrupt` (the file is quarantined aside as `.corrupt-<date>`, never overwritten silently).
- `FileRunJournalStore`: `journal-<runID>.jsonl`, append-only, fsync-on-append (journals are small and correctness-critical), torn-final-line tolerant on replay; reconciled journals compacted to a summary line. `mutationIndeterminate` is an additive schema-1 event, so existing schema-1 journals continue to decode unchanged. Duplicate complete indeterminate events replay conservatively without trapping; the latest receipt remains pending.
- `FileActivityStore`: monthly JSONL, [08 §2].
- **L3 target:** file-backed `ConflictStore`, `AdviceCacheStore`, and `LocationRegistry`, with the same atomic/corrupt-state discipline. They are not implemented at the L1 base.

The bridge-owned workspace manifest, sync-set/pause persistence, separate folder capability files, injected Application Support layout, and whole-workspace fail-closed bootstrap are specified once in [providers/01-workspace-engine-session.md §5](../providers/01-workspace-engine-session.md#5-durable-workspace-boundary-and-layout). They do not belong in `EngineStores` or `SyncLocation`.
- `InMemory*` variants for every protocol: actors over dictionaries; the test default.

## 4. SQLite (later — interface stability is the point now)

One `aetherloom.sqlite` behind one actor: `locations`, `sync_sets`, `base_records` (+ `record_location_memory`), `conflicts`, `advice_cache`, `activity_entries`, `run_journal`. Notes for the future implementer: WAL mode; foreign keys on; `base_records` unique on `(sync_set_id, path)` plus a case-folded path column for collision queries; migrations via `PRAGMA user_version`; raw SQLite3 vs GRDB decided then, in its own target — core never imports it.

## 5. Concurrency

One writer per store (actors). The orchestrator is the sole writer of records/journal/conflicts, and it serializes runs per sync set ([05 §1]), so cross-run write races are structurally absent. Reads (UI) get snapshot-consistent values.

## 6. Changing the current code

Phase 5 of [11-migration.md](11-migration.md): all-new code — today `Storage/` is empty and tests hold records in arrays. The tombstone lifecycle (`markDeleted`-equivalent via `BaseRecordUpdate.tombstone`) and the corrupt-store refusal path land here and get wired into planning in Phase 4's gate computation.
