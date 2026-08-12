# Evaluation Cutoffs

Evaluation cutoffs are explicit finish, pause, correction, routing, and reopen conditions. They keep development moving toward a safe merge decision without turning “more review” into an unbounded goal.

This policy generalizes the durable decisions in PR #12 commit `14c72efe008636c0c76590499166b3e1498f6af6` and the execution lessons from its orchestrated child-PR stack. It applies to every future feature and pull request.

Cutoffs never waive a safety invariant, a listed acceptance scenario, or required authoritative validation. They do allow low-risk permutations, cleanup, and adjacent improvements to be deferred with evidence and a precise revisit trigger.

This file defines the decision log, the default cutoff catalog, and the durable entry format. The development procedure those cutoffs bound — the loop, risk tiers, evaluation budget, subagent triggers, validation ladder, locks, human-smoke routing, and the merge-readiness bar — is defined once in [`../README.md`](../README.md). Where a rule appears in both, that file is normative.

## Canonical decision log

Material decisions go in [`DECISIONS.md`](DECISIONS.md) beside this policy, separate from work orders, implementation plans, and chat transcripts. The file is append-only with respect to decision content: never revise a recorded rationale, scope, risk, evidence, or trigger after the fact — append resolution or supersession metadata instead.

Identifiers are labels rather than decision content, so a duplicated `CUT-<number>` may be corrected in place. That is the one permitted in-place edit, it changes nothing a reader relies on, and it must leave the entry otherwise byte-identical.

Claim the next `CUT-<number>` from the log on the default branch at publication time, not from a stale local copy: parallel branches can otherwise claim the same number. Re-check for a collision when rebasing or merging. If a collision has already landed, keep the first-merged entry's number and renumber the later entry to the next free number, updating every citation of it in the same change. Check for citations outside the log first; if the old identifier has already been cited somewhere you cannot update, leave both entries alone and append re-designation metadata instead, since a label nobody can follow is worse than a duplicate.

Add a durable entry when:

- setting the evaluation finish line for a PR or feature;
- accepting or deferring a P2 residual risk;
- authorizing more than the default evaluation budget;
- permitting a narrow correction and replacement validation run;
- freezing or reopening a PR;
- routing a discovered defect to a different layer or follow-up PR.

Do not log routine commands, lock transfers, or progress polling. Those belong in transient task status, not architectural history.

## Default cutoff catalog

| ID | Decision point | Default cutoff | Response |
| --- | --- | --- | --- |
| E01 | Finish line | Acceptance scenarios, validation sources, evaluation budget, allowed residual risk, and reopen triggers are named before the first complete evaluation | Do not start an open-ended evaluation. Record the missing finish line first. |
| E02 | Base readiness | Base/upstream/PR SHA is ambiguous, divergent, occupied, or behind an unresolved gate | Do not dispatch a writer; report the exact mismatch. |
| E03 | Writer/test exclusivity | Another task owns the writer, branch/worktree, or shared test lock | Queue the work. Never overlap writers or shared Swift suites. |
| E04 | Subagent evidence | All assigned questions have cited answers, or two consecutive passes find no new relevant path, invariant, or risk | Return immediately with uncertainties; do not widen the search. |
| E05 | Subagent fan-out | One Explorer and one Test Designer are active and no new independent P0/P1 boundary is recorded | Do not create another subagent. One targeted follow-up per unresolved question is allowed. |
| E06 | Focused validation | A focused check fails in a way that needs code changes | Stop higher-cost validation, fix, and restart at the cheapest reproducing rung. |
| E07 | Complete evaluation | The frozen diff and all acceptance criteria/changed safety boundaries have one disposition | End the full evaluation. Route findings as one batch. |
| E08 | Correction batch | Findings from the complete evaluation are understood | Make one coherent correction batch, then run targeted verification. Avoid one-task-per-comment churn. |
| E09 | Fresh evaluation | Corrections introduce a new safety boundary, alter the acceptance contract/architecture, substantially rewrite evaluated code, or cannot be verified narrowly | Run one second fresh complete evaluation. Otherwise use targeted verification only. |
| E10 | Review ceiling | Two complete evaluations have occurred | Freeze after required targeted verification. A third requires user approval plus new P0/P1 evidence. |
| E11 | Exact-head CI | One authoritative exact-head run passes at the current head | Do not rerun for reassurance. Preserve its SHA, command, environment, result, known issues, and skips. A later base integration or any other head change voids that evidence and requires one fresh run, which this cutoff does not forbid. |
| E12 | Narrow correction | First authoritative run fails only on a bounded compile, test-fixture, or transient infrastructure problem before any safety scenario fails | Permit one focused correction and one replacement run; record the decision. |
| E13 | Practical freeze | Acceptance scenarios pass, no P0/P1 remains, exact-head validation is green, and residual risk is P2 or lower | Mark the evaluation complete and present the merge gate. Do not keep searching for work. |
| E14 | Reopen | New evidence shows a P0/P1 failure mode (for example immediate data loss, ambiguous destructive authority, or a concurrency/persistence defect), a listed-scenario regression, or invalidated exact-head evidence | Reopen narrowly for that evidence. Reviewer preference, style, or hypothetical permutations do not reopen. |
| E15 | Residual risk | Gap is missing permutation coverage or hardening with no demonstrated guard bypass | Record as P2 with an exact trigger; it does not block merge by default. |
| E16 | Scope routing | A reproduced defect belongs to an adjacent layer or would destabilize a frozen PR | Create a narrowly scoped follow-up/stacked PR after its base is stable. Do not reopen or expand the frozen PR by default. |
| E17 | Human smoke | A defined manual smoke scenario produces a reproducible failure | Treat it as acceptance evidence, classify P0–P3, and route it. Do not dismiss it because automation is green. |
| E18 | Ambiguous safety | Provider truth, ownership, recovery, version evidence, or conflict preservation cannot be proved | Fail closed and block the affected destructive path; do not use the review cutoff to accept ambiguity. |
| E19 | External wait | Progress depends only on CI, human smoke, approval, or another task | Release unused locks and use event-driven/bounded waits instead of repetitive state reads. |
| E20 | Authority | The next action is merge, base/readiness change, thread mutation, force-push, destructive recovery, or another ungranted mutation | Stop and present one precise approval gate. |

## Durable entry format

Append one copy of this entry to [`DECISIONS.md`](DECISIONS.md) for each material decision. Keep work orders and evaluation prompts in their own files.

```markdown
## CUT-<next number> — <short decision name>

- Date: <YYYY-MM-DD>
- PR/layer and exact relevant SHA(s): <PR link or feature; base, failed head, final head, and integration SHA as applicable>.
- Decision/cutoff: <the finish, correction, deferral, routing, freeze, or reopen decision>.
- Reason and evidence: <acceptance scenarios, evaluator result, CI run, human smoke result, or reproduced failure supporting the decision>.
- What was completed: <the exact shipped or evaluated scope>.
- What was explicitly deferred: <permutations, cleanup, follow-up work, or “none”>.
- Residual risk/severity: <P0–P3 and concrete remaining risk>.
- Exact revisit trigger or acceptance condition: <specific evidence that reopens work, or exact finish line still required>.
- Status: proposed | accepted | deferred | reopened | superseded | resolved
- Resolving PR/SHA: <PR and exact SHA, or “none/pending”>.
```

When later evidence changes the decision, append metadata instead of rewriting the original rationale:

```markdown
## Resolution metadata appended <YYYY-MM-DD>

- CUT-<number>: <new evidence, status, resolving PR/SHA, and whether the original revisit trigger fired>.
```

A reopen under E14 is recorded the same way: append metadata to the original entry with status `reopened` and the evidence that fired the revisit trigger, then append later resolution metadata when the reopened work closes.

### Worked example

```markdown
## CUT-042 — PR #99 practical freeze

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): PR #99; base `<base SHA>`; final head `<head SHA>`.
- Decision/cutoff: Freeze after the enumerated acceptance scenarios, one complete independent evaluation, targeted verification of its findings, and one green exact-head platform run. No additional complete review is required.
- Reason and evidence: All listed scenarios pass; the evaluator found no remaining P0/P1 issue; exact-head validation is green.
- What was completed: The feature contract and focused regressions.
- What was explicitly deferred: Exhaustive permutations and unrelated cleanup.
- Residual risk/severity: P2; untested permutations with no demonstrated guard bypass.
- Exact revisit trigger or acceptance condition: Reopen only for a reproduced acceptance regression, a demonstrated guard bypass, invalidated validation, or new P0/P1 evidence.
- Status: accepted
- Resolving PR/SHA: PR #99 / `<head SHA>`.
```
