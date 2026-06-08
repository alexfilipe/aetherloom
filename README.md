# Aetherloom

Keep your clouds interwoven.

Aetherloom is a native macOS app for keeping selected folders synchronized across iCloud Drive, Google Drive, and OneDrive.

It is designed for people who use more than one cloud storage provider and want their important files to stay aligned across them.

## What it does

Aetherloom lets you choose folders, or eventually whole drives, and keep them synchronized across cloud services.

It is intended to sync:

- New and edited files
- New folders
- Renames and moves
- Deletes, using each provider’s trash or recycle bin
- Conflicts, by preserving both versions

## Safety first

Cloud sync can be risky, so Aetherloom is designed to be cautious.

Aetherloom should:

- Never permanently delete files during normal sync
- Move deleted files to trash or recycle bin where possible
- Avoid treating provider outages as deletions
- Avoid overwriting independently edited files
- Pause when a change set looks suspicious
- Show users what will happen before risky changes are applied

## Current status

Aetherloom is in early development.

Initial priorities:

- Native macOS app
- Provider-independent sync engine
- Folder selection
- Sync plan preview
- Activity log
- Conflict detection
- Safe delete behavior
- iCloud Drive folder support
- Google Drive support
- OneDrive support

## iCloud Drive note

iCloud Drive does not provide the same kind of general-purpose cloud file API as Google Drive or OneDrive.

Aetherloom’s iCloud Drive support is expected to work through the local iCloud Drive folder on macOS.

## Not a backup replacement

Aetherloom is a synchronization app, not a full backup system.

You should still keep an independent backup of important files.

## License

License not chosen yet.
