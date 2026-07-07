# UI Task 04 — Overview Screen

## Role
Senior SwiftUI engineer. First screen reshape: `OverviewView` moves from `DemoStore` samples to bridge data, visually unchanged.

## Read first
`architecture/ui/05-screen-overview.md` (your spec — implement exactly), `ui/01-design-system.md` §5 (`MetricTile`, `InlineBanner`, `PlaceholderChip`), `ui/04-display-models.md`; current `Views/OverviewView.swift` and `Design/Theme.swift`; the Task-03 `AppModel`. Baselines green first.

## Invariants (override this prompt)
Refusals render calm (`InlineBanner`, no retry-harder); hold banners use engine `HoldNotice.message` verbatim; no counts computed in the view — everything arrives via display models.

## Deliverables
1. `OverviewView` per `ui/05`: banners (holds → `SafetyBanner`, refusals → new `InlineBanner`), hero card driven by `WorkspaceSnapshot` + `MetricTile`s, service tiles from `LocationState` + `statusLine`, pending-changes card from `PreviewDisplay`, recent activity from `ActivityRowDisplay`.
2. Interactions per `ui/05 § Interactions` with exact statuses: Sync All Now ✅, banner Review → preview sheet ✅, tile → filtered Sync Sets ✅, Connect… → `.connectProvider` sheet routing 🎭 (sheet body itself is Task 09 — route to a minimal labeled stub), NAS Wake & Mount 🎭-labeled demo control.
3. New components `MetricTile`, `InlineBanner` in `Design/` per `ui/01 §5`.
4. States per `ui/05 § States`: all-in-sync, busy (per-set disable), empty workspace.
5. `#Preview`s: populated (standard demo), all-in-sync, busy, empty.
6. Update `architecture/ui/11-functioning-vs-placeholder.md` if any status differs from spec.

## Prohibitions
No other screen files; no `DemoStore` deletion (its Overview usages go away, the type stays until Task 10); no engine-source edits.

## Acceptance
`ui/05 § Acceptance criteria` in full, including: standard demo world shows the mass-deletion banner, the NAS refusal banner, OneDrive paused tile, live pending/activity cards; zero sample literals remain in `OverviewView.swift` (grep for `sampleServices|2 min ago|alex@example`); Demo menu toggles propagate through events; suite + build green. Report per `agents/README.md`.
