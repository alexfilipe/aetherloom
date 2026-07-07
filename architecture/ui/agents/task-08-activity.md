# UI Task 08 — Activity Screen

## Role
Senior SwiftUI engineer. Reshape the activity feed onto the engine's real `ActivityStore` with filters, run grouping, and live streaming.

## Read first
`architecture/ui/09-screen-activity.md` (your spec — implement exactly), `ui/04-display-models.md` §6–§7, `architecture/core/08-observability.md`; current `Views/ActivityView.swift`; bridge `activity(matching:)` + `.activityAppended` events, core `ActivityQuery`/`ActivityCategory`. Baselines green first.

## Invariants (override this prompt)
Messages render verbatim; advisory entries always visibly attributed; category/set filtering goes through `ActivityQuery` (store-side), only search is client-side over the fetched window.

## Deliverables
1. `ActivityView` per `ui/09 §1`: filter bar (category chips, sync set picker, search), run-grouped feed (`runGroups`), expandable monospaced detail, day separators, relative/absolute timestamps, Load More pagination.
2. Behaviors per `ui/09 §2` table with exact statuses: live prepend ✅, outcome badges ✅, conflict deep link ✅, copy context menu ✅, Export… 🎭 disabled + `PlaceholderChip`.
3. Deep-link entry `show(.activity, filteredToRun:)` consumed from `RunResultToast` and sync set history (Tasks 03/05 emit it — wire the receiving side).
4. Presentation rules per `ui/09 §3` (glyphs/tones from the display map only; safety left-border accent).
5. States per `ui/09 §4`; `#Preview`s: populated grouped feed, filtered-empty, fresh-empty.

## Prohibitions
Only `ActivityView.swift` + minimal `AppModel` glue; no bespoke category→color logic in the view (display map only); no engine-source edits.

## Acceptance
`ui/09 §5` in full — bootstrap history visible with working conflict deep link and attributed advisory entry; an approved Documents run renders as one complete group reachable from its toast; interrupted-run recovery entry appears under Safety; filters round-trip through `ActivityQuery`. Suite + build green. Report per `agents/README.md`.
