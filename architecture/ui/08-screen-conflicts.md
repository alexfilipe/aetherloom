# 08 — Screen: Conflicts

Where preserved divergences get reviewed on the user's schedule. The engine has already done the safe thing (both versions kept); this screen is calm by design — nothing here is urgent, nothing can be lost. 🔁 Reshape of `Views/ConflictsView.swift`.

## 1. Layout

```text
PageHeader "Conflicts" / "Files that changed in more than one place. Every version is safe."
[segmented: Open (N) · Resolved]
ConflictCard per ConflictDisplay [04 §5]:
┌ path (PathText) + detectedAt + StatusBadge("Needs review", attention)
│ canonical sentence verbatim: "This file changed in more than one place.
│ Aetherloom preserved both versions."
│ VersionRow per location:
│    ServiceMark · location name · modified · size · ("Most recent") tag
│    [Choose This Version] button
│ preserved copy note: "Kept as “Budget (conflict from OneDrive, …).xlsx”"
│ AdviceChip (when advice exists): "Suggestion: keep the Google Drive version ·
│    medium confidence" → expands: rationale, per-version notes, attribution,
│    "On-device suggestion — you decide."  [Dismiss]
│ footer actions: [Keep Both]   [Compare…] 🎭
└──
```

Empty state (Open): green-tinted `EmptyStateView` "No conflicts. When a file changes in more than one place, it appears here with every version preserved."

## 2. Data & actions

| Element | Source / behavior | Status |
| --- | --- | --- |
| Open list | `session.openConflicts(in: nil)` (real `ConflictStore`), refreshed on `.conflictsChanged` | ✅ |
| Version rows | `ConflictDecision` observations → `VersionDisplay` | ✅ |
| Advice | `session.advice(for:)` — cached `ConflictAdvice` from the last prepare (validated, attributed) | ✅ |
| Keep Both | `resolveConflict(id, as: .keepBoth)` — records resolution; copy: "Both versions stay where they are." | ✅ |
| Choose This Version | confirmation popover: "Make the *Google Drive* version the one everywhere? The other version stays preserved as a conflict copy." → `.makeCanonical(locationID)`; footnote **"Applied on the next sync."** | ✅ |
| Resolved tab | `ConflictResolutionRecord`s: path, resolution, when; purely informational | ✅ |
| Compare… | disabled button + `PlaceholderChip("File comparison coming soon")` — content diffing needs real file access | 🎭 |

Resolution rules the UI must respect:

- Advice never preselects a version row; the chip is spatially separate from the buttons.
- Resolving is **recording intent**, not acting: cards move to Resolved with "applies on next sync" phrasing; the next prepare/execute pair actually converges it (the planner consumes `resolvedConflicts`). The demo must show this loop: resolve → Sync Now → Activity shows the propagation → conflict fully closed. ✅
- No bulk "resolve all with advice" action exists — deliberate friction; per [../core/07-ai-conflict-advisor.md](../core/07-ai-conflict-advisor.md) advice cannot become a default.

## 3. Badges & deep links

- Sidebar Conflicts badge = open count (live). ✅
- Preview sheet conflict rows and activity entries with `relatedConflictID` deep-link here, scrolling to and briefly highlighting the card. ✅

## 4. Acceptance criteria

- Demo world opens with the `Budget.xlsx` conflict: two version rows (iCloud/Google), preserved-copy name from the real plan, heuristic advice with rationale and attribution.
- Choosing a version → Resolved tab entry → Sync Now on Documents → conflict propagates canonically (assert in bridge test via fake provider contents) and Activity logs it.
- Dismissing advice hides it for that conflict permanently (bridge remembers per conflict ID) and logs nothing to the engine — dismissal is a UI preference.
- VoiceOver: card reads as one summary ("Budget.xlsx, needs review, two versions"), then per-version actions.
