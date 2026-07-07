# UI Task 05 — Sync Sets Screen, Detail & Wizard

## Role
Senior SwiftUI engineer. Reshape the sync set list, add the detail panel, and rebuild the New Sync Set wizard on real drafts.

## Read first
`architecture/ui/06-screen-sync-sets.md` (your spec — implement exactly), `ui/04-display-models.md` §2–§3; current `Views/SyncSetsView.swift`, `Views/NewSyncSetSheet.swift`; bridge `SyncSetDraft`/`updateSettings`/`createSyncSet`. Baselines green first.

## Invariants (override this prompt)
Threshold/exclusion edits round-trip through core `SyncSettings` — never duplicated app-side; deleting a sync set must not emit any provider mutation; unavailable locations are selectable-with-warning in the wizard, never forbidden (informed choice), and never treated as deletion.

## Deliverables
1. `SyncSetsView` per `ui/06 §1`: cards from `SyncSetState` + `statusLine`, dimmed unavailable location chips with hover reason, actions (Sync Now / Preview / Pause–Resume ✅, Delete with confirmation ✅, Reveal in Finder 🎭 disabled + `PlaceholderChip`).
2. Detail panel per `ui/06 §2` (`activeSheet = .syncSetDetail`): locations (Change Folder… 🎭), `SyncMode` picker ✅, thresholds editor ✅ with weakening-safety warning copy, exclusions editor ✅, danger zone ✅, run history with Activity deep links ✅.
3. Wizard per `ui/06 §3`: three steps, live validation (≥2 locations, unique name), scope text fields with 🎭 picker chip, review step with the whole-drive standing note; `createSyncSet` → "Never synced" card → first Sync Now flows genuinely.
4. States per `ui/06 §4`; `#Preview`s: standard four cards, empty, detail, each wizard step.

## Prohibitions
Only `SyncSetsView.swift`, `NewSyncSetSheet.swift` (rename to `NewSyncSetWizard.swift` if cleaner), a new detail view file, and minimal `AppModel` routing; no other screens; no engine-source edits.

## Acceptance
`ui/06 §5` in full — notably: threshold raise on Projects removes the mass-deletion hold on next prepare (manual check + existing bridge test reference), and a freshly created set syncs end-to-end through preview/approve; no `DemoStore` reads remain in these views; suite + build green. Report per `agents/README.md`.
