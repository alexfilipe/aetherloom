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

## CUT-015 — Verify hash-backed revision tokens at staging

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): draft PR [#17](https://github.com/alexfilipe/aetherloom/pull/17), strong-version evidence; prior frozen head `d7c0910d149fa25b030f28f2d29f04d55ffaf394`; prior exact-head macOS CI [run 31554154719](https://github.com/alexfilipe/aetherloom/actions/runs/31554154719).
- Decision/cutoff: Correct only the independent P1 finding that hash-token-only evidence could authorize staging without comparing fetched bytes. Treat `sha256-` revision tokens as strong only when followed by exactly 64 hexadecimal digits, normalize the parsed digest for comparison, and require ContentStage's bounded SHA-256 result to match that digest before any destination mutation.
- Reason and evidence: The prior run passed 324 tests in 8 suites with 0 failures, 9 known issues, and 1 opt-in skip, but its staging check consulted only `contentHash`. A corrupt or truncated fetch under a hash-token-only expected version could therefore reach canonical storage without proving the staged bytes matched the token.
- What was completed: Strict revision-token parsing, token-backed staged-byte verification, malformed-token strength coverage, and a deterministic corrupt-fetch executor regression that requires zero destination mutations.
- What was explicitly deferred: Every unrelated production change, review thread or PR metadata mutation, cleanup, refactor, exhaustive token/provider permutations, and any new synchronization layer.
- Residual risk/severity: Low after a green exact-head macOS run; providers using malformed or non-SHA revision tokens remain weak and must refine or fail closed at destructive authority boundaries.
- Exact revisit trigger or acceptance condition: Accept only if focused token/staging coverage and the full package suite pass on the one new exact head, static safety audits pass, and exactly one clear-queue macOS CI run succeeds. The immutable tested SHA and CI URL belong in the frozen report because appending them afterward would create a different, untested head.
- Status: accepted
- Resolving PR/SHA: Pending the focused correction commit and its single exact-head macOS CI run.

## CUT-009 — Evaluation-loop framework finish line

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): evaluation-loop documentation on branch `codex/standard-subagent-structure`; base `30e0e6a84080007748949a1728c8c0d96eb28ae0`; PR #12 cutoff precedent `14c72efe008636c0c76590499166b3e1498f6af6`; final publication SHA pending.
- Decision/cutoff: Generalize the PR #12 orchestration lessons into a risk-scaled define → implement → evaluate → decide framework for all future features and PRs. Default to one complete independent evaluation for high-risk work, one correction batch, targeted verification, and one exact-head authoritative run. Require new P0/P1 evidence and explicit user approval before a third complete evaluation.
- Reason and evidence: PR #12's durable decisions and live orchestration showed that exact finish lines, focused verification, one narrow correction allowance, human smoke evidence, and concrete reopen triggers preserve safety while preventing recursive review from indefinitely delaying merge.
- What was completed: Canonical framework documentation, bounded subagent triggers, risk tiers, evaluation/review ceilings, validation and lock rules, human-smoke routing, durable cutoff policy/template, and references from `AGENTS.md`, `CLAUDE.md`, and the architecture index.
- What was explicitly deferred: Runtime enforcement tooling, automation of task creation/locks, and any implementation or PR-state changes from the historical local-provider safety stack.
- Residual risk/severity: P3; the framework is procedural documentation and depends on future agents applying and recording its gates accurately.
- Exact revisit trigger or acceptance condition: Revisit when a completed feature or PR demonstrates that a default cutoff either allowed a P0/P1 defect through or required redundant evaluation without producing new actionable evidence.
- Status: accepted
- Resolving PR/SHA: Pending publication of the documentation change.

## PR-number metadata appended 2026-08-12

- CUT-003 through CUT-008: References to “expected PR #16” reflected the plan when those decisions were recorded and are now superseded for numbering only. PR #16 was assigned to the evaluation-loop documentation; the strong-version-evidence PR number remains pending. The recorded strong-evidence scope, bases, implementation SHAs, CI evidence, risks, and revisit triggers are unchanged.
- CUT-009: Published as draft PR #16. The framework was introduced by `ab6965e74786ce66a30d56e898bae0ebc1b7c5cd`; this appended metadata is the only post-publication correction.

## CUT-016 — Integrate current main into PR #12

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): PR [#12](https://github.com/alexfilipe/aetherloom/pull/12), branch `claude/local-sync-work-order`; pre-merge integration head `dc7cde3d4df405bb52f1ecd5bb984ca0793c1e1a`; merged `main` head `26878abcdedfbfd009b9c1d13c789c722c5f1dc1`; common ancestor `23177b20c93820cda70b6e31c43f9d339e4050a0`.
- Decision/cutoff: Merge current `main` into the PR #12 integration branch with a normal merge commit after explicit user authorization. Preserve both independently added cutoff-log histories verbatim, including their historically duplicated `CUT-009` identifiers, and document the collision here instead of renumbering or rewriting either entry.
- Reason and evidence: PR #12 had become conflicting after PR #16 advanced `main`. The integration branch was clean and synchronized, no Swift workflow was active, and the only Git merge conflict was the add/add cutoff log.
- What was completed: All code and framework-documentation changes from `main` were merged automatically. The sole cutoff-log conflict retained every entry from both sides and removed only Git conflict markers.
- What was explicitly deferred: Any product-level conflict-idempotence correction, PR #18 target selection, conflict-thread resolution, PR #12 readiness/merge, and merge-result validation beyond static checks until the exact merge commit is published and macOS CI completes.
- Residual risk/severity: Medium until exact-head macOS CI validates the combined branch. The duplicate historical `CUT-009` labels are a documentation ambiguity only; titles and SHAs disambiguate them.
- Exact revisit trigger or acceptance condition: Accept the integration only after `git diff --check`, ancestry/cleanliness verification, normal push, and one green exact-head macOS CI run. Reopen merge resolution only for a combined-branch regression or lost historical cutoff entry.
- Status: accepted
- Resolving PR/SHA: Merge commit and exact-head CI pending.

## Resolution metadata appended 2026-08-12

- CUT-016: Integrated current `main` as merge commit `4926685568c5daf1b401f7b84189f351ee3d9569`. Exact-head macOS CI [run 31562729072](https://github.com/alexfilipe/aetherloom/actions/runs/31562729072) passed 326 tests in 8 suites with 0 unexpected failures, 9 known issues, and 1 opt-in skip. PR #12 was clean and mergeable against `main` after the integration.

## CUT-017 — Close the reported PR #17 smoke anomalies without speculative PR #18 work

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): merged PR [#17](https://github.com/alexfilipe/aetherloom/pull/17); PR #12 integration head `4926685568c5daf1b401f7b84189f351ee3d9569`; user macOS smoke evidence captured after the `main` integration.
- Decision/cutoff: Treat the mass-deletion report as resolved by the documented preview step and treat the earlier `runAlreadyExists` alert as not reproducible when the conflict dialog is closed before starting a fresh sync. Do not reopen PR #17 and do not create a speculative PR #18 implementation from this evidence.
- Reason and evidence: The Projects preview displayed the required 30-item mass-deletion hold with “Paused for safety.” A subsequent clean conflict flow preserved both versions; after closing the dialog, starting Sync again produced a fresh Needs Review preview without `runAlreadyExists`. No permanent deletion, overwrite, or loss of either conflict version was observed.
- What was completed: User-level macOS smoke coverage for mass-deletion review and repeated unresolved-conflict preview on the updated integration branch. The two read-only PR #18 reproduction tasks also found no existing executable harness for the full two-run identity/path/journal/store comparison.
- What was explicitly deferred: Conflict-preservation idempotence implementation, semantic conflict identity, durable preservation mapping, full repeated-execution mutation/journal comparison, and PR #18 branch/PR creation.
- Residual risk/severity: Low to medium. The originally planned conflict-idempotence scenario remains unmeasured end to end, but there is currently no reproducible failure or immediate data-loss evidence authorizing an implementation target.
- Exact revisit trigger or acceptance condition: Reopen target selection only with a deterministic reproduction on a frozen `main` or integration SHA showing duplicate conflict records, new preservation paths, repeated filesystem mutations, `runAlreadyExists` after the clean close-and-resync flow, or loss/overwrite of preserved content.
- Status: deferred
- Resolving PR/SHA: No PR #18 implementation created; smoke anomalies closed at PR #12 head `4926685568c5daf1b401f7b84189f351ee3d9569` pending publication of this append-only record.

## CUT-018 — PR #18 directory-trash authority correction

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): draft PR #18, directory-trash authority; exact base and target `claude/local-sync-work-order` at `3e29a6b9ba9eaaa5755dec905e9f01d13358625d`; focused implementation head `d60c0928956756990f741c113bbed0e2e41a0e0c`; branch `codex/p1-directory-trash-authority`.
- Decision/cutoff: Correct only the final-review P1 in which lexicographic parent-first directory trash plus weak folder metadata could move an unplanned late descendant. Require the trash suffix to execute deepest-first after non-trash work, reject schedules that place a directory before a planned same-location descendant, and require the real local provider to prove the directory empty under its owned mutation and physical-root admission immediately before native trash or quarantine. Finish after the listed late-grandchild, deterministic order, and recoverable clean-deletion regressions, focused static audits, and exactly one green exact-head macOS CI run from an empty global workflow queue.
- Reason and evidence: At the reviewed base, `/Folder` could execute before descendants, and `trashCurrent` moved the full current directory without enumerating it; a late `/Folder/Sub/Late.txt` could therefore be swept into recoverable trash without plan authority. The correction preserves strong regular-file evidence, root identity, leases/deadlines, mutation journaling, prepared/committed trash receipts, and recovery artifacts. `git diff --check`, focused file-scope review, deterministic-timing audit, secret-assignment audit, and the production permanent-delete audit passed at implementation head `d60c0928956756990f741c113bbed0e2e41a0e0c`. Busy Beaver has neither Swift nor Xcode, so no local Swift suite or app build was run or claimed.
- What was completed: Stable depth-descending trash scheduling, descendant-before-directory schedule validation, folder-specific executor admission without weakening file checks, last-line empty-directory proof before both recoverable physical trash paths, a deterministic late-grandchild replan regression using the existing mutation gate, exact planned/actual deepest-first ordering coverage, clean nested recovery-artifact coverage, and invalid-schedule coverage.
- What was explicitly deferred: Conflict-preservation idempotence, UI, PR #12 thread disposition, unrelated cleanup/refactors, cloud-provider behavior, exhaustive directory race permutations, local Swift/Xcode validation, and any PR base/readiness or review-thread mutation.
- Residual risk/severity: P2 after green exact-head CI. Foundation exposes no atomic “move only if empty” primitive, so an external process could theoretically create a child after the final owned emptiness enumeration and before the immediately following filesystem move; the correction minimizes and fails closed before that OS-level window but does not introduce platform-specific filesystem primitives.
- Exact revisit trigger or acceptance condition: Accept only when the append-only disposition commit is the clean local/upstream/origin/PR head, is descended from the exact base, and one clear-queue macOS CI run at that exact head passes the full package suite including all listed regressions. Reopen for a reproduced unplanned-descendant move, parent-before-descendant execution, non-recoverable deletion, a listed regression failure, invalidated exact-head validation, or new P0/P1 evidence.
- Status: proposed
- Resolving PR/SHA: Draft PR #18 and final disposition commit pending; focused implementation is `d60c0928956756990f741c113bbed0e2e41a0e0c`.

## CUT-019 — PR #18 permitted test-fixture correction

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): draft PR [#18](https://github.com/alexfilipe/aetherloom/pull/18); failed exact head `19ccab332c2111ac824a796f9f598b2599cdc251`; macOS CI [run 31564897909](https://github.com/alexfilipe/aetherloom/actions/runs/31564897909); exact base `3e29a6b9ba9eaaa5755dec905e9f01d13358625d`.
- Decision/cutoff: Permit one test-only correction and one replacement exact-head macOS CI run. Replace the clean nested recovery test's post-run `currentState` calls made with stale pre-child-removal folder observations with assertions over the executor's applied trashed observations; retain the existing exact physical recovery-artifact, move-count, ordering, live-path absence, content, and convergence assertions. No production change or broader retry is authorized.
- Reason and evidence: Run 31564897909 compiled and linked all production and test targets, then ran 329 tests in 8 suites. The only unexpected issue was `.notFound` in `approvedCleanNestedDirectoryDeletionIsDeepestFirstAndRecoverable`; nine separately declared provider-conformance known issues remained known. Deepest-first child trash legitimately changes ancestor directory metadata, so querying recovery with the plan's stale folder observation is expected to fail closed. The executor had already returned a fresh applied trashed observation for each successful operation, which is the correct assertion surface. No listed safety scenario failed and no production defect was demonstrated.
- What was completed: Exact failure extraction and a correction limited to the stale test assertion. The late-grandchild fail-closed test, schedule validation, production compilation, and all existing suites otherwise passed.
- What was explicitly deferred: Every production change, additional fixture change, cleanup/refactor, exhaustive race permutations, and any CI run beyond the single replacement.
- Residual risk/severity: P2 until the replacement exact-head run is green; the failure was test-observation staleness, not ambiguous destructive authority.
- Exact revisit trigger or acceptance condition: Freeze after one replacement run at the clean corrected local/upstream/origin/PR head. Green completes validation; red requires stopping without another edit or dispatch unless new explicit authority is granted.
- Status: accepted
- Resolving PR/SHA: Test-only correction commit and replacement run pending.

## CUT-020 — PR #18 high-risk evaluation budget and finish line

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): draft PR [#18](https://github.com/alexfilipe/aetherloom/pull/18), directory-trash authority; exact base and target `claude/local-sync-work-order` at `3e29a6b9ba9eaaa5755dec905e9f01d13358625d`; production implementation `d60c0929cf9c726c07d9a9efca66e5da6abb1c23`; prior corrected and validated head `df8db46d21331d421bd1f2d26e687567529c1070`; final append-only alignment head pending publication.
- Decision/cutoff: Treat PR #18 as high risk. Its evaluation budget is writer self-evaluation, one independent complete-diff evaluation after the exact base/head pair is frozen and published, at most one coherent correction batch, targeted verification by the original independent evaluator, and one exact-head macOS validation. Do not request or perform a fresh second complete review unless E09 materiality is met: a correction adds a safety boundary, changes the architecture or acceptance contract, substantially rewrites evaluated code, or cannot be verified narrowly.
- Reason and evidence: Directory trash is a destructive-authority boundary. The bounded process must prove the three accepted scenarios without reopening unrelated work: a late grandchild remains live and forces replan without trashing its ancestors; clean approved nested deletion executes deepest-first; and clean nested deletion remains recoverable with no permanent-delete path. Writer static evaluation and macOS run [31565083759](https://github.com/alexfilipe/aetherloom/actions/runs/31565083759) passed at `df8db46d21331d421bd1f2d26e687567529c1070`; appending this durable contract creates a new documentation-only head, so exact-head evidence must be re-established before freeze.
- What was completed: The PR #18 code and regression scope remains exactly the narrow directory-trash correction recorded in CUT-018. Writer self-evaluation covered `git diff --check`, focused scope, permanent-delete production-source, deterministic timing, secret-assignment, ancestry, SHA equality, and temporary-root test-fixture audits. The prior replacement macOS run passed 329 tests in 8 suites with zero unexpected failures, nine declared known issues, and one opt-in skip.
- What was explicitly deferred: Conflict-preservation idempotence, UI, PR #12 thread disposition, unrelated cleanup/refactors, cloud-provider behavior, exhaustive filesystem race permutations, and any second fresh complete-diff evaluation unless E09 materiality is demonstrated. Merge, readiness/base changes, review-thread changes, force-push, and destructive recovery remain unauthorized.
- Residual risk/severity: P2; Foundation exposes no atomic “move only if empty” primitive, leaving a minimal external-creation window after the final owned emptiness proof and before the immediately following filesystem move. No demonstrated guard bypass remains. Revisit on a reproduced late descendant crossing that boundary or when a platform-specific atomic primitive can close it without weakening recoverability, root identity, receipts, leases, deadlines, or strong file evidence.
- Exact revisit trigger or acceptance condition: Finish only when all three listed directory-trash scenarios pass, no P0/P1 finding remains, local HEAD, upstream, origin branch, and GitHub PR head are exactly equal, exact-head macOS CI is green, and every remaining P2 has a concrete revisit trigger. Then the original independent evaluator must either report no blocking finding or complete targeted verification of at most one coherent correction batch. Reopen only for E09 materiality, a reproduced acceptance regression or guard bypass, invalidated exact-head evidence, changed base, or new P0/P1 evidence.
- Status: proposed
- Resolving PR/SHA: Draft PR #18; final frozen publication SHA, independent evaluation disposition, targeted verification if needed, and exact-head macOS run pending.

## Resolution metadata appended 2026-08-12

- CUT-018: The production implementation SHA is `d60c0929cf9c726c07d9a9efca66e5da6abb1c23`; the longer SHA recorded in CUT-018 was a transcription error. The scope and rationale are unchanged.
- CUT-019: The authorized test-only correction is `df8db46d21331d421bd1f2d26e687567529c1070`. Replacement macOS CI [run 31565083759](https://github.com/alexfilipe/aetherloom/actions/runs/31565083759) passed 329 tests in 8 suites with zero unexpected failures, nine declared known issues, and one opt-in skip. This evidence remains authoritative for the unchanged code and tests, but a new exact-head run is required after CUT-020 is appended and published.

## Resolution metadata appended 2026-08-12

- CUT-018: Resolved by PR [#18](https://github.com/alexfilipe/aetherloom/pull/18) at frozen head `beef6ffdd769f334a28c1a5f1e7a33952ff86b6c`, merged into `claude/local-sync-work-order` as `d3bb7408f4670508e0676697ebda80780ed307e5`. Exact-head macOS CI [run 31578077290](https://github.com/alexfilipe/aetherloom/actions/runs/31578077290) passed 329 tests in 8 suites with zero unexpected failures, nine known issues, and one opt-in Foundation Models skip. The independent complete-diff evaluator reported PASS WITH P2 RESIDUALS and no P0/P1 finding; all three directory-trash scenarios and the late-grandchild fail-closed sequence passed. The original ambiguous-authority trigger is closed. Reopen only for a reproduced unplanned-descendant move, parent-before-descendant execution, non-recoverable deletion, invalidated exact-head evidence, a listed regression, or new P0/P1 evidence.
- CUT-019: Resolved. The bounded correction remained test-only, the single replacement run passed, and no further correction or retry was needed.
- CUT-020: Accepted and frozen. The evaluation budget completed with writer self-evaluation, one independent complete-diff evaluation, no production correction batch, and one green exact-head macOS run. The accepted P2 residual is the minimal OS-level window between final directory emptiness proof and the immediately following recoverable filesystem move; revisit only if that race is reproduced or an atomic platform primitive can close it without weakening recoverability, root identity, receipts, ownership, deadlines, or strong file evidence. No second complete PR #18 evaluation is warranted under E09.

## CUT-021 — PR #12 integrated practical freeze

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): PR [#12](https://github.com/alexfilipe/aetherloom/pull/12); exact base `main` at `26878abcdedfbfd009b9c1d13c789c722c5f1dc1`; prior completely evaluated head `3e29a6b9ba9eaaa5755dec905e9f01d13358625d`; PR #18 frozen head `beef6ffdd769f334a28c1a5f1e7a33952ff86b6c`; PR #18 integration merge `d3bb7408f4670508e0676697ebda80780ed307e5`; integrated evaluated head before this documentation-only freeze entry `08140e64befbc2edff60eaac62606c80abe5c5d3`.
- Decision/cutoff: Freeze PR #12 after its one complete independent integrated evaluation, the narrowly routed PR #18 destructive-authority correction, one complete independent evaluation of that changed safety boundary, targeted verification by the original PR #12 evaluator, and one green exact-head macOS validation. The commit containing this entry is documentation-only and requires one final exact-head macOS run; it does not reopen code evaluation. Do not perform another complete review unless E09/E14 is triggered by a changed safety boundary, invalidated evidence, a listed regression, a reproduced guard bypass, or new P0/P1 evidence.
- Reason and evidence: The original complete evaluator found one P1 at `3e29a6b9ba9eaaa5755dec905e9f01d13358625d`: directory trash could move an unplanned late descendant. PR #18 corrected that boundary and its independent evaluator reported PASS WITH P2 RESIDUALS at `beef6ffdd769f334a28c1a5f1e7a33952ff86b6c`. After integration, the original PR #12 evaluator reported VERIFIED with no P0–P3 finding and proved the six corrected production/test blobs byte-identical through `08140e64befbc2edff60eaac62606c80abe5c5d3`. Exact-head macOS CI [run 31579634644](https://github.com/alexfilipe/aetherloom/actions/runs/31579634644) passed 329 tests in 8 suites with zero unexpected failures, nine known issues, and one opt-in Foundation Models skip. User macOS smoke also verified provider toggles, fail-closed unavailability, conflict preservation without `runAlreadyExists`, and the 30-item mass-deletion safety hold.
- What was completed: The full PR #12 local-provider safety stack; owned local I/O and deadline/recovery contracts; strong selective version evidence without scan-time whole-tree hashing; recoverable trash receipts; physical-root identity; real local-provider acceptance coverage; directory-trash deepest-first scheduling and empty-directory admission; static diff/permanent-delete audits; exact-head macOS validation; and bounded independent evaluation. Twelve currently unresolved review threads are addressed by reachable code/tests and are proposed for resolution without changing them here.
- What was explicitly deferred: The two duplicate unresolved conflict-preservation idempotence threads remain open under CUT-017 until the exact repeated prepare/execute scenario deterministically reproduces duplicate records, paths, mutations, journal events, or stored conflicts. Also deferred are exhaustive filesystem race permutations, unrelated cleanup/refactors, real cloud-provider work, and thread replies/resolution or PR readiness/merge changes without explicit authority.
- Residual risk/severity: P2. Foundation provides no atomic move-only-if-empty primitive, leaving a minimal external-creation window after the final directory emptiness proof and before recoverable movement. Conflict-preservation rerun idempotence remains unmeasured end to end but has no current deterministic failure. Crash recovery may still require manual intervention after ambiguous native-trash outcomes, and root identity probing can delay progress; both fail closed rather than authorize destructive work.
- Exact revisit trigger or acceptance condition: Accept the freeze when the final documentation-only head is clean and equal across local/upstream/origin/PR state, one macOS CI run at that exact head passes the full suite, PR #12 remains CLEAN/MERGEABLE against the exact base, and no new P0/P1 evidence appears. Reopen only for a reproduced unplanned descendant move, permanent deletion, silent overwrite, deletion inferred from incomplete/unavailable truth, recovery ambiguity that authorizes mutation, a listed regression, invalidated exact-head CI, changed base, deterministic conflict-idempotence failure under CUT-017, or another evidenced P0/P1 defect.
- Status: accepted
- Resolving PR/SHA: PR #12; final documentation-only freeze commit and exact-head CI pending.

## CUT-022 — Evaluation-loop framework refinement finish line

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): evaluation-loop documentation on branch `claude/orchestration-framework-review-07538f`; base `main` at `1f1b9e1202252f8c7b9c367b5c69e5aa383c0fcf`; final publication SHA pending.
- Decision/cutoff: Refine the framework from a full documentation review without changing its structure or defaults: align cutoff E14's reopen triggers with the framework's "newly evidenced P0/P1" rule, name where Define artifacts are recorded, default severity disagreements to the higher class until resolved at a gate, add a `reopened` status to the durable-entry template, and link the framework and the two documented tracks it governs from the root README's layout and AI-first sections. Documentation-only, low risk: writer self-evaluation plus link checks; no subagents, no independent evaluation, no test run.
- Reason and evidence: E14 as introduced enumerated only data loss, ambiguous destructive authority, scenario regression, and invalidated evidence, so a newly evidenced P1 concurrency/persistence defect would not have reopened a frozen PR despite the P1 class table requiring a block; the remaining gaps were unlinked or drift-prone cross-references found by inspecting every path the framework documents.
- What was completed: The E14 alignment, Define-artifact locations, severity-disagreement default, `reopened` status, root-README and architecture-index cross-references, CUT-numbering guidance, and the CUT-009 collision re-designation below.
- What was explicitly deferred: The `AGENTS.md`/`CLAUDE.md` mirror-drift guard, routed per user direction to PR [#19](https://github.com/alexfilipe/aetherloom/pull/19), which verifies parity with a pre-commit hook rather than a symlink so the check can be deleted when the two documents must diverge; runtime enforcement tooling for this framework; and any restructuring of the framework's sections.
- Residual risk/severity: P3; procedural documentation refinement with no behavior change.
- Exact revisit trigger or acceptance condition: Revisit if a recorded reopen shows the E14 wording still excludes a blocking finding class.
- Status: proposed
- Resolving PR/SHA: Pending publication of this documentation change.

## ID-collision metadata appended 2026-08-12

- CUT-009: The number was claimed twice on parallel branches: “Promote the cutoff log through PR #12” (first merged) and “Evaluation-loop framework finish line”. The first-merged promotion entry keeps CUT-009. The evaluation-loop framework finish-line entry is re-designated CUT-023 and should be cited as CUT-023 from now on; its recorded content is unchanged. Future entries claim the next number from the default branch's log at publication time per `architecture/orchestration/cutoffs/README.md`.
