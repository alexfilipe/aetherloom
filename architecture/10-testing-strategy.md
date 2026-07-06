# 10 — Testing Strategy

The architecture was shaped to be provable: pure reconciliation makes the decision table exhaustively checkable, decision-shaped plans make previews property-testable, fakes with call logs make read-only phases assertable, and the journal makes crash recovery a replayable unit test. Swift Testing throughout; zero network; zero real user folders; injected clocks and seeded randomness; the current 20 green tests are the behavioral contract every migration phase must keep passing ([11 §1]).

## 1. The test pyramid

```text
        Simulation suite          random multi-run scenarios on fakes; invariants asserted (§4)
      Orchestrator/executor       stage-by-stage behavior, journal recovery, gates, ordering
    Decision-table exhaustion     reconcile() — every row, plus generated fact-product sweep
  Pure unit tests                 versions, paths, naming, fingerprints, validators, catalogs
```

## 2. Decision-table exhaustion (the centerpiece)

- One named test per row of [03 §3] — the row number appears in the test name (`row10_editDelete_preservesEditAndRepropagates`).
- A generated sweep: for 2–4 locations, enumerate the full product of `LocationFact` shapes per item (bounded vocabulary ⇒ enumerable), assert `reconcile` is total (never traps), and assert the three meta-properties on every output: **no `propagateDeletion` without a base record and all-present-sides-matching**, **no content overwrite when any pairwise comparison is `unknown`**, **placeholders never influence deletion rows**.
- Move-matching and subtree-folding passes ([03 §5]) tested as pure transformations with hash-absent fallbacks.

## 3. Layer contracts

| Layer | Key tests |
| --- | --- |
| Domain | `VersionComparison` matrix incl. unknown-never-equals; `SyncPath` normalization/Unicode/case-fold; conflict naming (extensions, collisions, determinism) ✅ |
| Providers/fakes | Contract suite run against `FakeStorageProvider` (and later every real provider, opt-in): failure-never-emptiness, `.complete` proof, placeholder inclusion, precondition-enforcing stores, quarantine exclusion |
| Planning/gating | Refusal reasons for every unavailability/incomplete variant incl. disconnected local volume and unreachable NAS; threshold intent-counting (same user act ⇒ same gating across 2 vs 4 locations); schedule validator invariants (§ [04 §3] 1–4); fingerprint sensitivity/stability |
| Preview/approval | Decision-partition property; trash causality strings; golden previews; approval matrix (wrong fingerprint / expired / wrong counts / stray-approval-ignored / approved-but-drifted still aborts) |
| Executor | Precondition abort ✅; idempotent re-run ✅; stage fan-out (1 fetch, n stores — call-log asserted); hash-mismatch quarantine; post-write verification failure path; transfer-before-trash barrier; per-location concurrency bound |
| Journal/recovery | Kill the run (scripted fault) after each journal event type; recovery establishes truth without resuming; at-most-one-item record loss; `runFinished` idempotence |
| Orchestrator | Prepare-is-read-only (fake call log shows zero mutations); unavailable location short-circuits before scan; scan timeout ⇒ refusal; overlap guard; tombstone re-appearance ⇒ new file; activity checklist [08 §3] complete for a mixed run |
| Advisory | Nil-advisor byte-identity; malformed/slow/unavailable handling; heuristic rules exact; cache prevents re-inference; excerpts never populated |
| Stores | Round-trips; corrupt file ⇒ typed error ⇒ deletion-refusal end-to-end; torn JSONL lines; prune retention; registry refusal while referenced |

## 4. Simulation suite (the confidence multiplier)

A model-based random tester, seeded and replayable (`Support/SeededRandom`):

1. Build a sync set over 2–4 fake locations with random initial trees.
2. Loop N rounds: apply a random batch of user-like mutations at random locations (create/edit/rename/move/delete/case-rename; occasionally toggle a location unavailable, inject an incomplete scan, sprinkle placeholders, kill a run mid-execution via `FlakyStorageProvider`).
3. After each round, run prepare/execute (auto-approving holds after asserting their evidence) until fixed point.
4. Assert global invariants continuously:
   - **Preservation:** the multiset of distinct content hashes across all locations *plus fake trash* never shrinks.
   - **Convergence:** healthy rounds reach fixed point in ≤ 2 runs; the fixed point has identical trees (modulo conflict copies) everywhere.
   - **No false deletion:** any content absent at the end was trashed by an explicit `propagateDeletion` decision traceable in the journal.
   - **Refusal dominance:** rounds containing unavailability/incompleteness produce refusals and zero mutations at any provider.
- 500+ seeded iterations in CI-tier runs; a failing seed is committed as a named regression test.

## 5. Wording lock & performance smoke

- Golden tests over `ActivityMessageCatalog` and refusal/hold notices: every canonical sentence byte-exact, so safety-language edits are deliberate diffs.
- `@Test(.timeLimit)`: 10 000 items × 3 locations reconciles + plans in < 5 s debug — catches accidental quadratic grouping (the `ObservationIndex` exists precisely to keep this linear).

## 6. Real-provider tests (later, for completeness)

Opt-in only (env-flagged), temp directories and scripted fake mounts only, never a user's real cloud root or share; the provider contract suite of §3 is the acceptance bar for every real integration. On-device model tests likewise opt-in ([07 §6]).

## 7. Suite layout

```text
src/AetherloomCore/Tests/AetherloomCoreTests/
    DomainTests.swift  ReconciliationTableTests.swift  ReconciliationSweepTests.swift
    PlanningGatingTests.swift  PreviewApprovalTests.swift  ExecutorTests.swift
    JournalRecoveryTests.swift  OrchestratorTests.swift  AdvisoryTests.swift
    StoreTests.swift  ProviderContractTests.swift  SimulationTests.swift
    Support/            fixtures, fake factories, seeded RNG, clocks, golden helpers
```
