# 07 — Screen: Preview & Approval

The trust centerpiece: the sheet where a plan becomes visible and — only with explicit acknowledgment — executable. 🔁 Reshape of `Views/PreviewChangesSheet.swift`, now rendering a real `SyncPreparation` and implementing the approval contract of [../core/06-preview-and-approval.md](../core/06-preview-and-approval.md). Everything on this screen is ✅ functioning against the demo world.

## 1. Anatomy (720×560 sheet, resizable)

```text
┌ Header: sync set name · preview.headline (verbatim) · generatedAt · [✕]
├ Refusal state (when planFingerprint == nil):
│    InlineBanner per RefusalNotice (message verbatim, detail expandable)
│    body: EmptyStateView "Nothing can sync until this clears — and nothing
│          will be deleted while a provider is unreachable."
│    footer: [Close] only. No approve path exists — a refusal has no plan.
├ Holds strip (held plans): SafetyBanner per HoldNotice
│    massDeletion/massEdit → evidence summary ("all 30 under /Projects/Archive")
│    + HoldTriageNote as AdviceChip when present (attributed, advisory)
│    conflicts → link "Review conflicts" → [08]
│    any hold containing massDeletion → evidence only; no confirmation/execution
├ Sections (engine order, empty sections omitted):
│    Additions · Updates · Moves and renames · Waiting · Move to trash ·
│    Both versions preserved
│    Each: SectionHeader(title, count + byte total) + rows:
│      kind glyph · PathText · summary (engine text) · destination ServiceMarks
│      trash rows: causality line ("Deleted from Google Drive since last sync
│      on …. Copies at other locations move to trash.") — engine-provided
│      waiting rows: neutral tone, "waiting to download" phrasing from engine
├ Approval footer (§2)
```

## 2. The approval footer — state machine

```text
gate clear, no required counts → [Cancel]  [Sync Now ⌘⏎] enabled immediately
gate clear, required counts    → CountAcknowledgeRows + [Cancel] [Sync Now] (disabled until exact acknowledgements)
approvable hold, unacknowledged→ CountAcknowledgeRows + [Cancel] [Sync Now] (disabled)
approvable hold, acknowledged  → [Sync Now ⌘⏎] enabled
non-approvable hold            → evidence + [Close] only; no confirmation construction
executing                      → progress ("Applying N changes…"), controls locked
finished                       → RunResultToast + sheet dismiss
```

- `ConfirmationRequirement` [04 §4] exists only for executable preparations and drives the rows: one checkbox per nonzero count — "Move **N** items to trash (recoverable from each provider's trash)" and "**N** conflicts — both versions preserved". Zero-count rows don't render. Clear executable plans still carry a confirmation requirement, and nonzero clear-plan counts still require acknowledgement.
- For an executable preparation, Sync Now builds a non-optional `WorkspaceExecutionConfirmation` from the displayed fingerprint, confirmation/expiry times, and actual acknowledgement counts, then calls `execute(preparation, confirmation:)`. The bridge validates it and derives core `PlanApproval?`; `nil` exists only inside the bridge for a validated clear plan. A non-approvable hold never enters this path.
- **Expiry**: footer shows "Approval window: 15 minutes"; if `expiresAt` passes while the sheet is open, the footer flips to "This preview is stale — preview again" with a [Refresh Preview] button (re-runs `prepare`). The engine would reject the expired approval anyway; the UI just says it first.
- **Late drift**: `execute` returning `outcome == .stoppedForReplan(location:path:)` renders an InlineBanner that names the stopped operation and its location/path: "Files changed while syncing. The *operation* at *location/path* was not applied. Earlier completed changes remain recorded. Preview again to see the current plan." with [Refresh Preview]. Activity and summary keep any earlier applied operations and do not list the stopped operation as applied; the UI never promises rollback. This is invariant 5 made visible without hiding partial progress.
- **Partial failure**: `.failed(message:)` or nonempty `failedOperations` → toast reports "N applied, M failed — see Activity"; never silently discarded.

## 3. Advice on conflicts

`bothVersionsPreserved` rows show the conflict's `AdviceChip` when `preparation.advice` contains a matching `conflictID` — collapsed to "Suggestion · high confidence", expanding to rationale + attribution. Selecting anything still happens in the Conflicts screen; the preview never resolves conflicts. Advice absence (advisor timeout/rejection) simply renders nothing — the flow is identical without it. ✅ (via `HeuristicConflictAdvisor`)

## 4. Empty & edge states

- Clear gate with zero decisions: "Everything matches — nothing to sync." + [Close]. (Idempotent re-run demo: run Documents twice; second preview is empty. ✅)
- Waiting-only plans: sections show only Waiting; footer reads [Sync Later] (dismiss) since executing would be a no-op — button still allowed, engine handles it.
- Sheet opened while another run is active for this set: content replaced by "A sync is already running for this set" (engine's `runAlreadyInProgress` mapped, not raced).

## 5. Acceptance criteria

- Documents preview shows all six section types populated from the demo divergences, with engine-authored summaries and causality lines verbatim.
- Sync Now stays disabled until every nonzero acknowledgement row is checked on every executable clear or approvable-held plan; counts in the emitted `WorkspaceExecutionConfirmation` equal the plan's `approvalTrashCount`/`approvalConflictCount` (bridge tests pin this).
- Drift regressions cover both pre-first-mutation and late drift. For late drift, an earlier operation applies, a later operation stops for replan, summary/activity retains the applied operation, the stopped operation is absent from applied results, and the displayed copy names that exact outcome without promising rollback.
- Projects: the `massDeletion` hold renders evidence but no confirmation or execution action. The user changes the fake world or sync settings, explicitly prepares again, and only a fresh executable preparation may later sync.
- Keyboard-only pass: open → navigate sections → toggle acknowledgments (Space) → `⌘⏎` approve → toast.
