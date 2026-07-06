# 08 — Observability: Activity Log & Run Journal

Two records with different jobs: the **activity log** is for the user ("everything Aetherloom did, and every time it paused to keep your files safe"); the **run journal** ([05 §4]) is for the machine (crash recovery, forensic truth). The activity log is derived narrative; the journal is ground truth. Core contains no `print` and no OSLog — an app-side `ActivityStore` decorator may forward to OSLog later.

## 1. Activity entries

```swift
public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var occurredAt: Date
    public var syncSetID: UUID?
    public var runID: UUID?                    // groups one run's story
    public var category: ActivityCategory
    public var locationID: LocationID?
    public var path: SyncPath?
    public var message: String                 // user-facing, calm, self-contained
    public var detail: String?                 // causality, counts
    public var relatedConflictID: UUID?
}

public enum ActivityCategory: String, Codable, Hashable, Sendable {
    case sync        // applied operations, run start/finish
    case safety      // refusals, holds, approvals, replan-stops — what users must find later
    case conflict    // detected / resolved; "Both versions preserved"
    case advisory    // suggestions shown (attributed), advice failures
    case provider    // location added / unavailable / recovered
    case error       // store failures, verification failures, unexpected provider errors
}
```

`ActivityMessageCatalog` is the single source of every sentence (today's `SyncActivityLogFormatter` ✅ generalized): operation narrations ("Created ⟨path⟩ in ⟨location⟩ from ⟨location⟩.", "Moved ⟨path⟩ to ⟨location⟩ trash.", …), the canonical safety sentences verbatim, approval and advisory lines. One catalog means wording changes are single-point diffs — locked by golden tests ([10 §5]).

## 2. `ActivityStore`

```swift
public protocol ActivityStore: Sendable {
    func append(_ entry: ActivityEntry) async
    func entries(matching query: ActivityQuery) async -> [ActivityEntry]   // newest-first
    func prune(olderThan date: Date, keepingCategories: Set<ActivityCategory>) async
}

public struct ActivityQuery: Codable, Hashable, Sendable {
    public var syncSetID: UUID?; public var runID: UUID?
    public var categories: Set<ActivityCategory>?
    public var pathPrefix: SyncPath?
    public var dateRange: ClosedRange<Date>?
    public var limit: Int
}
```

Implementations ([09]): `InMemoryActivityStore` (actor, ring buffer, cap 10 000 — tests and first consumer) and `FileActivityStore` (append-only JSONL, one file per month, torn-final-line tolerant, atomic prune rewrites). SQLite variant arrives with the rest of persistence. Appends are awaited at stage boundaries but cheap; a failed append surfaces as `error` — the accountability channel is not best-effort.

## 3. What must be logged (normative, per run, shared `runID`)

1. Run started (set, location count) — `sync`
2. Every refusal and hold with canonical sentence + attribution/evidence — `safety`
3. Preparation summary (n additions / updates / moves / trash / conflicts / waiting; gate) — `sync`
4. Advice shown or advice failure — `advisory`
5. Approval accepted (fingerprint, acknowledged counts) — `safety`
6. Each applied operation (catalog sentence); skipped-as-satisfied operations as one rollup — `sync`
7. Precondition abort (`stoppedForReplan`: location + path) — `safety`
8. Post-write verification failure — `error`
9. Conflict detected / resolved — `conflict`
10. Recovery performed (what the journal established) — `safety`
11. Run finished with outcome — `sync`

Never logged: file contents, excerpts, credentials, tokens, absolute local paths (sync-relative only), advisor prompts.

## 4. Retention & privacy

`sync` / `provider` / `advisory`: 90 days. `safety` / `conflict` / `error`: 365 days — these answer "why did it pause that day?". Pruning runs opportunistically after runs. Everything is local, plain data, exportable as JSON later; nothing transmits anywhere.

## 5. UI contract

The Activity screen renders `entries(matching:)` directly: day-grouped, newest-first, category filter chips, path search, `safety` visually distinct ("Paused for safety"). All strings come from the catalog; the view adds none.

## 6. Changing the current code

Phase 5 of [11-migration.md](11-migration.md): `SyncActivityLogEntry` → `ActivityEntry` (adds runID/syncSetID/category/detail); formatter → catalog, keeping its seven operation sentences byte-identical (golden-locked); stores are new.
