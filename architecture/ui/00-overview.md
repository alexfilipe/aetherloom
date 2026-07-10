# 00 — UI Overview

## Product frame

Aetherloom's window is where a person decides to trust a sync tool with their files. Every screen answers one of the trust questions from `CLAUDE.md`: *which services are connected, which folders are selected, what will sync, what changed, what is risky, what is paused, what needs review.* The visual identity — calm cards, the drifting "aether" mesh, tone-colored status — already exists in the demo shell and is kept; this track gives it a real spine.

The defining constraint: the engine ([../core/](../core/README.md)) is far ahead of the integrations. Real Google Drive, OneDrive, iCloud, local-FS, and NAS providers do not exist yet, and per the development order they must not be started early. So the UI is built **full-stack against the demo world**: a real `SyncOrchestrator`, real planner, real gates, real journal, real activity log — fed by `FakeStorageProvider`s seeded with a believable file universe. The pixels users will eventually see are driven by the exact code paths real providers will drive.

## Principles

1. **The engine decides, the UI presents.** The UI never computes a sync decision, a threshold, a conflict, or a deletion inference. It renders `ChangePreview`, `HoldNotice`, `RefusalNotice`, `ConflictDecision`, `ActivityEntry` — values the engine already explains in user language.
2. **Trust through specificity.** Vague spinners breed suspicion. Every state shows *what* and *why*: which provider is unreachable, which folder tripped the mass-delete gate, which two versions diverged and when.
3. **Refusals are calm, not alarming.** A refusal means "nothing will happen until reality changes" — render it as patience ("Paused for safety", "Provider unavailable"), never as a red error with a retry-harder button. There is **no force-sync affordance anywhere in the app.**
4. **Approval is informed and explicit.** Gated plans require the user to see counts of trash moves and conflicts before "Sync now" enables. The UI constructs `PlanApproval` with acknowledged counts; the engine re-validates them (fingerprint, expiry, counts) — the UI never bypasses that.
5. **Advice wears a badge.** AI suggestions render as clearly attributed, dismissible annotations with a rationale — never as pre-selected defaults, never auto-applied.
6. **Placeholders are honest.** Future capabilities appear (so the app frame is complete) but are labeled and inert; see the conventions in [11-functioning-vs-placeholder.md](11-functioning-vs-placeholder.md#placeholder-conventions).
7. **Native first.** Standard macOS structure — `NavigationSplitView`, toolbar, menu commands, Settings scene, keyboard access, VoiceOver labels — with brand character layered on top, not instead.

## Layering

Strict one-way dependencies:

```text
AetherloomCore        engine: SyncOrchestrator, planner, gates, stores, fakes      [../core/]
   ▲
AetherloomBridge      NEW library target in the AetherloomCore package             [03, 04]
   │                  EngineSession protocol · DemoEngineSession (actor)
   │                  DemoWorld script · EngineEvent stream
   │                  display models + formatters (pure, tested)
   │                  imports: AetherloomCore, Foundation — NO SwiftUI/AppKit
   ▲
AetherloomApp         SwiftUI only                                                 [02, 05–10]
   ├─ AppModel        @MainActor ObservableObject: navigation, sheet routing,
   │                  cached bridge snapshots, event subscription
   ├─ Design/         Theme, components (design system)                            [01]
   └─ Views/          one file per screen; render display models; no engine calls
                      except through AppModel → EngineSession
```

Rules that keep the layers honest:

- Views read `AppModel` through SwiftUI ownership (`@StateObject` at the scene root, `environmentObject`/observed references below); they never hold an `EngineSession` directly and never `import AetherloomCore` for anything but value types being displayed.
- `AppModel` is thin: navigation state, in-flight flags, cached snapshots from the session, and async intents that forward to the session. Anything computable from core values lives in `AetherloomBridge` display mappings, where `swift test` reaches it.
- `AetherloomBridge` holds no UI types: colors, fonts, and SF Symbol names appear only as semantic tokens (e.g. `tone: .attention`, `symbol: .providerICloud`) that the app maps to real styling.

## One interaction, end to end

"Sync now" on the *Documents* sync set — everything below is real code (✅), no mocked responses:

```text
View button ─▶ AppModel.syncNow(setID)
  ─▶ EngineSession.prepare(syncSetID)                    SyncOrchestrator.prepare()
        availability → scan → reconcile → plan → gate → ChangePreview (+ advice)
  ◀─ SyncPreparation
  gate clear?  ── yes ─▶ EngineSession.execute(preparation, approval: nil)
  │                        journal → verify → apply → verify → BaseRecords update
  │                      ◀─ SyncRunSummary → toast + Activity refresh
  └─ no (holds) ─▶ AppModel presents PreviewChangesSheet
                     user reviews sections, acknowledges trash/conflict counts
                     ─▶ PlanApproval(fingerprint, counts) ─▶ execute(…, approval)
                     engine re-validates approval; drift ⇒ stoppedForReplan ⇒
                     UI says "Files changed while you were reviewing — preview again."
```

The `EngineEvent` stream (activity appended, run finished, availability changed) fans out to `AppModel`, which refreshes cached snapshots so Overview badges, sidebar counts, and the Activity feed stay live without polling.

## Architecture decisions & rejected alternatives (ADR summary)

| Decision | Chosen | Rejected, and why |
| --- | --- | --- |
| UI ↔ engine seam | **`EngineSession` protocol** in a new `AetherloomBridge` target; demo implementation composes the real orchestrator over fakes | (a) Wiring views to `SyncOrchestrator` directly — bakes demo composition into views, untestable without the app; (b) keeping the hardcoded `DemoStore` — zero engine coverage, UI drifts from real value shapes (it already has: no refusal/hold distinction, no fingerprints, no acknowledged counts) |
| Bridge placement | Library target inside the `src/AetherloomCore` package (like `AetherloomIntelligence`) | App-target-only code — `xcodebuild test` is the only harness, CI cost, and the temptation to reach into views; a separate package — dependency ceremony for no isolation gain |
| State pattern | One `@MainActor ObservableObject` `AppModel`, owned by the scene as `@StateObject`, plus small local view state; see [13](13-startup-bootstrap-lessons.md) for why startup ownership and isolation are explicit | One god `DemoStore` (current) — becomes the "large view model that contains sync logic" `CLAUDE.md` bans; rebuilding the app around per-screen view models — ceremony without moving engine logic into the testable bridge |
| Demo data | **Scripted demo world executed through the real engine**: seed fakes → run a converging pass to build real `BaseRecord`s → apply scripted divergences | Hardcoded sample structs (current) — can silently contradict engine semantics; recorded JSON fixtures — rot the moment core types evolve |
| Placeholder policy | Every screen and flow exists; unimplemented capabilities are visible, labeled, inert | Hiding unfinished areas — the app frame never gets exercised as a whole; silently faking success — violates "report outcomes faithfully" and trains users to distrust the real thing later |
| Pause semantics | Pause is **bridge state** (session skips paused sets; persisted with demo workspace), since the core has no pause concept by design | Adding pause to `SyncSet` in core — a UI scheduling concern would leak into the pure engine |
| Advice source | `HeuristicConflictAdvisor` (core, deterministic) in the demo session; `FoundationModelConflictAdvisor` slot documented | Wiring FoundationModels now — nondeterministic demos, Apple Silicon requirement for contributors |
| Status color system | Existing 4-value `Tone` (healthy/attention/paused/neutral), derivation centralized in bridge | Per-view ad-hoc color logic (current, partially) — inconsistent meaning of orange vs red across screens |

## Relationship to the current code

`src/AetherloomApp/` today: `AetherloomAppApp` (WindowGroup + About panel), `ContentView` (split view, sidebar, toolbar), five screens + two sheets, all reading a hardcoded `DemoStore`, styled by `Design/Theme.swift`. Everything visual survives. `DemoStore` and its sample types (`CloudService`, `ServiceStatus`, `SyncSet`(UI), `PlannedChange`, `ActivityItem`, `FileConflict`) are **retired in phases** ([agents/README.md](agents/README.md)): the bridge and display models take over screen by screen, and task-10 deletes the last of it. The UI's `SyncSet`/`Tone` name collisions with core types are resolved in [04-display-models.md](04-display-models.md#naming).
