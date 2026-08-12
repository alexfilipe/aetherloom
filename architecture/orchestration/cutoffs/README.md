# Evaluation Cutoffs

Evaluation cutoffs are explicit finish, pause, correction, routing, and reopen conditions. They keep development moving toward a safe merge decision without turning “more review” into an unbounded goal.

This policy generalizes the durable decisions in PR #12 commit `14c72efe008636c0c76590499166b3e1498f6af6` and the execution lessons from its orchestrated child-PR stack. It applies to every future feature and pull request.

Cutoffs never waive a safety invariant, a listed acceptance scenario, or required authoritative validation. They do allow low-risk permutations, cleanup, and adjacent improvements to be deferred with evidence and a precise revisit trigger.

## Canonical decision log

Material decisions go in `architecture/cutoff-decisions.md`, separate from work orders, implementation plans, and chat transcripts. The file is append-only: preserve existing entries and append resolution or supersession metadata instead of rewriting history.

Claim the next `CUT-<number>` from the log on the default branch at publication time, not from a stale local copy: parallel branches can otherwise claim the same number. Re-check for a collision when rebasing or merging; if a collision has already landed, keep the first-merged entry's number and re-designate the later entry with appended metadata rather than rewriting either entry.

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

## Evidence-complete subagent cutoffs

Bound subagents by evidence rather than duration or output volume. Each prompt names:

- one exact question;
- an exact SHA and bounded diff, paths, state transitions, or tests;
- what counts as sufficient evidence;
- at most the adjacent call sites or test files needed to verify the answer;
- the uncertainty that forces escalation rather than speculation.

Recommended defaults:

- zero subagents for a small, well-understood change;
- one Explorer and one Test Designer for safety-critical or unfamiliar work;
- one targeted follow-up for an unresolved question;
- no recursive delegation;
- no subagent tests unless it explicitly owns the test lock.

Stop after two consecutive passes reveal no new relevant path, invariant, or risk. Stop test design once every acceptance criterion has the smallest proving scenario plus only the necessary recovery or concurrency variant.

## Evaluation and validation cutoffs

Run the cheapest useful evaluation first:

```text
focused static check
        │ pass
        ▼
focused regression tests
        │ pass
        ▼
required full suite
        │ pass
        ▼
targeted audits
        │ pass
        ▼
one authoritative exact-head run
```

When a rung fails, do not spend time on later rungs that cannot change the decision. After correction, resume at the cheapest rung capable of reproducing the failure, then finish the remaining required rungs.

Reuse evidence only when the exact head and relevant code, tests, command, toolchain, and environment inputs are unchanged. “Previously green” without provenance is not reusable evidence.

## Preventing review paralysis

The default evaluation sequence is:

1. writer self-evaluation;
2. one complete independent evaluation when risk requires it;
3. one correction batch;
4. original evaluator's targeted verification;
5. one exact-head validation;
6. practical freeze and merge gate.

Missing exhaustive permutations are not automatically blocking. Neither are stylistic comments, speculative refactors, documentation polish, or a desire for a different design when the accepted contract is met.

Run a second fresh evaluation only under E09. Do not run a third without the E10 exception. Once E13 fires, reopen only under E14.

## Human evaluation and follow-up routing

A Mac smoke test, hardware test, or other user-observed result is part of the evaluation loop when the acceptance plan names it. Reserve the test lock while the human test is active if it shares fixed state with automation.

If smoke testing reveals an adjacent defect after the core PR is otherwise frozen:

1. reproduce and classify the defect;
2. keep the validated core PR frozen unless the defect violates its acceptance contract;
3. route the fix to the narrowest owning layer;
4. use a stacked follow-up PR when that preserves scope and evidence;
5. evaluate the follow-up against the observed scenarios rather than repeating the entire parent review.

This is how new evidence moves the product forward without restarting every prior evaluation.

## Durable entry format

Use [`TEMPLATE.md`](TEMPLATE.md). Every entry includes:

- date;
- PR/layer and exact relevant SHAs;
- decision/cutoff;
- reason and evidence;
- completed scope;
- explicit deferrals;
- residual risk and severity;
- exact revisit trigger or acceptance condition;
- status;
- resolving PR/SHA.

Append later resolution metadata rather than editing the original rationale.
