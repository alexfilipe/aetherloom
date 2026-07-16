# Provider Implementation Work Orders

Each `task-*.md` is a self-contained prompt for one implementation agent (Claude, Codex, GPT-5.5, …) covering one milestone of the provider track ([../00-overview.md §1](../00-overview.md)). Paste the file as the task instruction; the agent must also read the referenced design docs in the repo — **the docs are the specification, the prompt is the work order.** Backend-specific work orders live next to their designs (e.g. [../local/agents/](../local/agents/README.md)); this README owns the dispatch graph across all of them. The core and UI tracks are complete; provider tasks never restructure engine or app sources.

## Dispatch order

```text
01 conformance suite ─▶ local/01 read side ─▶ local/02 mutations ─▶ 02 workspace session ⏭
                                                    └─▶ local/03 NAS hardening ⏭ ──┘
                                                                (icloud track ⏭ after workspace session)
```

Strictly serial except local/03, which may run parallel to task-02 in a separate worktree (disjoint files); merge task-02 first. Each phase ends green before the next starts. **⏭ tasks must not be dispatched until their spec documents exist** — currently that blocks task-02 (needs `../01-workspace-session.md`), local/03, and everything iCloud.

## Global rules (authoritative here; abbreviated in each prompt)

1. **Safety invariants** (`architecture/core/00-overview.md § Safety invariants`) **override everything**, including these prompts. The track-specific corollaries (`../00-overview.md §2`): failure never masquerades as emptiness; everything that can hang has a deadline; no permanent-delete call exists anywhere, including private helpers.
2. File boundaries: track tasks 01–02 and all `local/*` tasks work only in `src/AetherloomCore/` (task-02 additionally in the `AetherloomBridge` sources and tests). Never touch `src/AetherloomApp/`, `www/`, `README.md`, `CLAUDE.md`, or `architecture/` except `architecture/ui/11-functioning-vs-placeholder.md` status updates when a task's spec says so.
3. Zero third-party dependencies; no network/ML/SQLite imports anywhere in this track.
4. Swift 6 strict concurrency: values `Codable + Hashable + Sendable`; mutable state in actors.
5. Existing engine sources are read-only unless a task explicitly names an exception; providers implement `StorageProvider` as it stands — protocol changes require stopping and reporting, not improvising.
6. **Filesystem test discipline** (`../00-overview.md §5`): every test runs under a temp root it creates and removes; unavailability via injected seams; no real mounts, no real user folders, no network; timeouts via injected deadlines, no real sleeps.
7. Capabilities are declared conservatively; a capability claimed without a conformance case proving it is a defect.
8. Engine-emitted user-facing strings use the canonical sentences from `architecture/core/00-overview.md § Canonical language` verbatim; providers themselves emit no user-facing prose.
9. Exit bar, every task: `swift test --package-path src/AetherloomCore` green, zero new warnings. Tasks touching the bridge also build the app: `xcodebuild -project src/AetherloomApp/AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build`. Report test counts before/after.
10. Style: match existing sources — small focused types, clear names, comments only for non-obvious constraints, no `print`. Commit nothing; leave changes in the working tree.

## Task index

| Task | Milestone | Status |
| --- | --- | --- |
| [task-01-conformance-suite.md](task-01-conformance-suite.md) | M1 — the reusable provider contract | Dispatchable |
| task-02-workspace-session.md ⏭ | M4 — first real sync behind `EngineSession` | Blocked on `../01-workspace-session.md` |
| [../local/agents/](../local/agents/README.md) | M2, M3, M5 — the local/NAS provider | See its README |

## Reporting format (end of every task)

- **Summary** — ≤ 10 bullets with file paths.
- **Deltas from spec** — anything done differently than the design docs, with justification, or "none".
- **Capabilities declared** — the exact `ProviderCapabilities` values shipped, each justified by a passing conformance case (provider tasks only).
- **Tests** — `N before → M after`, new test names; build result where applicable.
- **Open questions** — judgment calls made.
