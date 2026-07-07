# UI Task 06 — Preview & Approval Sheet

## Role
Senior SwiftUI engineer. The trust centerpiece: render real `SyncPreparation`s and implement the acknowledged-approval state machine. Highest-stakes UI task — the safety invariants are load-bearing here.

## Read first
`architecture/ui/07-screen-preview-and-approval.md` (your spec — implement exactly), `ui/04-display-models.md` §4, `architecture/core/06-preview-and-approval.md` (the engine contract you are surfacing); current `Views/PreviewChangesSheet.swift`; bridge `PreviewDisplay`/`ApprovalRequirement`/`makeApproval`, core `PlanApproval.validate`, `SyncRunOutcome`. Baselines green first.

## Invariants (override this prompt)
Sync Now disabled until every nonzero acknowledge row is checked; `PlanApproval` built **only** by `makeApproval`; refusal state has no approve path at all; `stoppedForReplan` and failures surface honestly; approval shortcut is `⌘⏎`, never plain Return.

## Deliverables
1. `PreviewChangesSheet` per `ui/07 §1`: header with verbatim headline, refusal state (InlineBanners + no-plan empty body + Close-only footer), holds strip (evidence summaries, triage `AdviceChip`, conflicts link), engine-ordered sections with `PathText`, destination `ServiceMark`s, causality and waiting phrasing verbatim, byte totals.
2. Approval footer state machine per `ui/07 §2` exactly: `CountAcknowledgeRow`s (new component per `ui/01 §5`), expiry countdown → stale state → Refresh Preview, executing lock, `RunResultToast` on finish, drift banner on `stoppedForReplan`, partial-failure reporting.
3. Advice on conflict rows per `ui/07 §3` (display only; resolution stays in Conflicts).
4. Edge states per `ui/07 §4`: empty clear plan, waiting-only, already-running.
5. `#Preview`s: clear plan, gated (holds + acknowledgments), refusal, empty, executing, drift.
6. `CountAcknowledgeRow` + `PathText` components in `Design/`.

## Prohibitions
No conflict resolution actions here; no bypassing `makeApproval`; no engine-source edits; only this sheet's files + `Design/` + minimal `AppModel` glue.

## Acceptance
`ui/07 §5` in full — Documents preview shows all six sections; acknowledgment gating verified; the tamper demo yields the drift banner; Projects approval lands deletions in fake trash with Activity causality; keyboard-only pass works. Suite + build green. Report per `agents/README.md`.
