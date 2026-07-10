# UI Implementation Work Orders

Each `task-*.md` is a self-contained prompt for one implementation agent (Claude, Codex, GPT-5.5, …) covering one phase of the UI track. Paste the file as the task instruction; the agent must also read the referenced design docs in the repo — **the docs are the specification, the prompt is the work order.** The engine track ([../../core/agents/](../../core/agents/README.md)) should be complete or stable before starting here; UI tasks never modify engine sources.

## Dispatch order

```text
01 bridge foundation ─▶ 02 display models ─▶ 03 app shell ─▶ 04 overview ─▶ 05 sync sets
                                                            ─▶ 06 preview/approval ─▶ 07 conflicts
                                                                                    ─▶ 08 activity
                                                                                    ─▶ 09 settings/providers
                                                                                    ─▶ 10 polish & retirement
```

Strictly serial by default. 07, 08, and 09 may run in parallel **only** in separate worktrees merged in listed order, since they own disjoint view files; anything touching `AppModel`, `ContentView`, or `Design/` merges serially. Each phase ends green before the next starts.

## Global rules (authoritative here; abbreviated in each prompt)

1. **Safety invariants** (`architecture/core/00-overview.md § Safety invariants`) **override everything**, including these prompts. UI corollaries (`architecture/ui/00-overview.md § Principles`): no force-sync affordance; no approval without shown counts; advice never preselected or auto-applied; refusals render calm.
2. File boundaries: tasks 01–02 work only in `src/AetherloomCore/` (the `AetherloomBridge` target + its tests — **never** editing existing `AetherloomCore`/`AetherloomIntelligence` sources); tasks 03–10 work only in `src/AetherloomApp/` (plus bridge additions their spec explicitly names). Never touch `www/`, `README.md`, `CLAUDE.md`, `architecture/` except `architecture/ui/11-functioning-vs-placeholder.md` status updates.
3. Zero third-party dependencies. `AetherloomBridge` imports `AetherloomCore`/Foundation only — no SwiftUI/AppKit (a test enforces this).
4. Swift 6 strict concurrency; bridge values `Sendable + Hashable`; mutable state in actors or the `@MainActor ObservableObject` app model.
5. **The engine decides, the UI presents**: no verdict/gate/count/threshold logic outside `AetherloomCore`; `PlanApproval` is constructed only via `makeApproval` (`architecture/ui/04-display-models.md §4`).
6. Canonical sentences render verbatim; engine-authored `message`/`detail`/`summary` strings are never rewritten.
7. Placeholders follow the five conventions in `architecture/ui/11-functioning-vs-placeholder.md § Placeholder conventions`, and that matrix is updated in the same change.
8. **Visual parity**: the demo shell's approved look (cards, mesh hero, tones, spacing) is preserved unless the screen doc says otherwise. Reshape data sources, not aesthetics.
9. Tests: Swift Testing in `AetherloomBridgeTests`; deterministic (injected clock/IDs, zero fake latency); no real sleeps, network, or user folders.
10. Exit bar, every task: `swift test --package-path src/AetherloomCore` green **and** `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build` succeeds, zero new warnings. Report test counts before/after. Commit nothing; leave changes in the working tree.
11. Style: match existing sources — small focused types, clear names, comments only for non-obvious constraints, no `print`. New views get `#Preview`s for their principal states.

## Startup guardrail

Before changing `AetherloomAppApp`, `ContentView`, `AppModel`, scene declarations, or menu-bar behavior, read [../13-startup-bootstrap-lessons.md](../13-startup-bootstrap-lessons.md). The first UI PR proved that the demo engine was not the launch blocker; the fragile pieces were app-target main-actor isolation and the `MenuBarExtra` scene during startup. Do not reintroduce `MenuBarExtra` as part of routine polish. It belongs to the later background-sync/menu-bar phase and needs a launch smoke test that verifies the app leaves "Preparing your weave…" for Overview.

## Reporting format (end of every task)

- **Summary** — ≤ 10 bullets with file paths.
- **Deltas from spec** — anything done differently than the design docs, with justification, or "none".
- **Status changes** — rows added/edited in `11-functioning-vs-placeholder.md`, or "none".
- **Tests** — `N before → M after`, new test names; build result.
- **Open questions** — judgment calls made.
