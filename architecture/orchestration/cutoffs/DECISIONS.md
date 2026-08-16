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

### CUT-027 — Route PR #27 provenance overrestriction through architecture

- Date: 2026-08-16
- PR/layer and exact relevant SHA(s): standalone docs-only architecture correction on branch `codex/provenance-metadata-architecture`, base `360e1c24be4cea3982dacdc879583c6fc8a682c2`, expected draft PR #30 and final head pending; paused L2 PR #27 failed at exact head `735d93022ca50e66c606d3d5e6daa18ba70684dc`.
- Decision/cutoff: Keep unsupported-xattr exclusion as the default, but ignore exact, case-sensitive raw `com.apple.provenance` only when the running OS's `xattr_preserve_for_intent(name, XATTR_OPERATION_INTENT_SYNC)` returns `0`. No payload schema or preservation semantics are accepted; the value never enters synchronized truth, operations, logs, fingerprints, mutation authority, or recovery authority. Every other name and every unavailable, erroneous, ambiguous, or preserve result fails closed. PR #27 remains paused and unmodified until this standalone architecture PR passes documentation/link/diff validation, one complete independent architecture evaluation with no P0/P1, exact-head static validation, and the user merge gate.
- Reason and evidence: PR #27 exact-head user-Mac L2 validation used `/tmp/aetherloom-pr27-fixture.0U9g39` and `/tmp/aetherloom-pr27-real-metadata.log`. The real-provider scan completed in `0.0024999380111694336` seconds with zero observations and two subtree exclusions, `/Documents` and `/Projects`, both `.unsupportedMetadata(.extendedAttributes)`. User inspection found only raw name `com.apple.provenance` on each directory, with an opaque 11-byte value not intentionally created by the fixture. The provider followed the accepted policy safely, and no data-loss bypass was observed, but representative intended roots became wholly opaque. This fires CUT-025/CUT-026's realistic-root practicality trigger. The defect is P2 safety-first overrestriction/liveness/usability, but the named acceptance/reopen trigger makes it merge-blocking.
- What was completed: This architecture correction defines the exact-name plus live Apple sync-intent boundary, payload non-authority, stable scan/convergence behavior, fail-closed reclassification at scan/preflight/mutation/recovery, L2 pure and integration regressions, and the repeat exact-head real-macOS probe contract.
- What was explicitly deferred: All implementation and tests; general xattr preservation/copying/removal; any interpretation or logging of `com.apple.provenance`; trust/origin transfer across locations; authoritative payload semantics; L3 and later Local Workspace work.
- Residual risk/severity: P2; Apple publishes the sync-intent API and default behavior but not this attribute's payload semantics, and a future OS may classify it differently. The live predicate and fail-closed fallback bound that uncertainty; this exception is compatibility policy, not a preservation claim.
- Exact revisit trigger or acceptance condition: After the user merges this docs PR, PR #27 MUST normally merge then-current `main` into its existing branch, implement the accepted rule without rebasing or changing PR identity/base, and repeat exact-head focused/full tests, CI, the app build, independent evaluation required by its active budget, and the full real metadata/performance Mac validation. The preserved Documents/Projects probe must produce more than zero observations and only intentionally unsupported fixture-root exclusions while recording OS/toolchain, live predicate result, exact counts, paths/reasons, and timing; preserve fixture/log evidence on failure. Reopen for any payload dependency/exposure, non-exact matching, predicate bypass or disagreement between scan/preflight/mutation/recovery, unsupported metadata becoming ordinary truth, or failed exact-head evidence. PR #27 and L3 remain blocked until these gates pass; the user remains the sole merger.
- Status: proposed
- Resolving PR/SHA: expected draft PR #30 / pending.

## Evaluation/correction metadata appended 2026-08-16

- CUT-027 independent evaluation: Exact published head `8118e3d0ad9f2a1ca157ba849b3fd858172d1813` received **NEEDS CORRECTION**, P0 0, P1 1, P2 1. The P1 found that classification and payload-non-authority prose did not operationally prevent copy-based staging, materialization, replacement, relocate fallback, or recovery from propagating source provenance metadata. The P2 found that the native C predicate was incorrectly described as capable of returning error or ambiguity even though it is a total integer classification.
- CUT-027 authorized correction: One coherent docs-only batch binds every cross-location/cross-filesystem copy and staging/materialization/recovery path to data-fork-only behavior, distinguishes same-object moves from materialization, leaves destination provenance OS-owned without blindly restoring old payloads, adds injected call/flag acceptance evidence, and defines a typed adapter where native `0` means ignore and every native nonzero means preserve. Binding unavailability/call failure are adapter outcomes; ambiguity exists only at the injected test seam. The original CUT-027 wording is superseded by this adapter clarification without rewriting the recorded entry.
- CUT-027 evidence invalidation and evaluation boundary: This correction changes the documented security/trust transfer boundary, so E09 requires a second fresh complete independent evaluation after publication. Prior exact-head equality, static evidence, CI run `31926567239`, and evaluation at `8118e3d0ad9f2a1ca157ba849b3fd858172d1813` do not validate the corrected head. Repeat documentation link/diff/scope/contradiction checks, local/upstream/origin/GitHub base/head equality, exact-head CI, and the fresh evaluation. Any remaining P0/P1 blocks. The user remains the sole merger; PR #27 and L3 remain paused and unmodified.

## Freeze metadata appended 2026-08-16

- CUT-027 corrected-head evidence: PR #30 remained a draft against base/current `main` `360e1c24be4cea3982dacdc879583c6fc8a682c2` at corrected published head `3c25fd7d4fbcf9dcaa74a16cecac7fa4a130bc30`. Exact-head CI run `31927295955`, job `95116740334`, succeeded. The required second fresh complete E09 evaluation returned **PASS WITH P2 RESIDUALS**, P0 0, P1 0, P2 1, P3 0: the first evaluation's P1 and P2 are closed and all 15 evaluated boundaries pass.
- CUT-027 accepted residual: P2; Apple publishes no authoritative `com.apple.provenance` payload semantics, and a future OS may classify the name differently. The live native zero/nonzero adapter plus fail-closed scan, preflight, mutation-adjacent, and recovery classification bounds that uncertainty. No additional work is required for this docs-only PR unless a recorded reopen trigger fires.
- CUT-027 freeze: Freeze at the next published head containing only this metadata append, subject to repeat documentation diff/scope/link checks, unchanged local/upstream/origin/GitHub base/head equality, replacement exact-head CI, and targeted verification of this append by the second evaluator. This is a docs-only Linux-host change: no local Swift/Xcode result is claimed, and PR #30 itself requires no user-Mac test. The user remains the sole merger; keep PR #30 draft and do not mark ready or merge. PR #27 and L3 remain paused until the user merges PR #30; PR #27 must then integrate current `main` normally and complete its full implementation, evaluation, CI/app-build, and real-fixture Mac gates.
- CUT-027 reopen triggers: Reopen for new P0/P1 evidence, a changed base or head, invalidated exact-head evidence, payload exposure or dependency, non-exact name matching, disagreement among scan/preflight/mutation/recovery classification, provenance or other unsupported metadata entering synchronized truth or authority, or a later failure of the preserved real Documents/Projects fixture. Otherwise stop at the user merge gate.

## Post-freeze review reopening appended 2026-08-16

- CUT-027 review result: A new complete review of frozen head `cd65cbba90de212f5c78a1ea88d0c4874cac9ac8` returned **CHANGES REQUIRED**, P0 0, P1 1, P2 1, P3 1. The P1 found that the exact live integer returned for raw name `com.apple.provenance` under `XATTR_OPERATION_INTENT_SYNC`, and the symbol's reachability from a Swift package through the intended adapter boundary, were inferred but never measured. The P2 found that a disposable `/tmp` fixture path was an unconditional forward `MUST`. The P3 found that injected test-seam ambiguity was optional in the normative policy but mandatory in acceptance.
- CUT-027 evidence invalidation: The freeze at `cd65cbba90de212f5c78a1ea88d0c4874cac9ac8`, its exact-head CI run `31927775949`, and its targeted append verification do not close the newly demonstrated P1. Keep PR #30 draft and PR #27/L3 paused. Do not publish a replacement freeze until an affected Mac records the OS build, exact raw name, native sync-intent integer, and successful Swift-package adapter reachability. If the integer is nonzero or the symbol is unreachable through a supportable adapter, reopen the architecture boundary instead of correcting or freezing this rule.
- CUT-027 authorized correction boundary: One narrow docs-only correction batch may require the adapter's test seam to model typed `.ambiguous`, make reuse of the preserved PR #27 fixture conditional with reproducible reconstruction when absent or unusable, and append the measured live predicate/reachability evidence if it proves native `0`. After publication, repeat exact local/upstream/origin/GitHub equality, documentation diff/scope/link checks, replacement exact-head CI, and targeted verification by the latest reviewer. No third complete evaluation is required unless the measurement forces an architecture-boundary change. The user remains the sole merger and alone may mark the PR ready.
- CUT-027 live predicate evidence: On the affected Mac, macOS `26.5.2` build `25F84`, Xcode `26.6` build `17F113`, Apple Swift `6.3.3` targeting `arm64-apple-macosx26.0`, a disposable SwiftPM executable imported a C target that included `<xattr_flags.h>`, compiled, linked, and invoked the system predicate. For exact raw name `com.apple.provenance` and `XATTR_OPERATION_INTENT_SYNC`, `xattr_preserve_for_intent` returned exact integer `0`. This proves both the rule's load-bearing live classification and symbol reachability through the intended Swift-package C-shim boundary on the affected OS. The probe source lived at `/var/folders/lx/8ptht2j14rbck792fblly3lm0000gn/T//aetherloom-pr30-predicate.VzBymX`; its captured log is `/tmp/aetherloom-pr30-provenance-predicate.log`. No attribute payload was read or exposed.

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
