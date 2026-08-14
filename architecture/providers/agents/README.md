# Provider Implementation Work Orders

Each task file is a self-contained implementation work order, while the linked architecture remains normative. The conformance/local-provider work is implemented and its old prompts are historical. [local-workspace-mvp.md](local-workspace-mvp.md) is now the sole cross-track dispatch graph and acceptance-ownership map for L1–L6.

## Dispatch order

```text
completed conformance/local provider ─▶ L1 docs ─▶ L2 ─▶ L3 ─▶ L4 ─▶ L5 ─▶ L6
```

L1–L6 are strictly serial at user-confirmed merge gates. Do not dispatch from the older M1–M3 prompts; their implementation is already in the repository. NAS and iCloud remain future work.

## Global rules (authoritative here; abbreviated in each prompt)

1. **Safety invariants** (`architecture/core/00-overview.md § Safety invariants`) **override everything**, including these prompts. The track-specific corollaries (`../00-overview.md §2`): failure never masquerades as emptiness; everything that can hang has a deadline; no permanent-delete call exists anywhere, including private helpers.
2. File boundaries are task-specific in the L2–L6 work orders. Implementation PRs may update only the factual UI status matrix and cutoff log under the narrow architecture exceptions; material contract changes require a standalone architecture PR.
3. Zero third-party dependencies; no network/ML/SQLite imports anywhere in this track.
4. Swift 6 strict concurrency: values `Codable + Hashable + Sendable`; mutable state in actors.
5. Existing engine sources are read-only unless a task explicitly names an exception; providers implement `StorageProvider` as it stands — protocol changes require stopping and reporting, not improvising.
6. **Filesystem test discipline** (`../00-overview.md §5`): every test runs under a temp root it creates and removes; unavailability via injected seams; no real mounts, no real user folders, no network; timeouts via injected deadlines, no real sleeps.
7. Capabilities are declared conservatively; a capability claimed without a conformance case proving it is a defect.
8. Engine-emitted user-facing strings use the canonical sentences from `architecture/core/00-overview.md § Canonical language` verbatim; providers themselves emit no user-facing prose.
9. Exit bar, every task: `swift test --package-path src/AetherloomCore` green, zero new warnings. Tasks touching the bridge also build the app: `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build`. Report test counts before/after.
10. Style: match existing sources — small focused types, clear names, comments only for non-obvious constraints, no `print`. The sole branch writer may stage/commit/push only at the orchestrator's named gates and only within the task's reviewed scope.

## Task index

| Task | Milestone | Status |
| --- | --- | --- |
| [task-01-conformance-suite.md](task-01-conformance-suite.md) | M1 — reusable provider contract | Completed; historical, do not dispatch |
| [../local/agents/](../local/agents/README.md) | M2/M3 — real local provider | Completed; historical, do not dispatch |
| [local-workspace-mvp.md](local-workspace-mvp.md) | L1–L6 — Local Workspace MVP | Current serial work-order stack |

## Reporting format (end of every task)

- **Summary** — ≤ 10 bullets with file paths.
- **Deltas from spec** — anything done differently than the design docs, with justification, or "none".
- **Capabilities declared** — the exact `ProviderCapabilities` values shipped, each justified by a passing conformance case (provider tasks only).
- **Tests** — `N before → M after`, new test names; build result where applicable.
- **Open questions** — judgment calls made.
