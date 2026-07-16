# Task 01 — Provider Conformance Suite (Milestone M1)

## Role
Senior Swift engineer on `AetherloomCore`. You extract the provider contract from the existing fake-only tests into one parameterized suite that any `StorageProvider` must pass, and prove the harness by running the fakes through it. **No new provider is implemented in this task.**

## Read first
`architecture/providers/00-overview.md` (§2 requirements, §3 is your spec), `architecture/core/02-provider-abstraction.md`, `architecture/core/10-testing-strategy.md`; current `Tests/AetherloomCoreTests/ProviderContractTests.swift` and `Support/`. Baseline green first.

## Invariants (override this prompt)
The suite must make the safety contract *checkable*: failure never masquerading as emptiness, trash recoverability, and precondition enforcement are mandatory cases, not optional ones. A provider passing the suite while violating `architecture/providers/00-overview.md §2` means the suite is wrong — fix the suite.

## Deliverables
1. `ProviderConformanceHarness` protocol and `ConformanceSeedItem` in `Tests/AetherloomCoreTests/Support/` per `providers/00 §3`: `declaredCapabilities`, `makeProvider(seeded:)`, `makeUnavailableProvider(reason:)` returning `nil` for non-reproducible reasons (skipped cases are *reported*, not silent).
2. The conformance suite as a Swift Testing suite parameterized over harnesses, covering the five case groups in `providers/00 §3` (truthfulness, scan fidelity, mutation contract, preservation, degradation honesty). Assertions branch on `declaredCapabilities` — over-claiming and under-claiming both fail.
3. A `FakeStorageProvider` harness run in at least two configurations: `.fullFidelity` and degraded hashes (`hasContentHashes == false`). Both pass.
4. A `FlakyStorageProvider`-wrapped configuration exercising the unavailability cases through scripted faults.
5. Existing `ProviderContractTests` assertions either migrate into the suite or remain where fake-specific (call log, scripting mechanics); no contract assertion is deleted. State the disposition of each in your report.

## Prohibitions
No changes to `Sources/` — this task is test-only; if the contract cannot be expressed without a source change, stop and report. No real filesystem providers, no temp-dir I/O beyond what existing support code already does, only `src/AetherloomCore/`.

## Acceptance
Suite green with the fake passing conformance in ≥ 3 configurations; skipped-case reporting visible in test output; contract-assertion disposition table in the report; zero new warnings. Report per `agents/README.md`.
