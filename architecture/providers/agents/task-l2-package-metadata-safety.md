# L2 — Arbitrary-Folder Package and Metadata Safety

## Objective and dependency

Implement [the accepted local fidelity boundary](../local/01-package-and-metadata-safety.md) before the app can point the provider at arbitrary user folders. Begin only after the user confirms L1 merged and the orchestrator verifies the merged default-branch SHA. This is a high-risk standalone PR.

## Exact scope

- Add typed positive scan exclusions to the core snapshot/domain surface and carry them through reconciliation, planning, preview, activity, and recovery without treating them as absence.
- Make `LocalFolderStorageProvider` detect package roots/subtrees with `isPackageKey` and detect unsupported xattrs, Finder tags/FinderInfo, and nonempty resource forks.
- Prevent descent into excluded directories and re-check the exclusion boundary adjacent to local mutations and recovery truth.
- Add core/local tests only in test-created temporary directories. Do not add bridge/app persistence or folder-picker work.

Do not implement metadata copying, package transfer, approval overrides, OAuth/cloud/NAS qualification, FSEvents, or background work. If the accepted policy cannot be implemented without weakening it, stop and route a new standalone architecture PR; do not edit normative architecture in L2.

## Acceptance and focused tests

L2 solely owns [LW-15 and LW-16](local-workspace-mvp.md#acceptance-matrix--one-owner-per-scenario). Named focused tests MUST cover package-root rejection; package-subtree no descent; ordinary files/directories accepted; each metadata reason; directory-subtree blocking; probe failure making the scan incomplete; previously tracked ordinary item becoming excluded; all-side zero mutation; no base/convergence/success language; preview/activity path and reason; and pre-execution acquisition of unsupported state stopping for replan.

Run the provider conformance and local-provider suites, then the full Swift suite. Static audits MUST show package/metadata reasons are typed, no permanent-delete path was introduced, and no exclusion is filtered before planning. The exact frozen/pushed head requires automated macOS validation when available and user-Mac tests using disposable folders containing a package, tag/xattr/FinderInfo fixture, and resource fork.

## Finish and stop

Apply the shared [validation ladder](local-workspace-mvp.md#validation-ladder-for-l2l5). Finish only when LW-15/LW-16 pass, full validation is green, no P0/P1 remains, and P2 risks have triggers. Freeze, record the cutoff/evidence, stop for exact-SHA user validation, then stop for the user merge. Do not start L3.
