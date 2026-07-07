# UI Task 03 — App Shell & Navigation

## Role
Senior SwiftUI engineer on macOS. You replace the demo shell's spine — `AppModel` over the bridge instead of `DemoStore` — while keeping the approved look pixel-faithful.

## Read first
`architecture/ui/02-shell-and-navigation.md` (your spec — implement exactly), `ui/00-overview.md` (layering), `ui/01-design-system.md` §5–§7; current `src/AetherloomApp/AetherloomApp/` in full (`AetherloomAppApp.swift`, `ContentView.swift`, `Design/Theme.swift`, `ViewModels/DemoStore.swift`). Build the app and run core tests first; record baselines.

## Invariants (override this prompt)
Views never hold an `EngineSession`; all engine access via `AppModel` intents; no sync logic in the app target; single sheet via `activeSheet`; no force-sync affordance anywhere.

## Deliverables
1. `AppModel` per `ui/02 §2`: navigation, `activeSheet` routing, cached snapshots, `busySyncSets` re-entry guard, event-loop task, the listed intents. Screens not yet reshaped (tasks 04–09) keep rendering `DemoStore` data — inject both during transition; `AppModel` owns `DemoStore` retirement progress notes in code comments.
2. Scenes per `ui/02 §1`: session constructed once (`DemoEngineSession.standard()` — add that factory to the bridge if Task 01 didn't); branded loading state on `bootstrapPhase`; `Settings` scene stub (pane shells only; content is Task 09); `MenuBarExtra` placeholder per `ui/02 §6`.
3. Sidebar per `ui/02 §3`: live badges from `WorkspaceSnapshot`, status footer from `WorkspaceStatus` (extract `ToneDot`).
4. Toolbar per `ui/02 §4`: Scan Now (prepare-all, no execution), Preview Changes (menu when multiple pending), New Sync Set. Wire to intents; keep icons/prominence.
5. `AetherloomCommands` per `ui/02 §5` incl. the Demo menu calling `DemoScenarioControls` (menu absent for non-demo sessions).
6. New design-system components used by the shell: `ToneDot`, `RunResultToast`, `PlaceholderChip` (per `ui/01 §5`).
7. `@SceneStorage` for `selectedDestination`; `#Preview`s for loading/ready shell states using a `PreviewEngineSession` fixture (add to bridge test-support if needed).

## Prohibitions
Do not reshape screen content views (tasks 04–09); do not delete `DemoStore` yet (Task 10); no engine-source edits; no new dependencies.

## Acceptance
App builds and launches into the demo world: sidebar badges and footer reflect real bridge state while screen bodies still show demo content; Demo menu toggles change the footer/badges within one scan; `⌘1–⌘4`, `⌘R`, `⇧⌘P`, `⌘N`, `⌘,` all work; core+bridge suite untouched and green; zero new warnings. Report per `agents/README.md`.
