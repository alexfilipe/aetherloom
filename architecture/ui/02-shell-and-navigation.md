# 02 — Shell & Navigation

The shell is everything outside a screen's content: scenes, window chrome, sidebar, toolbar, menu commands, and the app-level model that routes between them. 🔁 Reshape of `AetherloomAppApp.swift` + `ContentView.swift`.

## 1. Scenes

```swift
@main struct AetherloomApp: App {
    @StateObject private var appModel = AppModel(session: DemoEngineSession.standard())

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .environmentObject(appModel)
                .tint(Theme.accent)
        }
            .defaultSize(width: 1180, height: 760)
            .windowStyle(.hiddenTitleBar)
            .commands { AetherloomCommands(appModel: appModel) }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .tint(Theme.accent)
        }   // standard ⌘, window [10]
    }
}
```

- The session is constructed once at app start. `DemoEngineSession.standard()` boots the demo world asynchronously; `AppModel` exposes `bootstrapPhase: .loading/.ready/.failed(String)` and `ContentView` shows a branded loading state (mesh + logo + "Preparing your weave…") until `.ready`. Bootstrap starts from `ContentView.onAppear`, builds a detached `AppBootstrapPayload`, and applies the payload back on the main actor. ✅ See [13-startup-bootstrap-lessons.md](13-startup-bootstrap-lessons.md) before changing this startup path.
- The About panel (`AboutWindowController`) stays as-is. ✅
- Settings moves from a sidebar destination into the standard macOS `Settings` scene; the sidebar keeps a Settings item only as a shortcut that opens it (see [10-screen-settings-and-providers.md](10-screen-settings-and-providers.md)).
- `MenuBarExtra` is intentionally **not** part of the first UI PR. The Settings row is a disabled placeholder until background sync/menu-bar behavior is implemented. 🎭

## 2. AppModel

`@MainActor final class AppModel: ObservableObject` — the only object views talk to. Thin by contract ([00-overview.md](00-overview.md#layering)).

```swift
// Navigation & routing
var selectedDestination: SidebarDestination = .overview
var activeSheet: AppSheet?            // .previewChanges(SyncPreparation), .newSyncSet,
                                      // .syncSetDetail(UUID), .connectProvider(ProviderKind) 🎭
var pendingToast: RunResultToast.Model?

// Cached bridge snapshots (read-only for views)
private(set) var workspace: WorkspaceSnapshot?     // locations + sync sets + open conflict count
private(set) var recentActivity: [ActivityEntry]
private(set) var preparations: [UUID: SyncPreparation]   // last prepare() per sync set
private(set) var busySyncSets: Set<UUID>                  // in-flight prepare/execute

// Intents (all async, all forward to EngineSession)
func refreshWorkspace() async
func syncNow(_ syncSetID: UUID) async        // prepare → auto-execute if gate clear, else sheet
func preview(_ syncSetID: UUID) async        // prepare → sheet always
func approveAndExecute(_ preparation: SyncPreparation, approval: PlanApproval) async
func setPaused(_ paused: Bool, syncSetID: UUID) async
func resolveConflict(_ id: UUID, as resolution: Resolution) async
```

Event loop: after the initial bootstrap payload is applied, `AppModel` spawns a task iterating `session.events`; each `EngineEvent` triggers the narrow refresh it names (activity append → prepend to `recentActivity`; run finished → refresh that sync set + toast; availability changed → refresh locations). No timers, no polling. ✅

Concurrency rules: every intent guards re-entry per sync set via `busySyncSets` (the orchestrator would throw `runAlreadyInProgress` anyway — the UI simply disables the buttons first); all session calls are `await`ed off the main actor by the session itself (it is an actor), so intents stay trivially small.

## 3. Sidebar

🔁 Keeps today's design: header (logo chip, app name, tagline), destination list, status footer.

| Item | Badge (live, from bridge) |
| --- | --- |
| Overview | — |
| Sync Sets | count of sync sets whose status tone is `paused` or `attention` |
| Activity | — |
| Conflicts | open (unresolved) conflict count |
| Settings | — (opens Settings scene) |

Status footer states, in priority order (derived in bridge, see [04-display-models.md](04-display-models.md#workspace-status)): scanning/executing (`ProgressView` + stage name) → "Needs review" (orange dot; any hold or open conflict) → "Paused for safety" (red dot; any refusal-state sync set) → "Everything in sync" (green dot). ✅

## 4. Toolbar

| Control | Behavior | Status |
| --- | --- | --- |
| **Scan Now** (`⌘R`) | `prepare()` on every unpaused sync set (serially; the demo world is small). Spinner while running; results update cards/badges; does **not** execute anything. | ✅ |
| **Preview Changes** (`⇧⌘P`) | Opens the preview sheet for the sync set with pending changes; with several, a menu lists them. Disabled when no preparation exists yet (tooltip explains). | ✅ |
| **New Sync Set** (`⌘N`, prominent) | Opens the wizard [06]. | ✅ |

The window title stays hidden (`WindowTitleVisibilityConfigurator` kept — AppKit glue lives only in the app target).

## 5. Menu commands

`AetherloomCommands` (CommandGroups):

- **File**: New Sync Set `⌘N`; Scan Now `⌘R`.
- **View**: Go to Overview/Sync Sets/Activity/Conflicts `⌘1–⌘4`.
- **Demo** (menu title "Demo" — present only when the session is a demo session): scripted scenario toggles, each calling `DemoScenarioControls` ([03-engine-session.md](03-engine-session.md#scenario-controls)): Make OneDrive Reachable/Unreachable · Mount/Unmount NAS "Tank" · Edit a File in Two Places · Delete Many Files in "Projects" · Simulate Interrupted Run · Reset Demo World. ✅ (this menu is itself a demo-only surface, clearly not shipping UI)
- **Help**: Aetherloom Help → opens aetherloom.app. ✅

## 6. Menu bar extra 🎭 — deferred

The first UI PR does **not** declare a `MenuBarExtra` scene. During startup debugging, even a static/gated menu extra kept the built app on the loading screen; see [13-startup-bootstrap-lessons.md](13-startup-bootstrap-lessons.md).

Current shape: Settings shows "Show in menu bar" as a disabled, labeled placeholder ("Arrives with background sync"). Future background-sync work may reintroduce `MenuBarExtra`, but it must be added in isolation with a launch smoke test proving the app reaches Overview with the scene present.

## 7. Navigation rules

- `SidebarDestination` stays an enum; selection is `AppModel.selectedDestination` (non-optional; collapsing the sidebar never blanks the detail).
- Sheets route exclusively through `AppModel.activeSheet` (single `.sheet(item:)` in `ContentView`) — one modal at a time, by construction.
- Deep links between screens are model calls, not view plumbing: e.g. a conflict row in Preview jumps via `appModel.show(.conflicts, focusing: conflictID)`; Activity supports `show(.activity, filteredToRun: runID)`.
- State restoration: `selectedDestination` persisted via `@SceneStorage`; everything else derives from the session on relaunch.

## 8. Acceptance criteria

- Launch → branded loading → Overview populated from the demo world with **zero hardcoded sample values** in shell code.
- Toolbar/sidebar/menu shortcuts all reachable by keyboard; VoiceOver reads sidebar badges meaningfully.
- Demo menu → "Simulate Interrupted Run" followed by a scan shows the engine's journal-recovery activity entry (crash safety is user-visible; see [03-engine-session.md](03-engine-session.md#scenario-controls)). ✅
- Demo menu absent if the session is not a `DemoEngineSession`.
