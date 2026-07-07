# 03 — Reconciliation: the Pure Decision Table

The heart of the engine. Reconciliation answers exactly one question, per item: *given what I remember (base) and what I now see everywhere (observations), what is true?* It is a **pure, total, exhaustively-tested function** — no I/O, no clock, no provider calls, no ordering sensitivity.

This replaces the current planner's imperative core (`PlanningContext.handlePathChange → handleContentChange → handleDeletion` fall-through plus `processNewItems`), whose correctness depends on pass ordering and whose "do nothing" default branches are invisible. The behavior it already gets right is preserved; the structure becomes auditable.

## 1. Inputs and precondition

```swift
public struct ReconciliationInput: Sendable {
    public var syncSet: SyncSet
    public var base: [BaseRecord]                    // this set's memory
    public var snapshots: [LocationID: LocationSnapshot]
    public var environment: PlanningEnvironment
}
```

**Precondition (enforced by the caller, [04 §2](04-planning-and-gating.md)):** every location in the set has a snapshot with `status == .complete`. Reconciliation is never invoked otherwise — unavailability and incomplete scans refuse the run *before* any per-item reasoning, so "missing" below always means *positively absent from a complete, healthy scan*.

## 2. Step 1 — derive per-location facts

For each **item key** (join of base records and observations by itemID-then-path, case-folded; exclusions filtered first):

```swift
public enum LocationFact: Hashable, Sendable {
    // With a base record:
    case matchesBase                              // present; version same; path same
    case changed(ItemVersion)                     // present; version different
    case relocated(to: SyncPath)                  // same identity; version same; path different
    case changedAndRelocated(ItemVersion, to: SyncPath)
    case missing                                  // absent from a complete scan
    case waiting                                  // present but placeholder — content truth unknowable
    // Without a base record:
    case appeared(ItemObservation)                // new item
}
```

Fact derivation is where `VersionComparison` ([01 §3](01-domain-model.md)) does its work: `same` ⇒ matches, `different` ⇒ changed, **`unknown` ⇒ treated as `changed` with an unknown version — which can never win an overwrite and therefore lands in preservation rows below.** Placeholders derive `waiting` regardless of reported size/mtime (a dataless stub's metadata is not content). Folders never derive `changed` (folder "versions" are structural).

## 3. Step 2 — the verdict table

```swift
public enum ItemVerdict: Hashable, Sendable {
    case inSync
    case propagateContent(from: LocationID, to: Set<LocationID>)   // edit propagation (upload or version-checked overwrite per destination)
    case propagateCreation(from: LocationID, to: Set<LocationID>)  // new file/folder fan-out
    case propagatePath(to: Set<LocationID>, newPath: SyncPath)     // relocate propagation
    case propagateDeletion(to: Set<LocationID>, initiatedBy: LocationID)  // gated by SyncMode + thresholds downstream
    case conflict(ConflictDecision)                                 // §4 — always preservation-shaped
    case waiting(WaitingReason, locations: Set<LocationID>)         // placeholder-blocked; item skipped this run, reported
}
```

The normative table, generalized to n locations. "Changed sides" = locations whose fact is `changed`/`changedAndRelocated`; base-only rows require a base record; `appeared` rows don't.

| # | Facts pattern | Verdict |
| --- | --- | --- |
| 1 | all `matchesBase` | `inSync` |
| 2 | exactly one changed side; rest match base or missing-nowhere | `propagateContent(from: changed)` |
| 3 | ≥ 2 changed sides, all versions compare `same` | convergent edit → `inSync` (base record refreshed) |
| 4 | ≥ 2 changed sides, any pair `different` or `unknown` | `conflict(.editEdit)` |
| 5 | exactly one `relocated`; rest at base path, versions match | `propagatePath` |
| 6 | ≥ 2 `relocated` to the **same** path | convergent move → `inSync` (base path updated) |
| 7 | ≥ 2 `relocated` to **different** paths | `conflict(.moveMove)` — nothing moves until reviewed |
| 8 | one `changedAndRelocated`, rest match base | `propagateContent` + `propagatePath` (two decisions, one item) |
| 9 | ≥ 1 `missing`; **all** present sides `matchesBase` | `propagateDeletion(to: present, initiatedBy: a missing one)` |
| 10 | ≥ 1 `missing`; ≥ 1 side `changed` | `conflict(.editDelete)` — never trash; edited version re-propagates to the missing locations |
| 11 | ≥ 1 `missing`; ≥ 1 side `relocated` | treat as 5 with absence at others → `propagatePath` + `propagateCreation` to missing; if versions diverge too → `conflict(.editDelete)` |
| 12 | all `missing` | base record ready for tombstone confirmation → `inSync`-with-tombstone (nothing to do at providers) |
| 13 | any `waiting` involved in rows 2, 8, 10 (content needed from/at a placeholder) | `waiting(.contentNotMaterialized)` — skip item, report; **deletion rows are unaffected by placeholders** (placeholder = presence) |
| 14 | `appeared` at one location only | `propagateCreation` |
| 15 | `appeared` at ≥ 2 locations, versions all `same` | convergent creation → `inSync` (mint base record) |
| 16 | `appeared` at ≥ 2 locations, versions `different`/`unknown` | `conflict(.createCreate)` |
| 17 | `appeared` whose case-folded path collides with a different exact path anywhere | `conflict(.caseCollision)` |
| 18 | `appeared` file where destination has folder at path, or vice versa | `conflict(.typeClash)` — folder untouched, file preserved via copy |

The function is **total**: `reconcile(base:facts:) -> ItemVerdict` compiles with no default case over the constructed pattern space, and [10 §2](10-testing-strategy.md) requires a test per row plus generated coverage of the full 4-location fact product. There is no "silently do nothing" branch — today's mute edit-delete handling becomes row 10 by construction.

## 4. Conflicts

```swift
public struct ConflictDecision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ConflictKind        // editEdit, editDelete, createCreate, moveMove, caseCollision, typeClash
    public var path: SyncPath
    public var versions: [ConflictVersion]   // locationID + observation (metadata only)
    public var defaultResolution: Resolution // ALWAYS .preserveAll — the engine's unilateral maximum
    public var message: String               // canonical calm wording
}
```

Every conflict verdict lowers ([04](04-planning-and-gating.md)) to **conflict copies**: each divergent version is uploaded under a deterministic conflict name to every other location; nothing is overwritten or trashed. Conflict naming (✅ today's `ConflictResolver`, kept): `Budget.final.xlsx → "Budget.final (conflict from ⟨location display name⟩, ⟨UTC timestamp⟩).xlsx"`, collision-suffixed, timestamp from the injected environment.

Richer resolution (user picks a canonical version; AI advises) operates on `ConflictDecision` *after* preservation and via preview/approval — specified in [06](06-preview-and-approval.md) and [07](07-ai-conflict-advisor.md). Choosing never deletes: losers remain as conflict copies; removing those copies later is an ordinary reviewed trash.

## 5. Capability-degraded and enhanced modes

- **No stable itemIDs** (plain local/NAS): identity = path; a real rename derives `missing` + `appeared`. Safe by default (rows 9/14 — and row 9 still requires all-else-unchanged). **Enhancement:** before finalizing verdicts, a *move-matching pass* pairs `missing` records with `appeared` observations of identical content hash within the same location and rewrites the pair to `relocated` — restoring cheap renames for hash-capable providers without ever risking a wrong trash (no hash ⇒ no pairing ⇒ safe fallback).
- **Subtree moves:** when a folder with stable identity relocates, descendants all derive `relocated` with a common prefix; a folding pass emits one folder-level `propagatePath` and drops the redundant per-child verdicts. Fallback without folder IDs: per-item handling (noisy, correct).
- **No content hashes:** versions compare on size+mtime; equal-size-different-mtime edits compare `unknown` ⇒ row 4 preservation instead of overwrite. Exactly the conservative bias the invariants demand.

## 6. Changing the current code

Phase 3 of [11-migration.md](11-migration.md) — the deepest cut. Extract every behavior the current `PlanningContext` implements into table rows (its tests name them all: propagation ×6, edit-edit, independent creation, case collisions, exclusions…); implement `deriveFacts` + `reconcile` as pure functions with the existing tests re-pointed at verdicts; then add the rows the current code gets wrong or mutely right: edit-delete (row 10 — today a silent early-return), move-move (row 7 — today falls through), type clash (row 18 — today a silent skip), waiting-item granularity (row 13 — today a whole-set pause; keep the global pause until the preview can report waiting items, then flip). The old imperative planner is deleted only after the verdict-level suite is green and the plan-level golden tests match.
