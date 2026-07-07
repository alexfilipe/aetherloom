# 09 — Persistence

The engine's memory: base records, run journals, conflicts, advice cache, activity, locations. Everything sits behind small protocols; file-backed implementations ship now, SQLite arrives later behind the same interfaces (roadmap step 10). Stores serialize the domain model as-is — no parallel schemas.

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
    func append(_ event: JournalEvent, runID: UUID) async throws       // intent | result | itemConverged | runFinished
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
- Store failures are loud: `error` activity entry + surfaced in the run summary. Silence is the only forbidden behavior.
- **Never stored:** credentials/OAuth tokens (Keychain, app-side, later), file contents, advisor prompts.

## 3. File-backed implementations (now)

Root directory is injected by the app (no `Application Support` literals in core). All JSON via one encoder/decoder factory: sorted keys, ISO-8601 dates with fractional seconds — the same canonical encoding fingerprints use.

- `FileBaseRecordStore`: one atomic file per sync set (`records-<id>.json`), versioned envelope `{"schemaVersion": 1, "records": […]}`, forward-tolerant decoding (unknown keys ignored), decode failure ⇒ `corrupt` (the file is quarantined aside as `.corrupt-<date>`, never overwritten silently).
- `FileRunJournalStore`: `journal-<runID>.jsonl`, append-only, fsync-on-append (journals are small and correctness-critical), torn-final-line tolerant on replay; reconciled journals compacted to a summary line.
- `FileActivityStore`: monthly JSONL, [08 §2].
- `InMemory*` variants for every protocol: actors over dictionaries; the test default.

## 4. SQLite (later — interface stability is the point now)

One `aetherloom.sqlite` behind one actor: `locations`, `sync_sets`, `base_records` (+ `record_location_memory`), `conflicts`, `advice_cache`, `activity_entries`, `run_journal`. Notes for the future implementer: WAL mode; foreign keys on; `base_records` unique on `(sync_set_id, path)` plus a case-folded path column for collision queries; migrations via `PRAGMA user_version`; raw SQLite3 vs GRDB decided then, in its own target — core never imports it.

## 5. Concurrency

One writer per store (actors). The orchestrator is the sole writer of records/journal/conflicts, and it serializes runs per sync set ([05 §1]), so cross-run write races are structurally absent. Reads (UI) get snapshot-consistent values.

## 6. Changing the current code

Phase 5 of [11-migration.md](11-migration.md): all-new code — today `Storage/` is empty and tests hold records in arrays. The tombstone lifecycle (`markDeleted`-equivalent via `BaseRecordUpdate.tombstone`) and the corrupt-store refusal path land here and get wired into planning in Phase 4's gate computation.
