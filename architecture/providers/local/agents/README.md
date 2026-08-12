# Local-Provider Work Orders

Each `task-*.md` is a self-contained prompt for one implementation agent covering one milestone of the local/NAS backend. The track-wide dispatch graph, global rules, and reporting format live in [../../agents/README.md](../../agents/README.md) — **those rules are authoritative here too**; this README adds only what is local-specific.

## Current dispatch order

The conformance, read, mutation, recovery, and local end-to-end work described by the old task-00/task-01 prompts is implemented. Do not dispatch those prompts. Current local work begins at [L2 package/metadata safety](../../agents/task-l2-package-metadata-safety.md), inside the serial [Local Workspace MVP stack](../../agents/local-workspace-mvp.md). NAS hardening remains future and outside that stack.

## Local-specific rules

1. All provider sources go in `src/AetherloomCore/Sources/AetherloomCore/Providers/Local/`; tests in `Tests/AetherloomCoreTests/` beside the existing provider tests.
2. Every question about volume state goes through the `VolumeInspecting` seam ([../00-overview.md §1](../00-overview.md)) — a direct mount-state or reachability check outside the seam is a review-blocking defect, because it makes an unavailability reason untestable.
3. Temp-dir discipline is absolute: each test creates and removes its own root under the system temporary directory; nothing touches real user folders, real mounts, or `/Volumes`.
4. Capability declarations follow the table in [../00-overview.md §2](../00-overview.md) exactly; changing a value requires a spec change first, not a code-review argument.
5. The provider emits no user-facing strings; unavailability reasons carry technical `detail` text only.

## Task index

| Task | Milestone | Status |
| --- | --- | --- |
| [task-00-initial-local-sync.md](task-00-initial-local-sync.md) | M1–M3 + end-to-end proof | Completed; historical, do not dispatch |
| [task-01-read-side.md](task-01-read-side.md) | M2 read side | Completed; historical, do not dispatch |
| [../../agents/task-l2-package-metadata-safety.md](../../agents/task-l2-package-metadata-safety.md) | L2 arbitrary-folder safety | Current, only after L1 user merge |
| task-03-nas-hardening.md ⏭ | Future NAS qualification | Out of Local Workspace MVP scope |
