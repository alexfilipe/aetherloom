# 05 — Execution & Orchestration

Execution is where the engine finally touches the world, so it carries the heaviest engineering: content staging, precondition verification, post-write verification, a crash-safe journal, and per-item base-record updates. The orchestrator composes the whole pipeline and is the app's single entry point.

## 1. `SyncOrchestrator`

```swift
public actor SyncOrchestrator {
    public init(
        locations: LocationDirectory,                  // LocationID → SyncLocation
        providers: [LocationID: any StorageProvider],
        stores: EngineStores,                          // base records, journal, conflicts, activity, advice cache [09]
        stage: ContentStage,
        advisor: (any ConflictAdvisor)? = nil,         // [07]
        environment: EngineEnvironment                 // clock, ID gen, timeouts, parallelism caps
    )

    /// Stages 1–5. Read-only against providers. Always safe.
    public func prepare(_ syncSet: SyncSet) async -> SyncPreparation

    /// Stage 6–7. Runs only a clear-gated plan, or a held plan with a valid approval.
    public func execute(_ preparation: SyncPreparation, approval: PlanApproval? = nil) async throws -> SyncRunSummary
}

public struct SyncPreparation: Sendable {
    public var outcome: PlanOutcome            // refusal | plan
    public var preview: ChangePreview          // rendered for both cases [06]
    public var advice: [ConflictAdvice]        // possibly empty
    public var runID: UUID
}
```

Prepare/execute is a hard split: the UI holds a `SyncPreparation`, shows the preview, collects approval if held, and passes the same value back — nothing is recomputed between what the user saw and what runs, and reality is *still* re-verified per operation.

**Stage checklist** (each bracketed by activity entries with the shared `runID`, [08](08-observability.md)):

1. **Recover** — if the journal has an unfinished run for this set, run recovery (§4) first.
2. **Availability** — `checkAvailability()` concurrently; any unavailable ⇒ `refusal`, and *no scans run* (a partial view must never coexist with mutation decisions).
3. **Scan** — concurrent `scan(_:)` with per-location timeout (default 120 s; a hang becomes `unavailable`).
4. **Reconcile + plan + gate** — pure calls ([03], [04]) with the injected environment.
5. **Preview + advice** — render preview; if held and an advisor exists, request advice under budget ([07 §5]); persist `ConflictDecision`s.
6. **Execute** — §3.
7. **Summarize** — `SyncRunSummary { outcome: completed | refused | held | stoppedForReplan(location, path) | mutationIndeterminate(location, path, receiptID) | cancelled | failed(message), appliedOperations, skippedOperations, failedOperations, indeterminateOperations, perItemResults }`. Older persisted summaries decode a missing `indeterminateOperations` field as an empty list.

Overlap guard: one in-flight run per sync set; a second call fails fast with a typed error. Cancellation is cooperative between operations, never mid-commit; cancelled runs report truthfully and the next prepare starts from a fresh scan.

## 2. `ContentStage` — content-addressed staging

```swift
public actor ContentStage {
    public init(rootDirectory: URL, byteLimit: Int64)   // root injected; default cache dir chosen by the APP, not core
    public func materialize(_ ref: ContentRef, from provider: any StorageProvider) async throws -> StagedContent
    public func release(_ content: StagedContent) async
}
public struct StagedContent: Sendable { public var url: URL; public var verifiedHash: String?; public var size: Int64 }
```

- **Download once, fan out many.** A 3-destination create performs 1 fetch + 3 stores. (Today's executor re-downloads per action.)
- **Integrity:** after fetch, hash the staged bytes; if the source advertised a hash and it mismatches ⇒ fail the item (`error` activity), never propagate corrupt content. If the source has no hash, record size and pass the engine-computed hash forward — destinations and base records get it, upgrading future comparisons.
- **One canonical owner.** Handles for the same canonical stage root share one process-wide storage actor, so orchestrator reconstruction cannot clean a live temporary write or lose a receipt-bound pin.
- Eviction: LRU by bytes; contents referenced by an in-flight run are pinned. Crash leftovers are garbage-collected on next start by the app-side owner.

## 3. `ScheduleExecutor`

Executes an `OperationSchedule` wave by wave (topological order over `dependsOn`), honoring the global transfer-before-trash barrier ([04 §3]). Within a wave, operations on *different locations* may run concurrently (bounded, default 3); per-location execution is serial. Per operation:

```text
journal.intent(op)                                   // §4 — BEFORE any side effect
probe   = provider.currentState / absence check      // evaluate op.precondition against reality
mismatch ⇒ throw stoppedForReplan(location, path)    // aborts the remainder of the run — never retried internally
already-satisfied ⇒ journal.result(op, .skipped)     // idempotent re-runs come from here
apply   (makeFolder / transfer via stage / relocate / trash)
deadline before provider start ⇒ result(.deadlineExpiredBeforeStart)
deadline after provider start ⇒ mutationIndeterminate(op, receipt); stop
verify  = re-read metadata; size (+hash where available) must match what we wrote
journal.result(op, .applied(newObservation) | .failed(error))
```

Post-write verification is new and cheap insurance: it catches truncated uploads and provider-side rewrites at the only moment the engine knows exactly what the destination should look like, and it captures the destination's fresh revision token for the base record.

## 4. `RunJournal` — crash safety

Append-only write-ahead log per run (`journal-<runID>.jsonl`, [09 §3]): `runStarted(planFingerprint)`, `intent(op)`, `mutationIndeterminate(op, receipt)`, `result(op, outcome)`, `itemConverged(decisionID, BaseRecord)`, `runFinished(outcome)`.

- **Base records update per item**, emitted as `itemConverged` the moment all of an item's operations report `applied`/`skipped` — not as a bulk write at run end. The record store consumes the journal stream; a crash can lose at most the in-flight item's update, never leave half a run's records pretending convergence.
- A post-start deadline appends `mutationIndeterminate` but **not** a terminal `result`, `runFinished`, or “Sync finished” activity. The provider retains the late task and blocks normal provider work; the journal retains the same receipt across process restart. Operations already queued behind that mutation are resolved as pre-start/no-side-effect and never resume from the old schedule.
- If the `mutationIndeterminate` append itself fails after the side effect started, execution fails closed with only the intent durable. Same-process recovery discovers only a retained receipt bound to that exact run and operation, appends the missing event, and only then claims recovery. Another append failure leaves both the intent and provider barrier intact.
- **Recovery** (stage 1): a journal with `runStarted` but no `runFinished` ⇒ for each `intent` without a `result`, first wait for any in-process owned work to reach quiescence, then atomically claim the exact receipt and probe actual provider state. The exclusive claim spans every probe and `markReconciled`; a probe or journal failure restores the barrier for retry. After restart, only provider truth can resolve the claim. Provider unavailability never becomes confirmed absence. Local relocate recovery always probes both endpoints and accepts convergence only when the exact-kind destination has same-version evidence for the intended item and the source is positively absent or matching recoverable trash. Both-present, mismatched/unknown destination evidence, uncertain trash, or either unavailable endpoint leaves the WAL and barrier unresolved. Recovery never reissues the move. Receipt-bound staging temporary files and source pins are released only after the journal is durably reconciled.
- Recovery **never resumes or reapplies the old schedule**. It establishes truth, durably marks the journal reconciled, releases provider barriers, and only then allows availability checks, fresh scans, and replanning. This keeps "what runs" derived from "what is" and prevents duplicate mutation.

## 5. Execution gate enforcement

`execute` has a single choke point: `gate == .clear` runs; `gate == .hold` requires `approval.validate(against: plan, at: now) == .accepted` (fingerprint match, unexpired, acknowledged counts equal actual — [06 §3]); refusals are unexecutable by type (there is no plan to pass in). Approval acceptance is logged as a `safety` activity entry. Per-operation preconditions apply identically with or without approval — approval authorizes intent; reality is always re-checked.

## 6. Changing the current code

Phases 5–7 of [11-migration.md](11-migration.md). Today's `SyncPlanExecutor` ✅ already has the two hardest habits right — per-action precondition probes (`destinationChangedRequiresReplan`) and skip-if-satisfied idempotency — and its tests transfer directly to the `ScheduleExecutor`. New: staging (replaces per-action temp-file download), post-write verification, journal, wave ordering (replaces implicit action order), per-item record updates, and the orchestrator itself (today nothing composes the pipeline; tests do it by hand). The old executor is deleted after its test suite passes against the new one via the Phase-4 adapter.
