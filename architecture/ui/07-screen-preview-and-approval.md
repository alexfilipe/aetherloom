# 07 — Screen: Preview & Confirmation

The trust centerpiece: the sheet where a plan becomes visible and — only with explicit acknowledgment — executable. 🔁 Reshape of `Views/PreviewChangesSheet.swift`, now rendering a real `SyncPreparation` and implementing the confirmation contract of [../core/06-preview-and-approval.md](../core/06-preview-and-approval.md). Everything on this screen is ✅ functioning against the demo world.

## 1. Anatomy (720×560 sheet, resizable)

```text
┌ Header: sync set name · preview.headline (verbatim) · generatedAt · [✕]
├ Refusal state (when planFingerprint == nil):
│    InlineBanner per RefusalNotice (message verbatim, detail expandable)
│    body: EmptyStateView "Nothing can sync until this clears — and nothing
│          will be deleted while a provider is unreachable."
│    footer: [Close] only. No confirmation path exists — a refusal has no plan.
├ Holds strip (held plans): SafetyBanner per HoldNotice
│    massDeletion/massEdit → evidence summary ("all 30 under /Projects/Archive")
│    + HoldTriageNote as AdviceChip when present (attributed, advisory)
│    conflicts → link "Review conflicts" → [08]
│    ordinary massDeletion → evidence + [Review intentional deletions];
│      no confirmation/execution. Exact-match fresh reviewed plan + live reservation → normal footer
├ Sections (engine order, empty sections omitted):
│    Additions · Updates · Moves and renames · Waiting · Move to trash ·
│    Both versions preserved
│    Each: SectionHeader(title, count + byte total) + rows:
│      kind glyph · PathText · summary (engine text) · destination ServiceMarks
│      trash rows: causality line ("Deleted from Google Drive since last sync
│      on …. Copies at other locations move to trash.") — engine-provided
│      waiting rows: neutral tone, "waiting to download" phrasing from engine
├ Confirmation footer (§2)
```

## 2. The confirmation footer — state machine

```text
gate clear, no required counts → [Cancel]  [Sync Now ⌘⏎] enabled immediately
gate clear, required counts    → CountAcknowledgeRows + [Cancel] [Sync Now] (disabled until exact acknowledgements)
approvable hold, unacknowledged→ CountAcknowledgeRows + [Cancel] [Sync Now] (disabled)
approvable hold, acknowledged  → [Sync Now ⌘⏎] enabled
ordinary massDeletion hold     → evidence + [Close] [Review intentional deletions]; no confirmation construction
reviewing intentional deletes  → fresh-prepare progress; controls locked
reviewed massDeletion          → live-reservation countdown + CountAcknowledgeRows + [Cancel] [Sync Now]
executing                      → progress ("Applying N changes…"), controls locked
finished                       → RunResultToast + sheet dismiss
```

- `ConfirmationRequirement` [04 §4] exists only for executable preparations and drives the rows: one checkbox per nonzero count — "Move **N** items to trash (recoverable from each provider's trash)" and "**N** conflicts — both versions preserved". Zero-count rows don't render. Clear executable plans still carry a confirmation requirement, and nonzero clear-plan counts still require acknowledgement.
- For an ordinary `massDeletion` preparation, **Review intentional deletions** passes that exact preparation to `reviewIntentionalDeletions`. It constructs no confirmation and grants no execution. The fresh result replaces the sheet: mismatch/expiry remains ordinary and unconfirmable; only an exact-match `reviewedMassDeletion` result backed by core's opaque live reservation has a distinct fingerprint and normal exact-count confirmation footer. Persistent thresholds cannot exceed the hard maxima, and allowed in-range changes do not clear the evidence latch.
- For an otherwise executable preparation, Sync Now builds a non-optional `WorkspaceExecutionConfirmation` from the displayed fingerprint, effective confirmation/authority expiry, and actual acknowledgement counts, then calls `execute(preparation, confirmation:)`. The bridge validates it and derives core `PlanApproval?`; `nil` exists only inside the bridge for a validated clear plan. For reviewed deletion, core then atomically consumes the matching fingerprint/run/preparation reservation before executor construction. The reviewed value alone is not authority. An ordinary non-approvable hold never enters this path.
- **Expiry**: the confirmation footer shows “Confirmation expires in 15 minutes” or a live countdown; a reviewed footer counts down to the earlier of the 15-minute confirmation window and its display-only reservation expiry. If that effective `expiresAt` passes while the sheet is open, the expired confirmation state reads “Confirmation expired — preview again” with a [Refresh Preview] button (re-runs ordinary `prepare`; the user must choose **Review intentional deletions** again). The bridge rejects the expired confirmation before deriving any internal approval; core independently rejects missing/expired/reused/relaunch-lost/mismatched reservation state with zero executor calls.
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
- Projects: the ordinary `massDeletion` hold renders exact evidence, **Review intentional deletions**, and no confirmation/execution action. Review performs a fresh prepare; unchanged semantic truth despite new generated IDs/timestamps produces the same unreviewed fingerprint, then a distinct reviewed fingerprint plus opaque live reservation. Exact trash acknowledgement remains required, and only confirmation plus atomic reservation consumption may construct the executor. Changed settings/world/evidence, token failure, or missing/expired/reused/relaunch-lost/mismatched reservation returns no reviewed execution authority and zero executor calls. An attempted setting above the hard maximum is normalized, and any allowed in-range increase leaves the ordinary latch/hold in force.
- Keyboard-only pass: open → navigate sections → toggle acknowledgments (Space) → `⌘⏎` confirm → toast.
