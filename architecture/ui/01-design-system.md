# 01 — Design System

The design system already exists in embryo in `src/AetherloomApp/AetherloomApp/Design/Theme.swift` and is the approved product look. This document makes it normative, fills gaps (typography scale, motion, accessibility, focus/keyboard), and defines the split between **semantic tokens** (named meanings, defined in `AetherloomBridge` where needed by display models) and **concrete styling** (colors/fonts/materials, defined only in the app target).

## 1. Brand

- **Accent**: `Theme.accent` — indigo `Color(red: 0.42, green: 0.36, blue: 0.92)`, the "loom thread". Applied as the app-wide `.tint`.
- **Weave gradient**: accent → teal, top-leading → bottom-trailing. Used for the logo chip, empty-state icons, and small accents. Never for large text.
- **Aether mesh** (`WeaveMesh`): the slowly drifting 3×3 `MeshGradient` over the deep-indigo `Theme.meshColors`. Reserved for the Overview hero card only — one vivid surface per window, identical in light and dark mode.
- **Backdrop** (`ContentBackdrop`): window background color plus two faint radial washes (accent top-leading, teal bottom-trailing). Sits behind every screen's scroll view.

## 2. Tone — the status language

`Tone` is the single vocabulary for state color across the app. Its derivation from engine values is centralized in the bridge ([04-display-models.md](04-display-models.md#tone-derivation)); views never invent tones.

| Tone | Color | Symbol | Meaning (exhaustive) |
| --- | --- | --- | --- |
| `healthy` | green | `checkmark.circle.fill` | converged, available, completed |
| `attention` | orange | `exclamationmark.circle.fill` | needs review: holds, open conflicts, pending gated plan |
| `paused` | red | `pause.circle.fill` | refusal or user pause: provider unavailable, paused for safety, paused by user |
| `neutral` | secondary | `circle.fill` | waiting, in progress, never-run, informational |

Rules: red never means "error, act now" — it means "safely stopped"; copy under a red badge always says what Aetherloom is *protecting*, not what "failed". Orange is the only tone that requests user action. Tone colors are always paired with a symbol and text — color is never the sole signal (accessibility).

## 3. Color roles

| Role | Definition |
| --- | --- |
| Window background | `ContentBackdrop` (never flat `.windowBackgroundColor` alone) |
| Card surface | `.controlBackgroundColor` in a 14 pt rounded rect (`Theme.cardCornerRadius`), 1 pt primary-opacity gradient border, soft shadow (`.card()` modifier) |
| Hero surface | `WeaveMesh`, white foreground, `StatusBadge(onDark: true)` |
| Safety surface | orange 8 % fill + orange 30 % border (`SafetyBanner`) — reserved for holds needing review |
| Provider identity | per-provider gradient chips (`ServiceMark`): iCloud cyan→blue, Google green→teal, OneDrive blue→indigo, Dropbox indigo→blue, Local slate, NAS purple→indigo |

Both appearances must be checked for every new surface; the hero and provider chips are intentionally appearance-invariant.

## 4. Typography

System font throughout. `.rounded` design is the brand voice for **titles only**.

| Style | Usage |
| --- | --- |
| `.largeTitle.bold` + rounded | Page titles (`PageHeader`) |
| `.headline` | Card titles, section headers (`SectionHeader`), sidebar app name |
| `.subheadline` | Card body, row subtitles |
| `.callout.secondary` | Page subtitles |
| `.caption.weight(.semibold)` | Badges (`StatusBadge`) |
| `.caption2.secondary` | Timestamps, footnotes, placeholder labels |
| `.body.monospaced` | Paths, filenames in detail contexts, fingerprints |

Numbers that update live (counts, sizes) use `.contentTransition(.numericText())`.

## 5. Components (canonical inventory)

Existing, kept as-is: `card(padding:hoverLift:)`, `StatusBadge`, `ServiceMark`, `AppLogoMark`, `PageHeader`, `SectionHeader`, `EmptyStateView`, `SafetyBanner`, `WeaveMesh`, `ContentBackdrop`.

New in this track (built once in `Design/`, reused by screens):

| Component | Spec |
| --- | --- |
| `ToneDot` | 8 pt circle + glow used in the sidebar footer; extracted from `ContentView` |
| `MetricTile` | big numeric + caption, used on Overview hero and sync set detail |
| `PathText` | middle-truncating monospaced path with copy-on-click and tooltip of the full path |
| `AdviceChip` | sparkle symbol + "Suggestion" + confidence dot; expands to rationale; explicit "On-device suggestion — you decide" footer; never orange/red (advice is not a warning) |
| `PlaceholderChip` | small capsule reading "Coming soon" (or contextual variant); the standard marker for 🎭 surfaces |
| `CountAcknowledgeRow` | checkbox row "Move N items to trash" / "N conflicts — both versions preserved" used by the approval footer |
| `RunResultToast` | transient bottom-trailing capsule summarizing a `SyncRunSummary` (applied/skipped/failed counts); auto-dismisses, click opens Activity filtered to the run |
| `InlineBanner` | neutral/paused variant of `SafetyBanner` for refusals (calm slate/indigo, shield icon) — refusals must not reuse the orange review styling |

## 6. Layout metrics

- Window: default 1180×760, minimum 980×620. Detail column minimum 760.
- Sidebar: 200–280 pt, ideal 230.
- Screen content: `ScrollView` + `LazyVStack`, content max-width 980 pt centered, 24 pt outer padding, 16 pt inter-card spacing.
- Cards: 18 pt internal padding (dense lists 12–14 pt).
- Sheets: Preview Changes 720×560 (resizable); wizards 520 pt fixed width.

## 7. Motion

- Default: `.animation(.smooth)` on state-driven layout changes; `withAnimation(.smooth)` around snapshot refreshes.
- Card hover lift: existing scale 1.008 + shadow, 0.25 s.
- The mesh drifts at 30 fps via `TimelineView`; it must pause when the window is occluded (use `\.scenePhase`/occlusion state) — battery respect.
- Progress: indeterminate `ProgressView` for scans (< 3 s in demo); stage names ("Scanning", "Planning") come from the engine's activity stream, not invented client-side.
- Honor `accessibilityReduceMotion`: freeze the mesh, drop hover lift, replace numeric transitions with opacity.

## 8. Iconography

SF Symbols only, `.medium` weight default. Canonical assignments (do not improvise new ones for the same concept):

sidebar — overview `circle.hexagongrid.fill`, sync sets `folder.badge.gearshape`, activity `clock.arrow.circlepath`, conflicts `doc.on.doc`, settings `gearshape`; actions — sync `arrow.triangle.2.circlepath`, preview `doc.text.magnifyingglass`, add `plus`, pause `pause.circle`, resume `play.circle`; safety — shield `shield.lefthalf.filled`, trash `trash`, review `exclamationmark.circle.fill`; advice — `sparkles`; providers — per `ServiceMark` (placeholder glyphs until real brand marks are licensed — themselves 🎭).

## 9. Language

Canonical engine sentences ([../core/00-overview.md](../core/00-overview.md#canonical-language)) render verbatim, always the first line of their surface. UI-authored copy: calm, specific, second person, no jargon ("provider", not "backend"; "review", not "resolve blockers"), no exclamation marks, no blame ("Files changed while you were reviewing" — not "Approval invalid"). Buttons are verbs: "Preview Changes", "Sync Now", "Review", "Keep Both", "Choose This Version", "Move to Trash". Placeholder copy always names the future capability: "Connecting Google Drive arrives with the real provider integrations."

## 10. Accessibility & input

- Every interactive element: `accessibilityLabel`; badges combine into one element ("Documents, up to date").
- Full keyboard path for the approval flow: sheet focus order = holds → sections → acknowledgments → cancel/approve; `Esc` cancels; approve is `⌘Return` (never plain Return — approval must be deliberate).
- Sidebar navigation `⌘1–⌘5`; `⌘R` scan; `⇧⌘P` preview; `⌘N` new sync set; `⌘,` settings.
- Hit targets ≥ 24 pt; test at 1.5× Dynamic Type equivalent (`.controlSize` respects user settings).
- VoiceOver announcement on run completion and on new holds (`AccessibilityNotification.Announcement`).
