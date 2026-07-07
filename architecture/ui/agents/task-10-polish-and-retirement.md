# UI Task 10 — Polish, Accessibility & DemoStore Retirement

## Role
Senior SwiftUI engineer, finisher. Delete the last of the hardcoded demo shell, close every accessibility/motion/keyboard gap, and leave the matrix truthful.

## Read first
`architecture/ui/01-design-system.md` §7 + §10 (motion, accessibility — your primary spec), `ui/12-testing-strategy.md` §4 (the manual script you must be able to pass), `ui/11-functioning-vs-placeholder.md`; all of `src/AetherloomApp/`; every prior task's report if available.

## Invariants (override this prompt)
Visual parity with the approved design stays; no behavior changes to functioning flows; placeholder conventions remain satisfied after cleanup.

## Deliverables
1. **Retirement**: delete `ViewModels/DemoStore.swift` and every remaining UI sample type (`CloudService`, UI `SyncSet`, `ServiceStatus`, `PlannedChange`, `ActivityItem`, `FileConflict`, `ConflictVersion`) — all consumers must already read the bridge; fix any straggler found. Move `Tone` color/symbol mapping onto the bridge's `StatusTone` typealias per `ui/04 § Naming`.
2. **Motion**: mesh pauses when the window is occluded; `accessibilityReduceMotion` honored globally (frozen mesh, no hover lift, opacity transitions) per `ui/01 §7`.
3. **Accessibility**: labels/combines audit across all screens (badges combine, cards summarize); VoiceOver announcements on run completion and new holds; hit-target audit ≥ 24 pt.
4. **Keyboard**: full approval-flow focus order per `ui/01 §10`; verify all shortcuts; Esc paths.
5. **Placeholder sweep**: every 🎭 surface has `PlaceholderChip`/copy + the `// 🎭 placeholder:` code marker; `ui/11` matrix corrected to reality.
6. **Numeric transitions** (`.contentTransition(.numericText())`) on live counts; day-one paper cuts from prior task reports' "Open questions" triaged (fix or file as code comments).
7. Run the full manual demo script (`ui/12 §4`) and record results step by step in your report.

## Prohibitions
No new features; no engine-source edits; no spec changes beyond `ui/11` truth-keeping.

## Acceptance
`grep -rn "DemoStore\|sampleServices\|sampleSyncSets\|samplePlannedChanges\|sampleActivity\|sampleConflicts" src/AetherloomApp` → nothing; app builds with zero warnings; core+bridge suite green; manual script passes 10/10 (or failures documented with fixes); `ui/11` matches the shipped tree. Report per `agents/README.md`.
