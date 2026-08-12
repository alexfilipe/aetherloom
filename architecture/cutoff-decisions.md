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

## CUT-008 — PR #16 permitted CI correction

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; failed frozen head `668bd46584d6ec917cc410f71697cedaa2c61b3c`; correction `b77dcf9d7f8938ec62cd979b647542a23a8c12cb`.
- Decision/cutoff: Use the single authorized correction cycle only to add the two missing `await` keywords at relocation-recovery rechecks, then run the one authorized replacement CI after the global queue clears.
- Reason and evidence: Exact-head CI [run 31551029903](https://github.com/alexfilipe/aetherloom/actions/runs/31551029903) failed during compilation at those two call sites; no test executed and no behavioral or safety scenario failed.
- What was completed: Both async calls now await `matchingCurrentState`; the correction changes no authority rule or test fixture.
- What was explicitly deferred: Any additional cleanup or iteration unrelated to the reported compiler errors.
- Residual risk/severity: Low; replacement exact-head CI remains required.
- Exact revisit trigger or acceptance condition: Accept only when the replacement exact-head macOS CI run is green; otherwise stop if the failure is not within the already authorized narrow correction.
- Status: accepted
- Resolving PR/SHA: Expected PR #16 / `b77dcf9d7f8938ec62cd979b647542a23a8c12cb`.

## CUT-009 — Promote the cutoff log through PR #12

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): PR [#12](https://github.com/alexfilipe/aetherloom/pull/12), integration documentation; parent head `14c72efe008636c0c76590499166b3e1498f6af6`; local PR #16 merge `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`.
- Decision/cutoff: Make the durable cutoff log part of the PR #12 integration parent before PR #16, then incorporate that parent into PR #16 with a normal merge that preserves all existing PR #16 commits.
- Reason and evidence: Parent commit `14c72efe008636c0c76590499166b3e1498f6af6` adds only `architecture/cutoff-decisions.md`; its blob `d6b0dd3082c64a6a7434a5619a3ebf4015d229d3` was byte-identical to the clean PR #16 copy and passed exact-head macOS CI [run 31551701935](https://github.com/alexfilipe/aetherloom/actions/runs/31551701935).
- What was completed: The parent was merged normally as `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`; both `14c72efe008636c0c76590499166b3e1498f6af6` and the prior PR #16 head `dda49b2d5f8e87cf4c0a17520485d9b752a17787` are ancestors, and no cutoff entry was erased.
- What was explicitly deferred: Pushing the merge, publishing PR #16, and dispatching more CI pending diagnosis and orchestrator direction.
- Residual risk/severity: Low; the merge itself changes no file content.
- Exact revisit trigger or acceptance condition: Push only after the CI diagnosis is accepted and the orchestrator authorizes the next correction/publication step.
- Status: accepted
- Resolving PR/SHA: PR #12 / `14c72efe008636c0c76590499166b3e1498f6af6`; local integration merge `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`.

## CUT-010 — PR #16 replacement-CI diagnosis

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected PR #16; tested head `dda49b2d5f8e87cf4c0a17520485d9b752a17787`; macOS CI [run 31551176210](https://github.com/alexfilipe/aetherloom/actions/runs/31551176210).
- Decision/cutoff: Classify the replacement result as a test failure after a successful compile/link, not an infrastructure failure. Do not proceed, correct, push, dispatch, or publish under the exhausted practical cutoff; retain locks for an explicit orchestrator decision on one additional focused correction.
- Reason and evidence: The run built successfully and executed 324 tests in 8 suites. Every focused required PR #16 acceptance scenario passed. Eleven unexpected issues remained: six hashless conformance fixtures supplied weak scan observations directly to strong destructive preconditions; one hash-mismatch fixture was intercepted by the new source precondition before ContentStage verification; two strong recovery probes attempted to hash live source paths after those sources had been recoverably trashed; and two true legacy weak-receipt cases no longer satisfied RunRecovery's strong match. Nine separately declared known issues were also reported.
- What was completed: Exact failure extraction and source-level diagnosis. The current implementation failed closed: no failing result demonstrated overwrite, trash, canonical replacement, false convergence, or weak base-state authorization.
- What was explicitly deferred: Conformance-fixture refinement, a dedicated corrupt-fetch fixture, receipt-first strong recovery probing, and a decision whether true legacy weak receipts remain blocked or gain an explicit narrowly scoped proof type.
- Residual risk/severity: Medium for release readiness because exact-head CI is red; low for immediate data loss because the observed paths reject uncertain work. Legacy recovery can remain paused until reconciled.
- Exact revisit trigger or acceptance condition: Proceed only if the orchestrator authorizes one additional focused correction set, preserves fail-closed legacy behavior unless an explicit proof model is approved, and requires a new clear-queue exact-head macOS CI run to pass.
- Status: deferred
- Resolving PR/SHA: None; awaiting orchestrator direction.

## CUT-011 — Strong-evidence publication renumbered to PR #17

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): PR 17 - Implementation; branch `codex/p1-strong-version-evidence`; local head `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`; target `claude/local-sync-work-order` at `14c72efe008636c0c76590499166b3e1498f6af6`.
- Decision/cutoff: Supersede the unpublished expected PR #16 number with expected draft PR #17 for all strong-version-evidence entries. Preserve historical “expected PR #16” text as recorded.
- Reason and evidence: Unrelated open draft PR #16, `codex/standard-subagent-structure` targeting `main`, was allocated before strong-version-evidence publication.
- What was completed: Durable task and publication state now identify the work as PR 17 - Implementation while retaining the existing branch, local merge, commits, target, dirty log additions, and writer/test locks.
- What was explicitly deferred: Any code or test correction, CI dispatch, push, or draft PR creation. PR #16 remains untouched.
- Residual risk/severity: Low; this is publication-number metadata only. Exact-head CI remains red and publication remains blocked.
- Exact revisit trigger or acceptance condition: Publish only as draft PR #17 after explicit orchestrator authorization and green exact-head macOS CI, targeting `claude/local-sync-work-order` at the required integration lineage.
- Status: superseded
- Resolving PR/SHA: Historical expected PR #16 references are superseded by expected PR #17; no publication SHA or PR URL exists yet.

## CUT-012 — Authorize one final diagnosed correction and exact-head run

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected draft PR #17; branch `codex/p1-strong-version-evidence`; pre-correction local head `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`; failed tested head `dda49b2d5f8e87cf4c0a17520485d9b752a17787`; target `claude/local-sync-work-order` at `14c72efe008636c0c76590499166b3e1498f6af6`.
- Decision/cutoff: Authorize exactly one final correction set limited to the diagnosed run-31551176210 failures and exactly one corrected-head macOS CI run. A red final run freezes the work without further edits or reruns.
- Reason and evidence: The failed run compiled and all required strong-evidence scenarios passed, while eleven unexpected failures were confined to three unrefined conformance call paths, one corrupt-fetch fixture, two receipt-aware recovery probes, and two legacy weak-receipt expectations.
- What was completed: Authorization was bounded to explicit fixture refinement, a dedicated corrupt-fetch provider, receipt-aware state before live-path refinement, and fail-closed legacy expectations.
- What was explicitly deferred: Any weakened strong precondition, wider legacy proof model, unrelated production behavior, cleanup, refactor, exhaustive matrix, documentation polish, conflict-idempotence, or additional CI attempt.
- Residual risk/severity: Medium until the single corrected exact-head run is green; low immediate data-loss risk because the diagnosed behavior fails closed.
- Exact revisit trigger or acceptance condition: Freeze and publish draft PR #17 only after static audits and the one corrected exact-head macOS CI run pass; if it fails, stop without editing or rerunning.
- Status: accepted
- Resolving PR/SHA: Pending the final corrected commit and authorized CI disposition.

## CUT-013 — Freeze the final correction candidate for authoritative CI

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected draft PR #17; focused correction `9731d1f35a2e28be25717e9a4fd45ef9effa6e2c`; parent integration `14c72efe008636c0c76590499166b3e1498f6af6`; preserved merge `4471dcafc37f9e10084ba5452a93ae85ef64e5f4`.
- Decision/cutoff: Freeze the diagnosed correction plus this disposition entry as the only candidate for the final authorized exact-head macOS CI run. Green authorizes draft PR #17 publication; red requires stopping without edits or another run.
- Reason and evidence: Provider-contract fixtures now refine before destructive calls, corrupt-fetch coverage reaches ContentStage verification without forged evidence, recovery checks receipt-aware state before live-file refinement, and legacy weak receipts remain paused. `git diff --check`, focused scope review, permanent-delete audit, sleep audit, and secret-assignment audit passed; Busy Beaver has neither Swift nor Xcode, so no local Swift or app-target validation exists.
- What was completed: The four diagnosed run-31551176210 correction categories and required append-only cutoff metadata were committed without weakening provider preconditions, scan laziness, physical-root ownership, receipts, or recovery barriers.
- What was explicitly deferred: A wider legacy proof model, exhaustive permutations, unrelated cleanup or refactors, conflict-idempotence, local Swift/Xcode validation, and every additional correction or CI attempt.
- Residual risk/severity: Medium until authoritative macOS CI completes; immediate data-loss risk remains low because uncertainty and legacy weak evidence fail closed.
- Exact revisit trigger or acceptance condition: Accept and publish only if the one exact-head macOS CI run is green and local/upstream/origin SHAs, cleanliness, ancestry, and PR #12 targeting are all verified; otherwise stop frozen and unpublished.
- Status: accepted
- Resolving PR/SHA: Focused correction `9731d1f35a2e28be25717e9a4fd45ef9effa6e2c`; final exact-head CI run and draft PR #17 URL pending.

## CUT-014 — Authorize the final test-helper correction and disposition

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): expected draft PR #17; failed exact head `430134ec5ddca4ca4cd49f0c125f53b6e33277a6`; macOS CI [run 31553563703](https://github.com/alexfilipe/aetherloom/actions/runs/31553563703); parent integration `14c72efe008636c0c76590499166b3e1498f6af6`.
- Decision/cutoff: Authorize exactly the one-line `ExecutorTests.swift` call-site correction from the concrete `[FakeStorageProvider]` helper to the existing existential `providerMap:` helper, followed by exactly one final exact-head macOS CI run. Green permits draft PR #17 publication; red requires stopping unpublished without another edit or run.
- Reason and evidence: Run 31553563703 reached test-target compilation and failed only because `CorruptFetchProvider` cannot be placed in the concrete fake-provider array. Production code compiled, no test executed, and the existing `providerMap:` overload already accepts mixed `StorageProvider` implementations.
- What was completed: The diagnosed test-helper call was corrected without changing the corrupt-fetch behavior, production code, any other test, or provider authority.
- What was explicitly deferred: Every production change, other test change, cleanup, refactor, additional correction, or additional CI attempt.
- Residual risk/severity: Low for the correction because it changes only test construction; authoritative execution of the full suite remains required.
- Exact revisit trigger or acceptance condition: Freeze at the corrected exact head; publish draft PR #17 only if the one authorized run is green and all SHA, ancestry, cleanliness, and PR relationship checks pass. A red result ends work unpublished.
- Status: accepted
- Resolving PR/SHA: Corrected commit, final CI run, and draft PR #17 URL pending.
