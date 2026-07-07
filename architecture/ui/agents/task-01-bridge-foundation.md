# UI Task 01 — Bridge Foundation (`AetherloomBridge`)

## Role
Senior Swift engineer building the seam between Aetherloom's sync engine and its macOS UI. No UI code in this task — you deliver a library target and its tests.

## Read first
`architecture/ui/00-overview.md` (layering, ADRs), `architecture/ui/03-engine-session.md` (your spec — implement exactly), `architecture/ui/11-functioning-vs-placeholder.md`; then `src/AetherloomCore/Sources/AetherloomCore/` public surfaces: `Orchestration/SyncOrchestrator.swift`, `Storage/EngineStores.swift`, `Providers/FakeStorageProvider.swift`, `Preview/*`, `Advisory/HeuristicConflictAdvisor.swift`, `Logging/SyncActivityLog.swift`, `Models/CoreModels.swift`. Baseline: `swift test --package-path src/AetherloomCore` green; record the count.

## Invariants (override this prompt)
Never permanent-delete; failure-absence ≠ deletion; never silently overwrite; the bridge never edits, filters, or synthesizes engine outcomes; no execution of a gated plan without a `PlanApproval`.

## Deliverables
1. `Package.swift`: `AetherloomBridge` library target (deps: `AetherloomCore` only) + `AetherloomBridgeTests` test target. No source file imports SwiftUI/AppKit (add the grep-style test per `ui/12 §3`).
2. `EngineSession` protocol + supporting values (`WorkspaceSnapshot`, `LocationState`, `SyncSetState`, `SyncSetDraft`, `EngineEvent`, `EngineSessionError`) per `ui/03 §1` verbatim.
3. `DemoEngineSession` actor per `ui/03 §2`: five fake locations (stable core `LocationID`s), `EngineStores.inMemory()` with the activity store wrapped for event fan-out, `HeuristicConflictAdvisor`, real `SyncOrchestrator`; `prepare`/`execute` as verbatim passthroughs; pause as bridge state (`syncSetPaused` error).
4. `DemoWorld` manifest per `ui/03 §3`: the four sync sets, converging bootstrap pass **through the real orchestrator**, scripted divergences (edits/creates/rename/delete/conflict/mass-deletion), availability faults, Unicode/zero-byte/empty-folder/exclusion garnish. One manifest file; no scattered literals.
5. `DemoScenarioControls` per `ui/03 §4` including `simulateInterruptedRun()` (unfinished journal run) and `reset()`.
6. Multicast `events` AsyncStream (`bufferingNewest(64)`, multi-subscriber).
7. Tests per `ui/12 §2` "Demo world & session" bullets in full, deterministic (stepped clock, seeded IDs, zero latency), including the placeholder-hygiene call-log assertion and cancellation recovery.

## Prohibitions
No edits to existing `AetherloomCore`/`AetherloomIntelligence` sources or tests (additive package manifest change only); no display/formatting logic (Task 02); no persistence; no SwiftUI; only `src/AetherloomCore/`.

## Acceptance
Full suite green (core baseline intact + new bridge tests); `grep -rn "import SwiftUI\|import AppKit" src/AetherloomCore/Sources/AetherloomBridge` → nothing; bootstrap determinism test passes twice in a row; zero new warnings. Report per `agents/README.md`.
