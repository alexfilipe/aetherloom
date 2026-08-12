# 12 — UI Testing Strategy

The core suite ([../core/10-testing-strategy.md](../core/10-testing-strategy.md)) proves the engine; this track proves the seam and the presentation. Principle: **push logic to where `swift test` reaches it** (`AetherloomBridge`), keep views declarative enough that compiling + previews + a thin smoke pass suffice.

## 1. Test surfaces

| Surface | Harness | Runs in CI |
| --- | --- | --- |
| `AetherloomBridgeTests` (session, demo world, display models) | Swift Testing, `swift test --package-path src/AetherloomCore` | yes — same command as core |
| SwiftUI previews (every screen × key states) | Xcode canvas | no (compile-checked by the app build) |
| App build | `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build` | no at L1 base; required in L5 CI |
| `AetherloomAppTests` | Shared-scheme test action; authoritative `xcodebuild … test` command below | target/test action do not exist at L1; created and CI-gated in L5 |
| Startup smoke pass | launch the built macOS app and verify it leaves "Preparing your weave…" for Overview | when shell/scenes/bootstrap change |
| Manual demo-script pass (§4) | human / agent with the running app | release gates only |

Current CI at the L1 base runs only `swift test --package-path src/AetherloomCore`. L5 creates/configures the app test target and shared-scheme test action, then adds both app test and build commands to macOS CI. No XCUITest suite is required: app-target Swift Testing plus exact-head user smoke covers the MVP interaction boundary.

## 2. Bridge tests (the bulk)

Deterministic: inject `EngineEnvironment(now:makeID:)` with a stepped clock and seeded IDs; zero latency in tests (`setLatency(0)`); no real sleeps; temp dirs cleaned (bridge uses none by default).

**Demo world & session**

- Bootstrap produces exactly the scripted state: 4 sync sets with expected phases/tones; Documents preparation has all six section kinds; Projects has a `massDeletion` hold; Photos Archive a `volumeNotMounted` refusal.
- Converging pass leaves real `BaseRecord`s (spot-check counts); second Documents run after approval is empty (idempotence through the seam).
- Confirmation round-trip: `makeConfirmation` fingerprint/counts == plan, time/expiry enforced, bridge mapping correct for clear/held plans; expired confirmation rejected; drift → `stoppedForReplan` surfaced.
- Pause: paused set skipped by scan-all; `prepare` on it throws `syncSetPaused`.
- Conflict loop: resolve `.makeCanonical` → next run converges → fake contents match the chosen version → conflict closed.
- Events: every mutation emits its event; activity fan-out matches store contents; two subscribers both receive.
- Scenario controls: each control produces its engine-visible consequence on next scan; `reset()` restores the bootstrap state.
- **Placeholder hygiene**: a session wrapper recording provider `callLog()`s asserts zero mutation calls from any read path.
- Cancellation: cancelling a `prepare` task mid-scan leaves the session able to run again (no stuck `activeSyncSets`).

**Display models** — table-driven:

- Tone matrices over all `LocationUnavailabilityReason` and `SyncSetState` combinations; workspace-status priority order.
- Status lines pick engine notice text verbatim when notices exist.
- `previewDisplay` built from a *real* demo-world `SyncPreparation` (never hand-built): section order, totals, causality passthrough.
- Activity grouping (runID grouping, ungrouped passthrough), category glyph/tone map total over `ActivityCategory.allCases`.
- Formatting: en-US pinned relative dates, byte counts, pluralization.

## 3. App-target checks

- Every screen gets `#Preview`s for its principal states (populated / empty / busy / refusal / hold) using a `PreviewEngineSession` — a tiny in-process fixture session (bridge-provided) returning canned bridge values instantly. Previews must not run demo bootstrap.
- `AppModel` unit tests live in an `AetherloomAppTests` target (or exact equivalent) included in the shared `AetherloomApp` scheme test action. L5 makes them CI-gating and covers navigation routing, the exact non-optional confirmation interaction, enrollment/reauthorization grant forwarding, single-sheet invariant, busy-set re-entry guard, and toast lifecycle using a scripted `EngineSession`.
- Authoritative L5 app-test command: `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' test`. The separate app build command remains required.
- Compile-time layering guard: `AetherloomBridge` must not import SwiftUI/AppKit — enforced by a bridge test that greps the target sources (cheap and effective, same spirit as core's acceptance greps).

## 4. Manual demo script (release gate)

A ten-minute pass exercising what automation can't judge — feel, wording, appearance modes:

1. Launch → branded loading → Overview matches [05 acceptance] in light *and* dark mode.
2. Documents: Preview → acknowledge → Sync Now → toast → Activity run group complete.
3. Projects: review mass-deletion evidence → approve → trash entries in Activity.
4. Photos Archive: refusal is calm; Demo ▸ Mount NAS → next scan clears it.
5. Conflict: advice expand → dismiss → choose version → next sync converges.
6. Interrupted-run scenario → recovery entry.
7. New sync set wizard end-to-end; delete it.
8. Settings: advice toggle off/on; placeholder sweep — every 🎭 control labeled and inert.
9. Keyboard-only approval pass; VoiceOver spot-check on Overview and the approval sheet.
10. Reduce Motion on: mesh frozen, no hover lift.

For any change to `AetherloomAppApp`, `ContentView`, `AppModel`, scene declarations, or menu-bar behavior, run the startup smoke pass before the full manual script. The bridge tests can prove `DemoEngineSession` bootstraps; only the built app can prove SwiftUI scene startup reaches `.ready`. See [13-startup-bootstrap-lessons.md](13-startup-bootstrap-lessons.md).

## 5. Policy

Per `CLAUDE.md`: no browser/visual QA for copy or styling tweaks; screenshots only when layout/interaction meaningfully changed. At L1, CI gates only `swift test --package-path src/AetherloomCore`. L5 adds shared-scheme app tests and the app build to CI without replacing the Swift suite. UI work never adds network, ML, or third-party test dependencies.
