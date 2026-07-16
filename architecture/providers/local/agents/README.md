# Local-Provider Work Orders

Each `task-*.md` is a self-contained prompt for one implementation agent covering one milestone of the local/NAS backend. The track-wide dispatch graph, global rules, and reporting format live in [../../agents/README.md](../../agents/README.md) — **those rules are authoritative here too**; this README adds only what is local-specific.

## Dispatch order

```text
../../agents/task-01 (conformance suite) ─▶ 01 read side ─▶ 02 mutations ─▶ 03 NAS hardening ⏭
```

Strictly serial. Task 02 is blocked on [../01-mutations-and-trash.md](../README.md) ⏭ being written; task 03 on [../02-nas-hardening.md](../README.md) ⏭. Do not dispatch against a missing spec.

## Local-specific rules

1. All provider sources go in `src/AetherloomCore/Sources/AetherloomCore/Providers/Local/`; tests in `Tests/AetherloomCoreTests/` beside the existing provider tests.
2. Every question about volume state goes through the `VolumeInspecting` seam ([../00-overview.md §1](../00-overview.md)) — a direct mount-state or reachability check outside the seam is a review-blocking defect, because it makes an unavailability reason untestable.
3. Temp-dir discipline is absolute: each test creates and removes its own root under the system temporary directory; nothing touches real user folders, real mounts, or `/Volumes`.
4. Capability declarations follow the table in [../00-overview.md §2](../00-overview.md) exactly; changing a value requires a spec change first, not a code-review argument.
5. The provider emits no user-facing strings; unavailability reasons carry technical `detail` text only.

## Task index

| Task | Milestone | Status |
| --- | --- | --- |
| [task-01-read-side.md](task-01-read-side.md) | M2 — availability + scanning, zero mutations | Dispatchable after `../../agents/task-01` merges |
| task-02-mutations-and-trash.md ⏭ | M3 — atomic store, relocate, trash/quarantine, full conformance | Blocked on spec 01 ⏭ |
| task-03-nas-hardening.md ⏭ | M5 — timeouts, unreachable-mount fidelity, mtime tolerance | Blocked on spec 02 ⏭ |
