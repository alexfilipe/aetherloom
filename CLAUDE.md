# Aetherloom Agent Instructions

Aetherloom is a native macOS app for keeping selected folders, or eventually whole drives, synchronized across iCloud Drive, Google Drive, and OneDrive.

The project prioritizes reliability, data preservation, testability, and a polished native Mac experience.

## Core principles

- Prioritize user data safety over speed, convenience, or feature breadth.
- Never permanently delete files during normal sync.
- Deletes must use provider trash/recycle-bin behavior where possible.
- Never infer deletion from provider outages, authentication failures, network failures, incomplete scans, or inaccessible iCloud folders.
- Never infer deletion from iCloud placeholder or unavailable local files.
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
9. SQLite metadata
10. iCloud Drive local-folder support
11. OneDrive integration
12. Google Drive integration
13. Background sync

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
- destination changed after planning stops execution
- idempotent re-runs
- conflict filenames preserve extensions
- Unicode filenames
- case-insensitive filename collisions
- zero-byte files
- empty folders
- excluded files

Real cloud-provider tests must be opt-in only and must never run against a user’s real cloud root by default.

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
