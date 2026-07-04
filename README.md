<p align="center">
  <img src="Design/AetherloomAMark-transparent-tight.png" width="140" alt="Aetherloom app icon" />
</p>

<h1 align="center">Aetherloom</h1>

<p align="center"><b>Every drive, one weave.</b></p>

<p align="center">
  A native macOS app that keeps the same folders synchronized across iCloud Drive, Google Drive,
  OneDrive, local folders, and NAS-backed drives.
</p>

<p align="center">
  Every location holds a full copy, so losing access to one never means losing your files.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform: macOS" />
  <img src="https://img.shields.io/badge/swift-6.3-orange" alt="Swift 6.3" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI" />
</p>

<p align="center">
  <a href="https://aetherloom.app">aetherloom.app</a>
</p>

---

## Why Aetherloom

Files that live in only one place are one failure away from being out of reach: a locked account, an expired subscription, a dead disk, a provider outage, or just a service you decide to leave. If you already use more than one cloud, plus a Mac and maybe a NAS, you have everything you need to be resilient against all of that. Keeping the copies aligned by hand is the tedious, error-prone part.

Aetherloom weaves your storage locations together so the same folders exist, complete and current, in every place you choose:

- **Lose access to one, keep everything.** Every location holds a full copy, so no single provider, account, or disk ever holds the only one.
- **Own your copies.** A synced folder on your Mac or NAS is plain files on hardware you control. They stay readable with or without Aetherloom, no export required.
- **Sync across clouds.** Keep a folder identical in iCloud Drive, Google Drive, and OneDrive at the same time.
- **Bring the NAS in.** Folders on SMB/AFP/NFS mounts are first-class sync targets, not an afterthought.
- **See before it happens.** Every sync is planned first, and you can preview exactly what will change.

## Safety first

Redundancy only protects you if sync itself never destroys data. A sync engine that propagates a mistake to every copy makes things worse, not safer. Cloud sync tools have a long history of eating files; Aetherloom is built around the opposite bias: **when in doubt, pause and preserve.**

- Files are **never permanently deleted** during normal sync. Deletes go to each provider's trash or recycle bin.
- A provider outage, expired login, network failure, or incomplete scan is **never** treated as "the user deleted everything."
- An unmounted or sleeping NAS volume, a disconnected external disk, or an iCloud placeholder file is treated as *unavailable*, never as *deleted*.
- Files edited independently in two places are **never silently overwritten**. Both versions are preserved as conflict copies.
- Suspicious mass deletions or mass edits **pause sync** until you review them.
- If a destination changed after a sync was planned, execution stops rather than acting on stale information.

The app speaks the same language:

> Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable.

> Aetherloom found many deletions. This may be intentional, but sync is paused until you review it.

> This file changed in more than one place. Aetherloom preserved both versions.

## What it syncs

- New and edited files
- New folders
- Renames and moves
- Deletes (via provider trash / recycle bin)
- Conflicts (both versions kept)

Supported location types (planned): iCloud Drive (through its local folder on macOS), Google Drive, OneDrive, local folders, and NAS-backed folders mounted through macOS network filesystems.

## Status

Aetherloom is in **early development**. The project website is live at [aetherloom.app](https://aetherloom.app).

| Area | State |
| --- | --- |
| Core sync engine (models, planner, safety analyzer, conflict resolver, executor) | ✅ Implemented |
| Safety test suite | 🔜 Planned |
| SwiftUI app shell (overview, sync sets, activity, conflicts, preview sheet) | ✅ Demo UI with placeholder data |
| Local folder provider | 🔜 Next up |
| NAS-backed folder support | 🔜 Planned |
| SQLite metadata store | 🔜 Planned |
| iCloud Drive (local folder) support | 🔜 Planned |
| OneDrive / Google Drive integrations | 🔜 After the core engine is proven |
| Background sync | 🔜 Later |

Real cloud integrations are deliberately last: the provider-independent engine is developed and hardened against fake providers first, so the safety rules are proven before any real files are touched.

## Architecture

```text
Aetherloom/
  AetherloomApp/        SwiftUI macOS app (UI only, no sync rules in views)
  AetherloomCore/       Swift package with all sync logic
    Sources/AetherloomCore/
      Models/           Core value types
      Providers/        Provider protocol + fake providers for testing
      Planning/         Sync planner and conflict resolver
      Safety/           Safety analyzer (mass-change pauses, unavailability rules)
      Execution/        Plan executor
      Logging/          Activity log
      Storage/          Metadata storage
    Tests/              Planned Swift Testing suite
```

Design rules:

- All sync logic lives in `AetherloomCore`; the app target is UI only.
- Provider-independent logic comes before provider-specific integrations.
- Unavailable volumes and unreachable mounts are modeled as *provider unavailability*, never as deletion.
- Core tests never touch the network or real user data.

## Building

Requirements: Xcode 26+ on macOS.

Build and run the app:

```bash
cd AetherloomApp
xcodebuild -project AetherloomApp.xcodeproj -scheme AetherloomApp -destination 'platform=macOS' build
```

Or open `AetherloomApp/AetherloomApp.xcodeproj` in Xcode and hit Run.

## Testing

Tests are planned for the core sync engine. Once the suite exists, run:

```bash
swift test --package-path AetherloomCore
```

The suite should cover create/edit/rename/move/delete propagation plus the safety cases that matter most: mass-delete and mass-edit pauses, provider-unavailable-never-deletes, iCloud placeholders, disconnected volumes and NAS mounts, incomplete scans, conflict preservation, idempotent re-runs, Unicode and case-insensitive filenames, zero-byte files, empty folders, and exclusions.

Any future tests against real providers are opt-in only and never run against a user's real cloud root or a real mounted share by default.

## Not a backup replacement

Aetherloom keeps redundant, synchronized copies of your files across locations, which is great resilience against a single provider or disk failing. It is not a versioned backup system, though: deletions and edits propagate. Keep an independent backup (e.g. Time Machine or an offline archive) of anything you can't lose.

## Contributing

The project is young and the ground rules are simple:

- Data safety beats speed, convenience, and feature breadth, always.
- Sync logic goes in `AetherloomCore` with tests, never in SwiftUI views.
- New sync behavior needs planner/safety tests against the fake providers.
- Run `swift test --package-path AetherloomCore` before submitting changes.

## Contact

For questions, feedback, or anything that should not be a GitHub issue, email [hello@aetherloom.app](mailto:hello@aetherloom.app).

## License

A license has not been chosen yet.
