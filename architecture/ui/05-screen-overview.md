# 05 — Screen: Overview

The first thing users see; answers "is everything okay, and if not, what needs me?" in one glance. 🔁 Reshape of `Views/OverviewView.swift` — layout and styling survive; every value now comes from the bridge.

## Layout

```text
┌─ PageHeader  "Overview" / "Your files, safely woven across every drive."
├─ SafetyBanner (0..n, stacked)          ← holds needing review          [attention]
├─ InlineBanner (0..n)                   ← refusals (calm, not orange)   [paused]
├─ Hero card (WeaveMesh)
│    workspace status headline + StatusBadge(onDark)
│    MetricTiles: tracked items · connected locations · pending changes · open conflicts
│    last scan relative time
├─ SectionHeader "Services"
│    grid of ServiceTile (one per LocationState)
├─ Two-column row
│    ├─ "Pending changes" card                   ├─ "Recent activity" card
│    │   top preview entries + totals            │   last 6 ActivityRowDisplays
│    │   [Preview Changes] button                │   [Open Activity] link
└────┴──────────────────────────────────────────┴───────────────────────────
```

## Data

| Element | Source | Status |
| --- | --- | --- |
| Workspace status, metric tiles | `WorkspaceSnapshot` / `WorkspaceStatus` [04 §3] | ✅ |
| Safety banners | union of `HoldNotice`s across cached `lastPreparation`s; message verbatim; "Review" → preview sheet of that sync set | ✅ |
| Refusal banners | `RefusalNotice`s; "Details" reveals `detail`; no retry button — reality must change (Demo menu can change it) | ✅ |
| Service tiles | `LocationState` → `statusLine(for:)`: provider mark, name, account label, folder scope, tone badge, last-checked | ✅ (account label content 🎭) |
| Pending changes card | `lastPreparation.preview` top entries via `PreviewDisplay` | ✅ |
| Recent activity | `session.activity(matching: .init(limit: 6))` + `.activityAppended` events | ✅ |

## Interactions

| Interaction | Behavior | Status |
| --- | --- | --- |
| Hero "Sync All Now" | `syncNow` per unpaused set; gated sets open the preview sheet instead of executing | ✅ |
| SafetyBanner "Review" | opens Preview sheet scrolled to holds | ✅ |
| Service tile click | Sync Sets screen filtered to sets using that location | ✅ |
| Service tile "Connect…" (shown when `accountLabel == nil` for cloud kinds) | `activeSheet = .connectProvider(kind)` — placeholder sheet [10 §3] | 🎭 |
| NAS tile "Wake & Mount" | demo-only: routes to `DemoScenarioControls.setNASMounted(true)`; labeled with `PlaceholderChip("Demo")` | 🎭 (control) / ✅ (resulting state change is real) |
| Pending card "Preview Changes" | opens sheet [07] | ✅ |

## States

- **All in sync**: no banners; hero reads "Everything in sync" with green badge; pending card shows `EmptyStateView` ("Nothing waiting — Aetherloom checked N minutes ago").
- **Busy**: hero badge shows stage ("Scanning…"); tiles of scanned locations show subtle progress rings; controls that would start runs are disabled per `busySyncSets`.
- **First run / empty workspace** (post demo-reset edge): hero invites "Create your first sync set", prominent `⌘N` button.

## Acceptance criteria

- With the standard demo world, Overview shows: 1 mass-deletion SafetyBanner (Projects), 1 refusal InlineBanner (Photos Archive / NAS), OneDrive tile "Provider unavailable" (paused tone), pending changes from Documents, and live activity — all traceable to engine values, zero literals in the view.
- Demo menu toggles (NAS mount, OneDrive reachable) update tiles and banners within one scan, through events only.
- VoiceOver order: status → banners → tiles → cards. Banner announcement fires when a new hold appears.
