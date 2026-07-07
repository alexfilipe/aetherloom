# UI Task 09 — Settings & Provider Placeholders

## Role
Senior SwiftUI engineer. Build the Settings scene panes and the connect-provider placeholder flow — the highest placeholder density in the app, so the placeholder conventions are your primary spec.

## Read first
`architecture/ui/10-screen-settings-and-providers.md` (your spec — implement exactly), `ui/11-functioning-vs-placeholder.md § Placeholder conventions` (binding), `ui/01-design-system.md` §9; current `Views/SettingsView.swift`; the Task-03 Settings scene stub; bridge `BridgePreferences` needs (add it here per `ui/10 §2` if absent).

## Invariants (override this prompt)
No placeholder path may call an `EngineSession` mutation or end in a success state; the Safety pane's non-negotiables are informational locks, never toggles; the advice toggle must genuinely add/remove the advisor from orchestration.

## Deliverables
1. Panes per `ui/10 §1`: General (launch-at-login 🎭, menu-bar toggle ✅ via `@AppStorage`), Safety (default `SafetyThresholds` editor ✅ backed by `BridgePreferences`; non-negotiables section with lock glyphs), Suggestions (advice toggle ✅ — session rebuilds orchestrator config; backend rows: Heuristic ✅ label, Apple Intelligence 🎭 disabled), Providers (rows per `ProviderKind` with exact statuses from the spec table), Demo (demo-session-only ✅, top banner).
2. `BridgePreferences` actor in `AetherloomBridge` (UserDefaults-backed, JSON-encoded core types) + tests: threshold defaults round-trip; new-set drafts consume them; existing sets untouched. (This is the one sanctioned bridge addition in an app task.)
3. Connect-provider sheet per `ui/10 §3`: step rail, honesty copy, `PlaceholderChip`, Cancel/Learn More — cannot end "Connected".
4. Sidebar Settings item opens the scene; old in-window `SettingsView` destination removed.
5. `#Preview`s per pane + connect sheet (two providers).
6. Update `ui/11` matrix rows this task changes.

## Prohibitions
No OAuth/network scaffolding of any kind; no engine-source edits; files: Settings panes, connect sheet, `AetherloomBridge/BridgePreferences` + tests, minimal `AppModel` glue.

## Acceptance
`ui/10 §4` in full — advice toggle verifiably adds/removes chips after next prepare; default-threshold change affects only newly created sets (bridge test); placeholder sweep clean (every 🎭 labeled + inert, fake call logs show zero mutations from placeholder paths). Suite + build green. Report per `agents/README.md`.
