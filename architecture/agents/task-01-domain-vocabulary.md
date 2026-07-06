# Task 01 — Domain Vocabulary (Migration Phase 1)

## Role
Senior Swift engineer on `AetherloomCore`, the safety-first sync engine of Aetherloom (macOS multi-location folder sync). You perform the foundational model refactor. No features beyond it.

## Read first
`design/architecture/00-overview.md` (invariants), `01-domain-model.md` (your spec), `11-migration.md` (§1 rules, §2 map rows 1–6), then all of `AetherloomCore/Sources` and `Tests`. Run `swift test --package-path AetherloomCore` and record the baseline (expect 20 green).

## Invariants (override this prompt)
Never permanent-delete; failure-absence ≠ deletion; never silently overwrite; unknown comparisons route to preservation; when in doubt, preserve and pause.

## Deliverables
1. `SyncPath` — rename of `CloudPath`, logic kept (normalization, parent/name/extension helpers, `caseInsensitiveKey`).
2. `ItemKind` (`file | folder | symlink(target:)`), `ItemVersion`, `VersionComparison` (`same | different | unknown`) with the fixed precedence: contentHash ⇒ size+modifiedAt ⇒ revisionToken; **no comparable field in common ⇒ `unknown`, and `unknown` never equals anything**. `ItemObservation` — split of `CloudItem` per `01 §3`.
3. `ProviderKind`, `LocationID`, `SyncLocation` per `01 §1`; delete `ProviderID` entirely.
4. `BaseRecord` + `LocationMemory` + `Tombstone` per `01 §4`, replacing `SyncRecord`'s per-service fields.
5. `SyncSet.locations: [LocationID]` + `SyncSettings`; scope moves onto `SyncLocation`.
6. `LocationSnapshot` + `ObservationIndex` (byPath / byItemID / byCaseFoldedPath, built at init) replacing `ProviderSnapshot`'s flat array; `ScanStatus` carries the same three states as today.
7. `PlanningEnvironment` (`now`, `makeID`, `locationNames`) per `01 §7`; thread it into `SyncPlanner`/`ConflictResolver` call sites replacing loose `generatedAt` parameters.
8. **Centralize comparisons:** planner `contentSignature`/`sameContent`/`itemChanged` and executor `sameContent`/`sameVersion` all reroute through `VersionComparison` / an `itemChanged(vs base:)` helper on `ItemVersion`. One comparison implementation in the codebase afterward.
9. Mechanically update planner, safety analyzer, executor, fake provider, formatter to compile against the new vocabulary. **Do not restructure their logic** — that is Phases 3–6; keep this diff reviewable as a model change.
10. Port all tests (renamed constructors, identical assertions) + add: two same-kind locations propagate; `.localFolder`+`.nasFolder` set passes create/conflict/delete suites; `BaseRecord` JSON round-trip; `VersionComparison` full matrix incl. unknown-never-equals.

## Prohibitions
No protocol changes beyond compilation needs (Task 02); no planner logic changes; no new deps; only `AetherloomCore/`.

## Acceptance
Suite green (all ported + ≥ 4 new); `grep -rn "ProviderID\|CloudPath\|CloudItem\b\|googleDriveItemID\|oneDriveETag" AetherloomCore/Sources AetherloomCore/Tests` → nothing; no `switch` over `ProviderKind` in `Planning/ Safety/ Execution/`; exactly one version-comparison implementation; zero new warnings. Report per `agents/README.md`.
