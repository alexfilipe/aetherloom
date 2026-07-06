# 11 — Migration: Changing the Current Code

`AetherloomCore` today is a good scaffold with the right instincts (precondition-checked execution, conservative planning, 20 green tests) and the wrong skeleton (closed provider enum, fall-through planner, pause sentinel, flat actions). This document is the complete route from that code to the target architecture — ordered so the tree is **green and invariant-preserving after every phase**.

## 1. Rules of the road

1. **The existing 20 tests are the behavioral contract.** They port (renamed constructors, same assertions) and must pass at the end of every phase. Deliberate behavior changes are enumerated in §4 — there are exactly three.
2. Clean breaks, no shims: nothing outside the package consumes it, so deprecated aliases only add noise. Delete replaced types in the same phase that replaces them.
3. Old and new may coexist *within* a phase via adapters (noted below); an adapter never survives its phase +1.
4. `swift test --package-path AetherloomCore` green + zero new warnings is the exit bar for every phase.

## 2. Old → new map

| Today (`Sources/AetherloomCore/…`) | Becomes | Kind of change |
| --- | --- | --- |
| `CloudPath` | `SyncPath` | rename; logic kept (normalization, case-fold key ✅) |
| `CloudItem` | `ItemObservation` + `ItemVersion` | split; comparison logic centralizes into `VersionComparison` |
| `ProviderID` (closed enum) | `LocationID` + `ProviderKind` + `SyncLocation` | replace & delete |
| `SyncRecord` (per-service fields) | `BaseRecord` + `LocationMemory` + `Tombstone` | restructure |
| `SyncSet.providers: [ProviderID: SyncScope]` | `SyncSet.locations: [LocationID]`; scope moves to `SyncLocation` | restructure |
| `ProviderSnapshot([CloudItem])` | `LocationSnapshot(ObservationIndex)` | index at scan; planner stops rebuilding dictionaries |
| `CloudProvider` protocol | `StorageProvider` | rename + `checkAvailability`/`capabilities`/`scan`; `move`+`rename` → `relocate`; `UploadOptions` → `StoreOptions.OverwritePolicy`; `authenticateIfNeeded` folds into availability |
| `FakeCloudProvider` | `FakeStorageProvider` | keep internals (revisions, preconditions ✅); add availability taxonomy, capability degradation, fault scripting, call log, fake trash |
| — | `FlakyStorageProvider` | new |
| `SyncPlanner` + `PlanningContext` (`handlePathChange`/`handleContentChange`/`handleDeletion`/`processNewItems`) | `deriveFacts` + `reconcile` decision table + lowering | **rewrite of the heart**; every existing branch becomes a named table row |
| `SafetyAnalyzer` | pure `ExecutionGate` computation + `MassChangeEvidence` | fold into planning; count intents, not fan-out ops |
| `SyncAction.pause` sentinel; `SyncRiskLevel.paused` | `PlanOutcome.refusal(SyncRefusal)` | replace & delete; `.safe/.needsReview` → `gate .clear/.hold` |
| `SyncAction` (embedded `CloudItem`s) | `ItemDecision` + `Operation` (refs + typed preconditions) | restructure |
| `ConflictResolver` | kept (conflict naming) | display name + timestamp already injected ✅; parameter source changes |
| `SyncConflict` | `ConflictDecision` (+ `kind`, versions, default resolution) | extend |
| `SyncPlanExecutor` | `ScheduleExecutor` + `ContentStage` + `RunJournal` | rebuild around staging/journal; its precondition & idempotency behavior (✅ the best part of the scaffold) transfers with its tests |
| `SyncActivityLogEntry` / `SyncActivityLogFormatter` | `ActivityEntry` / `ActivityMessageCatalog` | extend; seven sentences kept byte-identical |
| — | `SyncOrchestrator`, `ChangePreview`, `PlanApproval`, `EngineStores` (+ file/in-memory impls), `Advisory/`, `AetherloomIntelligence` | new |
| `AetherloomCore.swift` (placeholder comment file) | deleted | trivial |

## 3. Phases

Each phase = one agent work order ([agents/](agents/)); the graph is 1 → 2 → 3 → 4 → {5, then 6} → 7 → 8 → 9.

- **Phase 1 — Domain vocabulary** (`task-01`): §2 rows 1–6. Mechanical + the `unknown`-never-equals upgrade. Tests port.
- **Phase 2 — Provider abstraction** (`task-02`): §2 rows 7–9. Fake keeps its guts, gains scripting surface.
- **Phase 3 — Reconciliation core** (`task-03`): implement `deriveFacts`/`reconcile` pure; re-point planner tests at verdicts via a thin verdict→old-plan adapter; add the missing rows (edit-delete 10, move-move 7, type-clash 18); delete `PlanningContext`.
- **Phase 4 — Planning & gating** (`task-04`): `PlanOutcome`/refusals/holds/fingerprints; lowering to decisions+schedule with validator; gate math from `SafetyAnalyzer` (then delete it); adapter renders schedules to legacy actions for the old executor until Phase 6.
- **Phase 5 — Persistence & observability** (`task-05`): `EngineStores` protocols + in-memory + file implementations; `ActivityEntry`/catalog; journal store. Parallel-safe with Phase 4 except the refusal wiring for corrupt stores.
- **Phase 6 — Execution** (`task-06`): `ContentStage`, `ScheduleExecutor`, journal integration, post-write verification, recovery; port executor tests; delete old executor + Phase-4 adapter.
- **Phase 7 — Orchestration, preview, approval** (`task-07`): `SyncOrchestrator`, `ChangePreview`, `PlanApproval`, end-to-end wiring; flip placeholder handling from whole-set refusal to item-level `waiting` (§4 change 3) now that the preview can report it.
- **Phase 8 — Advisory** (`task-08`): core advisory + heuristics + validator + orchestrator seam; `AetherloomIntelligence` target.
- **Phase 9 — Test expansion** (`task-09`): decision-table sweep, simulation suite, wording locks, coverage audit.

## 4. Deliberate behavior changes (exactly three; everything else is structure)

1. **Threshold counting** ([04 §4]): intents instead of fan-out operations. Two existing mass-change tests update expected counts; gating becomes topology-independent.
2. **Silent rows become loud** ([03 §3] rows 7, 10, 18): edit-delete now emits a conflict + re-propagation (was: silent no-op), move-move and type-clash now warn + preserve (was: silent fall-through/skip). Strictly more conservative.
3. **Placeholders** ([03] row 13, Phase 7): item-level `waiting` instead of whole-set pause. The existing placeholder test's *assertion that no trash is planned* is preserved; its "whole plan pauses" expectation relaxes to "the placeholder item is excluded and reported". Until Phase 7, current behavior stands.

## 5. What must never regress mid-migration

At every phase boundary: no permanent-delete path exists; no trash without a base record and complete healthy scans; unknown version comparison routes to preservation; precondition-mismatch aborts execution; re-runs are idempotent; canonical safety sentences byte-identical (golden-locked from Phase 5).
