# 11 — Functioning vs Placeholder (Authoritative Matrix)

The single source of truth for what the app **actually does** versus what it **previews**. When a screen doc and this table disagree, this table wins; update it in the same commit as any status change. Statuses per the legend in [README.md](README.md#status-legend): ✅ functioning (real engine/bridge behavior inside the demo world) · 🎭 placeholder (visual scaffold, honest and inert).

"Functioning" always means: *real `AetherloomCore` code paths over fake providers and in-memory stores.* No functioning feature touches the network or real user files yet — that boundary moves only when `WorkspaceEngineSession` exists.

## Sync pipeline

| Capability | Status | Backing |
| --- | --- | --- |
| Availability checks, refusal on unavailability | ✅ | `SyncOrchestrator` + `FakeStorageProvider.setAvailability` |
| Scanning, incomplete-scan refusal | ✅ | real scan path (timeouts included) |
| Reconciliation, planning, gating (mass delete/edit, deletions review, conflicts) | ✅ | real planner + `ExecutionGate` |
| Change preview (sections, causality, waiting, byte sizes) | ✅ | `ChangePreviewRenderer` output rendered verbatim |
| Approval with acknowledged trash/conflict counts, fingerprint, 15-min expiry | ✅ | `PlanApproval` + engine validation |
| Execution: staging, journal, precondition verification, drift abort (`stoppedForReplan`) | ✅ | `ScheduleExecutor` |
| Journal recovery after interrupted run | ✅ | `RunRecovery` (scripted trigger via Demo menu) |
| Delete-to-trash (provider trash, recoverable) | ✅ | fake providers' trash |
| Conflict preservation + resolution recording + next-run convergence | ✅ | `ConflictStore` + planner resolution intake |
| On-device conflict advice + hold triage notes (attributed, dismissible) | ✅ | `HeuristicConflictAdvisor` through the real advisory pipeline |
| Activity log (all categories, queries) | ✅ | engine `ActivityStore` |
| Idempotent re-runs (second preview empty) | ✅ | engine behavior |
| **Real cloud/local/NAS data** | 🎭 | none — demo world only; every byte is fake |
| Background / scheduled sync | 🎭 | none |
| Change-hint (cursor) optimized scans | 🎭 (invisible) | full scans only in demo |

## Workspace management

| Capability | Status | Notes |
| --- | --- | --- |
| Create sync set (wizard) → first real sync | ✅ | real `SyncSet` in bridge registry |
| Edit mode/thresholds/exclusions, effective on next plan | ✅ | engine `SyncSettings` |
| Pause/resume sync set | ✅ (bridge-level) | core has no pause by design; not yet persisted across relaunch |
| Delete sync set (never touches files) | ✅ | bridge + stores |
| Choose real folders / scopes via picker | 🎭 | text-field scopes over the demo tree only |
| Workspace persistence across relaunch | 🎭 | demo world reseeds each launch; file-backed stores exist in core for the future session |

## Providers & accounts

| Capability | Status | Notes |
| --- | --- | --- |
| Provider availability states in UI (unreachable, unmounted, etc.) | ✅ | real `LocationAvailability` taxonomy |
| Account labels ("alex@…") | 🎭 | scripted strings on `LocationState` |
| Connect / disconnect / OAuth | 🎭 | connect sheet is a scripted preview that cannot "succeed" |
| NAS mount/wake | 🎭 control → ✅ state | button is demo-scripted; resulting availability change and engine reaction are real |
| Dropbox | 🎭 | listed as planned |

## Shell & chrome

| Capability | Status |
| --- | --- |
| Navigation, badges, workspace status footer, toasts, deep links | ✅ |
| Keyboard shortcuts, VoiceOver labels, reduced motion | ✅ |
| Menu bar extra: status line | ✅ · its Pause All / Sync All items 🎭 |
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

Each 🎭 row upgrades by implementing capability behind the existing seam — `WorkspaceEngineSession` (real providers, file-backed stores, keychain-backed accounts) replaces `DemoEngineSession` per the core development order; the connect sheet's internals swap OAuth in; pickers swap `NSOpenPanel` in. **No screen layout waits on any of that.**
