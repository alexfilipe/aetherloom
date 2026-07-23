# Task 00 — Initial Local Sync, End to End (Milestones M1–M3, bundled)

This is the **bundled work order** for the initial local-sync implementation: the provider conformance suite, the complete `LocalFolderStorageProvider`, and an end-to-end proof that the real engine syncs two real directories. It is the single-agent alternative to dispatching `../../agents/task-01-conformance-suite.md` → `task-01-read-side.md` → task-02 serially. If any of those has already merged, skip the corresponding phase and say so in your report. Work proceeds in phases; **the full suite is green at the end of every phase** before the next begins.

## Role

Senior Swift engineer on `AetherloomCore`. You are building the first code in this project that touches real files. The engine above you is finished and trusted; your job is to give it a backend that is *exactly as truthful as the fakes it was hardened against* — and then to demonstrate the first real sync: two temporary directories, real bytes, trash-recoverable deletes, conflict copies on disk.

## Read first (the docs are the specification)

1. `architecture/core/00-overview.md` — safety invariants (the constitution) and the pipeline.
2. `architecture/core/02-provider-abstraction.md` — the `StorageProvider` contract you are implementing.
3. `architecture/providers/00-overview.md` — §2 shared requirements, §3 conformance suite (Phase 1 spec), §5 test discipline.
4. `architecture/providers/local/00-overview.md` — **normative for Phases 2–3**: shape (§1), capability table (§2), availability order (§3), scan semantics (§4), mutation sketch (§5).
5. `architecture/providers/agents/README.md` and `README.md` beside this file — global rules; they bind this task.
6. Current sources: `Providers/*`, `Execution/*`, `Orchestration/SyncOrchestrator.swift`, `Storage/EngineStores.swift`, `Preview/PlanApproval.swift`, and the existing test suites (`ProviderContractTests`, `OrchestratorTests`, `SimulationTests` show the composition patterns to follow).

Baseline first: `swift test --package-path src/AetherloomCore` green before any change.

**Phase 3 carries normative detail that exists only in this prompt** (its spec document `../01-mutations-and-trash.md` is not yet written). Where this prompt conflicts with a design doc or a safety invariant: stop and report; do not improvise a resolution.

## Safety invariants (override everything in this prompt)

1. **No permanent-delete call exists anywhere in the provider, including private helpers.** `grep` for it will run in acceptance.
2. **Failure never masquerades as emptiness.** No code path returns a `.complete` snapshot after any enumeration error, timeout, or unavailability signal. `.complete` + zero observations requires positive verification that the scope exists and is empty.
3. **A missing root is classified volume-first**: `volumeNotMounted` / `volumeUnreachable` are ruled out *before* `scopeMissing` may be reported.
4. **Placeholders are presence.** Dataless/ubiquitous-not-downloaded items observe with `isPlaceholder = true`, never as absent, never as edited; scanning and `fetch` never trigger materialization.
5. **Everything that can hang has an injected deadline**; expiry maps to `.incomplete` (scan) or `volumeUnreachable` (probe), never a truncated success.
6. **`notFound` requires positively confirmed absence at a healthy volume** (seam says mounted and responsive); any doubt throws `unavailable`.
7. **The provider writes only**: inside its scope as directed by protocol calls, its own `/.aetherloom/` space under the location root, and staging URLs handed to it.

## Phase 1 — Provider conformance suite (test-only)

Per `architecture/providers/00-overview.md §3`, in `Tests/AetherloomCoreTests/Support/`:

1. `ConformanceSeedItem` — path, kind, content bytes (files), enough to seed any backend.
2. `ProviderConformanceHarness` protocol — `declaredCapabilities`, `makeProvider(seeded:)`, `makeUnavailableProvider(reason:) -> (any StorageProvider)?` (nil ⇒ reason not reproducible for that backend; the case is **skipped and reported**, never silently passed).
3. The suite itself, Swift Testing, parameterized over harnesses, five case groups: truthfulness, scan fidelity (Unicode NFC/NFD, zero-byte, empty folders, deep nesting, symlinks), mutation contract (`.neverOverwrite` ⇒ `itemAlreadyExists` on existing path; `.ifVersionMatches` ⇒ `preconditionFailed` on drift; `relocate` preserves content; `makeFolder` on existing ⇒ throws), preservation (post-`trash` content recoverable; item gone from next scan), degradation honesty (capability `false` ⇒ corresponding observation field absent; over-claiming and under-claiming both fail).
4. Harnesses for `FakeStorageProvider` at `.fullFidelity` and with `hasContentHashes == false`, plus a `FlakyStorageProvider`-wrapped configuration for the unavailability cases. All pass.
5. Existing `ProviderContractTests` assertions migrate into the suite or stay where fake-specific (call-log, scripting mechanics); no contract assertion is deleted. Record the disposition of each.

**Exit bar:** suite green; fake passes in ≥ 3 configurations; no changes under `Sources/`.

## Phase 2 — `LocalFolderStorageProvider`, read side

In `src/AetherloomCore/Sources/AetherloomCore/Providers/Local/`, per `local/00-overview.md` exactly:

1. The actor per §1: `init(location:rootURL:volumes:deadlines:)`. `VolumeInspecting` answers only the dangerous questions (mounted? bounded-probe responsive? volume properties — case sensitivity, trash support, network-ness? directory exists?); real implementation over URL volume resource keys; scriptable test double. `ProviderDeadlines` with injected clock.
2. `checkAvailability()` in the §3 order — all five outcomes reachable and tested.
3. `scan(_:)` per §4: re-check availability first; `FileManager.enumerator` with prefetched keys (`isDirectoryKey`, `fileSizeKey`, `contentModificationDateKey`, `isSymbolicLinkKey`, `isUbiquitousItemKey`, `ubiquitousItemDownloadingStatusKey`); any error-handler hit ⇒ `.incomplete(reason:)`; whole-scan deadline, expiry ⇒ `.incomplete`; observations carry `ItemVersion(size:modifiedAt:)` only (no hash, no `itemID`); symlinks as `ItemKind.symlink(target:)`; ubiquitous-not-downloaded ⇒ `isPlaceholder = true`; `/.aetherloom/` never reported; paths carried as observed (no Unicode rewriting).
4. `currentState(of:)` — resource-value re-read; missing at healthy volume ⇒ `notFound`, doubt ⇒ `unavailable`. `fetch(_:to:)` — `copyItem` to the staging URL; placeholder ⇒ throws `placeholderOnly`. `changedSubtrees` — `ChangeHint(changedRoots: [], nextCursor: nil, isComplete: false)`.
5. Capabilities per the §2 table verbatim (`hasNativeTrash` may stub `false` until Phase 3).
6. Mutations throw `ProviderError.unsupported`, marked `// Phase 3`.
7. Tests beyond conformance: NFC/NFD and zero-byte fixtures in a real temp dir; unreadable subdirectory ⇒ `.incomplete`; every unavailability reason via the scripted seam; expired-deadline scan; case-sensitivity sourced from the seam.
8. A conformance harness over temp-dir worlds; read-side groups run, mutation/preservation groups skipped-and-reported.

**Exit bar:** suite green including read-side conformance; grep shows no mutation calls in `Providers/Local` (`copyItem` to staging is the only write, and it targets the staging URL).

## Phase 3 — Mutations and trash (NORMATIVE HERE, pending `../01-mutations-and-trash.md`)

1. **`store(from:at:options:)`** — enforce `OverwritePolicy` inside the actor *before* writing: `.neverOverwrite` ⇒ destination must not exist (else `itemAlreadyExists`); `.ifVersionMatches(v)` ⇒ read the destination's current `ItemVersion` from resource values, compare via the existing `ItemVersion` comparison, mismatch or unknown ⇒ `preconditionFailed`. Then write atomically: copy staged content to a temporary URL obtained from `FileManager.url(for: .itemReplacementDirectory, …, appropriateFor: destination)` (same volume — the move is atomic), then `replaceItemAt`. An interrupted store never leaves a torn or half-written destination. The check-then-replace race window is accepted and documented — the executor's emulated precondition plus post-write verification covers it (`core/02 §3`, `core/05 §5`). Return a fresh observation from post-write resource values.
2. **`makeFolder(at:)`** — `createDirectory(withIntermediateDirectories: false)`; existing path ⇒ `itemAlreadyExists`; missing parent ⇒ error (the operation schedule guarantees parents first — a missing parent is drift, not a case to paper over).
3. **`relocate(_:to:)`** — verify the destination path is absent (respecting the volume's case sensitivity: on case-insensitive volumes a case-variant occupant counts as present) ⇒ else `itemAlreadyExists`; same-volume: `moveItem`; cross-volume: copy → verify size/bytes at destination → `trash` the source. **Never copy-then-remove.** Return the new observation.
4. **`trash(_:)`** — if the seam reports native trash support: `FileManager.trashItem(at:resultingItemURL:)`. Otherwise quarantine: `moveItem` (never copy-delete) to `/.aetherloom/trash/<ISO-8601 run timestamp>/<relative path>` under the location root, creating intermediates; name collisions get numeric suffixes. Flip `hasNativeTrash` to the probed value.
5. **Precondition discipline everywhere**: every mutation that replaces or displaces content re-reads reality immediately before acting, inside the actor, and throws `preconditionFailed` on drift — the provider is the last line behind the executor's own verification.
6. **Trash-test containment**: the default temp-dir harness scripts the seam to report *no* native trash support, so preservation tests exercise the quarantine path entirely inside the temp root. Exactly one dedicated test exercises real `trashItem`, captures `resultingItemURL`, and removes that test-created artifact in teardown (test-code-only exception to the no-delete rule; it must justify itself in a comment).
7. Full conformance passage for the local harness — mutation and preservation groups now run; the only remaining skips are `makeUnavailableProvider` reasons the backend genuinely cannot reproduce (report which).

**Exit bar:** suite green; local harness passes all five conformance groups; `grep -rn "removeItem" src/AetherloomCore/Sources/AetherloomCore/Providers/Local` → nothing.

## Phase 4 — End-to-end local↔local sync

New `Tests/AetherloomCoreTests/LocalSyncEndToEndTests.swift`: a real `SyncOrchestrator` over **two `LocalFolderStorageProvider`s on two temp roots**, composed with `FileBaseRecordStore`, `FileRunJournalStore`, and `FileActivityStore` rooted in the test temp dir (the file-backed stores exist and this is their first real exercise) and `InMemory*` for conflicts/advice/locations. Follow `OrchestratorTests` patterns for approval/fingerprint handling. Scenarios, asserted **on the real filesystem**:

1. Create, edit, and folder propagation A→B and B→A; byte-identical content at both roots afterward.
2. Rename and move: with `hasStableItemIDs == false` these degrade by design to create-plus-delete — assert content at the new path, the old path's content in trash/quarantine (recoverable), and **nothing permanently deleted**.
3. Delete-to-trash propagation: deletion on A moves B's copy to trash/quarantine; content retrievable.
4. Independent edits ⇒ both versions on disk afterward, conflict filename preserving the extension; resolution recorded; next run converges.
5. Mass-delete hold: many deletions on one side ⇒ gate holds, **zero filesystem mutations** occur before approval.
6. Unavailability mid-composition: seam scripts one side `volumeNotMounted` ⇒ refusal, zero mutations, canonical sentence surfaced.
7. Drift abort: mutate a destination file between plan and execute ⇒ run stops for replan; no overwrite of the drifted file.
8. Idempotence: immediately re-running after convergence yields an empty preview and zero provider mutations.
9. Unicode filename and zero-byte file survive a full round trip; empty folders propagate.

Every test creates and removes its own temp roots; deterministic (injected clocks/IDs); no real sleeps.

**Exit bar:** all scenarios green; total suite green.

## Prohibitions

No changes to engine sources (`Reconcile/`, `Plan/`, `Planning/`, `Execution/`, `Orchestration/`, `Preview/`, `Advisory/`, `Models/`, `Storage/`) — if the contract cannot be met without one, stop and report. No `StorageProvider` protocol changes. No FSEvents, no `NSOpenPanel`/security-scoped bookmarks, no bridge/UI work, no NAS-specific tuning beyond the injected deadlines, no SQLite, no new dependencies. No real mounts, no real user folders, nothing outside test-created temp roots. Only `src/AetherloomCore/`; never touch `src/AetherloomApp/`, `www/`, `README.md`, `CLAUDE.md`, or `architecture/`.

## Acceptance

- `swift test --package-path src/AetherloomCore` green; zero new warnings; test counts before/after.
- Conformance: fake in ≥ 3 configurations and local harness at declared capabilities all pass; skipped cases visibly reported and enumerated.
- `grep -rn "removeItem" src/AetherloomCore/Sources/AetherloomCore/Providers/Local` → nothing; no permanent-delete symbol anywhere in the provider.
- All nine Phase 4 scenarios present and green.

## Reporting (per `../../agents/README.md`, plus)

- The exact `ProviderCapabilities` values shipped, each justified by a named passing conformance case.
- Disposition table for every former `ProviderContractTests` assertion (migrated / retained-as-fake-specific).
- Conformance cases skipped for the local harness, with reasons.
- Anything observed but out of scope — xattr/Finder-tag loss, package behavior, mtime granularity — reported as findings, not fixed.
