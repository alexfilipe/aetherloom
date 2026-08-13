# L6 — Exact-Head Local-Alpha Qualification

## Objective and dependency

Qualify, but do not expand, the integrated Local Workspace MVP. Begin only after the user confirms L5 merged and the orchestrator verifies the exact integrated default-branch SHA. L6 evaluates that SHA; it does not branch from an open PR or relabel earlier evidence.

## Exact scope

- Re-run the targeted local safety, persistence, bridge, startup, relaunch, recovery, package/metadata, realistic exclusion-volume, overlap, conflict, pause, one-shot reviewed-mass-deletion, latch, and deletion-to-trash suites against the exact integrated head.
- Run the complete Swift suite, configured app build, startup guardrail, and a user-performed disposable-folder local-alpha script.
- Produce a release-gate evidence record with exact SHA, commands, environments, results, artifacts, known skips, accepted P2 risks/triggers, and go/no-go decision.

No feature work, architecture change, cleanup, migration UI, cloud/NAS/whole-drive qualification, scheduling, or distribution work belongs here. A discovered defect is classified and routed to the narrowest new PR after its base is stable; an architecture change returns to a standalone docs PR.

## Qualification and stop conditions

The integrated run reuses the LW-01–LW-20 scenario definitions from [the sole acceptance matrix](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario); it does not duplicate their ownership. Evidence must show the exact merged head, all required automated results, and the user's exact-head app/relaunch/bookmark/real-folder result.

Stop and mark **no-go** for any P0/P1, listed-scenario regression, ambiguous mutation authority, corrupt-state freshness fallback, missing exact-head evidence, or user failure. Mark **local-alpha qualified** only when all gates pass and every P2 has an exact revisit trigger. Then freeze the evidence and stop for the user's release decision; agents do not publish or distribute the app without separate authority.
