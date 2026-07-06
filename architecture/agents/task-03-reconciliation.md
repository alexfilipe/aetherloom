# Task 03 — Reconciliation Core (Migration Phase 3)

## Role
Senior Swift engineer on `AetherloomCore`. You replace the imperative planner heart with the pure, total decision table — the deepest cut of the migration. **Requires Tasks 01–02 merged.**

## Read first
`architecture/00-overview.md`, `03-reconciliation.md` (your spec — the §3 table is normative row by row), `11-migration.md` (§1, §4 change 2); `Planning/SyncPlanner.swift` in full (every `PlanningContext` branch), `Planning/ConflictResolver.swift`, all planner tests. Baseline green first.

## Invariants (override this prompt)
No `propagateDeletion` without a base record AND all present sides matching base AND complete healthy scans (guaranteed upstream). `VersionComparison.unknown` never wins an overwrite. Every ambiguous pattern lands on a preservation-shaped verdict. The function is total — no silent default branch.

## Deliverables
1. `Reconcile/LocationFact.swift` + `deriveFacts` per `03 §2`: identity join (itemID-then-path, case-folded), exclusions filtered first, placeholders ⇒ `waiting`, folders never `changed`, unknown comparison ⇒ `changed`-with-unknown.
2. `Reconcile/ItemVerdict.swift` + `Reconcile/Reconciler.swift`: `reconcile(base:facts:) -> ItemVerdict`, implementing **all 18 rows** of `03 §3` — including the three the current code handles silently: row 10 edit–delete (conflict + re-propagate edit, never trash), row 7 move–move (conflict, nothing moves), row 18 type clash (conflict copy, folder untouched). Row 13: keep the *current* whole-set placeholder pause for now (Phase 7 flips to item-level `waiting` — see `11-migration.md §4.3`), but derive and carry the `waiting` facts so the flip is one gate change.
3. `ConflictDecision` + `ConflictKind` + `ConflictVersion` per `03 §4`, replacing/extending `SyncConflict` (add `kind`); conflict naming stays in `ConflictResolver` ✅, fed from `PlanningEnvironment`.
4. Enhancement passes per `03 §5`, each a separate pure transformation with its own tests: hash-based move-matching (missing+appeared, identical hash, same location ⇒ `relocated`; no hash ⇒ no pairing) and subtree-move folding (stable folder IDs only).
5. **Adapter (dies in Phase 4):** render verdicts to the legacy `SyncPlan`/action list so `SafetyAnalyzer`, executor, and all existing plan-level tests keep working unchanged this phase.
6. Delete `PlanningContext` and the `handle*`/`processNewItems` chain once green.
7. Tests: one named test per table row (`rowNN_…`); a generated 2–4-location fact-product sweep asserting totality plus the three meta-properties of `10 §2`; enhancement-pass tests incl. hashless fallbacks; all existing planner tests pass via the adapter with identical assertions.

## Prohibitions
No gate/threshold/refusal work (Phase 4); no executor changes; the only permitted behavior changes are rows 7/10/18 becoming loud (`11-migration.md §4.2`); only `src/AetherloomCore/`.

## Acceptance
Suite green (existing planner tests via adapter + ≥ 18 row tests + sweep); `grep -rn "PlanningContext\|handlePathChange\|handleContentChange\|handleDeletion" src/AetherloomCore/Sources` → nothing; `reconcile` has no `default:` over fact patterns; zero new warnings. Report per `agents/README.md`, explicitly confirming which behavior changes you introduced (must be exactly §4.2's rows).
