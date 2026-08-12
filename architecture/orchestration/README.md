# Evaluation-Loop Development Framework

This is Aetherloom's standard development framework for every feature and pull request. It uses short, evidence-driven evaluation loops to reach a safe implementation and a timely merge decision. Multi-agent orchestration is one way to run the loop; it is not the purpose of the loop.

The framework supplements, and never relaxes, `AGENTS.md`, `CLAUDE.md`, and the safety invariants in `architecture/core/00-overview.md`.

## Precedent and intent

The framework generalizes the durable cutoff decisions recorded for PR #12 at commit `14c72efe008636c0c76590499166b3e1498f6af6`, especially these patterns:

- define the finish line and deferrals before another evaluation cycle;
- accept one complete evaluation plus focused verification and exact-head validation;
- permit one narrow correction and one replacement validation run when the failure is clearly bounded;
- freeze when the enumerated acceptance scenarios pass;
- reopen only for a newly evidenced P0/P1 failure mode — PR #12 met this as immediate data loss, ambiguous destructive authority, a failed listed scenario, or missing authoritative validation — rather than for reviewer preference;
- carry low residual risk with an exact revisit trigger instead of demanding exhaustive permutations.

The goal is not zero conceivable risk or zero reviewer comments. The goal is enough relevant evidence to make one of three honest decisions: **merge-ready**, **defer with a durable cutoff**, or **blocked by a named safety/correctness failure**.

## The core loop

Every feature or PR follows the same loop, scaled to its risk:

```text
Define ─▶ Implement ─▶ Evaluate ─▶ Decide
   ▲                         │          │
   └──── bounded correction ◀┘          ├─ merge-ready
                                       ├─ defer with cutoff
                                       └─ block on named failure
```

### 1. Define

Before implementation, record:

- the user-visible or safety outcome;
- exact in-scope and out-of-scope behavior;
- acceptance scenarios and required validation;
- the changed safety boundaries;
- the evaluation budget and finish line;
- acceptable residual risks and exact revisit triggers;
- branch, base, publication, and merge authority.

The finish line must be testable. “Review until nobody can find anything else” is not a finish line.

Record the definition where it is durable: scope, acceptance scenarios, and validation requirements belong in the owning track's `agents/` work order (see [`../README.md`](../README.md)) or the PR description; the finish line, evaluation budget, residual-risk policy, and reopen triggers belong in the cutoff decision log per [`cutoffs/README.md`](cutoffs/README.md).

### 2. Implement

Use one writer for one branch/worktree. Preserve unrelated work. For safety-critical or unfamiliar areas, dispatch bounded read-only exploration and test-design subagents before editing. For a small, understood change, the writer may work directly without manufacturing extra tasks.

### 3. Evaluate

Evaluate the implementation against the defined acceptance scenarios and changed safety boundaries:

1. static and focused checks;
2. focused regression tests;
3. one required full suite;
4. targeted source/diff audits;
5. one independent complete-diff evaluation when risk warrants it;
6. one authoritative exact-head platform run when local validation is not authoritative.

An evaluation must answer a defined question. Do not repeat a full review or suite merely because the head SHA changed; use the materiality rules below.

### 4. Decide

At the finish line, choose:

- **Merge-ready:** all blocking acceptance criteria pass, required exact-head evidence is green, and remaining risks are low enough to accept with recorded revisit triggers.
- **Deferred:** the implementation is safe for its defined scope, while non-blocking coverage, permutations, cleanup, or adjacent features are recorded in the cutoff log.
- **Blocked:** a P0/P1 finding, ambiguous destructive authority, a listed-scenario failure, or missing required authoritative evidence remains.

Do not keep a merge-ready PR in evaluation simply to search for more work.

## Scale the loop to risk

| Risk | Typical changes | Evaluation shape |
| --- | --- | --- |
| Low | Documentation, copy, metadata, mechanical non-behavioral edits | Writer self-evaluation and lightweight static/diff checks. No subagents or independent evaluator by default. |
| Medium | Isolated feature behavior, UI state, adapters, bounded refactors | Focused regressions and the relevant suite; add one independent evaluation when the changed contract is difficult to observe locally. |
| High | Data safety, deletion/trash, destructive authority, concurrency, recovery, persistence, provider identity, conflict preservation | Bounded Explorer/Test Designer as useful, focused and full validation, one complete independent evaluation, targeted recheck, and authoritative exact-head platform evidence. |

Escalate based on the changed boundary and credible failure impact, not diff size alone. De-escalate only when evidence shows the change is non-behavioral or mechanically contained.

## Risk and finding classes

Use these classes to decide what may stop the loop:

| Class | Meaning | Default disposition |
| --- | --- | --- |
| P0 | Immediate or credible data loss, permanent deletion, silent overwrite, security compromise, or recovery corruption | Block. Fix and re-evaluate. |
| P1 | Reproducible safety-invariant violation, failed listed acceptance scenario, concurrency/persistence defect, or ambiguous destructive authority | Block. Fix and re-evaluate. |
| P2 | Non-blocking gap, missing permutation coverage, hardening opportunity, or low residual risk with no demonstrated guard bypass | Record a cutoff and revisit trigger; does not prevent merge by default. |
| P3 | Style, naming, cleanup, speculative refactor, or unrelated improvement | Defer outside the loop. |

Severity is based on demonstrated impact and evidence, not reviewer confidence or comment count. A P2 becomes blocking only when new evidence shows a P0/P1 failure mode.

When the writer and an evaluator disagree on a finding's class, treat the finding at the higher class until the orchestrator or the user resolves the disagreement at a gate. A P0/P1 claim is never downgraded by writer preference alone.

## Evaluation budget

The default budget for a feature PR is:

1. one implementation self-evaluation;
2. one independent complete-diff evaluation for safety-critical, cross-layer, concurrency, recovery, persistence, or destructive-authority changes;
3. one correction batch;
4. one targeted verification by the original evaluator;
5. one exact-head full-suite/platform validation.

A second fresh complete-diff evaluation is required only when the correction batch:

- changes the architecture or acceptance contract;
- introduces a new mutation, recovery, persistence, concurrency, or destructive-authority path;
- substantially rewrites code the first evaluator already assessed; or
- cannot be verified by the original evaluator against its specific findings.

A third complete-diff evaluation is not part of the default loop. It requires explicit user approval and new P0/P1 evidence that the previous evaluation could not cover. Rephrased concerns, style feedback, hypothetical permutations, or a new reviewer preference are insufficient.

After the finish line is met, freeze the PR. Reopen only for a newly evidenced P0/P1 issue, a listed-scenario regression, loss of exact-head validation, or a changed base that invalidates the evidence.

## Roles and boundaries

### Writer

The writer owns exactly one branch and one worktree. It is the only task that edits or publishes that branch. It may not delegate writing, run a competing shared test suite, force-push, merge, or change PR metadata without authority.

### Evaluator

An evaluator may be the writer for focused checks and self-evaluation. A required independent evaluation uses a fresh, read-only top-level task at exact frozen base and head SHAs. The independent evaluator does not edit, commit, push, comment, resolve threads, or change PR state.

### Durable orchestrator

Use an orchestrator when work spans dependent PRs, branches, user gates, or shared locks. It owns coordination, not child code. It verifies live state, records exact SHAs and locks, dispatches tasks just in time, deduplicates findings, applies evaluation cutoffs, and presents merge gates.

### Bounded read-only subagent

Use a subagent only for an independent question whose answer can shorten or de-risk implementation. The default specializations are:

- **Explorer:** maps relevant code paths, invariants, state transitions, and failure modes with file-and-line evidence.
- **Test Designer:** maps acceptance criteria to current coverage and proposes the smallest proving regression set.

Subagents do not edit, publish, mutate GitHub state, acquire the writer lock, or recursively create agents.

## Triggering bounded subagents

Trigger a subagent when all of these are true:

- the parent has one concrete decision it needs;
- the investigation is read-only and independent of current edits;
- inputs can be fixed to an exact SHA, diff, subsystem, or test set;
- an evidence-complete cutoff can be stated before dispatch;
- the answer will affect scope, design, tests, or evaluation.

Do not trigger one for narration, duplicate review, broad “look for anything” searches, or work the parent can finish faster directly.

Every subagent prompt states:

1. **Question:** one decision the parent needs.
2. **Inputs:** exact SHA and bounded files, diff, tests, or review threads.
3. **Allowed actions:** read-only commands and analysis.
4. **Forbidden actions:** edits, publication, external mutations, locked tests, and recursive delegation.
5. **Evidence contract:** citations, inspected commands, uncertainties, and recommendation.
6. **Cutoff:** evidence-complete condition, expansion boundary, and escalation trigger.

Start with at most one Explorer and one Test Designer. Permit one targeted follow-up for an unresolved question. A specialist beyond that requires a newly identified independent P0/P1 boundary recorded in the cutoff log.

## Multi-PR topology

Create durable tasks just in time:

```text
Orchestrator
└── Implementation task (one writer)
    ├── Explorer (optional, bounded, read-only)
    └── Test Designer (optional, bounded, read-only)

Frozen published revision
└── Independent evaluator (one complete evaluation)
    └── findings routed to the original writer as one batch

Correction, if required
└── Original evaluator performs targeted verification
    └── fresh complete evaluation only if materiality rules require it
```

Do not create an implementation task before its base is stable. Do not create an evaluator before the writer reports a clean, published, validated revision with exact base and head SHAs. Do not create later dependent tasks before preceding merge/user gates complete.

Name user-visible tasks consistently as `PR <number> - <agent role>` (for example, `PR 42 - Implementation` or `PR 42 - Independent Evaluator`). This keeps the task tree scannable without repeating the repository name.

## Authoritative state for orchestrated work

Report this state after material transitions:

```text
CURRENT PHASE:
AUTHORITATIVE BRANCH:
AUTHORITATIVE HEAD:
ACTIVE WRITER:
TEST LOCK OWNER:
FROZEN EVALUATION BASE:
FROZEN EVALUATION HEAD:
EVALUATION CYCLE / BUDGET:
VALIDATION STATUS:
BLOCKING FINDINGS:
ACCEPTED/DEFERRED FINDINGS:
BLOCKERS:
RESIDUAL RISKS:
NEXT USER GATE:
CUTOFF DECISION LOG:
```

Use exact SHAs for every handoff. Distinguish local, upstream, remote, and GitHub PR heads until equality is proved.

## Validation ladder and correction cutoff

Run validation from cheapest to most expensive:

1. static or narrowly focused checks;
2. focused regression tests;
3. required full suite;
4. diff/format and source audits;
5. authoritative CI or hardware validation.

Stop at the first failure that requires code changes. Resume after the fix from the cheapest rung capable of reproducing that failure, then complete the remaining required rungs.

One narrow correction and one replacement authoritative run are allowed when a first exact-head run fails for a clearly bounded compile error, test-fixture error, or transient infrastructure problem and no behavioral safety scenario failed. Broader or repeated failure returns to the normal correction loop and may require a new cutoff decision.

Reuse prior evidence only when the exact head SHA and relevant code, tests, toolchain, environment, and command inputs are unchanged. Never report skipped or unavailable validation as passed.

Integrating a new base into the branch changes the head and therefore invalidates prior exact-head evidence, even when the merge is clean and conflict-free. Run one fresh authoritative run at the integrated head and record both the new base and that head. This is required revalidation, not the reassurance rerun E11 forbids.

## Locks

- `ACTIVE WRITER` has at most one owner across an orchestrated stack.
- `TEST LOCK OWNER` has at most one owner for Swift or any shared-resource suite.
- Read-only exploration may run concurrently only when it does not use a locked resource.
- Release locks while waiting only on CI, approval, or evaluator output.
- Transfer locks explicitly; never infer release from inactivity.

## Durable cutoff decisions

Cutoffs are part of the evaluation loop, not an escape from it. They define when evidence is enough, what is intentionally deferred, and exactly what would reopen the work.

Record material cutoff decisions in a file separate from work orders and implementation plans. The canonical append-only format and defaults are in [`cutoffs/README.md`](cutoffs/README.md), with an entry template in [`cutoffs/TEMPLATE.md`](cutoffs/TEMPLATE.md). The current project decision log is `architecture/cutoff-decisions.md`, introduced by PR #12 commit `14c72efe008636c0c76590499166b3e1498f6af6`.

At minimum, add or update a durable decision when:

- defining a PR's evaluation finish line;
- accepting or deferring a P2 residual risk;
- extending the default evaluation budget;
- allowing a narrow correction/retry;
- freezing or reopening a PR;
- selecting a branch/PR boundary for newly discovered work.

Do not log routine commands or every state transition. The decision log records durable judgment, while task commentary reports transient progress.

## Merge-readiness exit bar

A feature or PR is ready for its merge approval gate when:

- all defined acceptance scenarios pass;
- no unresolved P0/P1 finding remains;
- required exact-head local/remote and platform evidence is green;
- the intended commit graph and PR relationship are verified;
- accepted P2 risks and deferred work have exact revisit triggers;
- the evaluation budget is complete or any extension is explicitly approved;
- the branch is frozen and locks are released;
- the cutoff decision log states the finish line and disposition.

Exhaustive permutations, unrelated cleanup, broad documentation polish, and additional full reviews are not implicit merge requirements.
