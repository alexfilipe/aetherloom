# 06 — Screen: Sync Sets

Where users define and manage what stays in sync. 🔁 Reshape of `Views/SyncSetsView.swift` + `Views/NewSyncSetSheet.swift`; adds a detail surface that today doesn't exist.

## 1. List

Cards (one per `SyncSetState`), existing visual design:

- Header row: name, `StatusBadge(statusLine.text, tone)`, overflow menu.
- Location chips: `ServiceMark` + folder scope path per location, unavailable locations dimmed with their availability reason on hover.
- Metrics row: tracked items · last sync (relative) · pending summary (from `PreparationDigest`: "3 updates, 2 additions waiting" — composed by `DisplayFormatting`, counts from the engine).
- `safetyNote` (when present) as a footnote in tone color — verbatim canonical sentence.
- Actions: **Preview Changes** · **Sync Now** · **Pause/Resume**.

| Interaction | Behavior | Status |
| --- | --- | --- |
| Sync Now | `AppModel.syncNow(id)`: prepare → execute if clear, else preview sheet | ✅ |
| Preview Changes | prepare → sheet [07] always | ✅ |
| Pause / Resume | `session.setPaused` — bridge state, skipped by scans, badge flips to "Paused by you" | ✅ (bridge-level) |
| Card click | opens detail (§2) | ✅ |
| Overflow → Delete Sync Set… | confirmation alert ("Stops syncing; never touches files"), removes set + base records in bridge | ✅ |
| Overflow → Reveal in Finder | disabled, `PlaceholderChip` — no real folders exist in the demo world | 🎭 |

Empty state: `EmptyStateView` + New Sync Set button.

## 2. Detail (sheet-style panel, `activeSheet = .syncSetDetail(id)`)

```text
name + status header
Locations        one row per location: mark, name, scope path, availability badge,
                 [Change Folder…] 🎭 (disabled, "arrives with real providers")
Mode             SyncMode picker: Balanced mirror / Ask before deleting / Don't propagate deletes  ✅
                 (writes via updateSettings → affects real planning on next run)
Safety           thresholds editor: mass-delete count/ratio, mass-edit count/ratio  ✅ (real SyncSettings)
                 explanatory copy: "Aetherloom pauses and asks when changes exceed these."
Exclusions       list of SyncExclusion patterns + add/remove (matchStyle picker)  ✅
Danger zone      Delete Sync Set  ✅
History          last 10 runs: outcome, counts, link into Activity filtered to runID  ✅
```

Every edit round-trips through `SyncSetDraft`/`updateSettings` and is visible in the next preparation (e.g. add exclusion `*.tmp` → excluded file disappears from preview). This is deliberate: settings are the one place the UI *configures* the engine, and it must use the engine's own types.

## 3. New Sync Set wizard (`⌘N`)

Three steps in a 520 pt sheet, replacing today's single form:

1. **Name & mode** — name field (default "New Sync Set", validated non-empty/unique), `SyncMode` picker with plain-language descriptions.
2. **Locations** — checklist of `LocationState`s (mark, name, availability). Rules enforced live: minimum 2; unavailable locations selectable but flagged "will pause sync until reachable" (informed, not forbidden). Scope per selected location: text field with the demo folder tree hint; a real folder picker is 🎭 (`PlaceholderChip("Picker arrives with real providers")`).
3. **Review** — summary card mirroring the list card; note "Nothing syncs until you preview and approve the first plan."

Create → `session.createSyncSet(draft)` → card appears as "Never synced" (neutral) → first **Sync Now** genuinely flows: scan → plan (creations propagate) → preview → execute. ✅

Whole-drive selection (`SyncScope.entireDrive`) is allowed but the review step pins a standing note: "Whole-drive sync always requires review before each first run" — matching engine gating expectations. ✅

## 4. States

- Preparing/executing: card shows stage spinner in place of the pending summary; actions disabled for that set only.
- Refused set: actions stay enabled (a scan is harmless and is how the refusal clears), Sync Now simply re-prepares and re-renders the refusal.
- Never-run set: metrics show "—", pending summary "Preview changes after the first scan".

## 5. Acceptance criteria

- Demo world renders 4 cards with states: Documents `attention` (holds), Projects `attention` (mass deletion), Photos Archive `paused` (refusal), Whole Drive Mirror `paused` (by user).
- Creating "Test" over iCloud+Local, adding a file via Demo menu conflict control excluded — then Sync Now produces a real preview with real creations; executing converges it (verify via Activity).
- Threshold edit on Projects (raise mass-delete absolute above 30) → next prepare has **no** mass-deletion hold: proof the settings path reaches the real gate. (Copy in the editor warns about weakening safety.)
- Deleting a sync set never emits any provider mutation (assert via fake call logs in bridge tests).
