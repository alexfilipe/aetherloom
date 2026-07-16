# 00 — Local Provider Overview (and Read-Side Spec)

`LocalFolderStorageProvider` 🆕 implements `StorageProvider` ✅ over Foundation's `FileManager` and URL resource keys. This document is normative for the provider's shape, capability declaration, availability, and scanning — the read side, milestone M2. Mutations and NAS specifics are sketched here and specified in 01/02 ⏭.

## 1. Shape

```swift
public actor LocalFolderStorageProvider: StorageProvider {
    public init(
        location: SyncLocation,          // kind == .localFolder or .nasFolder
        rootURL: URL,                    // the selected folder; scopes resolve beneath it
        volumes: any VolumeInspecting,   // seam: mount state, reachability probes, volume properties
        deadlines: ProviderDeadlines     // injected timeouts; tests use synthetic clocks
    )
}
```

`VolumeInspecting` 🆕 is the testability seam — small by design, covering exactly the dangerous questions: *is the volume containing this URL mounted? does a bounded probe of it respond? what are its properties (case sensitivity, trash support, network-ness)? does this directory exist on it?* The real implementation answers via `URL.resourceValues` volume keys and bounded filesystem probes; test doubles script every answer. Everything else — enumeration, attribute reads, content I/O — uses `FileManager` directly.

## 2. Capability declaration (initial, conservative)

Per [../00-overview.md §2](../00-overview.md) rule 5, every `true` needs a conformance case proving it; when in doubt, degrade toward preservation.

| Capability | `.localFolder` | `.nasFolder` | Rationale |
| --- | --- | --- | --- |
| `hasNativeTrash` | probed per volume | `false` | `FileManager.trashItem` works on local volumes that support it; network mounts quarantine ([../../core/02-provider-abstraction.md §4](../../core/02-provider-abstraction.md)) |
| `hasStableItemIDs` | `false` initially | `false` | File IDs exist (`fileResourceIdentifier`) but their persistence across remounts/reboots is unproven; path identity degrades renames safely. Upgrading later is a flag flip plus conformance cases — see open questions |
| `hasContentHashes` | `false` | `false` | No cheap hash at scan time; hashes are computed during staging for transfer verification only. Same-size/same-mtime independent edits route to preservation, as designed |
| `hasChangeHints` | `false` | `false` | Full scans; FSEvents is a later optimization ([../00-overview.md §6](../00-overview.md)). `changedSubtrees` returns a hint marked not complete |
| `supportsVersionCheckedStore` | `false` | `false` | The filesystem has no compare-and-swap write; the executor's emulation (probe → compare → store) applies ([../../core/02-provider-abstraction.md §3](../../core/02-provider-abstraction.md)) |
| `isCaseSensitive` | from volume key | `nil` | `nil` assumes insensitive — detects more collisions, which is the safe direction |

## 3. Availability

`checkAvailability()` is cheap, side-effect-free, and runs every question through `volumes` under `deadlines`. Normative order:

1. **Volume mounted?** The volume containing `rootURL` is absent from the mounted set ⇒ `unavailable(.volumeNotMounted)`. This covers unplugged external disks and unmounted shares.
2. **Volume responsive?** A bounded probe (deadline from `deadlines`) hangs or times out ⇒ `unavailable(.volumeUnreachable)`. This is the sleeping-NAS case; a mounted-but-hanging share must never proceed to a scan that would hang the run.
3. **Scope root present?** The volume is mounted and responsive but `rootURL` does not exist ⇒ `unavailable(.scopeMissing)` — surfaced for review, never deletion-inference (invariant 2).
4. **Root readable?** Present but unreadable (permissions, sandbox denial) ⇒ `unavailable(.unknown(detail:))` with the underlying error's description.
5. Otherwise `available`.

The ordering matters: a missing root must be classified as *volume gone* before it can be classified as *scope missing*, because the two produce different user guidance and only `scopeMissing` implies a healthy backend.

## 4. Scanning

`scan(_:)` enumerates the scope with `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`, prefetching: `isDirectoryKey`, `fileSizeKey`, `contentModificationDateKey`, `isSymbolicLinkKey`, `isUbiquitousItemKey`, `ubiquitousItemDownloadingStatusKey`. Normative:

- **Availability is re-checked first.** A scan against an unavailable location returns `status: .unavailable(reason)` with no observations — it never enumerates.
- **Any enumeration error ⇒ `.incomplete(reason:)`.** The error handler records the failure and the scan finishes with whatever it has, marked incomplete; the engine refuses to plan on it ✅. A `.complete` status is the proof obligation "I visited everything" — one unreadable subdirectory voids it.
- **The whole scan runs under a deadline.** Expiry ⇒ `.incomplete` (volume was responsive at check time) — never a truncated `.complete`.
- **Observations:** files and folders map to `ItemObservation` with `version = ItemVersion(size:modifiedAt:)`; no `contentHash`, no `itemID` (per §2); symlinks map to `ItemKind.symlink(target:)` and are excluded from propagation by the engine's built-in exclusions ✅.
- **Dataless files are placeholders, defensively.** Any item whose resource values say it is ubiquitous-and-not-downloaded observes with `isPlaceholder = true` — even though iCloud scopes are a later milestone, a user can select a folder that contains evicted iCloud items today, and a placeholder must never look absent or edited (invariant 2). The provider never triggers materialization during a scan.
- **Name normalization:** paths are carried as observed; Unicode normalization differences (NFC/NFD) are the reconciler's concern via `SyncPath` semantics, not silently rewritten by the provider.
- **`/.aetherloom/` is never reported.** It is the provider's own quarantine/metadata space and a built-in exclusion ✅.

## 5. Mutations and trash (sketch — normative spec in 01 ⏭)

- `store` writes to a temporary URL **on the destination volume**, then `replaceItemAt` — an interrupted store never leaves a torn destination file. `OverwritePolicy` is enforced by probe-compare inside the provider's actor before the replace.
- `relocate` uses `moveItem` after confirming the destination path is absent; cross-device relocates are copy-verify-trash, never copy-delete.
- `trash`: native trash where `hasNativeTrash`, else quarantine to `/.aetherloom/trash/<ISO-8601 run date>/<relative path>` at the location root.
- `fetch` copies content to the executor's staging URL; on a placeholder it throws `placeholderOnly` ✅ rather than triggering a download (materialization policy belongs to the iCloud variant).
- `currentState` re-reads one item's resource values; missing item at a healthy volume ⇒ `notFound`, anything doubtful ⇒ `unavailable` ([../../core/02-provider-abstraction.md §6](../../core/02-provider-abstraction.md)).

## 6. Open questions (resolve before or during the tasks that touch them)

1. **Stable IDs**: are APFS file IDs dependable across remounts for `hasStableItemIDs = true` on local volumes? Upgrade path: flag flip + conformance cases proving rename tracking. Until proven, `false`.
2. **mtime granularity on network filesystems**: SMB servers commonly truncate to 1–2 s. Does `ItemVersion` comparison need an explicit tolerance, or does size+mtime equality remain safe as-is? (Direction of error today: coarse mtimes make *fewer* `same` verdicts, which routes to preservation — acceptable, but noisy.) Belongs to 02 ⏭.
3. **Extended attributes, Finder tags, resource forks**: not preserved by the staging path today. Decide preserve-vs-document-loss before M4 ships a real sync.
4. **Packages** (`.app`, `.photoslibrary`): the core ADR excludes symlinks by default but is silent on packages. Treating a package as an ordinary folder tree is mechanically fine but semantically risky mid-edit. Needs a core-level decision; candidate: observe, exclude by default, visible warning — mirroring symlinks.
5. **Sandbox and security-scoped bookmarks**: the app is currently unsandboxed; real folder selection works with plain paths. Decide before M4 whether `WorkspaceEngineSession` persists security-scoped bookmarks now so later sandboxing needs no migration. Owned by 01-workspace-session.md ⏭ at the track level.
