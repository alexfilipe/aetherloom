# Durable Cutoff Decision Entry

Append one copy of this entry to `architecture/cutoff-decisions.md` for each material decision. Keep work orders and evaluation prompts in their own files.

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

When later evidence changes the decision, append metadata instead of rewriting it:

```markdown
## Resolution metadata appended <YYYY-MM-DD>

- CUT-<number>: <new evidence, status, resolving PR/SHA, and whether the original revisit trigger fired>.
```

A reopen under E14 is recorded the same way: append metadata to the original entry with status `reopened` and the evidence that fired the revisit trigger, then append later resolution metadata when the reopened work closes.

## Evaluation-budget example

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
