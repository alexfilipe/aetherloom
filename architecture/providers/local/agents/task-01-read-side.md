# Task 01 — Local Provider Read Side (Milestone M2)

## Role
Senior Swift engineer on `AetherloomCore`. You implement the first real `StorageProvider` over the filesystem — availability and scanning only. The provider must be able to *look* at real directories with the engine's full truthfulness discipline before it is allowed to touch anything. **Requires the conformance suite (`../../agents/task-01`) merged.**

## Read first
`architecture/providers/local/00-overview.md` (your spec — implement exactly), `architecture/providers/00-overview.md` (§2, §5), `architecture/core/02-provider-abstraction.md`; current `Providers/*` sources and the conformance harness in test support. Baseline green first.

## Invariants (override this prompt)
Failure never masquerades as emptiness: no code path may return a `.complete` snapshot after any enumeration error, timeout, or unavailability. A missing root is classified volume-first (`volumeNotMounted` before `scopeMissing`, per spec §3). Placeholders observe as present with `isPlaceholder = true`, never as absent, and scanning never triggers materialization.

## Deliverables
1. `LocalFolderStorageProvider` actor in `Sources/AetherloomCore/Providers/Local/` per spec §1, with the capability table from spec §2 verbatim (native-trash probing may land as a stub returning `false` until task-02).
2. `VolumeInspecting` protocol + real implementation (URL volume resource keys, bounded probes) + a scriptable test double. `ProviderDeadlines` with injected clock support.
3. Read-side surface implemented: `checkAvailability()` (spec §3 order, all five outcomes), `scan(_:)` (spec §4, including deadline expiry ⇒ `.incomplete`, dataless-item placeholder flagging, `/.aetherloom/` suppression), `currentState(of:)`, `fetch(_:to:)` (throws `placeholderOnly` on placeholders), and `changedSubtrees` returning a not-complete hint.
4. Mutation methods (`store`, `makeFolder`, `relocate`, `trash`) throw `ProviderError.unsupported` — clearly marked for task-02.
5. A `ProviderConformanceHarness` for this provider over temp-dir worlds, wired so the suite's **read-side case groups** (truthfulness, scan fidelity, degradation honesty) run against it; mutation and preservation groups are skipped-and-reported until task-02.
6. Direct tests beyond conformance: Unicode (NFC/NFD) and zero-byte fixtures on a real temp dir; unreadable-subdirectory ⇒ `.incomplete`; every unavailability reason via the scripted seam; scan-under-expired-deadline; a case-insensitivity value sourced from the seam.

## Prohibitions
No mutations of any scanned content; no FSEvents; no `NSOpenPanel`/bookmarks (workspace-session scope); no changes to `StorageProvider` or engine sources (stop and report if the contract can't be met); no real mounts or user folders in tests; only `src/AetherloomCore/`.

## Acceptance
Suite green including read-side conformance for the new harness; skipped mutation cases visibly reported; `grep -rn "trashItem\|removeItem\|moveItem\|createDirectory" src/AetherloomCore/Sources/AetherloomCore/Providers/Local` → nothing (read side writes nothing; `fetch` copies via `copyItem` to the staging URL only); zero new warnings. Report per `../../agents/README.md`, including the exact capability values shipped.
