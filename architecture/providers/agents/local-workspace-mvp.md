# Local Workspace MVP — Ordered Work and Acceptance Ownership

This is the sole dispatch map for the Local Workspace MVP. The normative behavior is in [../01-workspace-engine-session.md](../01-workspace-engine-session.md) and [../local/01-package-and-metadata-safety.md](../local/01-package-and-metadata-safety.md); the task files define implementation scope and validation, not new architecture.

## Serial topology and authority

```text
L1 architecture (PR #26, docs only)
  user merges ─▶ L2 package/metadata safety
  user merges ─▶ L3 durable workspace persistence
  user merges ─▶ L4 WorkspaceEngineSession
  user merges ─▶ L5 real app integration
  user merges ─▶ L6 exact-head local-alpha qualification
```

L2–L5 are standalone implementation PRs against the then-current default branch. No later branch, writer, or PR may begin until the user confirms the prior PR merged and the orchestrator verifies the merged default-branch SHA. The user performs every merge. Agents MUST NOT stack dependent branches, change bases to bypass a gate, enable auto-merge, or assume merge readiness means merged.

Every implementation PR L2–L5 requires exact-head user validation on the user's Mac after the candidate is frozen and pushed. CI complements but does not replace that evidence. Any head change invalidates the evidence. L6 runs only against the exact integrated default-branch head after L5 is user-merged.

## Acceptance matrix — one owner per scenario

This table assigns each required acceptance scenario exactly once. Feature scenarios belong to L2–L5; LW-20 is the durable orchestrator's cross-PR evidence gate and blocks every implementation layer. Task documents cite IDs; they do not redefine or duplicate these rows.

| ID | Sole owner | Minimum proving scenario |
| --- | --- | --- |
| LW-01 | L5 | Production launch constructs the real session and presents an honest empty workspace; the demo world is not seeded. |
| LW-02 | L5 | Two user-selected temporary folders round-trip access and persisted physical identity into one sync set with zero content mutation. |
| LW-03 | L4 | Creating and updating a sync set changes metadata only and performs no provider read or mutation. |
| LW-04 | L4 | The first **Sync Now** prepares and exposes a real preview through the migrated AppModel/session protocol; neither Demo nor Workspace session can execute during prepare or bypass preview. |
| LW-05 | L4 | Gate/confirmation matrix proves: clear/no-count enables; clear/nonzero-trash requires acknowledgement; approvable hold requires exact acknowledgements; every ordinary hold containing `massDeletion` exposes evidence but constructs no confirmation, enables no execution, and makes zero executor calls. Exact threshold construction/decode/update clamps delete count/ratio to `1...25`/`0.01...0.25` and edit count/ratio to `1...50`/`0.01...0.50`; defaults are the maxima, and no persistent setting weakens them. The durable evidence latch survives relaunch and any allowed in-range increase and clears only after changed deletion evidence or successful reconciled reviewed execution. Pure gating consumes an injected latch and returns a transition; the orchestrator durably applies it before exposing preparation. **Review intentional deletions** issues a single-use expiring non-persistent authorization bound to the exact sync set, original unreviewed fingerprint, deletion-evidence digest/counts, and settings/world snapshots. A fresh full prepare must reproduce every binding; identical semantics with different generated IDs, scan/display timestamps, and enumeration order reproduce the unreviewed fingerprint, while semantic drift changes it. Exact match atomically exchanges the authorization for an opaque in-memory expiring one-shot execution reservation bound to the distinct reviewed fingerprint/run/preparation. Issuance, transition/rejection, and reservation consumption/expiry/rejection are durably recorded in safety activity/journal as digests only. The reviewed plan still requires normal unexpired exact-count confirmation, and core atomically consumes the matching live reservation before executor construction. Missing, expired, reused, relaunch-lost, or mismatched authorization/reservation yields no reviewed execution authority or mutation and zero executor calls. Executable cases validate fingerprint/time/expiry/exact counts and propagate file create, edit, folder create, and recoverable trash. |
| LW-06 | L4 | Relaunch reconstructs sync sets, locations, folder-access records/authority, pause, base records, conflicts/resolutions, advice, activity, digests, journals, durable mass-deletion safety latches, stage pins, and recovery state, while restoring no bearer review authorization, execution reservation, or reviewed preparation as authority. |
| LW-07 | L4 | A converged workspace relaunches and its next manual prepare is empty. |
| LW-08 | L4 | One parameterized refusal test covers all nine access/truth causes from the workspace contract: missing access data, denied scope, stale bookmark, removed root, unmounted volume, unreadable root, wrong persisted volume identity, wrong canonical/physical identity, and incomplete scan; each yields zero mutations and zero deletion inference. |
| LW-09 | L3 | Corrupt manifest bytes are preserved/quarantined and bootstrap fails closed instead of creating a fresh workspace. |
| LW-10 | L4 | Independent edits preserve both versions on disk and in durable conflict state. |
| LW-11 | L4 | Conflict resolution survives relaunch, mutates nothing when recorded, and affects only a newly prepared and explicitly confirmed run. |
| LW-12 | L4 | An interrupted run reconstructs unfinished recovery, uses current truth on the next manual prepare, and never replays the old schedule. |
| LW-13 | L4 | Deleting a sync set removes/updates owned metadata only; provider call logs and filesystem contents prove no scan or content mutation. |
| LW-14 | L4 | Overlap matrix rejects same root, canonical aliases, ancestor→descendant, and descendant→ancestor on the same volume before set creation; unproved disjointness fails closed. |
| LW-15 | L2 | Package root, a selected directory inside a package, and encountered package subtree; file and directory metadata/resource fork; exact `0644`/`0755` plus effective uid/gid baseline; ordinary umask/executable/private/foreign-owned exclusions; and non-baseline permission, special-bit, ACL, or ownership cases produce the accepted typed policy and exact durable path/reason. Realistic-volume qualification proves bounded one-root-per-exclusion evidence and inspectable display aggregation. |
| LW-16 | L2 | A previously tracked directory plus tracked descendants becomes subtree-excluded. Using component-aware normalized/case-folded `SyncPath` ancestry, the root and every covered descendant derive waiting/excluded at every location and produce zero absence facts, deletion decisions, deletion mutations, base updates, convergence, or success presentation anywhere. The exact exclusion-root evidence remains individually inspectable, with no fabricated descendant rows. |
| LW-17 | L4 | Pause state survives relaunch and blocks prepare until explicit resume. |
| LW-18 | L5 | The user performs the real-local-folder smoke script on the exact frozen and pushed SHA, including preview-before-mutation and recoverable trash. |
| LW-19 | L5 | The user verifies security-scoped folder access and provider availability survive app relaunch on that exact SHA; automated resolution uses `.withoutMounting` and `.withoutUI`, and bootstrap/prepare never mounts or wakes an unavailable network volume. |
| LW-20 | Durable orchestrator (L2–L5 gate) | For every L2–L5 PR, record branch, base SHA, frozen/pushed head SHA, local/upstream/origin/GitHub equality, CI/build results, user-Mac result, skips, and evidence locations; local-only or ambiguous evidence blocks that PR. |

L6 repeats the applicable integrated scenarios as release qualification; it does not create a second ownership assignment or weaken an earlier PR's gate.

## Validation ladder for L2–L5

Each task applies this ladder and stops at the first rung requiring changes:

1. static scope, forbidden-symbol, secrecy, and diff checks;
2. the task's focused regression tests;
3. `swift test --package-path src/AetherloomCore` on macOS;
4. for app/bridge integration where applicable, the configured `xcodebuild` build and targeted app tests;
5. source/layering/safety audits against the two normative contracts;
6. freeze the candidate, push/publish its draft PR, and prove local branch, upstream, origin, GitHub PR base, and GitHub PR head equality;
7. one independent complete-diff evaluation of that exact published base/head;
8. at most one coherent correction batch, followed by the correction rule below;
9. one authoritative exact-head automated CI/macOS validation when available;
10. provide the exact-SHA user-Mac validation handoff, stop for the result, record it, then stop for the user merge.

Any correction changes the head and invalidates evaluation, CI/macOS, and user evidence tied to the prior head. Re-run the applicable static/focused/full/audit rungs, freeze, push/publish, and prove local/upstream/origin/PR base/head equality **before** the original evaluator performs a targeted recheck or a fresh evaluation. A second fresh complete evaluation is required only when corrections add a safety boundary, change the accepted architecture/acceptance contract, substantially rewrite evaluated code, or cannot be checked narrowly. A third requires explicit user approval plus new P0/P1 evidence. P0/P1 findings, a listed-scenario failure, ambiguous destructive authority, or missing LW-20 exact-head/user evidence block. A P2 may be accepted only with a durable exact revisit trigger.

## Task index

| Layer | Work order | Changed boundary | Begins only after |
| --- | --- | --- | --- |
| L2 | [task-l2-package-metadata-safety.md](task-l2-package-metadata-safety.md) | Local scans/mutations gain typed package and metadata exclusions | User confirms L1 merged |
| L3 | [task-l3-workspace-persistence.md](task-l3-workspace-persistence.md) | Durable manifest, stores, access files, stage/quarantine layout | User confirms L2 merged |
| L4 | [task-l4-workspace-engine-session.md](task-l4-workspace-engine-session.md) | Production bridge/session over real providers and stores | User confirms L3 merged |
| L5 | [task-l5-real-app-integration.md](task-l5-real-app-integration.md) | Picker, bookmarks, entitlements, default real launch | User confirms L4 merged |
| L6 | [task-l6-local-alpha-qualification.md](task-l6-local-alpha-qualification.md) | Exact integrated-head qualification, no feature expansion | User confirms L5 merged |

## L1 documentation finish line

L1 changes only `architecture/**/*.md`. Run documentation link/diff checks, freeze the candidate, publish its draft PR, and prove local/upstream/origin/GitHub base/head equality before independent architecture evaluation. The active CUT-025 metadata records the explicitly authorized evaluation/correction budget and supersedes the default one-batch wording for this PR only. Every correction repeats applicable checks, freeze, publication/equality proof, and then the authorized evaluator sequence. Exact-head validation is documentation/static validation only: no Swift or Xcode claim is made, and the Linux host limitation is recorded plainly. When no P0/P1 architecture finding remains and any P2 has an exact trigger, freeze the evaluated published head and stop for the user to merge. Browser QA is skipped per project instructions.
