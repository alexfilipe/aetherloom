# Cutoff decisions

This is the working log of deliberate scope decisions: what is still in flight, what was deliberately left undone, and exactly what would reopen it. It is meant to be read in full by any agent starting work, so it is kept short.

Closed decisions are removed once their open residue has been carried forward, so this file alone tells you what is still owed. Nothing is lost: git holds every entry verbatim. The full log as it stood before the 2026-08-12 pruning is one command away, and the closed index below says which ID to look for.

```bash
git show 90a2342:architecture/orchestration/cutoffs/DECISIONS.md
```

The policy governing this log, the default cutoff catalog, and the entry format are in [`README.md`](README.md).

## Active decisions

Full entries for decisions whose feature or pull request is still in flight. Append new ones here in the format from [`README.md`](README.md).

### CUT-024 — Prune the cutoff log to a readable working set

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): cutoff documentation on branch `claude/prune-cutoff-decisions-920122`; base `main` at `90a2342`.
- Decision/cutoff: Retire closed entries from this log instead of accumulating them, keeping only in-flight decisions, a distilled backlog of every unfired deferral and residual risk, standing constraints, and a one-line index of what was retired. Relax the append-only rule to permit exactly that removal: an entry may leave this file and an open deferral may be distilled into a backlog line, but recorded decision content is still never rewritten in place. Rely on git for the verbatim record rather than a second copy in the repository.
- Reason and evidence: The log had reached 341 lines and 57 KB across 23 entries, all of whose pull requests (#12–#20) are merged. Every agent starting work read the full history of settled decisions to find the handful of open ones, which is the cost this framework exists to avoid. An in-repo archive file was considered and rejected: it duplicates what git already stores immutably, and being greppable it would have been pulled into context anyway. No `CUT-` identifier is cited anywhere outside this directory, so retiring entries breaks no reference.
- What was completed: The retirement of CUT-001 through CUT-023, the carried backlog, the standing constraints, the closed index, the git retrieval pointer, the revised pruning policy in `README.md`, and updated references from `architecture/README.md`, the framework README, and `AGENTS.md`/`CLAUDE.md`.
- What was explicitly deferred: Any change to a cutoff's meaning, severity, or trigger; the default cutoff catalog; and tooling to enforce or automate pruning.
- Residual risk/severity: P3. Documentation-only. The risk is that distillation dropped an open deferral or softened a trigger, checked by confirming every retired entry's deferrals and residual risks appear in the backlog or standing constraints, or were closed by their own resolution metadata.
- Exact revisit trigger or acceptance condition: Revisit if a future PR needs a deferral or trigger that survives only in git history, or if this file grows past roughly 150 lines again.
- Status: proposed
- Resolving PR/SHA: Pending publication of this documentation change.

## Carried backlog

Open deferrals and accepted residual risks from closed decisions. Each is still live: treat the trigger as the condition that turns it into work. The named entry holds the full reasoning and evidence; retrieve it with the command above.

| Source | What remains | Severity | Revisit trigger |
| --- | --- | --- | --- |
| CUT-001 | Root-identity guards have centralized enforcement plus representative regressions, not an independent boundary matrix injecting identity swaps at every fetch, store, native-trash, and quarantine call site. | P2 | A centralized guard is bypassed at one of those call sites, a root-identity regression appears, or a dedicated boundary-matrix PR is scheduled. |
| CUT-007 | Trash receipts persisted before strong evidence still carry weak artifact comparison. Legacy recovery stays fail-closed; migration to strong digests is not done. | P2 | A safe one-time migration can hash the proven artifact under an owned recovery claim, or legacy recovery evidence is shown ambiguous. |
| CUT-017, CUT-021 | Conflict-preservation idempotence is unmeasured end to end: no harness compares identity, paths, mutations, journal events, and stored conflicts across two runs. Two PR #12 review threads remain open on it. | P2 | A deterministic reproduction on a frozen SHA shows duplicate conflict records, new preservation paths, repeated filesystem mutations, `runAlreadyExists` after the clean close-and-resync flow, or loss or overwrite of preserved content. |
| CUT-018, CUT-020, CUT-021 | Foundation exposes no atomic move-only-if-empty primitive, so a minimal window remains between the final owned emptiness proof and the recoverable directory move. Fails closed; no demonstrated bypass. | P2 | A late descendant is reproduced crossing that window, or a platform-specific atomic primitive can close it without weakening recoverability, root identity, receipts, leases, deadlines, or strong file evidence. |
| CUT-021 | Crash recovery may still need manual intervention after an ambiguous native-trash outcome, and root-identity probing can delay progress. Both fail closed rather than authorize destructive work. | P2 | Recovery ambiguity is shown to authorize mutation rather than block it, or probing delay becomes a usability defect with a reproduction. |
| CUT-022, CUT-023 | The evaluation-loop framework has no runtime enforcement tooling, and the pre-existing work-order and agent documents were never migrated to the consolidated structure. | P3 | A recorded reopen shows E14 still excludes a blocking finding class, a rule is found stated in two documents again, or a rule that existed before the refinement is found in neither. |

## Standing constraints

Conditions from closed decisions that bind future work rather than waiting to be scheduled. Honour them; they do not need rescheduling or re-approval.

- **New content-displacing planner operations** must be classified for evidence strength before they can displace content, and must not reach execution on weak evidence (CUT-004).
- **New provider mutation primitives** must keep the strong precondition adjacent to the physical commit, and no weak observation may become a canonical base version (CUT-005).
- **Weak content-stage materializations** get unique, non-reusable keys; a shared weak key requires a run-scoped, cryptographically safe design first (CUT-006).
- **Providers with malformed or non-`sha256-` revision tokens** are weak by definition; they must refine or fail closed at every destructive-authority boundary (CUT-015).
- **Directory trash** executes deepest-first, after non-trash work, and a directory must be proved empty under owned mutation immediately before native trash or quarantine (CUT-018).

## Closed decisions index

One line per retired entry, so an ID cited in the backlog above can be placed without retrieving anything. All of these were retired on 2026-08-12 and are recoverable in full from git at `90a2342`. Their pull requests are merged; entries that still read `proposed` or named a pending head, publication, or CI run were completed as recorded. Expected-PR numbering resolved as: the strong-version-evidence work published as PR #17, and PR #16 carried the evaluation-loop framework documentation.

| ID | Decision | Outcome |
| --- | --- | --- |
| CUT-001 | PR #13 physical-root finish line | Merged; permutation coverage carried forward. |
| CUT-002 | PR #15 demo-safety smoke | Merged; five observed defects fixed. |
| CUT-003 | PR #17 strong-evidence practical freeze | Merged as PR #17 (recorded as expected PR #16). |
| CUT-004 | Selective refinement instead of scan hashing | Merged; standing constraint above. |
| CUT-005 | Strong authority at execution, providers, and base state | Merged; standing constraint above. |
| CUT-006 | Owned incremental hashing and stage reuse | Merged; standing constraint above. |
| CUT-007 | Recovery compatibility boundary | Merged; legacy receipt migration carried forward. |
| CUT-008 | PR #17 permitted CI correction | Used; two missing `await` keywords. |
| CUT-009 | Promote the cutoff log through PR #12 | Merged. |
| CUT-010 | PR #17 replacement-CI diagnosis | Superseded by the CUT-012 correction authorization. |
| CUT-011 | Strong-evidence publication renumbered | Published as PR #17. |
| CUT-012 | One final diagnosed correction and exact-head run | Used; fixtures, corrupt-fetch provider, receipt-aware recovery. |
| CUT-013 | Freeze the final correction candidate | Superseded by the CUT-014 test-helper correction. |
| CUT-014 | Final test-helper correction | Used; one call-site change. |
| CUT-015 | Verify hash-backed revision tokens at staging | Merged; standing constraint above. |
| CUT-016 | Integrate current `main` into PR #12 | Merged; CI green at the integrated head. |
| CUT-017 | Close PR #17 smoke anomalies without speculative work | Closed; conflict idempotence carried forward. |
| CUT-018 | PR #18 directory-trash authority correction | Merged; standing constraint and P2 window carried forward. |
| CUT-019 | PR #18 permitted test-fixture correction | Used; test-only, replacement run green. |
| CUT-020 | PR #18 high-risk evaluation budget and finish line | Completed within budget; no correction batch needed. |
| CUT-021 | PR #12 integrated practical freeze | Merged; P2 residuals carried forward. |
| CUT-022 | Evaluation-loop framework refinement finish line | Merged as PR #20; deferrals carried forward. |
| CUT-023 | Evaluation-loop framework finish line | Merged as PR #16; renumbered from a duplicate CUT-009. |
