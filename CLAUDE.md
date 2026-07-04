# Aetherloom Agent Instructions

Aetherloom is a native macOS app for keeping selected folders, or eventually whole drives, synchronized across iCloud Drive, Google Drive, OneDrive, local folders, and NAS-backed folders.

The project prioritizes reliability, data preservation, testability, and a polished native Mac experience.

## Core principles

- Prioritize user data safety over speed, convenience, or feature breadth.
- Never permanently delete files during normal sync.
- Deletes must use provider trash/recycle-bin behavior where possible.
- Never infer deletion from provider outages, authentication failures, network failures, incomplete scans, or inaccessible iCloud folders.
- Never infer deletion from iCloud placeholder or unavailable local files.
- Never infer deletion from unmounted, sleeping, disconnected, or temporarily unreachable local or NAS-backed volumes.
- Never silently overwrite independently edited files.
- Preserve conflicting versions with conflict copies.
- Pause and require review for suspicious mass changes.
- Prefer pausing too often over risking user data.

## Architecture

- Keep sync logic in `AetherloomCore`.
- Keep SwiftUI app/UI code in the app target.
- Do not put sync rules directly in SwiftUI views.
- Build provider-independent logic before provider-specific integrations.
- Use fake providers for planner and safety tests.
- Treat local folders and NAS-backed folders as first-class provider targets in the architecture.
- Model unavailable local volumes and unreachable NAS mounts as provider unavailability, not deletion.
- Real Google Drive, OneDrive, and iCloud integrations should be added only after the core sync engine is well tested.

Expected structure:

```text
Aetherloom/
  AetherloomApp/
  AetherloomCore/
  AetherloomCoreTests/
```

## Development order

When starting new implementation work, prefer this order:

1. Core models
2. Fake providers
3. Sync planner
4. Safety analyzer
5. Conflict resolver
6. Unit tests
7. Minimal SwiftUI shell
8. Local filesystem provider
9. NAS-backed folder support through mounted macOS network filesystems
10. SQLite metadata
11. iCloud Drive local-folder support
12. OneDrive integration
13. Google Drive integration
14. Background sync

Do not start with OAuth, background sync, menu bar agents, App Store sandboxing, or cloud-provider integrations unless explicitly asked.

## Testing

Use Swift Testing for `AetherloomCore` where practical.

Core tests should cover:

- create propagation
- edit propagation
- folder propagation
- rename propagation
- move propagation
- delete-to-trash propagation
- independent edit conflicts
- mass delete pause
- mass edit pause
- provider unavailable does not delete
- incomplete scan does not delete
- iCloud placeholder does not delete
- disconnected local volume does not delete
- unavailable NAS mount does not delete
- destination changed after planning stops execution
- idempotent re-runs
- conflict filenames preserve extensions
- Unicode filenames
- case-insensitive filename collisions
- zero-byte files
- empty folders
- excluded files

Real cloud-provider tests must be opt-in only and must never run against a user’s real cloud root by default.

Local and NAS-backed provider tests must also be conservative: do not run destructive tests against a user-selected real folder or mounted share by default. Prefer temporary directories and fake mount/unavailable states.

## UI expectations

Aetherloom should feel like a beautiful, trustworthy native Mac app.

The UI should help users understand:

- which services are connected
- which folders or drives are selected
- what will sync
- what changed
- what is risky
- what is paused
- what needs review

Use calm, clear language.

Preferred wording:

- “Preview changes”
- “Move to trash”
- “Needs review”
- “Paused for safety”
- “Both versions preserved”
- “Provider unavailable”

Avoid making the app feel like a raw admin dashboard.

## Safety language

When a provider is unavailable, the app should communicate:

> Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.

When many deletions are detected:

> Aetherloom found many deletions. This may be intentional, but sync is paused until you review it.

When a conflict is found:

> This file changed in more than one place. Aetherloom preserved both versions.

## Code quality

- Keep code modular and testable.
- Prefer small, focused types.
- Avoid large view models that contain sync logic.
- Prefer pure planner logic where possible.
- Use clear names over clever abstractions.
- Do not introduce real network dependencies into core tests.
- Do not commit secrets, tokens, test credentials, or `.env` files.

## Validation

After code changes, run the relevant tests when possible.

Prefer at least:

```bash
swift test --package-path AetherloomCore
```

If the Xcode project exists and the scheme is configured, also prefer:

```bash
xcodebuild -project Aetherloom.xcodeproj -scheme Aetherloom -destination 'platform=macOS' build
```

## Browser QA policy

Do not open or use the browser for visual QA after every change.

For small, targeted changes, especially copy, CSS, typography, spacing, metadata, or static HTML edits:

- make the requested change

- run only lightweight validation if appropriate

- summarize what changed

- do not launch the browser unless explicitly asked

Use browser QA only when:

- I explicitly ask for visual QA

- the change affects layout, responsive behavior, interactions, screenshots, animations, or JavaScript behavior

- you need to debug a visual issue that cannot be verified from the code

- the change is large enough that visual regression risk is meaningful

When browser QA is not performed, say:

"Browser QA skipped per project instructions."

Never spend extra time taking screenshots or checking the page visually for tiny CSS/copy-only edits unless I request it.
