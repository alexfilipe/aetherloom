# UI Task 07 — Conflicts Screen

## Role
Senior SwiftUI engineer. Reshape conflict review onto the real `ConflictStore` and the advisory pipeline.

## Read first
`architecture/ui/08-screen-conflicts.md` (your spec — implement exactly), `ui/04-display-models.md` §5, `architecture/core/07-ai-conflict-advisor.md` §1 (hard boundaries you are rendering); current `Views/ConflictsView.swift`; bridge `openConflicts`/`advice(for:)`/`resolveConflict`. Baselines green first.

## Invariants (override this prompt)
Advice never preselects an option and is spatially separate from action buttons; attribution mandatory whenever advice renders; resolution is recorded intent ("Applied on the next sync"), never immediate action; no bulk resolve-with-advice.

## Deliverables
1. `ConflictsView` per `ui/08 §1`: Open/Resolved segments, `ConflictCard` with verbatim canonical sentence, per-location `VersionRow`s ("Most recent" tag from display model), preserved-copy note, `AdviceChip` (expand → rationale, per-version notes, attribution, "you decide" footer, Dismiss), Keep Both / Choose This Version with confirmation popover, Compare… 🎭 disabled + chip.
2. Behaviors per `ui/08 §2` table with exact statuses; advice dismissal persisted per conflict ID as a UI preference (bridge or `@AppStorage` — pick one, justify in report).
3. Deep links per `ui/08 §3`: sidebar badge already live (Task 03); implement scroll-to-and-highlight for `show(.conflicts, focusing:)`.
4. `AdviceChip` component in `Design/` per `ui/01 §5` (also consumed by Task 06 — coordinate: if Task 06 already built it, reuse).
5. `#Preview`s: open with advice, open without advice, resolved tab, empty.

## Prohibitions
Only `ConflictsView.swift` + `Design/AdviceChip` + minimal `AppModel` glue; no engine-source edits.

## Acceptance
`ui/08 §4` in full — Budget.xlsx card complete with heuristic advice; resolve → next sync converges (verify via Activity + demo pass); dismissal survives navigation and logs nothing to the engine; VoiceOver summary reads correctly. Suite + build green. Report per `agents/README.md`.
