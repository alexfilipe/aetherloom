# L4 — `WorkspaceEngineSession` and Real Local Composition

## Objective and dependency

Implement the production bridge seam specified by [01-workspace-engine-session.md](../01-workspace-engine-session.md) over real `LocalFolderStorageProvider`s and the L3 durable workspace. Begin only after the user confirms L3 merged and the merged default-branch SHA is verified. This is a high-risk standalone PR.

## Exact scope

- Implement `WorkspaceEngineSession` bootstrap, state reads/events, metadata-only location/sync-set operations, pause, conflict intent, prepare, explicit-confirmation execution, and sync-set deletion.
- Inject a folder-access resolver/scope lease abstraction; L4 tests use controlled capabilities. Keep actual `NSOpenPanel`, bookmark creation/resolution APIs, entitlements, and app default-session selection for L5.
- During enrollment call `locationByRecordingVolumeIdentity`, commit identity/access references before provider construction, and enforce same/alias/ancestor overlap rejection.
- Compose `SyncOrchestrator`, real local providers, all file-backed stores, persistent stage, recovery state, and the manifest. Bootstrap reconstructs and presents but never auto-prepares or auto-executes.
- Hold security-scope leases over every authorized provider operation, including late indeterminate work and recovery.

Do not put sync decisions in bridge/app code, replay schedules, auto-approve, add background sync, add real UI, or change the accepted package/metadata policy.

## Acceptance and focused tests

L4 solely owns [LW-03 through LW-08, LW-10 through LW-14, and LW-17](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario). Use fake/call-log tests for metadata-only and access-failure proofs, real local providers only over test-created temporary directories for end-to-end cases, and reconstructed session instances for relaunch/recovery.

Focused coverage MUST include explicit confirmation for clear and held plans; fingerprint mismatch/expiry; all seven parameterized LW-08 causes; scope start/stop balance across success, refusal, cancellation, timeout, and indeterminate recovery; identity persistence before construction; overlap failure before scan; conflict-intent no-mutation; no schedule replay; metadata-only deletion; durable pause; and converged empty relaunch. Then run all bridge/core tests, the complete Swift suite, applicable app build compatibility, source/layering audits, and exact-head macOS/user validation.

## Finish and stop

Apply the shared [validation ladder](local-workspace-mvp.md#validation-ladder-for-l2l5). Finish only when every assigned row passes, no P0/P1 remains, and exact-head evidence is accepted. Freeze and stop for the user merge. Do not start L5.
