# L3 — Durable Workspace Persistence

## Objective and dependency

Implement the durable boundary in [workspace contract §5](../01-workspace-engine-session.md#5-durable-workspace-boundary-and-layout). Begin only after the user confirms L2 merged and the merged default-branch SHA is verified. This is a high-risk standalone PR.

## Exact scope

- Add file-backed core conflict, advice-cache, and location stores; retain the existing base-record, journal, and activity stores.
- Add a versioned bridge-owned manifest/store for sync sets, pause, first/last-run markers and digests, location/access/store references, and recovery references.
- Add separate `FolderAccessRecord` persistence for opaque capability bytes and persistent owned `stage/` and `quarantine/` directories under an injected workspace root.
- Implement atomic sibling-temp/flush/rename writes, schema checks, corrupt-byte preservation/quarantine, artifact discovery, and fail-closed consistency validation.
- Keep Application Support path selection out of core/bridge logic; tests inject only owned temporary roots.

Do not construct real providers, implement the production session, add AppKit/bookmark resolution, select folders, or migrate/repair corrupt workspaces. Manifest deletion/cleanup must never touch provider contents.

## Acceptance and focused tests

L3 solely owns [LW-09](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario). Supporting cases MUST prove every store and manifest round-trips; old-or-new atomicity under injected failures at write/flush/rename boundaries; unsupported/unreadable/partial generations fail closed; missing manifest plus any recognized artifact fails closed; truly absent workspace is fresh; missing referenced location/access data fails closed; corrupt bytes are retained; sync-set metadata deletion has no provider surface; and orphan metadata remains safe.

Capability secrecy tests MUST scan encoded manifest, `SyncLocation`, activity, diagnostics, and exported values for a canary bookmark byte/string and find none outside the referenced file under `folder-access/`. Stage-pin tests MUST prove receipt-bound artifacts survive reconstruction and remain until journal reconciliation. Run focused store/manifest tests, the complete Swift suite, static Application Support/capability-secrecy audits, and exact-head macOS/user validation.

## Finish and stop

Apply the shared [validation ladder](local-workspace-mvp.md#validation-ladder-for-l2l5). The durable orchestrator's [LW-20](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario) evidence gate blocks L3. Finish only when LW-09 and supporting persistence cases pass, no P0/P1 remains, and exact-head evidence is accepted. Freeze and stop for the user merge. Do not start L4.
