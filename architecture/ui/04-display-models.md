# 04 — Display Models

Pure, tested mappings from engine values to what screens render. All live in `AetherloomBridge/Display/`; every function here is a value transformation with injected `now: Date` — no clocks, no I/O, no SwiftUI. This is where "the UI presents" gets its precision: one place decides what a `RefusalReason` looks like, so every screen agrees. 🆕

## Naming

The demo shell's UI types collide with core (`SyncSet`, and `Tone` overlaps core status concepts). Resolution:

- Core value types keep their names and are displayed via *presentation* wrappers, never duplicated.
- Retired with `DemoStore`: UI `SyncSet`, `CloudService`, `ServiceStatus`, `PlannedChange`, `ActivityItem`, `FileConflict`, `ConflictVersion`.
- `Tone` moves to `AetherloomBridge` as `StatusTone` (`healthy | attention | paused | neutral`); the app keeps a `Tone = StatusTone` typealias plus the color/symbol extension (colors stay app-side).

## 1. Provider presentation

```swift
public struct ProviderPresentation: Sendable, Hashable {
    public var kind: ProviderKind
    public var displayName: String        // core displayName
    public var symbolName: String         // SF Symbol, canonical set from [01 §8]
    public var paletteToken: ProviderPalette  // .iCloud, .google, .oneDrive, .dropbox, .local, .nas
}
public extension ProviderKind { var presentation: ProviderPresentation }
```

The app maps `ProviderPalette` → gradients (today's `CloudService.gradient` values move into `Design/`). Brand glyphs remain placeholder SF Symbols. 🎭

## 2. Tone derivation

Single source of truth; screens never map states to tones themselves.

```swift
public enum StatusTone { case healthy, attention, paused, neutral }

public func tone(for availability: LocationAvailability) -> StatusTone
// available → healthy;
// notAuthenticated/networkUnreachable/volumeUnreachable/rateLimited/unknown → paused;
// volumeNotMounted → neutral   (a sleeping NAS is expected life, not an incident)

public func tone(for state: SyncSetState) -> StatusTone
// paused by user → paused; last prep refused → paused;
// holds or open conflicts → attention; preparing/executing/never-run → neutral;
// otherwise healthy
```

## 3. Status lines

```swift
public struct StatusLine: Sendable, Hashable {
    public var text: String          // "Up to date" · "Needs review" · "Paused for safety" ·
                                     // "Provider unavailable" · "Waiting for volume" · "Never synced"
    public var tone: StatusTone
    public var safetyNote: String?   // canonical engine sentence when one applies, verbatim
}

public func statusLine(for state: SyncSetState, now: Date) -> StatusLine
public func statusLine(for location: LocationState, now: Date) -> StatusLine
```

`safetyNote` rules: refusal for unavailability → the canonical "Sync paused because this provider is unavailable…" sentence; `massDeletion`/`massEdit` hold → "Aetherloom found many deletions…"; conflicts → "This file changed in more than one place…". Sentences come from the engine's notices (`RefusalNotice.message`, `HoldNotice.message`) whenever a notice exists — the bridge only *selects*, composing text itself solely for states the engine has no words for ("Never synced", "Paused by you").

### Workspace status

```swift
public enum WorkspaceStatus: Sendable, Hashable {
    case busy(stage: String)        // any set preparing/executing — stage from activity entries
    case needsReview(count: Int)    // Σ holds + open conflicts
    case pausedForSafety            // any refusal-state set (and nothing needs review)
    case allInSync
}
```

Priority exactly in that order; drives the sidebar footer and the menu bar extra.

## 4. Preview display

`ChangePreview` is already user-shaped (sections, headline, notices). Display adds grouping and formatting only:

```swift
public struct PreviewDisplay: Sendable, Hashable {
    public var headline: String                      // preview.headline verbatim
    public var refusals: [NoticeDisplay]             // message + detail + location presentation
    public var holds: [HoldDisplay]                  // message, evidence summary ("all 30 under /Projects/Archive"),
                                                     // advisoryNote (triage) if present
    public var sections: [SectionDisplay]            // non-empty sections, engine order, entry count,
                                                     // per-entry: path, summary, causality, destination chips, size
    public var totals: PreviewTotals                 // per-kind counts + byte total
    public var approvalRequirement: ApprovalRequirement?
}

public struct ApprovalRequirement: Sendable, Hashable {
    public var fingerprint: PlanFingerprint
    public var trashCount: Int          // == plan.approvalTrashCount
    public var conflictCount: Int       // == plan.approvalConflictCount
}

public func previewDisplay(for preparation: SyncPreparation, locations: [LocationState]) -> PreviewDisplay
public func makeApproval(_ req: ApprovalRequirement, at now: Date) -> PlanApproval
// PlanApproval(planFingerprint:approvedAt:acknowledgedTrashCount:acknowledgedConflictCount:)
```

`makeApproval` is the **only** constructor of `PlanApproval` in the UI stack, and it takes counts from the plan-derived requirement — the UI physically cannot acknowledge numbers it didn't show. Expiry stays the core default (15 min); the sheet surfaces "Approval expires…" from `expiresAt`.

## 5. Conflict display

```swift
public struct ConflictDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID                              // ConflictDecision.id
    public var path: SyncPath
    public var message: String                       // decision.message (canonical sentence)
    public var versions: [VersionDisplay]            // per location: provider presentation,
                                                     // modified date, size, "most recent" flag
    public var preservedCopyName: String?            // from the plan's preserve operations when present
    public var advice: AdviceDisplay?                // recommendation label, confidence, rationale,
                                                     // generatedBy name/backend, per-version notes
    public var options: [ResolutionOptionDisplay]    // keepBoth + makeCanonical(per location)
}
```

`AdviceDisplay` carries `attribution: String` ("Suggested on-device by Heuristic Advisor") — attribution is mandatory whenever advice renders ([../core/07-ai-conflict-advisor.md](../core/07-ai-conflict-advisor.md)).

## 6. Activity display

```swift
public struct ActivityRowDisplay: Sendable, Hashable, Identifiable { … }
// timestamp (relative + absolute tooltip), category glyph + tone, message,
// optional detail, location presentation, path, relatedConflictID
public func activityRows(_ entries: [ActivityEntry], locations: [LocationState], now: Date) -> [ActivityRowDisplay]
public func runGroups(_ rows: [ActivityRowDisplay]) -> [RunGroupDisplay]   // grouped by runID, newest first
```

Category → tone/glyph: `sync` neutral `arrow.triangle.2.circlepath` · `safety` paused `shield.lefthalf.filled` · `conflict` attention `doc.on.doc` · `advisory` neutral `sparkles` · `provider` neutral `externaldrive` · `error` attention `exclamationmark.triangle`.

## 7. Formatting

One `DisplayFormatting` namespace: relative dates ("2 minutes ago", `now`-injected), absolute tooltips (`.dateTime`), byte counts (`ByteCountFormatStyle`, file-count style), item counts ("1 change" / "N changes"), path middle-truncation hints. Tests pin en-US output; localization is out of scope but everything routes through here for later.

## 8. Testing (see [12-testing-strategy.md](12-testing-strategy.md))

Every function above gets table-driven Swift Testing coverage in `AetherloomBridgeTests`, including: tone matrix over all `LocationUnavailabilityReason` cases; status-line priority; `makeApproval` count fidelity; preview display against a real `SyncPreparation` produced by the demo world (not hand-built fixtures).
