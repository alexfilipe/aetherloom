# 00 — Overview: Moving the Real-Data Boundary

## Why this track exists

The engine's real local boundary now exists: `LocalFolderStorageProvider` implements the full provider contract, conservative mutation/recovery behavior, and temporary-directory end-to-end tests. The production app has not crossed that boundary: it still starts `DemoEngineSession` over fakes and in-memory state. The next work composes the existing local provider into the durable `WorkspaceEngineSession` specified in [01-workspace-engine-session.md](01-workspace-engine-session.md).

The strategic choice, restated from the development order in `CLAUDE.md`: **local folders first, then NAS, then iCloud Drive, then cloud APIs.** A local↔local sync exercises 100 % of the real pipeline — staging, journal, preconditions, trash, recovery — with the fewest new failure modes. iCloud Drive is then a small, well-contained delta (placeholder semantics on top of a filesystem provider) instead of the place where filesystem bugs and placeholder bugs are discovered simultaneously.

## 1. Milestones

| # | Milestone | Outcome | Where designed |
| --- | --- | --- | --- |
| M1 | Provider conformance suite ✅ | Reusable contract exercised by fakes and local provider | §3 below |
| M2 | Local provider, read side ✅ | Truthful availability and complete/incomplete scanning of real temporary directories | [local/00-overview.md](local/00-overview.md) |
| M3 | Local provider, mutations ✅ | Owned atomic stores, relocate, recoverable trash/quarantine, indeterminate recovery, local end-to-end tests | [local/00-overview.md](local/00-overview.md) |
| L2 | Arbitrary-folder safety | Typed package and unsupported-metadata exclusions before user-folder enrollment | [local/01-package-and-metadata-safety.md](local/01-package-and-metadata-safety.md) |
| L3–L5 | Durable production workspace | Persistent workspace, `WorkspaceEngineSession`, picker/bookmarks, and default real app session | [01-workspace-engine-session.md](01-workspace-engine-session.md) |
| L6 | Local-alpha qualification | Exact integrated-head relaunch/recovery and real-folder qualification | [agents/local-workspace-mvp.md](agents/local-workspace-mvp.md) |
| M5 | NAS hardening ⏭ | Future timeout/mount and filesystem-fidelity qualification; not part of the local MVP | [local/](local/README.md) |
| M6 | iCloud Drive variant ⏭ | Dataless placeholders observed (`isPlaceholder`, never absent), materialization before fetch | icloud/ ⏭ |
| — | SQLite, FSEvents hints, cloud APIs ⏭ | Deferred; interfaces already stable ([../core/09-persistence.md §4](../core/09-persistence.md)) | later |

The completed M1–M3 work is the base. L2→L6 is strictly serial and user-merge gated; see the sole [work-order map](agents/local-workspace-mvp.md). NAS and iCloud remain future work.

## 2. Shared normative requirements

Every real provider, current and future, obeys these — they extend the normative behavior in [../core/02-provider-abstraction.md §2](../core/02-provider-abstraction.md):

1. **Failure never masquerades as emptiness.** A `.complete` snapshot with zero observations is legal only after positively verifying the scope exists and is empty or that every present in-scope path is covered by typed exclusions. Any enumeration error, timeout, doubt, or unaccounted path produces `.incomplete` or `unavailable`. A subtree exclusion positively accounts for its root/descendants without descending; observation count alone never defines completeness.
2. **Everything that can hang has a deadline and an owner appropriate to its effects.** Availability probes and scans run under injected timeouts; a hang maps to `volumeUnreachable` (or backend-appropriate reason), not to a stuck run. Blocking mutations remain owned after a caller deadline, retain their late result, and block conflicting work until journal recovery reconciles provider truth. Task cancellation is never treated as cancellation of a Foundation or backend syscall.
3. **No permanent-delete call exists in any implementation**, including private helpers. Trash uses the platform facility; backends without reliable trash quarantine to `/.aetherloom/trash/…` per [../core/02-provider-abstraction.md §4](../core/02-provider-abstraction.md).
4. **`notFound` requires positively confirmed absence at a healthy backend** ([../core/02-provider-abstraction.md §6](../core/02-provider-abstraction.md)); when the backend can't answer, throw `unavailable`.
5. **Capabilities honesty.** Declare a capability only when the backend proves it; `nil`/`false` defaults degrade toward preservation (more conflict copies, more collision detection — never more deletion).
6. **Side effects only through the protocol.** No provider writes outside the scope it was given, except its own quarantine directory under the location root and staging URLs handed to it by the executor.
7. **Conformance passage is a merge gate.** No provider is composed into an orchestrator — even experimentally — before it passes the suite at its declared capabilities.

## 3. The conformance suite

The engine's contract is enforced by the parameterized conformance suite against fake configurations and the real local provider. New backends add a harness rather than bespoke contract semantics.

Current harness shape (implementation names may contain supporting detail):

```swift
/// One per backend. Lives in test support; production code never sees it.
public protocol ProviderConformanceHarness: Sendable {
    var declaredCapabilities: ProviderCapabilities { get }
    /// A fresh provider over a fresh, isolated world seeded with these items.
    func makeProvider(seeded: [ConformanceSeedItem]) async throws -> any StorageProvider
    /// A provider currently unavailable for this reason, or nil when the
    /// backend cannot reproduce the reason in tests (case is skipped and reported).
    func makeUnavailableProvider(reason: LocationUnavailabilityReason) async throws -> (any StorageProvider)?
}
```

Case groups, with assertions branching on `declaredCapabilities` — a provider must be *exactly* as good as it claims:

- **Truthfulness** — truly empty scope scans `.complete` and empty; an exclusion-only scope is `.complete` only when typed exclusions account for every path; every scriptable unavailability reason yields `unavailable`, never an empty `.complete`; enumeration failure or any unaccounted path yields `.incomplete`.
- **Scan fidelity** — Unicode names (NFC/NFD), zero-byte files, empty folders, deep nesting, symlinks observed as `ItemKind.symlink`; observations round-trip through `currentState`.
- **Mutation contract** — mutations are **idempotent under re-application** (journal recovery re-applies completed intents; `FakeStorageProvider` ✅ and `ProviderContractTests` ✅ define these semantics): `store` with `.neverOverwrite` succeeds and returns the existing observation when the destination holds byte-identical content, and throws `itemAlreadyExists` when it holds different content; `.ifVersionMatches` throws `preconditionFailed` on drift; `makeFolder` returns the existing folder and throws `itemAlreadyExists` only when a non-folder occupies the path; `relocate` to the item's current path succeeds, to an occupied destination throws, and preserves content and identity per capabilities.
- **Preservation** — after `trash`, content is recoverable (native trash or quarantine) and the item no longer appears in a scan; nothing in the API can permanently destroy content.
- **Degradation honesty** — `hasContentHashes == false` ⇒ observations carry no hash; `hasStableItemIDs == false` ⇒ no `itemID`; `supportsVersionCheckedStore == false` ⇒ the emulated path still enforces preconditions through `currentState`.

The suite runs against `FakeStorageProvider` in at least two capability configurations (full fidelity; degraded hashes) from day one. Real backends add a harness, not new test logic.

## 4. Targets and layering

- Filesystem-backed providers (local, NAS, the iCloud variant) live **inside `AetherloomCore`** under `Providers/Local/` — they import Foundation only, and core already touches the filesystem through the file-backed stores. Core's "no network/ML/SQLite imports" rule is untouched.
- Each future cloud provider gets **its own target** (precedent: `AetherloomIntelligence` isolates the only ML import). Core never imports an SDK.
- `WorkspaceEngineSession` lives in `AetherloomBridge` next to `DemoEngineSession`, behind the same `EngineSession` protocol ([../ui/03-engine-session.md §1](../ui/03-engine-session.md)). The app picks the session at launch; screens are indifferent.
- The engine composes providers through `StorageProvider` + capabilities only. `ProviderKind` ✅ selects which implementation to construct and which glyph to draw — nothing else.

## 5. Test discipline for real backends

- Every filesystem test creates its own temporary directory root and removes it; a test that writes outside its root is a review-blocking defect.
- Unavailability states (unmounted volume, unreachable mount, missing scope) are produced through the provider's injected volume-inspection seam — never by requiring real hardware states.
- Opt-in tests against a real external disk or SMB share exist for manual verification only: environment-gated (`AETHERLOOM_REAL_MOUNT_TESTS=1`), read-mostly, never against a folder the user did not create for the test, and never in CI defaults.
- Timeout behavior is tested with injected deadlines/clocks, not real sleeps.

## 6. Decisions & rejected alternatives (ADR summary)

| Decision | Chosen | Rejected, and why |
| --- | --- | --- |
| First real backend | Local↔local folders | iCloud-first — user-visible sooner, but stacks placeholder semantics on top of unproven filesystem code; local-first makes iCloud a small delta |
| NAS shape | Same `LocalFolderStorageProvider`, different availability probing + capabilities | A separate NAS provider class — duplicates every filesystem code path to vary only probing, timeouts, and trash strategy |
| Contract enforcement | One parameterized conformance suite, fakes pass it first | Per-provider bespoke test files — the contract drifts, and "the real provider is held to the fake's standard" stops being checkable |
| Persistence for first real sync | Existing JSON file stores ✅ | SQLite now — roadmap step 10, but the store protocols are stable and JSON carries realistic workloads; do it when scale demands, behind unchanged interfaces |
| Filesystem provider home | Inside `AetherloomCore` (Foundation only) | Separate package target — isolation without benefit; core already does file I/O in stores, and the split would force public surface area for no consumer |
| Testability of volume states | Injected volume-inspection seam | Mocking `FileManager` wholesale — enormous surface, and the dangerous logic (mounted? reachable? scope exists?) is exactly the small part worth seaming |
| Change detection | Full scans; `hasChangeHints == false` | FSEvents now — an optimization with real complexity (event coalescing, drops); correctness never depends on it, so it waits until real syncs prove slow |
