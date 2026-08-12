# L2 — Arbitrary-Folder Package and Metadata Safety

## Objective and dependency

Implement [the accepted local fidelity boundary](../local/01-package-and-metadata-safety.md) before the app can point the provider at arbitrary user folders. Begin only after the user confirms L1 merged and the orchestrator verifies the merged default-branch SHA. This is a high-risk standalone PR.

## Exact scope

- Add typed positive scan exclusions to the core snapshot/domain surface and carry them through reconciliation, planning, preview, activity, and recovery without treating them as absence.
- Make `LocalFolderStorageProvider` detect package roots/subtrees with `isPackageKey`; unsupported xattrs, Finder tags/FinderInfo, and nonempty resource forks; non-baseline permissions/special bits; ACLs; and non-baseline ownership.
- Support only regular files at exactly `0644` and directories at exactly `0755`, owned by the effective user and primary group. Create and verify targets at those baselines; exclude every other profile.
- Add one all-location live-access classification preflight after confirmation and before the schedule's first mutation. Prevent descent into excluded directories and retain mutation-adjacent and recovery checks as defense in depth.
- Add core/local tests only in test-created temporary directories. Do not add bridge/app persistence or folder-picker work.

Do not implement metadata copying, package transfer, approval overrides, OAuth/cloud/NAS qualification, FSEvents, or background work. If the accepted policy cannot be implemented without weakening it, stop and route a new standalone architecture PR; do not edit normative architecture in L2.

## Acceptance and focused tests

L2 solely owns [LW-15 and LW-16](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario). Named focused tests MUST cover package-root rejection; package-subtree no descent; ordinary baseline files/directories accepted and created with exact `0644`/`0755` modes; every metadata reason; non-baseline file/directory modes; executable and special bits; ACLs; non-baseline user/group ownership; directory-subtree blocking; probe ambiguity making the scan incomplete/refused; previously tracked ordinary content becoming excluded; no base/convergence/success language; preview/activity path and reason; mutation-adjacent checks; and recovery classification.

The proving preflight regression MUST prepare and confirm a multi-location schedule, make the **last participating location** acquire an exclusion before execution, and assert through every provider call log and filesystem that the all-location preflight aborts before the first mutation everywhere. Equivalent ambiguity/unavailability variants MUST also prove zero mutations and fresh-prepare requirement.

Run the provider conformance and local-provider suites, then the full Swift suite. Static audits MUST show package/metadata reasons are typed, no permanent-delete path was introduced, and no exclusion is filtered before planning. The exact frozen/pushed head requires automated macOS validation when available and user-Mac tests using disposable folders containing a package, tag/xattr/FinderInfo fixture, and resource fork.

## Finish and stop

Apply the shared [validation ladder](local-workspace-mvp.md#validation-ladder-for-l2l5). The durable orchestrator's [LW-20](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario) evidence gate blocks L2. Finish only when LW-15/LW-16 pass, full validation is green, no P0/P1 remains, and P2 risks have triggers. Freeze, record the cutoff/evidence, stop for exact-SHA user validation, then stop for the user merge. Do not start L3.
