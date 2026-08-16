# 09 — Persistence

The engine's memory: base records, run journals, conflicts, advice cache, activity, locations, and mass-deletion safety latches. Everything sits behind small protocols. File-backed base-record, journal, and activity stores exist today; L3 adds file-backed conflict, advice-cache, location, and latch stores. SQLite remains later behind the same interfaces. Stores serialize the domain model as-is — no parallel schemas.

## 1. Interfaces

```swift
public struct EngineStores: Sendable {
    public var baseRecords: any BaseRecordStore
    public var journal: any RunJournalStore
    public var conflicts: any ConflictStore
    public var adviceCache: any AdviceCacheStore
    public var activity: any ActivityStore          // [08]
    public var locations: any LocationRegistry
    public var massDeletionLatches: any MassDeletionSafetyLatchStore
}

public protocol BaseRecordStore: Sendable {
    func records(for syncSetID: UUID) async throws -> [BaseRecord]     // throws BaseRecordStoreError.corrupt(syncSetID:) — impossible to ignore
    func apply(_ update: BaseRecordUpdate) async throws                // upsert | tombstone | purge — one item at a time, journal-driven [05 §4]
}

public protocol RunJournalStore: Sendable {
    func begin(runID: UUID, syncSetID: UUID, fingerprint: PlanFingerprint) async throws
    func append(_ event: JournalEvent, runID: UUID) async throws       // intent | mutationIndeterminate | result | itemConverged | runFinished
    /// Durable audit event that does not create an unfinished mutation run.
    func recordSafety(_ event: SafetyJournalEvent, syncSetID: UUID, runID: UUID) async throws
    func unfinishedRun(for syncSetID: UUID) async throws -> JournalReplay?
    func markReconciled(runID: UUID) async throws
}

public protocol MassDeletionSafetyLatchStore: Sendable {
    func latch(for syncSetID: UUID) async throws -> MassDeletionSafetyLatch?
    func upsert(_ latch: MassDeletionSafetyLatch) async throws
    func clear(syncSetID: UUID, matchingEvidenceDigest: String) async throws
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
- **Mass-deletion review audit failure fails closed.** Review issuance, authorization-to-reservation transition/rejection, reservation consumption/expiry/rejection, and latch lifecycle are written as typed safety-journal events; failure to durably record the applicable event emits no reviewed plan, constructs no executor, and grants no execution authority.
- **A latch-store failure refuses deletion planning.** A missing/corrupt/unreadable latch store cannot be interpreted as “no latch,” because that would let a threshold edit bypass prior safety state. Latches persist safety state only; neither a latch nor its audit events are execution authority.
- **A post-start deadline is not a failure result.** Append `mutationIndeterminate(operationID, receipt, occurredAt)` and leave the operation pending and the run unfinished. The event is the durable evidence that a side effect may have occurred even when the originating process exits.
- **Failure to append that event is also non-terminal.** The provider continues retaining its in-process receipt and barrier. Recovery may rediscover only a receipt carrying the exact durable run/operation correlation, then repairs the missing event before any recovery claim, probe, or release; it never converts this persistence failure into a provider failure result.
- **Uncertain recovery never compacts the journal.** Provider unavailability, a still-running owned task, a failed truth probe, or a failed `markReconciled` leaves the WAL intact. Recovery abandons its exclusive session claim but retains the provider barrier and receipt-bound stage artifacts for retry. `markReconciled` happens before the provider releases its mutation barrier.
- Store failures are loud: `error` activity entry + surfaced in the run summary. Silence is the only forbidden behavior.
- **Never stored:** credentials/OAuth tokens (Keychain, app-side, later), file contents, advisor prompts, bearer mass-deletion review authorizations, or bearer execution reservations. Only their digests/bindings/expiry/results may appear in audit records.

## 3. File-backed implementations

Root directory is injected by the app (no `Application Support` literals in core). All JSON via one encoder/decoder factory: sorted keys, ISO-8601 dates with fractional seconds — the same canonical encoding fingerprints use.

- `FileBaseRecordStore`: one atomic file per sync set (`records-<id>.json`), versioned envelope `{"schemaVersion": 1, "records": […]}`, forward-tolerant decoding (unknown keys ignored), decode failure ⇒ `corrupt` (the file is quarantined aside as `.corrupt-<date>`, never overwritten silently).
- `FileRunJournalStore`: `journal-<runID>.jsonl`, append-only, fsync-on-append (journals are small and correctness-critical), torn-final-line tolerant on replay; reconciled journals compacted to a summary line. `mutationIndeterminate` is an additive schema-1 event, so existing schema-1 journals continue to decode unchanged. Duplicate complete indeterminate events replay conservatively without trapping; the latest receipt remains pending.
- `FileMassDeletionSafetyLatchStore`: one atomic versioned record per sync set, keyed by deletion-evidence digest and exact counts. Threshold settings are deliberately absent. Corrupt or unreadable state refuses deletion planning; compare-and-clear prevents an older run from clearing a newer latch.
- `FileActivityStore`: monthly JSONL, [08 §2].
- **L3 target:** file-backed `ConflictStore`, `AdviceCacheStore`, `LocationRegistry`, and `MassDeletionSafetyLatchStore`, with the same atomic/corrupt-state discipline. They are not implemented at the L1 base.
- `InMemory*` variants for every protocol: actors over dictionaries; the test default.

The bridge-owned workspace manifest, sync-set/pause persistence, separate folder capability files, injected Application Support layout, and whole-workspace fail-closed bootstrap are specified once in [providers/01-workspace-engine-session.md §5](../providers/01-workspace-engine-session.md#5-durable-workspace-boundary-and-layout). They do not belong in `SyncLocation`. The manifest references the core latch-store schema/location but never stores a one-shot mass-deletion authorization, an execution reservation, or a restorable reviewed preparation as authority.

## 4. SQLite (later — interface stability is the point now)

One `aetherloom.sqlite` behind one actor: `locations`, `sync_sets`, `base_records` (+ `record_location_memory`), `conflicts`, `advice_cache`, `activity_entries`, `run_journal`, `mass_deletion_latches`. Notes for the future implementer: WAL mode; foreign keys on; `base_records` unique on `(sync_set_id, path)` plus a case-folded path column for collision queries; migrations via `PRAGMA user_version`; raw SQLite3 vs GRDB decided then, in its own target — core never imports it.

## 5. Concurrency

One writer per store (actors). The orchestrator is the sole writer of records/journal/conflicts/latches, and it serializes runs per sync set ([05 §1]), so cross-run write races are structurally absent. Reads (UI) get snapshot-consistent values.

## 6. Changing the current code

Phase 5 of [11-migration.md](11-migration.md): all-new code — today `Storage/` is empty and tests hold records in arrays. The tombstone lifecycle (`markDeleted`-equivalent via `BaseRecordUpdate.tombstone`) and the corrupt-store refusal path land here and get wired into planning in Phase 4's gate computation.
