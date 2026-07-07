# 10 — Screen: Settings & Providers

Settings moves out of the sidebar into the standard macOS `Settings` scene (`⌘,`), organized as panes. The sidebar's Settings item simply opens it. 🔁 Reshape of `Views/SettingsView.swift` (today: four demo toggles). This is the screen with the highest placeholder density — by design, it frames the full product without faking capabilities.

## 1. Panes

### General 🎭 (mostly)

| Setting | Status |
| --- | --- |
| Launch at login | 🎭 disabled toggle, "arrives with background sync" |
| Show in menu bar | ✅ toggles the `MenuBarExtra` placeholder's visibility (bridge/app preference, `@AppStorage`) |
| Appearance follows system note | text only |

### Safety ✅ (defaults) / per-set overrides live in the sync set detail [06 §2]

- **Default thresholds for new sync sets**: mass-delete count/ratio, mass-edit count/ratio — real `SafetyThresholds`, stored as the bridge's `SyncSetDraft` defaults. Editor copy explains each: "Pause and ask when more than N files would be deleted at once."
- **Non-negotiables section** — rendered as informational rows with lock glyphs, not toggles: "Deletes always go to each provider's trash" · "Conflicting versions are always preserved" · "An unreachable provider never causes deletions". These are engine invariants; presenting them as un-toggleable settings is deliberate trust UI. ✅ (statements are true of the real engine)

### Suggestions (AI) ✅

- "Suggest conflict resolutions on this Mac" toggle — when off, the session passes `advisor: nil` to the orchestrator composition (demo session rebuilds orchestrator config); advice chips disappear everywhere. Real on/off behavior. ✅
- Explanatory copy: on-device, advisory-only, never acts; link to aetherloom.app AI page.
- Advisor backend row: "Heuristic (built-in)" today; "Apple Intelligence" row present but disabled 🎭 ("Requires Apple Silicon; arrives with the Foundation Models integration" — the `AetherloomIntelligence` target exists but stays unwired in the demo app).

### Providers

One row per `ProviderKind`: mark, name, connection state.

| Provider | Row state | Status |
| --- | --- | --- |
| Local Folder | "Built in" caption; [Choose Folder…] disabled 🎭 | 🎭 |
| NAS Folder | mount state from demo `LocationState` ✅ display; [Mount Settings…] 🎭 | mixed |
| iCloud Drive / Google Drive / OneDrive | demo account label; [Connect…] opens the connect sheet (§3); [Disconnect] disabled 🎭 | 🎭 |
| Dropbox | "Planned" caption, everything disabled | 🎭 |

### Demo (visible only for `DemoEngineSession`)

- Duplicates the Demo menu controls [02 §5] with descriptions, plus [Reset Demo World]. ✅
- Banner at top: "You're exploring Aetherloom's demo world — real files are never touched."

## 2. Persistence

UI preferences (`menu bar visibility`, advice toggle, demo dismissals) → `@AppStorage`. Engine-shaped defaults (thresholds) → bridge (`UserDefaults`-backed `BridgePreferences` actor, JSON-encoded core types, tested). Per-set settings live in the engine's `SyncSet.settings` via `updateSettings` — never duplicated app-side.

## 3. Connect-provider sheet 🎭 (`activeSheet = .connectProvider(kind)`)

The one fully-scripted placeholder flow, designed so the real OAuth flow can replace its internals without layout change:

```text
ServiceMark(kind, 64pt) + "Connect Google Drive"
Step rail: Sign in → Grant access → Choose folders     (all steps shown, inert)
Body copy: what Aetherloom will/won't access; "Aetherloom only sees folders you choose."
PlaceholderChip("Preview — provider connections arrive with the real integrations")
[Cancel]   [Learn More → aetherloom.app]
```

No fake success state exists: the sheet cannot end in "Connected". Honesty rule — a placeholder may *show* a future flow but never *complete* one.

## 4. Acceptance criteria

- Settings opens via `⌘,` and the sidebar item; every pane renders in both appearances.
- Advice toggle off → conflict cards and preview rows show no `AdviceChip`s; back on → they return after the next prepare. ✅
- Editing default thresholds affects the next *created* sync set's plan gating (bridge test), and existing sets are untouched.
- Every 🎭 control is disabled or ends in labeled inert states; nothing mutates engine state from a placeholder path (assert via fake call logs).
