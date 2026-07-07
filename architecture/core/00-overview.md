# 00 — System Overview

## Product frame

Aetherloom keeps selected folders (eventually whole drives) synchronized across iCloud Drive, Google Drive, OneDrive, Dropbox (later), local folders, and NAS-backed folders. Every location in a *sync set* holds a full copy; the pitch is **availability through redundancy**, and the engineering promise underneath it is **sync that cannot destroy data**. The engine is hardened against fake providers before any real integration exists.

## Safety invariants

The constitution. Every design choice below is downstream of these; when anything conflicts, these win.

1. **Never permanently delete during normal sync.** Deletes go to provider trash / recycle bin / quarantine.
2. **Absence caused by failure is never deletion.** Outages, auth failures, network failures, incomplete scans, unmounted/sleeping/disconnected volumes, unreachable NAS mounts, and iCloud placeholders are *unavailability*.
3. **Never silently overwrite independent edits.** Divergent versions are all preserved.
4. **Suspicious mass changes hold sync until reviewed.**
5. **Never act on stale state.** Every mutation re-verifies its precondition at execution time; drift aborts the run.
6. **Prefer refusing too often over risking data.** False refusals are a UX cost; loss is unacceptable.
7. **Intelligence never decides.** The on-device advisor ranks and explains; only deterministic logic plus explicit user approval causes actions.

## Topology decision: a hub with remembered base state

Aetherloom is a **hub-and-spoke** synchronizer: the user's Mac is the only agent that ever moves data, and the engine's store is the hub's memory. That decision shapes everything:

- Conflict detection is **three-way per item**: the remembered *base* (last converged state) against each location's current *observation*. With a single mover, this is complete — no version vectors, no CRDTs, no vector clocks needed, and none of their failure modes.
- Deletion is only ever inferred as *base says it existed here, a **complete and healthy** scan says it doesn't*. No base record ⇒ no deletion, ever.
- Correctness never depends on provider change feeds. Change cursors (`listChanges`) are an *optimization* to scan less; the full snapshot is always the ground truth path, and any doubt falls back to it.

## The pipeline

One run of one sync set. Stages 1–5 are read-only against providers; nothing mutates the world before stage 6.

```text
1 AVAILABILITY  each location: available / unavailable(reason) ── any unavailable ⇒ REFUSAL
2 SCAN          LocationSnapshot per location (indexed observations; complete/incomplete)
                └─ any incomplete ⇒ REFUSAL
3 RECONCILE     pure: (BaseRecords, Snapshots) → per-item ItemVerdicts        [03]
4 PLAN + GATE   pure: verdicts → SyncPlan { decisions, operation schedule,
                fingerprint, gate: clear | hold(reasons) }                    [04]
5 PREVIEW       ChangePreview (+ optional on-device advice on conflicts)      [06,07]
                gate == hold ⇒ wait for PlanApproval bound to the fingerprint
6 EXECUTE       journal intent → verify precondition → apply → verify result  [05]
                → journal result → update BaseRecord (per item)
7 REPORT        activity entries throughout; run summary at the end           [08]
```

A **refusal** (stage 1–2, or deletion-safety conditions in stage 4) means *no executable plan exists* — there is nothing to approve; only reality changing clears it. A **hold** (conflicts, mass changes) means a plan exists but is withheld for review. Making these two different types — instead of a `.pause` sentinel action inside the plan, as the current code does — removes the entire class of "did every caller remember to check for pause first?" bugs.

## Layering

Strict one-way dependencies, all inside `AetherloomCore` (zero third-party deps, no ML/network/SQLite imports; Swift 6 strict concurrency; values are `Codable + Hashable + Sendable`, mutable state lives in actors):

```text
Domain        SyncPath, ItemVersion, ItemObservation, BaseRecord, SyncLocation, SyncSet   [01]
   ▲
Providers     StorageProvider protocol, availability, capabilities, fakes                 [02]
   ▲
Reconcile     pure decision table: facts → verdicts                                       [03]
   ▲
Plan          lowering, operations, gates, fingerprints, thresholds                       [04]
   ▲
Preview       ChangePreview, PlanApproval                                                 [06]
   ▲
Execute       ContentStage, ScheduleExecutor, RunJournal                                  [05]
   ▲
Orchestrate   SyncOrchestrator (the only composer; the app's entry point)                 [05]
   ─ uses ─▶  Stores (protocols) [09]   Observability [08]   Advisory (optional) [07]

AetherloomIntelligence (separate target): FoundationModels advisor adapter — the only ML import anywhere.
AetherloomApp (SwiftUI): UI only; currently an unwired demo shell.
```

## Architecture decisions & rejected alternatives (ADR summary)

| Decision | Chosen | Rejected, and why |
| --- | --- | --- |
| Conflict model | Three-way vs remembered base (hub topology) | Version vectors / CRDTs — solve multi-writer coordination we don't have; add unfalsifiable complexity to the safety argument |
| Planner shape | **Pure decision table** per item ([03]) producing typed verdicts | Imperative fall-through passes (current `PlanningContext.handle*` chain) — ordering-sensitive, silent default branches, unauditable coverage |
| "Paused" representation | Typed `Refusal` / `ExecutionGate.hold` ([04]) | `.pause` action inside `actions[0]` (current) — a sentinel every consumer must remember to check |
| Plan unit | Per-item `ItemDecision` lowered to an `Operation` DAG | Flat `[SyncAction]` with embedded full item snapshots (current) — unreviewable per file, implicit ordering, bloated values |
| Transfer path | Content-addressed **staging store**, download once → fan out, hash-verified | Per-action download/upload (current) — n redundant downloads per fan-out, no corruption check, no resume |
| Crash safety | Write-ahead **run journal**; recovery re-verifies unconfirmed intents against reality, then replans | Trusting in-memory execution reports — a crash mid-run silently corrupts base state, which then mis-classifies every future change |
| Scan model | Full snapshot is ground truth; change cursors only ever *narrow* a scan | Change-feed-driven sync — provider feeds lie by omission; missing events must never look like deletions |
| Placeholder handling | Item-level `waiting` verdict (rest of the set syncs; blocked items reported) | Whole-set pause on any placeholder (current) — safe but needlessly binary; placeholders are *presence*, so deletion inference is unaffected |
| Threshold counting | Count **intents** (decisions) against tracked records | Counting fan-out operations (current) — the same user action trips thresholds differently depending on location count |
| Symlinks/packages | Excluded by default with a visible warning | Silent skip or naive follow — both are data-integrity traps; revisit per provider later |

## Canonical language

Engine-emitted user-facing strings use these verbatim; the UI adds detail beneath them, never rewrites them:

- "Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable."
- "Aetherloom found many deletions. This may be intentional, but sync is paused until you review it."
- "This file changed in more than one place. Aetherloom preserved both versions."
- Preferred phrases: "Preview changes", "Move to trash", "Needs review", "Paused for safety", "Both versions preserved", "Provider unavailable".

(Refusals and holds both render as "Paused for safety" to users; the distinction is architectural, not linguistic.)

## Relationship to the current code

`AetherloomCore` today (planner, safety analyzer, executor, fakes, 20 green tests) implements most of the *behavior* above with a narrower structure: closed 3-cloud `ProviderID`, per-service `SyncRecord` fields, fall-through planner, pause sentinel, flat action list, no staging/journal/orchestrator/stores. Those 20 tests are the behavioral contract for the migration — every phase in [11-migration.md](11-migration.md) keeps their assertions passing.
