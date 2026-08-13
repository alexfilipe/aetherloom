# L5 — Real App, Picker, Bookmarks, and Onboarding

## Objective and dependency

Make the real workspace the production app path while retaining demo/preview fixtures only for previews and tests. Begin only after the user confirms L4 merged and the merged default-branch SHA is verified. This is a medium-to-high-risk standalone PR.

## Exact scope

- Add read/write `NSOpenPanel` folder enrollment and the macOS adapter that creates app-scoped `.withSecurityScope` bookmarks and resolves them with `.withSecurityScope`, `.withoutMounting`, and `.withoutUI`, reporting stale/denied access without implicit UI, mounts, or NAS wakeups.
- Set the production user-selected-files entitlement to read/write and include app-scoped bookmark entitlement configuration.
- Inject the app's Application Support workspace root, construct `WorkspaceEngineSession` by default, and present honest empty/corrupt/unavailable/recovery onboarding.
- Wire AppModel/UI intents to metadata-only enrollment/editing and the mandatory prepare → preview → explicit-confirm flow. Require reauthorization for stale bookmarks.
- Keep `DemoEngineSession` and preview fixtures reachable only from previews/tests or an explicitly non-production test/demo launch path.
- Create and configure an `AetherloomAppTests` target (or exact equivalent), add it to the shared `AetherloomApp` scheme's test action, and make CI run app tests and the app build on macOS. Current CI at the L1 base runs only the Swift package tests; L5 moves app test/build coverage into the required gate.
- Update [UI functioning status](../../ui/11-functioning-vs-placeholder.md) factually in the same PR as the behavior.

Do not add scheduled/background sync, menu-bar work, OAuth/cloud providers, whole-drive/NAS qualification, migration UI, App Store distribution work, or automatic execution.

## Acceptance and focused tests

L5 solely owns [LW-01, LW-02, LW-18, and LW-19](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario). Automated coverage MUST prove production composition is real and empty, demo is not default, picker cancellation is inert, enrollment metadata round-trips with no file mutation, stale access requires reauthorization, AppModel remains presentation-only, and startup reaches Overview.

Run the full Swift suite, retain the app build command, and make this authoritative app-test command green on macOS:

```bash
xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' test
```

Also run `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build`. Audit the entitlements and ensure bookmark canary bytes never enter UI/log/activity/diagnostics. Tests MUST prove bootstrap/prepare bookmark resolution uses `.withoutMounting` and `.withoutUI` and cannot mount or wake an unavailable network volume. Freeze/publish and prove equality before evaluation, then complete exact-head CI and user smoke. The handoff MUST name clean disposable folders and verify selection, relaunch access, first-run preview, explicit confirmation, create/edit/folder propagation, recoverable trash, exclusion visibility, refusal with zero mutation, pause persistence, and startup guardrails.

## Finish and stop

Apply the shared [validation ladder](local-workspace-mvp.md#validation-ladder-for-l2l5). The durable orchestrator's [LW-20](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario) evidence gate blocks L5; L5 does not own or retroactively supply earlier PR evidence. A user-observed failure is acceptance evidence and invalidates the head. Finish only after exact-SHA user-Mac validation passes, no P0/P1 remains, and any P2 has a trigger. Freeze and stop for the user merge. Do not start L6.
