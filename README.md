# Aetherloom

Keep your clouds interwoven.

Aetherloom is a native macOS app for keeping selected folders synchronized across iCloud Drive, Google Drive, OneDrive, local folders, and NAS-backed folders.

It is designed for people who use more than one cloud storage provider, local disk location, or network-attached storage location and want their important files to stay aligned across them.

## What it does

Aetherloom lets you choose folders, or eventually whole drives, and keep them synchronized across cloud services, local filesystem locations, and NAS-mounted folders.

Supported target categories should include:

- Cloud folders and drives, starting with iCloud Drive, Google Drive, and OneDrive
- Local folders on the Mac
- NAS-backed folders mounted through SMB, AFP, NFS, or other macOS-supported network filesystems

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
- Avoid treating unmounted, sleeping, or temporarily unreachable NAS locations as deletions
- Avoid treating disconnected local volumes as deletions
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
- Local folder support
- NAS-backed folder support
- iCloud Drive folder support
- Google Drive support
- OneDrive support

## Local and NAS-backed folders

Local folders and NAS-backed folders should be treated as first-class sync locations, not as an afterthought.

For local folders, Aetherloom should use native macOS folder selection, security-scoped access where needed, filesystem metadata, and safe local writes.

For NAS-backed folders, Aetherloom should be especially conservative. A mounted network share can disappear because the Mac slept, the network changed, credentials expired, or the NAS is temporarily unavailable. Aetherloom must treat those states as provider unavailability, not as file deletion.

Deletes in local or NAS-backed folders should still follow the same safety philosophy: prefer trash when available, preserve conflicts, verify destination state before overwriting, and pause when the folder or volume state is uncertain.

## iCloud Drive note

iCloud Drive does not provide the same kind of general-purpose cloud file API as Google Drive or OneDrive.

Aetherloom’s iCloud Drive support is expected to work through the local iCloud Drive folder on macOS.

## Not a backup replacement

Aetherloom is a synchronization app, not a full backup system.

You should still keep an independent backup of important files.

## License

License not chosen yet.
