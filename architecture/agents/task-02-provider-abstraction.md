# Task 02 — Provider Abstraction (Migration Phase 2)

## Role
Senior Swift engineer on `AetherloomCore`. You reshape the provider contract so availability, capabilities, and truthful scanning are first-class, and upgrade the fakes into the engine's full test rig. **Requires Task 01 merged.**

## Read first
`architecture/00-overview.md`, `02-provider-abstraction.md` (your spec — implement exactly), `11-migration.md` (§2 rows 7–9); current `Providers/*`, `Execution/*`, tests. Baseline green first.

## Invariants (override this prompt)
Failure never masquerades as emptiness — every failure is `unavailable` or `incomplete`, never an empty `.complete` scan. No permanent-delete path may exist on the protocol or be wrapped by any implementation. `notFound` requires positively confirmed absence at a healthy backend.

## Deliverables
1. `StorageProvider` protocol per `02 §1` (rename from `CloudProvider`): `locationID`, `capabilities`, `checkAvailability()`, non-throwing `scan(_:) -> LocationSnapshot`, `changedSubtrees` (hint-only), `fetch`/`store(StoreOptions)`/`makeFolder`/`relocate`/`trash`/`currentState`. Collapse `move`+`rename` into `relocate`; fold `authenticateIfNeeded` into availability (`notAuthenticated` reason); replace `UploadOptions` with `StoreOptions.OverwritePolicy` (`.neverOverwrite | .ifVersionMatches(ItemVersion)`) so an uncheckable overwrite is unrepresentable.
2. `LocationAvailability` + `LocationUnavailabilityReason` per `02 §2` (all seven reasons).
3. `ProviderCapabilities` per `02 §3` with `.fullFidelity`.
4. `FakeStorageProvider` (rename; keep internals — revision counters, precondition enforcement): `init(location:capabilities:items:)`; full availability scripting; capability degradation (`hasContentHashes == false` ⇒ hashless observations); per-call fault injection `failNext(_:with:)`; artificial latency; **call log** (operation, path, order); **fake trash** whose content stays retrievable for preservation assertions.
5. `FlakyStorageProvider` — wraps any provider, applies scripted mutations/faults between calls.
6. Built-in non-removable exclusions in `SyncSettings`: `/.aetherloom/` prefix and symlinks; `isExcluded` honors them with empty user exclusions.
7. Tests: availability taxonomy ⇒ paused/refused planning with the canonical unavailable sentence, specifically `volumeNotMounted` (disconnected local disk) and `volumeUnreachable` (sleeping NAS) producing **zero trash actions**; degraded-hash independent edit (same size, different mtime) ⇒ conflict copies, never overwrite; equal size+mtime ⇒ no action; `.complete`+empty only when truly empty and unscripted; built-in exclusions; call log records scan-only during planning; fake-trash retrievability.

## Prohibitions
No real filesystem/NAS probing (contract only — real providers are later roadmap steps); no planner restructuring (Phase 3); executor changes limited to compiling against `relocate`/`StoreOptions`; only `src/AetherloomCore/`.

## Acceptance
Suite green (ported + ≥ 7 new); `grep -rn "CloudProvider\|UploadOptions\|func move(\|func rename(" src/AetherloomCore/Sources` → nothing; no permanent-delete symbol anywhere; zero new warnings. Report per `agents/README.md`.
