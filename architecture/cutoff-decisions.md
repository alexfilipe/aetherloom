# Cutoff decisions

This append-only log records deliberate scope decisions. Existing entries remain intact; later resolution or supersession metadata is appended to the relevant entry.

## CUT-001 — PR #13 physical-root finish line

- Date: 2026-08-11
- PR/layer and exact relevant SHA(s): PR [#13](https://github.com/alexfilipe/aetherloom/pull/13), local I/O ownership; final head `b111b83b0598e739c4fb6f590b8221ed1bed4b8b`; integration merge `cb68021a2abb313f56e7895ac9ee142aab7d1e48`.
- Decision/cutoff: Finish only the two physical-root findings, require green exact-head macOS CI and targeted R4 verification, perform no additional full review, and reopen only for an immediate P0 data-loss defect.
- Reason and evidence: The ownership/recovery fixes were validated at the frozen head by successful workflow-dispatch CI [run 31541925458](https://github.com/alexfilipe/aetherloom/actions/runs/31541925458) and the assigned focused R4 verification.
- What was completed: Physical-root identity binding and the two required ownership/recovery findings.
- What was explicitly deferred: R4 noted that focused tests did not independently inject identity swaps at every fetch, store, native-trash, and quarantine call site. Centralized guards plus representative regressions were accepted; the broader boundary matrix was deferred.
- Residual risk/severity: Low; missing permutation coverage, not a known guard bypass.
- Exact revisit trigger or acceptance condition: Revisit if a centralized guard is bypassed at one of those call sites, a root-identity regression appears, or a dedicated boundary-matrix PR is scheduled.
- Status: accepted
- Resolving PR/SHA: PR #13 / `b111b83b0598e739c4fb6f590b8221ed1bed4b8b` (merged as `cb68021a2abb313f56e7895ac9ee142aab7d1e48`).

## CUT-002 — PR #15 demo-safety smoke

- Date: 2026-08-11
- PR/layer and exact relevant SHA(s): PR [#15](https://github.com/alexfilipe/aetherloom/pull/15), demo-safety smoke; final head `3b5efa34ab8fee71e26119aa58a38dd90e44deb2`; merge into the PR #13 branch `2c2fa061820f599b3e8798232bb8bae6c257d674`.
- Decision/cutoff: Limit work to the user-observed clean-baseline, NAS, mass-deletion, interrupted-run, and provider-menu synchronization defects. Accept exact-head CI plus user Mac smoke instead of another full review, while leaving PR #13 core ownership scope unchanged.
- Reason and evidence: The changes repaired the observed demo paths, and the frozen head passed workflow-dispatch CI [run 31548128194](https://github.com/alexfilipe/aetherloom/actions/runs/31548128194); user Mac smoke was the required app-level acceptance evidence.
- What was completed: The five observed demo-safety synchronization defects and their focused regressions.
- What was explicitly deferred: Any expansion of PR #13 ownership/recovery architecture and another full review cycle.
- Residual risk/severity: Low; broader demo permutations were outside the observed defect set.
- Exact revisit trigger or acceptance condition: Revisit on a reproduced demo-safety regression outside the covered paths or an independently approved ownership follow-up.
- Status: accepted
- Resolving PR/SHA: PR #15 / `3b5efa34ab8fee71e26119aa58a38dd90e44deb2` (merged as `2c2fa061820f599b3e8798232bb8bae6c257d674`).

## CUT-003 — PR #16 practical freeze

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16, strong-version-evidence layer; exact base `cb68021a2abb313f56e7895ac9ee142aab7d1e48`; branch `codex/p1-strong-version-evidence`.
- Decision/cutoff: Complete the minimal coherent strong-evidence path and every assigned acceptance scenario, retain metadata-only scans and lazy unchanged reruns, pass static audits and one exact-head macOS CI run, then freeze. One narrow compile/test-fixture correction and one replacement run are allowed only if the first CI failure is focused and the queue is clear.
- Reason and evidence: Strong evidence is a destructive-authority safety boundary; broader iteration is not required once all enumerated scenarios and exact-head validation pass.
- What was completed: Scope fixed around overwrite, trash/delete propagation, canonical replacement, convergence/base-state updates, execution rechecks, provider last-line preconditions, selective owned-I/O hashing, and stale-stage prevention.
- What was explicitly deferred: Exhaustive permutations, unrelated cleanup or refactors, broad documentation polish, and conflict-preservation idempotence.
- Residual risk/severity: Low to medium until exact-head CI completes; no listed safety scenario may be deferred under this entry.
- Exact revisit trigger or acceptance condition: Block or reopen only for immediate data loss, ambiguous destructive authority, a listed scenario failure, or inability to obtain green exact-head CI.
- Status: accepted
- Resolving PR/SHA: Pending publication of PR #16; implementation is based on `cb68021a2abb313f56e7895ac9ee142aab7d1e48`.

## CUT-004 — Selective refinement instead of scan hashing

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; base `cb68021a2abb313f56e7895ac9ee142aab7d1e48`; strong-evidence planning layer.
- Decision/cutoff: Model strong, weak, different, and unknown comparisons explicitly. Keep scans metadata-only; after a provisional plan, refine only weak regular-file observations participating in an operation that would displace content, then replan and fingerprint the refined snapshots. Evidence failure produces an explicit refusal with no destructive schedule.
- Reason and evidence: Size/mtime equality can identify candidates but cannot authorize displacement. Selective replanning preserves ordinary scan laziness while removing weak authority from overwrite, trash, relocate, and canonical replacement.
- What was completed: Explicit evidence states, read-only provider refinement, iterative selective replanning, fail-closed refusal, and refined-snapshot fingerprinting coverage.
- What was explicitly deferred: Whole-tree hashes, speculative hashing of safe path-absent creation, and exhaustive evidence-selection permutations.
- Residual risk/severity: Low; future planner operation kinds must be classified before they can displace content.
- Exact revisit trigger or acceptance condition: Revisit when adding a new content-displacing operation or if a required operation can reach execution without strong evidence.
- Status: accepted
- Resolving PR/SHA: Pending PR #16 implementation commit.

## CUT-005 — Strong authority at execution, providers, and base state

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; base `cb68021a2abb313f56e7895ac9ee142aab7d1e48`; executor/provider/base-state layer.
- Decision/cutoff: Require strong sameness for file convergence and already-satisfied destructive operations, re-read strong evidence immediately before execution, enforce provider-level strong preconditions at the mutation boundary, and never replace an existing strong base version with weak operation output.
- Reason and evidence: Approval-time hashes alone do not cover post-approval drift or provider TOCTOU windows. Executor and provider checks are separate defenses; successful transfer/relocate verification supplies strong observations for base updates.
- What was completed: Strong executor probes and apply rechecks, fake/local provider preconditions for overwrite/relocate/trash, post-operation verification, and strong-base preservation.
- What was explicitly deferred: Exhaustive timing permutations beyond deterministic same-size/same-mtime regressions and the existing centralized physical-root guards.
- Residual risk/severity: Low; external mutation remains possible after any final check, so provider operations must continue to keep the check adjacent to physical commit.
- Exact revisit trigger or acceptance condition: Revisit on a demonstrated check-to-commit gap, a new provider mutation primitive, or a weak version entering a canonical base update.
- Status: accepted
- Resolving PR/SHA: Pending PR #16 implementation commit.

## CUT-006 — Owned incremental hashing and stage reuse

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; base `cb68021a2abb313f56e7895ac9ee142aab7d1e48`; local I/O and content-stage layer.
- Decision/cutoff: Hash local files with bounded incremental SHA-256 inside PR #13's owned-read/mutation mechanism. Retain physical leases across caller deadlines and recovery barriers. Reuse staged bytes only under strong keys; give every weak materialization a unique key and remove it when unpinned.
- Reason and evidence: Whole-file reads are unbounded, unowned hashing can outlive safety coordination, and weak size/mtime stage keys can return stale bytes.
- What was completed: Fixed-size streaming hashes, owned selective evidence reads, root/recovery checks, streaming stage verification, and non-reusable weak stage keys.
- What was explicitly deferred: Cross-run weak-stage fanout and hashing performance tuning beyond the bounded implementation.
- Residual risk/severity: Low; weak staging may perform additional reads by design.
- Exact revisit trigger or acceptance condition: Revisit only with a run-scoped cryptographically safe weak-fanout design or measured evidence that bounded hashing needs tuning without weakening leases.
- Status: accepted
- Resolving PR/SHA: Pending PR #16 implementation commit.

## CUT-007 — Recovery compatibility boundary

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; base `cb68021a2abb313f56e7895ac9ee142aab7d1e48`; local trash-recovery layer.
- Decision/cutoff: New trash receipts retain strong file evidence and recovery artifact checks re-hash under owned I/O. Legacy receipts may use their pre-existing exact-artifact weak comparison only inside the recovery path; weak evidence still cannot authorize a new destructive mutation or a new strong base state.
- Reason and evidence: Removing legacy receipt recognition would regress established recovery barriers, while extending legacy weak equality to live mutations would violate the PR #16 authority contract.
- What was completed: Strong receipt/artifact verification for new operations and a narrowly scoped legacy compatibility predicate.
- What was explicitly deferred: Migration of already-persisted legacy receipts to strong digests.
- Residual risk/severity: Low to medium and isolated to legacy recovery evidence; existing exact path, owned-root, receipt, artifact-presence, and recovery barriers remain required.
- Exact revisit trigger or acceptance condition: Revisit when a safe one-time legacy receipt migration can hash the proven artifact under an owned recovery claim, or if legacy recovery evidence is shown ambiguous.
- Status: deferred
- Resolving PR/SHA: None; migration deferred beyond PR #16.

## Resolution metadata appended 2026-08-12

- CUT-003: Implemented by `bc493acfa1d325e37c7ef1b8146a53aab69183cf`; PR number and exact-head CI remain pending publication.
- CUT-004: Implemented by `bc493acfa1d325e37c7ef1b8146a53aab69183cf`.
- CUT-005: Implemented by `bc493acfa1d325e37c7ef1b8146a53aab69183cf`.
- CUT-006: Implemented by `bc493acfa1d325e37c7ef1b8146a53aab69183cf`.
- CUT-007: The compatibility boundary is implemented by `bc493acfa1d325e37c7ef1b8146a53aab69183cf`; legacy receipt migration remains deferred.
