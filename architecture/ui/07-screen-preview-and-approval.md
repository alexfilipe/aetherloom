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
├ Holds strip (gated plans): SafetyBanner per HoldNotice
│    massDeletion/massEdit → evidence summary ("all 30 under /Projects/Archive")
│    + HoldTriageNote as AdviceChip when present (attributed, advisory)
│    conflicts → link "Review conflicts" → [08]
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
gate clear                     → [Cancel]  [Sync Now ⌘⏎]           (enabled immediately)
gate hold, unacknowledged      → CountAcknowledgeRows + [Cancel] [Sync Now] (disabled)
gate hold, all acknowledged    → [Sync Now ⌘⏎] enabled
executing                      → progress ("Applying N changes…"), controls locked
finished                       → RunResultToast + sheet dismiss
```

- `ApprovalRequirement` [04 §4] drives the rows: one checkbox per nonzero count — "Move **N** items to trash (recoverable from each provider's trash)" and "**N** conflicts — both versions preserved". Zero-count rows don't render.
- Sync Now builds `PlanApproval` exclusively via `makeApproval(requirement, at: now)` and calls `execute(preparation, approval:)`. For clear gates it passes `approval: nil`.
- **Expiry**: footer shows "Approval window: 15 minutes"; if `expiresAt` passes while the sheet is open, the footer flips to "This preview is stale — preview again" with a [Refresh Preview] button (re-runs `prepare`). The engine would reject the expired approval anyway; the UI just says it first.
- **Drift**: `execute` returning `outcome == .stoppedForReplan(location:path:)` renders an InlineBanner: "Files changed while you were reviewing — nothing was applied to *path*. Preview again to see the current plan." with [Refresh Preview]. This is invariant 5 made visible.
- **Partial failure**: `.failed(message:)` or nonempty `failedOperations` → toast reports "N applied, M failed — see Activity"; never silently discarded.

## 3. Advice on conflicts

`bothVersionsPreserved` rows show the conflict's `AdviceChip` when `preparation.advice` contains a matching `conflictID` — collapsed to "Suggestion · high confidence", expanding to rationale + attribution. Selecting anything still happens in the Conflicts screen; the preview never resolves conflicts. Advice absence (advisor timeout/rejection) simply renders nothing — the flow is identical without it. ✅ (via `HeuristicConflictAdvisor`)

## 4. Empty & edge states

- Clear gate with zero decisions: "Everything matches — nothing to sync." + [Close]. (Idempotent re-run demo: run Documents twice; second preview is empty. ✅)
- Waiting-only plans: sections show only Waiting; footer reads [Sync Later] (dismiss) since executing would be a no-op — button still allowed, engine handles it.
- Sheet opened while another run is active for this set: content replaced by "A sync is already running for this set" (engine's `runAlreadyInProgress` mapped, not raced).

## 5. Acceptance criteria

- Documents preview shows all six section types populated from the demo divergences, with engine-authored summaries and causality lines verbatim.
- Sync Now stays disabled until every acknowledge row is checked; acknowledged counts in the emitted `PlanApproval` equal the plan's `approvalTrashCount`/`approvalConflictCount` (bridge test pins this).
- Tampering demo: mutate a fake between prepare and execute (Demo menu conflict control) → execution reports `stoppedForReplan` and the drift banner appears. ✅
- Projects: mass-deletion hold renders evidence and requires acknowledgment; after approval, deletions land in fake providers' **trash**, visible in Activity ("moved to trash", recoverable phrasing).
- Keyboard-only pass: open → navigate sections → toggle acknowledgments (Space) → `⌘⏎` approve → toast.
