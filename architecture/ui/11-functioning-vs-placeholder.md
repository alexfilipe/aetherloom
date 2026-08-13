# 11 — Functioning vs Placeholder (Authoritative Matrix)

The single source of truth for what the app **actually does** versus what it **previews**. When a screen doc and this table disagree, this table wins; update it in the same commit as any status change. Statuses per the legend in [README.md](README.md#status-legend): ✅ functioning (real engine/bridge behavior inside the demo world) · 🎭 placeholder (visual scaffold, honest and inert).

For app rows, “functioning” currently means real `AetherloomCore` paths behind `DemoEngineSession`. A real `LocalFolderStorageProvider` and local end-to-end tests exist in core, but the production app does not compose them. `WorkspaceEngineSession`, durable app workspace state, and folder access are not wired yet.

## Sync pipeline

| Capability | Status | Backing |
| --- | --- | --- |
| Availability checks, refusal on unavailability | ✅ | `SyncOrchestrator` + `FakeStorageProvider.setAvailability` |
| Scanning, incomplete-scan refusal | ✅ | real scan path (timeouts included) |
| Reconciliation, planning, gating (mass delete/edit, deletions review, conflicts) | ✅ | real planner + `ExecutionGate` |
| Change preview (sections, causality, waiting, byte sizes) | ✅ | `ChangePreviewRenderer` output rendered verbatim |
| Current demo-only approval with acknowledged counts, fingerprint, 15-min expiry | ✅ | current bridge/AppModel still expose core `PlanApproval`; L4 replaces that AppModel-facing seam with `WorkspaceExecutionConfirmation` |
| Bridge-enforced intentional mass-deletion review UI | 🎭 | core already keeps ordinary `massDeletion` held and never constructs `ScheduleExecutor`; L4 removes confirmation/execution from that path and adds the exact-binding one-shot **Review intentional deletions** flow whose fresh match installs an opaque live execution reservation consumed before executor construction |
| Execution: staging, journal, precondition verification, drift abort (`stoppedForReplan`) | ✅ | `ScheduleExecutor` |
| Journal recovery after interrupted run | ✅ | `RunRecovery` (scripted trigger via Demo menu) |
| Delete-to-trash (provider trash, recoverable) | ✅ | fake providers' trash |
| Conflict preservation + resolution recording + next-run convergence | ✅ | `ConflictStore` + planner resolution intake |
| On-device conflict advice + hold triage notes (attributed, dismissible) | ✅ | `HeuristicConflictAdvisor` through the real advisory pipeline |
| Activity log (all categories, queries) | ✅ | engine `ActivityStore` |
| Idempotent re-runs (second preview empty) | ✅ | engine behavior |
| **Real local-folder data in the app** | 🎭 | local provider exists in core/tests; production launch still uses `DemoEngineSession` |
| **Real cloud/NAS data in the app** | 🎭 | no cloud integration; NAS is not qualified for the local MVP |
| Background / scheduled sync | 🎭 | none |
| Change-hint (cursor) optimized scans | 🎭 (invisible) | full scans only in demo |

## Workspace management

| Capability | Status | Notes |
| --- | --- | --- |
| Create sync set (wizard) → first real sync | ✅ | real `SyncSet` in bridge registry |
| Edit mode/thresholds/exclusions, effective on next plan | ✅ | engine `SyncSettings` |
| Pause/resume sync set | ✅ (bridge-level) | core has no pause by design; not yet persisted across relaunch |
| Delete sync set (never touches files) | ✅ | bridge + stores |
| Choose real folders / scopes via picker | 🎭 | no production `NSOpenPanel` or security-scoped bookmark wiring |
| Workspace persistence across relaunch | 🎭 | demo world reseeds each launch; file-backed stores exist in core for the future session |
| Sandboxed read/write folder authority | 🎭 | sandbox is enabled, but the project is configured for read-only selection and has no app-scoped bookmark persistence |

## Providers & accounts

| Capability | Status | Notes |
| --- | --- | --- |
| Provider availability states in UI (unreachable, unmounted, etc.) | ✅ | real `LocationAvailability` taxonomy |
| Account labels ("alex@…") | 🎭 | scripted strings on `LocationState`, visibly prefixed “Demo account” |
| Provider identity glyphs | 🎭 | SF Symbol preview marks; help and accessibility copy name the future official artwork |
| Connect / disconnect / OAuth | 🎭 | connect sheet is a scripted preview that cannot "succeed" |
| NAS mount/wake | 🎭 control → ✅ state | button is demo-scripted; resulting availability change and engine reaction are real |
| Dropbox | 🎭 | listed as planned |

## Shell & chrome

| Capability | Status |
| --- | --- |
| Navigation, badges, workspace status footer, toasts, deep links | ✅ |
| Keyboard shortcuts and confirmation focus order | ✅ |
| VoiceOver labels and run/hold announcements | ✅ |
| Reduced motion and mesh scene/occlusion pausing | ✅ |
| Menu bar extra / status line | 🎭 deferred; Settings has a disabled placeholder until background sync reintroduces the scene safely |
| Demo menu & Settings Demo pane | ✅ (demo-only surface, absent for real sessions) |
| Finder reveal, log export, file comparison | 🎭 |
| Notifications | 🎭 (not present at all — no placeholder chosen) |

## Placeholder conventions

Binding rules for every 🎭 surface (enforced in review):

1. **Labeled**: carries `PlaceholderChip` or explicit "arrives with…" copy naming the future capability. No unlabeled dead controls.
2. **Inert toward the engine**: may change local UI state only; never calls `EngineSession` mutation APIs. Bridge tests assert zero fake-provider calls from placeholder paths.
3. **Never completes**: a placeholder flow has no success terminal state (see the connect sheet rule, [10 §3]).
4. **Discoverable in code**: mark the view with `// 🎭 placeholder: <capability> — see architecture/ui/11-functioning-vs-placeholder.md`.
5. **Tracked here**: adding or upgrading a surface updates this file in the same change.

## Upgrade path

Local rows upgrade through the ordered [Local Workspace MVP work](../providers/agents/local-workspace-mvp.md): durable state and `WorkspaceEngineSession`, then `NSOpenPanel`, app-scoped bookmarks, read/write entitlement, and production session selection. OAuth/account work remains later and does not block the local MVP. **No screen layout is evidence that those capabilities already function.**
