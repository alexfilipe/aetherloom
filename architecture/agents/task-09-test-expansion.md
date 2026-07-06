# Task 09 — Test Expansion & Simulation Suite (Migration Phase 9)

## Role
Senior Swift engineer acting as the adversarial QA pass on `AetherloomCore`. You run **last**, after Phases 1–8. You close every coverage gap, build the simulation suite, and audit the whole engine against the design docs. Production code changes only to fix defects your tests expose — each fix individually reported with its motivating test.

## Read first
`design/architecture/10-testing-strategy.md` (your spec — §3 table and §4 simulation are the checklist), `00-overview.md`, `11-migration.md §5`; the full test suite and all sources. Record the baseline pass count.

## Invariants (override this prompt)
Tests are deterministic: seeded randomness only, injected clocks, no real sleeps, no network, no real user folders, temp dirs cleaned. A test encoding behavior that contradicts the safety invariants is a bug in the test. Failing seeds become committed named regression tests, never re-rolled away.

## Deliverables
1. **Audit table**: every row of `10 §3` (and every "must" in docs 01–09) mapped to an existing test name or "missing" — deliver the table in your report, then implement every "missing".
2. **Reorganize** into the `10 §7` layout; move existing tests without changing assertions; shared builders into `Support/` (fixtures, fake factories, `SeededRandom`, clocks, golden helpers).
3. **Decision-table sweep** (`10 §2`): generated 2–4-location fact-product; totality; the three meta-properties (no deletion without matching base; unknown never overwrites; placeholders never affect deletion rows).
4. **Simulation suite** (`10 §4`): seeded model-based tester — random trees, N rounds of random user-like mutations + scripted failures (unavailability, incomplete scans, placeholders, mid-run kills via `FlakyStorageProvider`), prepare/execute to fixed point with evidence-asserted auto-approval; continuous invariants: preservation (content-hash multiset incl. fake trash never shrinks), convergence (≤ 2 runs; identical trees modulo conflict copies), no false deletion (every absent content traces to a journaled `propagateDeletion`), refusal dominance (failure rounds mutate nothing). ≥ 500 seeded iterations locally; commit the seeds.
5. **Provider contract suite** (`10 §3` row 2) runnable against any `StorageProvider` — executed on the fakes now; the acceptance bar for every future real provider.
6. **Wording locks** for any canonical sentence not already golden-locked in Phase 5 (refusal/hold notices, approval lines, advisory attributions).
7. **Performance smoke**: 10 000 items × 3 locations reconcile+plan < 5 s debug (`.timeLimit`).
8. **Determinism check**: `swift test` × 3 identical results; total default-suite runtime < 90 s (tune iteration counts with justification).
9. **Coverage report**: `swift test --enable-code-coverage`; per-directory line coverage for `Reconcile/ Plan/ Preview/ Execute/ Orchestration/ Advisory/ Storage/`; flag files < 80 %.

## Prohibitions
No new dependencies (hand-rolled seeded generation); no behavior changes outside defect fixes; no weakening of any existing assertion; only `AetherloomCore/`.

## Acceptance
Every `10 §3` row maps to a named passing test (audit table delivered); simulation suite green with committed seeds; sweep green; determinism and runtime budgets met; zero warnings. Report per `agents/README.md`, plus the audit table, coverage numbers, and the list of production fixes (test → fix).
