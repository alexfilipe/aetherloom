# Cutoff decisions

This is the working log of deliberate scope decisions: what is still in flight, what was deliberately left undone, and exactly what would reopen it. It is meant to be read in full by any agent starting work, so it is kept short.

Closed decisions are removed once their open residue has been carried forward, so this file alone tells you what is still owed. Nothing is lost: git holds every entry verbatim, and the closed index below names, for each batch of retired entries, the commit whose copy of this file still contains them in full.

The policy governing this log, the default cutoff catalog, and the entry format are in [`README.md`](README.md).

## Active decisions

Full entries for decisions whose feature or pull request is still in flight. Append new ones here in the format from [`README.md`](README.md).

### CUT-025 — PR #26 Local Workspace architecture finish line

- Date: 2026-08-12
- PR/layer and exact relevant SHA(s): L1 standalone architecture PR #26; base `15baf5c7a0899e9c8b901c67315f4f0a5d86a0c5`; final head pending.
- Decision/cutoff: L1 finishes after docs/link/diff checks, one complete independent architecture evaluation against the frozen base/head, at most one coherent correction batch, targeted recheck by the original evaluator, and exact-head documentation validation. No Swift/Xcode result is required or claimed for this docs-only Linux-host change. Freeze, publish as a draft PR, and stop for the user merge when no P0/P1 remains. L2 may begin only after the user confirms L1 merged; L3–L6 follow the same user-confirmed serial merge order recorded in the work stack.
- Reason and evidence: The Local Workspace MVP changes data-access, persistence, recovery, identity, and destructive-authority boundaries. A complete standalone contract and one bounded independent evaluation are required before implementation, while repeated unbounded review would not add authority.
- What was completed: Pending: normative `WorkspaceEngineSession`, folder-access, package/metadata, overlap, persistence/recovery contracts; factual status reconciliation; and L2–L6 work orders with single-owner acceptance mapping.
- What was explicitly deferred: All implementation; OAuth/cloud providers; background/scheduled sync; whole-drive/NAS qualification; migration UI; SQLite; App Store distribution; and full metadata/package preservation.
- Residual risk/severity: P2 may be accepted only for a documentation ambiguity or untested implementation permutation with no demonstrated safety-contract gap, and only with an exact implementation-layer revisit trigger. Any missing or contradictory destructive-authority, corrupt-state, capability-secrecy, exclusion, or recovery rule is P1 and blocks L1.
- Exact revisit trigger or acceptance condition: Accept L1 only when the frozen diff has one disposition for every required contract and acceptance scenario, internal links/diff scope are clean, the evaluator reports no P0/P1, and exact-head docs validation is recorded. Reopen for new P0/P1 evidence, a contradictory/missing listed contract, invalidated exact-head evidence, or a changed base. After merge, implementation discovering a material contract change triggers a new standalone architecture PR and pauses the affected layer.
- Status: proposed
- Resolving PR/SHA: PR #26 / pending frozen head and user merge.

## Progress metadata appended 2026-08-12

- CUT-025: The first published candidate was `19550973c75ab68aa61839f101085df20028f5fc` on base `15baf5c7a0899e9c8b901c67315f4f0a5d86a0c5`; exact-head CI run 109 succeeded. Its independent complete evaluation returned **CHANGES REQUIRED** with four P1 and three P2 findings. One coherent correction batch was authorized to close all seven.
- CUT-025 handoff ordering: Repository publication rules govern the remaining correction loop: repeat applicable static/focused/full/audit checks, freeze the corrected candidate, push/publish it, and prove local/upstream/origin/GitHub PR base/head equality before the original evaluator's targeted recheck (or any required fresh evaluation). The correction invalidates evaluation and later exact-head evidence for `19550973c75ab68aa61839f101085df20028f5fc`. Exact-head CI/macOS/user gates follow the evaluator disposition.
- CUT-025 corrected-head provenance: The correction commit cannot contain its own SHA. Its exact SHA and local/upstream/origin/GitHub equality MUST therefore be recorded in the post-publication handoff evidence before evaluator recheck. The resolving user-merge SHA remains pending; CUT-025 stays active.

## Progress metadata appended 2026-08-13

- CUT-025: Fresh complete evaluation of published head `dcaffce4c2491a4b6aeca5b8d89d49b4192e8469` found one P1 and two P2 findings. On 2026-08-13 the user explicitly authorized one narrow second correction batch, targeted recheck by that fresh evaluator, one third/final complete independent evaluation, and replacement exact-head CI/freeze.
- CUT-025 budget boundary: No further correction or review extension is authorized. Any P0/P1 remaining after this batch blocks L1 and MUST return to the user. This correction changes the head, so publication and local/upstream/origin/GitHub PR base/head equality MUST be repeated before either authorized review. CUT-025 remains active pending the replacement evidence and user merge.

## Reopen metadata appended 2026-08-13

- CUT-025: At exact PR head `5d104910f207e7fb838f9df0c70608017d072771`, eight actionable inline threads were confirmed unresolved and not outdated. The user explicitly reopened and authorized one bounded L1 `architecture/**/*.md` correction covering those eight threads; this authority supersedes the preceding no-further-correction boundary only for that enumerated batch. The writer stops after a local commit without publication or thread mutation.
- CUT-025 changed-boundary evaluation: The correction adds an explicit one-shot reviewed-mass-deletion safety boundary and changes LW-05, so E09 requires a fresh complete independent evaluation of the corrected published head. Before that evaluation, the orchestrator MUST publish, prove local/upstream/origin/GitHub PR base/head equality, and repeat exact-head documentation validation. The correction writer is not its evaluator. Any remaining P0/P1 returns to the user; no unenumerated correction is authorized here.
- CUT-025 accepted permission-baseline consequence: L1 deliberately retains exact `0644`/`0755` plus effective uid/gid support, accepting as P2 that ordinary umask, executable, private, foreign-owned, or subtree-covered content may be excluded in the MVP. Reopen only if L2 realistic-volume qualification shows representative intended roots are impractical, exclusion evidence misses its performance/inspectability budget, or a separately proven round-trip/normalization policy can broaden support without weakening ownership, recovery, or no-false-deletion guarantees.

## Freeze metadata appended 2026-08-13

- CUT-025 corrected-head evidence: PR #26 published base `15baf5c7a0899e9c8b901c67315f4f0a5d86a0c5` and corrected head `cf6d709f06f59812a2b5ee9c6c685312a0f90af4`; local branch, upstream, origin-tracking ref, and GitHub PR head were equal. Exact-head CI run `31753012907` (`AetherloomCore tests`) passed. The required fresh independent complete evaluation returned **PASS WITH P2 RESIDUALS**: P0 0, P1 0, P2 2, P3 0; all eight review-comment corrections were satisfied, the full architecture diff and links were checked, and no destructive-authority or false-deletion gap remained.
- CUT-025 accepted historical-work-order residual: The stale `architecture/core/agents/` dispatch surface remains P2 because `architecture/core/11-migration.md` is historical and the Local Workspace L1–L6 map is authoritative, so it cannot currently route implementation or weaken a guard. Do not dispatch or reactivate a historical core work order. Reopen before any such reactivation; first mark the index/tasks historical and non-dispatchable, reconcile the three-versus-four behavior-change wording, and keep the mass-deletion review boundary owned by L4.
- CUT-025 accepted confirmation-constructor residual: The non-optional `makeConfirmation` signature cannot represent its documented already-expired execution-authority ceiling, but bridge/core expiry and live-reservation checks remain fail-closed with zero executor authority. This is P2 and does not block L1. Before creating the L4 writer task or branch, route and user-merge a standalone architecture-only correction that makes the helper optional or throwing with a typed expired-authority result and assigns a focused zero-confirmation/zero-executor test. If that correction is not merged, L4 is blocked.
- CUT-025 freeze: The L1 merge gate is accepted at the next published head containing only this durable freeze metadata, subject to targeted evaluator verification of this append, replacement exact-head CI/static validation, and unchanged base/head equality. Any other head change, base change, P0/P1 evidence, listed-scenario contradiction, or invalidated validation reopens the gate. The user remains the sole merger; L2 remains blocked until the user confirms L1 merged and main is reverified.

### CUT-026 — L2 package and metadata safety finish line

- Date: 2026-08-14
- PR/layer and exact relevant SHA(s): L2 standalone implementation on branch `codex/local-workspace-package-metadata-safety`; exact base `0047ba7d918c9a447e4dc5b0d7b0af6cbc765da5` (merged PR #26 and frozen `origin/main` at dispatch); final head and draft PR pending.
- Decision/cutoff: L2 finishes only when LW-15/LW-16 pass for typed positive item/subtree exclusions, complete-scan accounting, shared component-aware normalized/case/diacritic-folded ancestry, cross-layer waiting/non-mutation propagation, package-ancestry enrollment validation, fail-closed local package/metadata/mode/ACL/ownership classification, exact created-target baselines, all-location preflight, mutation-adjacent and recovery checks, and exact inspectable root evidence with display-only grouping. Apply the validation ladder through focused provider/reconciliation/planning/execution/recovery and conformance/local suites, the full Swift suite, source/layering/forbidden-symbol/diff/secrecy audits, one complete independent evaluation, at most one coherent correction batch with targeted recheck, and one exact-head CI/macOS result plus exact-SHA user-Mac evidence before the merge gate.
- Reason and evidence: L2 changes provider truth, absence/deletion inference, filesystem fidelity, mutation admission, base-record convergence, and recovery authority. A package or unsupported metadata profile must remain positive presence everywhere; ambiguity, last-location drift, or unavailable truth must abort before every provider mutation.
- What was completed: Pending implementation and evidence for LW-15/LW-16, including package-root/interior enrollment refusal, no-descent scans, every metadata/permission/ACL/ownership reason, descendant BaseRecords, Unicode/case/component boundaries, last-location preflight zero-mutation, ambiguity/unavailability, exact target modes/ownership, and disposable realistic Documents/Projects qualification measurements.
- What was explicitly deferred: L3 bridge/app persistence; folder picker/bookmarks; OAuth/cloud/NAS qualification; FSEvents/background sync; metadata copying or normalization beyond establishing the accepted target baseline; package transfer; confirmation override; whole-drive support; and every permanent-delete path.
- Residual risk/severity: P2 may be accepted only for an untested macOS filesystem permutation or bounded performance hardening with no demonstrated exclusion, preflight, recovery, ownership, or no-false-deletion bypass. Representative-root impracticality, uninspectable/unbounded exclusion evidence, ambiguous destructive authority, a listed scenario failure, or any exclusion producing absence/deletion/base convergence is P1 and blocks L2.
- Exact revisit trigger or acceptance condition: Freeze only after exact local/upstream/origin/GitHub base/head equality, one complete independent evaluation with no P0/P1, green exact-head automated macOS CI, recorded realistic-volume counts/timing, and the orchestrator's exact-SHA user-Mac package/xattr/FinderInfo/tag/resource-fork/permission/ownership result. Reopen for a changed base/head, invalidated CI or user evidence, a reproduced raw-prefix/component-boundary error, silent scan omission, exclusion-derived mutation/convergence/success presentation, package/metadata drift admitted after confirmation, or new P0/P1 evidence. The user alone may mark ready or merge; no agent may change the base, resolve threads, enable auto-merge, merge, or begin L3.
- Status: proposed
- Resolving PR/SHA: pending.

## Resolution metadata appended 2026-08-14

- CUT-026 independent evaluation: Published head `2883e48403b95082b8d5f25cda57d39f0c4f1251` received **CHANGES REQUIRED** with P0 0, P1 0, P2 4, and P3 2. One coherent correction batch is accepted for the six findings; final corrected head remains pending publication.
- CUT-026 correction scope: Correct false permission evidence for symlinks, require subtree classification for `makeFolder`, prevent an opaque excluded subtree from authorizing deletion of a missing tracked record, bound stale-preparation invalidation without re-admitting an old preparation, and normalize the package-ancestry volume boundary with focused system-volume coverage.
- CUT-026 changed-boundary evaluation: The opaque-subtree correction adds a conservative no-deletion safety boundary beyond the evaluated implementation. Under E09, the corrected published head requires a second fresh complete independent evaluation rather than only targeted verification. The evaluation ceiling is then reached; any third complete evaluation requires explicit user approval plus new P0/P1 evidence.
- CUT-026 accepted measurement residual: The automated disposable Documents/Projects qualification proves accounting, exact evidence, grouping, and bounded model/enumeration behavior with a scripted metadata inspector; it does not measure real per-item metadata-probe syscall cost. Exact-SHA user-Mac validation is the sole merge-gate proof of representative real-world scan cost. This P2 reopens if that user-Mac scan exceeds the performance/UI budget or cannot retain bounded exact evidence.
- CUT-026 correction state: Reopened for the accepted correction batch. After publication, require focused/static/full validation, exact local/upstream/origin/GitHub base/head equality, one green exact-head macOS CI run, the second complete evaluation with no P0/P1, and exact-SHA user-Mac evidence. The user remains the sole merger; threads remain unresolved unless the user explicitly authorizes resolution.

## Re-correction metadata appended 2026-08-15

- CUT-026 N1 reopen evidence: Targeted verification of corrected head `27236b9753ee8d596c81b61b8553f4586c659985` found N1 (P1): the F2 correction treated every subtree exclusion at a location as evidence for every missing tracked record, silently suppressing unrelated delete-to-trash decisions while producing no row for the held record. This fires E14 and CUT-026's uninspectable-exclusion/listed-scenario triggers.
- CUT-026 authorized re-correction: The user authorized one narrow correction that distinguishes subtree roots positively present beside the persisted per-location base observation from newly opaque roots, preserves normal visible delete-to-trash for the former, and represents unresolved newly opaque relocation risk as an exact, non-approvable, non-mutating review hold only after ordinary observation/move matching. The paired regressions MUST prove ordinary unrelated deletion remains visible and executable through its existing review gate, while opaque relocation produces no deletion, mutation, base convergence, or success language.
- CUT-026 evaluation boundary: This re-correction does not authorize a third complete evaluation. After exact-head publication and macOS CI, the already-routed second complete independent evaluation covers N1 together with the corrected L2 candidate. Any remaining P0/P1 blocks and returns to the user; F4 remains the accepted P2 residual with its recorded user-Mac trigger. Final corrected head remains pending publication, and the user remains the sole merger.

## Architecture-revisit metadata appended 2026-08-15

- CUT-026 second-evaluation reopen evidence: The second complete evaluation of exact pair base `a71b19a67e67cec8510915e6fc7f5e8acc707624` / head `7f696a5a1d2d880147b3440fc454c1387cc3ae09` returned **NEEDS CORRECTION**, P0 0/P1 3/P2 1. P1 evidence showed (a) neither-regular/nor-directory/nor-symlink nodes could fall through as ordinary files into blocking hash/fetch, (b) the subtree-root digest was not a sound complete lifecycle baseline, and (c) even perfect stable-root equality could not prove that a missing item was not relocated into a long-standing opaque subtree. These findings fire E14's listed-scenario and ambiguous-destructive-authority triggers.
- CUT-026 user-authorized architecture correction: The user explicitly authorized one coherent architecture/implementation correction and a third complete evaluation after publication. Digest equality is removed as deletion authority and its unpublished model/plumbing/tests are removed without inventing migration work. After observation and move matching, every tracked record still missing at a complete location carrying one or more subtree exclusions receives a typed, exact, visible, deterministic, non-approvable opaque-relocation **Needs review** hold, regardless of whether roots are new, stable, removed/reappeared, case/Unicode-respelled, or unrelated. The hold blocks deletion and every other mutation, generic approval, base/recovery convergence, and completion/success language. A complete missing location with no subtree exclusion retains ordinary visible delete-to-trash review.
- CUT-026 special-kind boundary: Filesystem kind comes from the final component's `lstat` mode. Regular files, directories, and settings-excluded symlinks retain their defined behavior. FIFO, Unix socket, character device, block device, and every other known non-regular kind produce a typed item exclusion with exact kind evidence; indeterminate kind or `lstat` ambiguity makes scan/classification incomplete/ambiguous. Neither may become an ordinary observation or reach transfer/trash/relocate, blocking hash/fetch, or recovery mutation authority. macOS regressions use real FIFO/socket nodes; privileged device creation is not required.
- CUT-026 accepted opaque-evidence liveness limitation: A genuine deletion is intentionally held when the same missing-location snapshot contains even a long-standing unrelated opaque subtree. This P2 usability/liveness cost is explicitly user-accepted because relocation/absence cannot be proved. Reopen before enabling approval/execution of any deletion that coexists with opaque subtree evidence; when authoritative relocation/absence proof becomes available; or when an explicit architecture-approved user-decision mechanism is designed. Existing deletion approval and confirmation never override the hold; confirmation override remains outside L2.
- CUT-026 correction/evaluation boundary: This is the sole authorized correction for the new P1 batch. Publication MUST preserve base/branch/PR identity and use a normal fast-forward push. The corrected exact head still requires one green exact-head macOS CI run, exact-SHA user-Mac validation (including the existing real metadata/performance boundary), exact local/upstream/origin/GitHub base/head equality, and the newly authorized third complete independent evaluation. Any remaining P0/P1 returns to the user. The user alone may mark ready or merge; agents may not change the PR base/state, resolve threads, enable auto-merge, or merge.

## External-review correction and follow-up routing appended 2026-08-15

- CUT-026 external-review reopen evidence: Independent review of exact pair base `a71b19a67e67cec8510915e6fc7f5e8acc707624` / head `48ec6e7ae606485458a53f71c8a5b9dc9af9ab51` found P0 0/P1 1/P2 3. The remaining P1 reproduced a common whole-run deadlock: one opaque root plus one genuine deletion made the non-approvable item hold block unrelated edits, creates, and moves indefinitely. Held-run success wording, pathname identity binding, and sampling time in semantic fingerprints were classified P2.
- CUT-026 user-authorized safe-subset correction: The opaque-relocation decision remains non-approvable, non-mutating, and non-converging. A non-empty existing schedule may execute only when a pure proof establishes exact one-owner operation mapping, exact decision/schedule references, zero operations for held decisions, no dependency crossing held ownership, participating-location membership for every operation touch, and component-aware source/destination disjointness from each held path at every participating location and each exact opaque root at its evidence location. Duplicate evidence, any ownership/dependency/membership/path ambiguity, an empty subset, or another global non-approvable hold blocks executor and WAL construction. Other approvable holds retain exact full-plan approval bindings. Partial activity states that independent changes were applied while items remain paused; held-only/refused execution never says “Sync finished.”
- CUT-026 identity-bound local I/O deferral: Route P2 to a standalone follow-up named **Local identity-bound I/O and mutation** before L4 engine-session enrollment or L5 real-app integration. Current L2 fails closed for stable special nodes; a pathname replacement after classification can still cause a hang/refusal or act on a replacement node. Strong-evidence staging and post-fetch byte/hash checks bound destination corruption, while the weak-evidence stage key at `ContentStage.swift:294-295` does not prove pathname identity. The follow-up finish line is descriptor-first open with `O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`, descriptor `fstat` regular-kind and device/inode/generation binding, descriptor-based reads, and identity-bound mutation commit/revalidation with focused swap/FIFO/socket tests and one complete safety evaluation. Reclassify to P1 and reopen L2 immediately if a reproduced swap bypasses mutation/base/preflight protection, or if weak evidence skips required verification and can corrupt a destination.
- CUT-026 semantic-fingerprint timestamp deferral: Route P2 to a focused follow-up named **Remove sampling timestamps from semantic plan fingerprints**. Remove `scannedAt` and every sampling/display timestamp from the semantic projection while preserving semantic observation/exclusion truth and deterministic ordering. Complete it before any approval reuse/persistence or L4 confirmation flow depends on cross-prepare fingerprint equality. Reopen earlier if two identical truth snapshots with different sampling times fail an L2-required approval or safety-reproduction scenario.
- CUT-026 validation boundary: Safe-subset execution adds a new mutation-admission boundary after the prior third evaluation. The corrected published head requires focused/static/full validation, one green exact-head macOS CI run, a fresh complete independent evaluation authorized under the project's exceptional-review gate, exact local/upstream/origin/GitHub base/head equality, and exact-SHA user-Mac validation. Any remaining P0/P1 blocks; the user remains the sole merger and review threads remain unresolved without explicit authority.

## Carried backlog

Open deferrals and accepted residual risks from closed decisions. Each is still live: treat the trigger as the condition that turns it into work. The named entry holds the full reasoning and evidence; retrieve it with its batch's command in the closed index below.

| Source | What remains | Severity | Revisit trigger |
| --- | --- | --- | --- |
| CUT-001 | Root-identity guards have centralized enforcement plus representative regressions, not an independent boundary matrix injecting identity swaps at every fetch, store, native-trash, and quarantine call site. | P2 | A centralized guard is bypassed at one of those call sites, a root-identity regression appears, or a dedicated boundary-matrix PR is scheduled. |
| CUT-007 | Trash receipts persisted before strong evidence still carry weak artifact comparison. Legacy recovery stays fail-closed; migration to strong digests is not done. | P2 | A safe one-time migration can hash the proven artifact under an owned recovery claim, or legacy recovery evidence is shown ambiguous. |
| CUT-017, CUT-021 | Conflict-preservation idempotence is unmeasured end to end: no harness compares identity, paths, mutations, journal events, and stored conflicts across two runs. Two PR #12 review threads remain open on it. | P2 | A deterministic reproduction on a frozen SHA shows duplicate conflict records, new preservation paths, repeated filesystem mutations, `runAlreadyExists` after the clean close-and-resync flow, or loss or overwrite of preserved content. |
| CUT-018, CUT-020, CUT-021 | Foundation exposes no atomic move-only-if-empty primitive, so a minimal window remains between the final owned emptiness proof and the recoverable directory move. Fails closed; no demonstrated bypass. | P2 | A late descendant is reproduced crossing that window, or a platform-specific atomic primitive can close it without weakening recoverability, root identity, receipts, leases, deadlines, or strong file evidence. |
| CUT-021 | Crash recovery may still need manual intervention after an ambiguous native-trash outcome, and root-identity probing can delay progress. Both fail closed rather than authorize destructive work. | P2 | Recovery ambiguity is shown to authorize mutation rather than block it, or probing delay becomes a usability defect with a reproduction. |
| CUT-006 | Bounded incremental hashing was implemented but never performance-tuned. | P3 | Measured evidence shows bounded hashing needs tuning, and the tuning does not weaken owned leases. |
| CUT-022 | The pre-existing work-order and agent documents were never migrated to the consolidated structure. | P3 | A recorded reopen shows E14 still excludes a blocking finding class, a rule is found stated in two documents again, or a rule that existed before the refinement is found in neither. |
| CUT-023 | The evaluation-loop framework has no runtime enforcement tooling and no automation of task creation or locks; it depends on agents applying and recording its gates accurately. | P3 | A completed feature or PR demonstrates that a default cutoff either allowed a P0/P1 defect through or required redundant evaluation without producing new actionable evidence. |
| CUT-024 | Cutoff pruning has no enforcement tooling, and a future summary could drop or soften recorded residue. | P3 | Revisit if a future PR needs a deferral or trigger that survives only in git history, or if this file grows past roughly 150 lines again. |

## Standing constraints

Conditions from closed decisions that bind future work rather than waiting to be scheduled. Honour them; they do not need rescheduling or re-approval.

- **New content-displacing planner operations** must be classified for evidence strength before they can displace content, and must not reach execution on weak evidence (CUT-004).
- **New provider mutation primitives** must keep the strong precondition adjacent to the physical commit, and no weak observation may become a canonical base version (CUT-005).
- **Weak content-stage materializations** get unique, non-reusable keys; a shared weak key requires a run-scoped, cryptographically safe design first (CUT-006).
- **Providers with malformed or non-`sha256-` revision tokens** are weak by definition; they must refine or fail closed at every destructive-authority boundary (CUT-015).
- **Directory trash** executes deepest-first, after non-trash work, and a directory must be proved empty under owned mutation immediately before native trash or quarantine (CUT-018).

## Closed decisions index

One line per retired entry, so an ID cited in the backlog above can be placed without retrieving anything. Entries are grouped by the batch that retired them, and each batch names the commit whose copy of this file still holds those entries in full. A batch's commit is fixed at the moment it is retired and is never repointed, so an earlier batch stays reachable no matter how many prunings follow.

### Retired in `15baf5c` — CUT-024

```bash
git show 15baf5c:architecture/orchestration/cutoffs/DECISIONS.md
```

| ID | Decision | Outcome |
| --- | --- | --- |
| CUT-024 | Prune the cutoff log to a readable working set | Merged as PR #25; tooling/summary-integrity trigger carried forward. |

### Retired in `90a2342` — CUT-001 through CUT-023

```bash
git show 90a2342:architecture/orchestration/cutoffs/DECISIONS.md
```

Their pull requests are merged; entries that still read `proposed` or named a pending head, publication, or CI run were completed as recorded. Expected-PR numbering resolved as: the strong-version-evidence work published as PR #17, and PR #16 carried the evaluation-loop framework documentation.

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
