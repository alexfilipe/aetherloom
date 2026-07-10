# 13 — Startup Bootstrap Lessons

This note records what the first UI PR learned while fixing a launch hang where the app stayed forever on the branded loading screen:

> Preparing your weave…

Keep this file close to the shell, bootstrap, and scene docs. The failure looked like an engine bootstrap problem at first, but the engine was completing; the app could not reliably publish the ready state while the initial SwiftUI scene graph was being built.

## Final resolution

The shipped day-one shape is:

1. Construct `DemoEngineSession.standard()` once in `AetherloomAppApp`.
2. Own `AppModel` with `@StateObject`, pass it to `ContentView`, and provide it through `environmentObject`.
3. Start bootstrap from the first `ContentView.onAppear`, guarded by `startBootstrapIfNeeded()`.
4. Build one `AppBootstrapPayload` in a detached task.
5. Mark the payload loader `nonisolated` so Swift's app-target default main-actor isolation does not quietly pull the work back onto the main actor.
6. Apply the payload on `@MainActor`, then start the event stream and flip `bootstrapPhase` to `.ready`.
7. Defer `MenuBarExtra` entirely until background sync/menu-bar behavior is implemented; Settings shows only a disabled, labeled placeholder.

That combination lets the branded loading screen remain honest while giving the engine enough room to seed the demo world and the SwiftUI window enough room to render the ready shell.

## Paths tried and rejected

### 1. Treating the demo engine as the likely blocker

**What we tried:** Add bridge/session coverage and run the standard session bootstrap outside the app.

**What we learned:** `DemoEngineSession.standard()` can bootstrap, return a workspace, and expose activity from `swift test --package-path src/AetherloomCore`. The hang was not caused by the core planner, fake providers, demo world seeding, activity store, or advisory path.

**Guardrail:** Keep a bootstrap regression test in `AetherloomBridgeTests`, but do not respond to this UI symptom by weakening the engine path or replacing real engine output with fabricated sample state.

### 2. Moving bootstrap between init, `.task`, `Task {}`, and `onAppear`

**What we tried:** Start bootstrap from model init, then from SwiftUI lifecycle hooks.

**What we learned:** Moving the call site alone does not fix the hang. The app target builds with Swift 6 default main-actor isolation; helper methods and static factories in the app target can be main-actor isolated unless explicitly marked otherwise. A `Task.detached` that awaits an implicitly main-actor function still depends on the main actor.

**Guardrail:** Any non-UI bootstrap assembly that lives in the app target must be explicitly `nonisolated` or moved behind an actor/protocol that is not main-actor isolated.

### 3. Suspecting custom commands

**What we tried:** Remove and restore the app command groups.

**What we learned:** Custom commands were not the root cause. They can stay as long as they only call `AppModel` intents and do not eagerly force long-running work during scene creation.

**Guardrail:** Keep command actions lazy. Buttons may create tasks when invoked; they should not start demo-world bootstrap work while menus are being constructed.

### 4. Simplifying or gating `MenuBarExtra`

**What we tried:** Simplify the menu-bar content, make it static, and gate insertion until the app was ready.

**What we learned:** In this startup path, the presence of the `MenuBarExtra` scene was enough to keep the app stuck on the loading screen. Even a placeholder-only menu extra made SwiftUI/AppKit spend startup time rebuilding menu graph state before the ready payload could publish reliably.

**Guardrail:** Do not reintroduce a `MenuBarExtra` scene in the first UI PR. When the background-sync phase begins, add it in isolation with a launch smoke test and keep its content trivial until the main window reaches `.ready`.

### 5. Starting the event loop before bootstrap completes

**What we tried:** Subscribe to `session.events` immediately as part of model construction.

**What we learned:** Early subscription was unnecessary for launch. The first useful UI state is the bootstrap payload; events matter after the initial workspace exists.

**Guardrail:** Start the event loop after a successful bootstrap payload is applied. This avoids extra startup concurrency while preserving live updates once the app shell is visible.

## Validation recipe for future startup changes

When changing `AetherloomAppApp`, `ContentView`, `AppModel`, scene declarations, or menu-bar behavior:

1. Run `swift test --package-path src/AetherloomCore`.
2. Run `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build`.
3. Launch the built app once and verify it leaves "Preparing your weave…" for Overview.
4. If a `MenuBarExtra` is reintroduced, repeat the launch smoke test with that scene enabled and disabled.

The important question is not just "does the engine bootstrap?" It is "can the built macOS app publish `.ready` and render the Overview while all declared scenes exist?"
