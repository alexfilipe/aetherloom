# Aetherloom UI Architecture

This directory is the canonical design for Aetherloom's **native macOS SwiftUI app** — written as the UI *should be*, evolving today's demo shell in `src/AetherloomApp/` into the full-stack app frame. The strategy is deliberate: build the **complete UI surface now**, run it against the **real sync engine wired to fake providers** (a "demo world"), and leave real provider integrations, OAuth, and filesystem access as clearly marked placeholders. When real providers arrive, they slot in behind an already-proven seam.

Two audiences:

1. **Developers** — read the numbered documents in order. 00–02 give the frame, design language, and shell; 03–04 are the engine bridge (the heart of this track); 05–10 specify each screen; 11 is the authoritative functioning-vs-placeholder matrix; 12 is verification.
2. **Implementation agents** (Claude, Codex, GPT-5.5, …) — each file under [agents/](agents/) is a self-contained work order for one phase. See [agents/README.md](agents/README.md) for the dispatch graph.

## Scope

In scope now: the app shell, design system, navigation, all primary screens (Overview, Sync Sets, Preview & Approval, Conflicts, Activity, Settings), the `AetherloomBridge` layer that drives them from a real `SyncOrchestrator` running against `FakeStorageProvider`s, a scripted demo world exercising every safety behavior, and placeholder surfaces for provider connection.

Out of scope now: OAuth and real cloud APIs, real filesystem/NAS providers, FSEvents watchers, background sync, menu-bar agent behavior (the Settings toggle is a labeled placeholder; the scene is deferred), App Store sandboxing, notifications, localization beyond English.

## Document map

| Doc | Contents |
| --- | --- |
| [00-overview.md](00-overview.md) | UI principles, layering, the demo-world decision, architecture decisions & rejected alternatives |
| [01-design-system.md](01-design-system.md) | Tokens, tone system, components, typography, motion, iconography, accessibility, language |
| [02-shell-and-navigation.md](02-shell-and-navigation.md) | Scenes, window chrome, sidebar, toolbar, commands, badges, status footer, Demo menu |
| [03-engine-session.md](03-engine-session.md) | `AetherloomBridge`: the `EngineSession` protocol, `DemoEngineSession`, the demo world script, events |
| [04-display-models.md](04-display-models.md) | Pure mappings from core values to display values; formatting; tone derivation |
| [05-screen-overview.md](05-screen-overview.md) | Overview: hero status, service tiles, pending changes, safety banners, recent activity |
| [06-screen-sync-sets.md](06-screen-sync-sets.md) | Sync set cards, detail, pause/resume, the New Sync Set wizard |
| [07-screen-preview-and-approval.md](07-screen-preview-and-approval.md) | `ChangePreview` rendering, holds and refusals, acknowledged approval, execution results |
| [08-screen-conflicts.md](08-screen-conflicts.md) | Conflict review, version comparison, on-device advice display, resolution recording |
| [09-screen-activity.md](09-screen-activity.md) | The accountability feed: filters, run grouping, detail |
| [10-screen-settings-and-providers.md](10-screen-settings-and-providers.md) | Settings panes; provider connect placeholders |
| [11-functioning-vs-placeholder.md](11-functioning-vs-placeholder.md) | **Authoritative matrix**: what is real, what is scaffold, what is visual-only |
| [12-testing-strategy.md](12-testing-strategy.md) | Bridge tests, display-model tests, preview coverage, visual QA policy |
| [13-startup-bootstrap-lessons.md](13-startup-bootstrap-lessons.md) | Launch hang investigation: what fixed startup, what did not, and what not to repeat |
| [agents/](agents/) | Ten self-contained implementation work orders |

## Ground rules

- **The engine decides, the UI presents.** No sync rules, thresholds, comparisons, or deletion inference in the app target or in `AetherloomBridge` display mappings. The UI's power is limited to: request a preparation, show it faithfully, collect explicit approval, request execution, show what happened.
- **Safety invariants** ([../core/00-overview.md](../core/00-overview.md#safety-invariants)) bind the UI too. Concretely: approval UI must make trash and conflict counts explicit before enabling "Sync now" (invariant 4/6); advice is never pre-applied (invariant 7); refusals render as calm pauses, never as errors demanding "force" actions — no "force sync" affordance exists anywhere.
- **Canonical language** from [../core/00-overview.md](../core/00-overview.md#canonical-language) is used verbatim; the UI adds detail beneath engine sentences, never rewrites them.
- **Placeholders are honest.** Every placeholder interaction produces visible feedback labeled as a preview of a future capability (see [11-functioning-vs-placeholder.md](11-functioning-vs-placeholder.md#placeholder-conventions)); nothing pretends to have synced a real byte.
- **Visual parity matters.** The current demo shell's look — cards, mesh hero, tone badges — is the approved product design and the source of the website's screenshots. Reshaping replaces data sources, not aesthetics, unless a screen doc says otherwise.
- `AetherloomBridge` imports `AetherloomCore` and Foundation only — no SwiftUI, no AppKit — so `swift test` covers it. The app target holds SwiftUI and AppKit glue only.

## Status legend

Used throughout these documents and in code comments:

- ✅ **Functioning** — backed by real `AetherloomCore` behavior (through the demo world's fake providers) or by real bridge state. The interaction does what it says within the demo world.
- 🎭 **Placeholder** — visual and interactive scaffold for a future capability; produces honest mock feedback, changes no engine state.
- 🔁 **Reshape** — exists today in the demo shell with hardcoded sample data; keeps its visual design, switches to the bridge.
