# 06 — Change Preview & Approval

"See before it happens" is the product's headline promise. Because plans are **decision-shaped** ([04 §2]), the preview is now a near-direct rendering: one decision → one reviewable entry, with the schedule as its audit trail. This is the payoff of freeing the plan from the flat action list — the preview can no longer drift from the plan, because it *is* the plan, rendered.

## 1. `ChangePreview`

Pure, deterministic rendering: `ChangePreviewRenderer.render(outcome:locations:base:advice:) -> ChangePreview`.

```swift
public struct ChangePreview: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var planFingerprint: PlanFingerprint?     // nil for refusals
    public var headline: String                      // "12 changes ready to sync" | "Needs review" | "Paused for safety"
    public var refusals: [RefusalNotice]             // canonical sentences, one per reason
    public var holds: [HoldNotice]                   // reason + MassChangeEvidence groups ("all 312 under /Photos/2019")
    public var sections: [PreviewSection]            // fixed order: additions, updates, movesAndRenames, waiting, movesToTrash, bothVersionsPreserved
    public var conflicts: [ConflictDecision]         // with attached advice when present
    public var generatedAt: Date
}

public struct PreviewEntry: Codable, Hashable, Sendable {
    public var decisionID: UUID                      // 1:1 with ItemDecision — the partition property
    public var path: SyncPath
    public var summary: String                       // "Move 'Old Notes.txt' to OneDrive trash"
    public var causality: String?                    // "Deleted from Google Drive (alex@…) since last sync on ⟨date⟩. Copies at other locations move to trash."
    public var destinations: [LocationID]
    public var byteSize: Int64?
    public var isTrash: Bool
}
```

Rules:

- **Every decision appears exactly once** (`decisionID` partition — tested as a property, [10 §3]). A preview that hides work is a correctness bug, not a styling choice.
- **Trash entries always explain causality**: which location the item vanished from, when it was last synced (from the `BaseRecord`), and that destination copies go to *trash*. The single most trust-building sentence in the app.
- `waiting` items are shown, not hidden ("Waiting for 3 files to download from iCloud Drive") — the honest form of the old whole-set placeholder pause.
- Section titles use the preferred phrases verbatim ("Move to trash", "Both versions preserved"); trash and conflict sections render last, after the routine material.
- Refusal previews have no sections and no fingerprint — there is nothing to approve; the notice carries the canonical sentence and, where useful, per-location detail.

## 2. Conflict resolution in the preview

Each `ConflictDecision` renders with its versions (per-location metadata), the always-present default **Keep both**, optional `makeCanonical(location)` choices, and — when present — one clearly-labeled advisory suggestion ([07]). Resolution flows:

- *Keep both*: acknowledgment; the preservation copies were in the plan all along.
- *Make canonical*: adds operations (propagate winner under the canonical name) to a **new plan** on the next prepare — resolution choices are inputs to planning, never mid-flight plan mutations. Losers stay preserved as conflict copies; trashing those later is an ordinary reviewed delete.

## 3. `PlanApproval`

```swift
public struct PlanApproval: Codable, Hashable, Sendable {
    public var planFingerprint: PlanFingerprint
    public var approvedAt: Date
    public var expiresAt: Date                       // default +15 min
    public var acknowledgedTrashCount: Int           // must equal the plan's actual counts —
    public var acknowledgedConflictCount: Int        // the UI cannot under-disclose
    public func validate(against plan: SyncPlan, at now: Date) -> ApprovalValidation  // accepted | rejected(reason)
}
```

Contract ([05 §5] enforces it at one choke point): `clear` plans run with or without approval (a stray approval is ignored); `hold` plans require a valid one; refusals are unexecutable by type. Approval expiry exists because the world drifts — and even a valid approval never bypasses per-operation preconditions. Approvals are logged: "You approved 6 items to move to trash for 'Documents'."

## 4. UI contract

The engine hands the preview sheet everything so no sync rule leaks into SwiftUI: headline, notices with canonical sentences, ordered sections with causality strings, conflicts with version metadata and advice, byte totals. Buttons map 1:1: "Preview changes" → `prepare`, "Sync now" → `execute(prep)`, "Approve and sync" → `execute(prep, approval:)`, conflict choices → resolution inputs for the next prepare. The current SwiftUI app remains a demo shell; this contract is for the future wiring.

## 5. Changing the current code

Phase 7 of [11-migration.md](11-migration.md): all-new code (`Preview/`), no legacy to unwind — today nothing renders plans. The golden-value test style (fixed fixtures → exact `ChangePreview` equality) starts here and becomes the wording lock for canonical sentences.
