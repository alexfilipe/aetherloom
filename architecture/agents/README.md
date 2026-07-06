# Implementation Work Orders

Each `task-*.md` is a self-contained prompt for one implementation agent (Claude, GPT-5.5, …) covering one migration phase from [../11-migration.md](../11-migration.md). Paste the file as the task instruction; the agent must also read the referenced design docs in the repo — the docs are the specification, the prompt is the work order.

## Dispatch order

```text
01 domain ─▶ 02 providers ─▶ 03 reconciliation ─▶ 04 planning/gating ─▶ 06 execution ─▶ 07 orchestration+preview ─▶ 08 advisory ─▶ 09 tests
                                                        05 stores/observability ────────┘        (05 may run parallel to 04; merge 04 then 05)
```

Strictly serial except 04∥05. Never run two agents on the same files concurrently. Each phase ends green before the next starts.

## Global rules (authoritative here; abbreviated in each prompt)

1. **Safety invariants** (`../00-overview.md § Safety invariants`) **override everything**, including these prompts. On any apparent conflict: stop, report, don't implement.
2. Work only inside `AetherloomCore/` unless the task says otherwise (task-08 adds a package target). Never touch `AetherloomApp/`, `www/`, `README.md`, `CLAUDE.md`.
3. Zero third-party dependencies; no ML/network/SQLite imports in the core target.
4. Swift 6 strict concurrency: values `Codable + Hashable + Sendable`; mutable state in actors.
5. Pure layers stay pure: no I/O, no `Date()`, no global UUID/RNG below the orchestrator — everything injected via environment values.
6. Tests: Swift Testing, fakes only, deterministic, temp dirs cleaned up, no real sleeps.
7. Engine-emitted user-facing strings use the canonical sentences from `../00-overview.md § Canonical language` verbatim.
8. Migration rules from `../11-migration.md §1` apply: existing test assertions are the contract; the three sanctioned behavior changes (§4 there) are the only ones allowed; clean breaks, no deprecation shims; adapters die by the next phase.
9. Exit bar, every task: `swift test --package-path AetherloomCore` green, zero new warnings. Report test counts before/after.
10. Style: match existing sources — small focused types, clear names, comments only for non-obvious constraints, no `print`. Commit nothing; leave changes in the working tree.

## Reporting format (end of every task)

- **Summary** — ≤ 10 bullets with file paths.
- **Deltas from spec** — anything done differently than the design docs, with justification, or "none".
- **Behavior changes** — must be a subset of `11-migration.md §4`, or empty.
- **Tests** — `N before → M after`, new test names.
- **Open questions** — judgment calls made.
