# UI Task 02 — Display Models

## Role
Senior Swift engineer. You give the bridge its presentation vocabulary: pure, tested mappings from engine values to display values. Still no UI code.

## Read first
`architecture/ui/04-display-models.md` (your spec — implement exactly), `ui/01-design-system.md` §2 (tone semantics) and §8–§9 (symbols, language), `architecture/core/00-overview.md § Canonical language`; the Task-01 bridge sources; core `Preview/ChangePreview.swift`, `Plan/ExecutionGate.swift`, `Advisory/ConflictAdvisor.swift`, `Logging/SyncActivityLog.swift`. Baseline green first.

## Invariants (override this prompt)
Engine-authored strings pass through verbatim — selection, never rewriting. `makeApproval` is the only `PlanApproval` constructor and takes counts only from `ApprovalRequirement`. No clocks: every time-dependent function takes `now: Date`.

## Deliverables
1. `AetherloomBridge/Display/` per `ui/04`: `StatusTone`, `ProviderPresentation` (+`ProviderPalette`), `tone(for:)` for availability and sync-set state (exact case mapping from `ui/04 §2` — note `volumeNotMounted → neutral`), `StatusLine` + `statusLine(for:)`, `WorkspaceStatus` with priority order, `PreviewDisplay`/`ApprovalRequirement`/`makeApproval`, `ConflictDisplay` (+ advice attribution), `ActivityRowDisplay`/`runGroups`, `DisplayFormatting`.
2. Wire `WorkspaceSnapshot.status` and `SyncSetState`-derived digests to use these mappings (bridge computes once; UI reads).
3. Tests per `ui/12 §2` "Display models" bullets in full: exhaustive tone matrices (`LocationUnavailabilityReason` all cases, `ActivityCategory.allCases`), status-line priority, verbatim-passthrough assertions, `previewDisplay` built from a real demo-world `SyncPreparation`, `makeApproval` count fidelity + expiry passthrough, en-US pinned formatting.

## Prohibitions
No SwiftUI/AppKit/Color/Font types — semantic tokens only; no new session capabilities; no edits to engine sources; only `src/AetherloomCore/`.

## Acceptance
Suite green; every public display function has at least one table-driven test; a search for hardcoded user-facing sentences in `Display/` finds only states the engine has no words for (per `ui/04 §3` — "Never synced", "Paused by you", and formatting fragments); zero new warnings. Report per `agents/README.md`.
