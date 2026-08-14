# 03 — The Engine Session (`AetherloomBridge`)

The seam between the app and the engine. `AetherloomBridge` exists as a library target in the `src/AetherloomCore` package (alongside `AetherloomIntelligence`): it depends on `AetherloomCore` + Foundation, never SwiftUI/AppKit, and is covered by `swift test`. `DemoEngineSession` is implemented and remains the production app's current launch session. The target real-local implementation is normatively specified in [../providers/01-workspace-engine-session.md](../providers/01-workspace-engine-session.md).

```swift
// Existing package products/targets
.library(name: "AetherloomBridge", targets: ["AetherloomBridge"]),
.target(name: "AetherloomBridge", dependencies: ["AetherloomCore"]),
// AetherloomBridgeTests test target
```

## 1. `EngineSession` — the UI-facing protocol

One protocol keeps screens indifferent to what stands behind it. Today the implemented app session is `DemoEngineSession`; L4 adds `WorkspaceEngineSession` behind this seam and L5 makes it the production default. The signature below describes the UI-facing shape; the provider document owns production bootstrap, capability, persistence, and confirmation semantics.

```swift
public protocol EngineSession: Sendable {
    // Lifecycle
    func bootstrap() async throws -> WorkspaceSnapshot
    var events: AsyncStream<EngineEvent> { get }

    // Reading (values, safe to cache; UI refreshes on events)
    func workspace() async -> WorkspaceSnapshot
    func syncSetStates() async -> [SyncSetState]
    func locationStates() async -> [LocationState]
    func openConflicts(in syncSetID: UUID?) async throws -> [ConflictDecision]
    func resolvedConflicts(in syncSetID: UUID?) async throws -> [ConflictResolutionRecord]
    func advice(for conflictIDs: [UUID]) async -> [ConflictAdvice]      // cached from last prepare
    func suggestionsEnabled() async -> Bool
    func activity(matching query: ActivityQuery) async -> [ActivityEntry]
    func lastPreparation(for syncSetID: UUID) async -> SyncPreparation?

    // Sync pipeline
    func prepare(syncSetID: UUID) async throws -> SyncPreparation
    func reviewIntentionalDeletions(_ preparation: SyncPreparation) async throws -> SyncPreparation
    func execute(
        _ preparation: SyncPreparation,
        confirmation: WorkspaceExecutionConfirmation
    ) async throws -> SyncRunSummary

    // Workspace edits
    func enrollLocalFolder(_ draft: LocalFolderDraft, access: FolderAccessGrant) async throws -> LocationState
    func reauthorizeLocalFolder(_ locationID: LocationID, access: FolderAccessGrant) async throws -> LocationState
    func createSyncSet(_ draft: SyncSetDraft) async throws -> SyncSetState
    func setSuggestionsEnabled(_ enabled: Bool) async throws
    func setPaused(_ paused: Bool, syncSetID: UUID) async
    func updateSyncSet(mode: SyncMode, settings: SyncSettings, syncSetID: UUID) async throws
    func deleteSyncSet(_ syncSetID: UUID) async throws
    func resolveConflict(id: UUID, as resolution: Resolution) async throws
}
```

Contract points:

- `prepare` passes the orchestrator's `SyncPreparation` through unchanged. `reviewIntentionalDeletions` accepts only the displayed ordinary `massDeletion` preparation and delegates to core's single-use, expiring, exact-match fresh-prepare flow. On exact match, core atomically exchanges the review authorization for an opaque actor-owned execution reservation bound to the distinct reviewed fingerprint/run/preparation; neither bearer reaches the bridge, UI, or `AppModel`. An otherwise executable preparation is a clear plan or a held plan whose gate permits approval, but a reviewed plan also needs that live reservation. `execute` requires the exact non-optional `WorkspaceExecutionConfirmation` from [the production contract](../providers/01-workspace-engine-session.md#1-current-state-and-target-boundary); the bridge validates fingerprint/time/expiry (capped by the reviewed preparation's display-only authority expiry) and exact required counts, then deterministically derives the internal core `PlanApproval?`. Core independently atomically consumes the matching reservation before executor construction. An ordinary non-approvable hold or reviewed plan without its live reservation is rejected before any executor call. The bridge never edits an outcome, filters a hold, or exposes bearer review/reservation authority or nullable core approval to `AppModel`.
- Pause lives here, not in core: `prepare` on a paused set throws `EngineSessionError.syncSetPaused`; "Scan Now" skips paused sets. Pause state is part of `SyncSetState`.
- Conflict resolution calls `ConflictStore.resolve(id, as:, at:)`. The bridge then emits `.conflictsChanged`; the *effect* of a resolution (e.g. `makeCanonical` propagating a version) materializes on the **next run**, exactly as the engine defines it — the UI copy must say so ("Applied on the next sync").
- Every mutation emits an `EngineEvent`; reads never mutate.
- L4 migrates this protocol, `DemoEngineSession`, `WorkspaceEngineSession`, AppModel call sites, and their compile/interaction tests together. Both session implementations require the same confirmation shape; demo behavior is not a nullable escape hatch.

### Supporting value types (bridge-owned)

```swift
public struct WorkspaceSnapshot: Sendable, Hashable {
    public var locations: [LocationState]
    public var syncSets: [SyncSetState]
    public var openConflictCount: Int
    public var status: WorkspaceStatus            // see 04 §workspace-status
}

public struct LocationState: Sendable, Hashable, Identifiable {
    public var location: SyncLocation             // core value
    public var availability: LocationAvailability // from provider.checkAvailability()
    public var lastCheckedAt: Date?
    public var accountLabel: String?              // demo: scripted; real: from auth. 🎭 field
    public var id: LocationID { location.id }
}

public struct SyncSetState: Sendable, Hashable, Identifiable {
    public var syncSet: SyncSet                   // core value (settings, locations, mode)
    public var isPaused: Bool                     // bridge state
    public var lastRun: RunDigest?                // runID, finishedAt, outcome
    public var lastPreparation: PreparationDigest?// counts per preview section, holds, refusals
    public var trackedItemCount: Int              // BaseRecordStore count
    public var phase: SyncSetPhase                // idle | preparing | executing
}

public struct SyncSetDraft: Sendable, Hashable {
    public var name: String
    public var locationIDs: [LocationID]          // ≥ 2, validated
    public var mode: SyncMode
    public var settings: SyncSettings
}

public enum EngineEvent: Sendable, Hashable {
    case activityAppended(ActivityEntry)
    case syncSetChanged(UUID)
    case locationsChanged
    case conflictsChanged
    case runFinished(SyncRunSummary)
    case worldReset                                // demo only
}
```

`events` is a multicast `AsyncStream` (one continuation per subscriber, buffered `.bufferingNewest(64)`). The activity feed is the engine's own `ActivityStore` — the bridge wraps the store it hands the orchestrator so appends also fan out as `.activityAppended` without polling.

## 2. `DemoEngineSession`

`public actor DemoEngineSession: EngineSession`. Composition, all real core types:

```swift
locations   5× SyncLocation: Local Folder(~/Aetherloom), NAS "Tank" (smb://tank.local),
            iCloud Drive, Google Drive, OneDrive        (stable LocationIDs from core)
providers   5× FakeStorageProvider (latency ~120–400 ms so progress UI is visible)
stores      EngineStores.inMemory() — activity store wrapped for event fan-out
advisor     HeuristicConflictAdvisor()                   (deterministic advice ✅)
environment EngineEnvironment(now: Date.init, makeID: UUID.init)
orchestrator SyncOrchestrator(locations:providers:stores:stage:environment:advisor:)
world       DemoWorld (the script, §3) + DemoScenarioControls (§4)
```

`bootstrap()`:

1. Seed each fake provider from the `DemoWorld` manifest (files, folders, sizes, dates).
2. Register sync sets (§3) and run one **converging pass** per healthy set through the real orchestrator (`prepare` → `execute`) so `BaseRecord`s and initial activity are genuine engine output, not fabricated.
3. Apply the scripted **divergences** (§3) by mutating the fakes — as if edits happened on other devices since that converged state.
4. Flip the scripted availability faults: OneDrive → `.unavailable(.networkUnreachable)`, NAS → `.unavailable(.volumeNotMounted)`.
5. Run a scan pass (`prepare` on each unpaused set, discarding nothing — results cached as `lastPreparation`) so the UI opens with real pending changes, a real hold, and a real refusal.

Bootstrap is deterministic given the manifest (stable paths, sizes, and dates; UUIDs may vary — nothing in the UI depends on specific IDs).

## 3. The demo world script

One manifest type (`DemoWorld.swift`) declares everything; no scattered literals. The scenarios are chosen to exercise every safety surface in [11-functioning-vs-placeholder.md](11-functioning-vs-placeholder.md):

| Sync set | Locations | Seeded state after bootstrap | Exercises |
| --- | --- | --- | --- |
| **Documents** | iCloud, Google, Local | ~40 converged items; then: 2 edits (one side each), 2 creates, 1 rename, 1 delete (Google side), and `Budget.xlsx` edited **independently** on iCloud and Google | clean sections, delete-to-trash causality, conflict + advice, `deletionsNeedReview`/`conflicts` holds, acknowledged confirmation |
| **Projects** | iCloud, Google | ~60 converged items; then 30 files under `/Projects/Archive` removed on the Google side | ordinary non-approvable `massDeletion` safety stop; explicit **Review intentional deletions** → exact-match fresh reviewed plan → normal exact-count confirmation |
| **Photos Archive** | Local, NAS, Google | ~25 converged items; NAS then unmounted | refusal (`volumeNotMounted`), "no files deleted while unreachable" messaging |
| **Whole Drive Mirror** | iCloud, Google, OneDrive | created **paused**, never run | paused-by-user presentation; OneDrive unavailability visible on Overview |

Unicode filenames, a zero-byte file, an empty folder, and one excluded pattern (`.DS_Store` via `SyncExclusion`) are sprinkled into *Documents* so real edge cases appear in previews and activity.

## 4. Scenario controls

`public struct DemoScenarioControls` (exposed by `DemoEngineSession`, used by the Demo menu [02 §5]):

```swift
func setOneDriveReachable(_ reachable: Bool) async        // provider.setAvailability
func setNASMounted(_ mounted: Bool) async                 // .volumeNotMounted toggle
func makeConflict() async                                  // divergent edit of a random converged Documents file
func makeMassDeletion() async                              // remove >threshold files in Projects (Google side)
func simulateInterruptedRun() async                        // write unfinished journal run; next prepare recovers
func reset() async                                          // rebuild the world; emits .worldReset
```

Each control mutates **fakes or stores only** and emits events; the engine reacts on the next scan exactly as it would to reality changing. This is the demonstration mechanism for the safety story — no control ever fabricates a UI state directly.

## 5. Threading & failure model

- The session is an actor; all methods are safe from any context. `AppModel` is the only caller.
- Session methods that hit the orchestrator can throw (`SyncOrchestratorError.runAlreadyInProgress`, executor errors). The bridge maps engine errors to `EngineSessionError` cases with user-presentable `failureDescription`s; unknown errors surface as `.engineFailure(detail:)` — shown honestly in a toast, never swallowed.
- Long operations are cancellable: `AppModel` holds the `Task` per intent; sheet dismissal cancels an in-flight `prepare` (the orchestrator supports cooperative cancellation).

## 6. What this layer must never do

- Re-derive or second-guess verdicts, gates, counts, or fingerprints (no arithmetic on plan contents beyond *display* counting).
- Offer any AppModel-facing API that executes without a non-optional `WorkspaceExecutionConfirmation`, or expose the bridge's internal `PlanApproval?` mapping.
- Construct a confirmation, enable execution, derive approval, or call the executor for an ordinary non-approvable hold. The only transition is core's explicit one-shot **Review intentional deletions** fresh-prepare/reservation flow; settings normalize to the engine's hard maxima and cannot bypass a matching durable latch. A reviewed value or audit digest never substitutes for core's live reservation.
- Let `AppModel` or SwiftUI construct providers, retain bookmark capability bytes, or decide sync behavior. `WorkspaceEngineSession` owns real-folder capability and composition under the provider contract; `DemoEngineSession` MUST remain isolated from real user folders.
- Leak fake-provider details (e.g. `FakeProviderCall` logs) into non-demo API surfaces.
