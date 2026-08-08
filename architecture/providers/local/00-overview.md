# 00 — Local Provider Overview (and Read-Side Spec)

`LocalFolderStorageProvider` 🆕 implements `StorageProvider` ✅ over Foundation's `FileManager` and URL resource keys. This document is normative for the provider's shape, capability declaration, availability, and scanning — the read side, milestone M2. Mutations and NAS specifics are sketched here and specified in 01/02 ⏭.

## 1. Shape

```swift
public actor LocalFolderStorageProvider: StorageProvider {
    /// Probes volume properties once through the seam (bounded by deadlines)
    /// and freezes the resulting capabilities for the instance's lifetime —
    /// `capabilities` is a synchronous protocol property, so all async
    /// probing happens here, never on the property.
    public static func make(
        location: SyncLocation,          // kind == .localFolder or .nasFolder
        rootURL: URL,                    // the selected folder; scopes resolve beneath it
        volumes: any VolumeInspecting,   // seam: mount state, reachability probes, volume properties
        deadlines: ProviderDeadlines     // injected timeouts; tests use synthetic clocks
    ) async -> LocalFolderStorageProvider
}
```

A failed or timed-out probe freezes the conservative value (`false`/`nil`), never blocks construction. Frozen capabilities can go stale (a different volume mounted beneath the same path); that is safe: availability checks gate every run, and a stale `hasNativeTrash == true` degrades at runtime by falling back to quarantine (§5) — the degradation direction is always preservation. Sessions construct a fresh provider per composition rather than mutating capabilities in place.

`VolumeInspecting` 🆕 is the testability seam — small by design, covering exactly the dangerous questions: *is the volume containing this URL mounted? does a bounded probe of it respond? what are its properties (case sensitivity, trash support, network-ness)? does this directory exist on it?* The real implementation answers via `URL.resourceValues` volume keys and bounded filesystem probes; test doubles script every answer. Everything else — enumeration, attribute reads, content I/O — uses `FileManager` directly.

## 2. Capability declaration (initial, conservative)

Per [../00-overview.md §2](../00-overview.md) rule 5, every `true` needs a conformance case proving it; when in doubt, degrade toward preservation.

| Capability | `.localFolder` | `.nasFolder` | Rationale |
| --- | --- | --- | --- |
| `hasNativeTrash` | probed at construction | `false` | Side-effect-free probe via the seam: `FileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: rootURL, create: false)` throwing ⇒ no native trash. Network mounts quarantine ([../../core/02-provider-abstraction.md §4](../../core/02-provider-abstraction.md)); a stale `true` falls back to quarantine at runtime |
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

## 5. Mutations, ownership, and trash

All blocking local side effects run through one provider-root `LocalMutationCoordinator`. Root-wide serialization is deliberately conservative: stores touch replacement directories, relocates touch source and destination trees, and trash touches both user paths and `/.aetherloom/` receipts. Narrow path locks would make ancestor/descendant and composite relocate overlap easy to get wrong.

The coordinator atomically claims queued work before invoking it and returns one of four semantic outcomes:

1. confirmed success;
2. confirmed failure;
3. deadline expired while queued, proving no side effect started; or
4. deadline expired after start, with a durable `ProviderMutationReceipt` and an indeterminate result.

For outcome 4, the blocking task and its eventual success/failure remain retained. Every mutation already queued behind it is invalidated as pre-start/no-side-effect; calls arriving during the recovery barrier are also rejected pre-start. Quiescence alone does not release the root. Ordinary availability, scans, current-state probes, and later mutations remain barred until engine recovery probes actual provider state, marks the journal reconciled, and explicitly releases the receipt. Only a fresh call authorized after new scans and replanning may then enter. After process restart no task result exists, so recovery atomically claims the journaled receipt as `unknownAfterRestart` and relies only on safe provider probes. Recovery never replays the old mutation.

If persisting the indeterminate journal event fails, the live provider still exposes its retained receipt. Recovery first writes that missing event, then performs the same quiescent probe and release sequence. Receipt matching uses ID, provider, kind, and ordered affected paths rather than the sub-millisecond `startedAt` value, which may be rounded by durable JSON. A process-wide registry shares one owner bundle (coordinator plus recovery artifacts) for every provider constructed with the same canonical root and configured enrollment volume identity. `LocationID` is not a key component. It also retains the configured root path as an alias: a broken enrolled symlink still finds its existing owner, while a new unresolved alias is refused if it could match another in-process root on that volume. A second provider or orchestrator therefore sees the exact live in-process barrier; a different root or expected volume identity receives a distinct owner. Entries remain strongly retained for the process lifetime so cleanup can never drop an active syscall or unresolved receipt.

Ordinary reads that authorize sync truth use writer-preferred coordinator leases. Existing admitted reads may overlap. Once a mutation queues, later availability, scan, construction-capability, and current-state reads fail closed; the mutation starts only after all underlying read work returns. The caller may receive a read timeout or cancellation first, but that does not release the physical lease. Recovery reads are exclusive and admitted only for the matching quiescent or atomically claimed restart receipt.

- `store` writes to a temporary URL **on the destination volume**, then `replaceItemAt` — an interrupted store never leaves a torn destination file. `OverwritePolicy` is enforced by probe-compare inside the provider's actor before the replace. Idempotent re-application per the conformance contract ([../00-overview.md §3](../00-overview.md)): `.neverOverwrite` against a destination holding byte-identical content (compare staged vs destination bytes) succeeds without writing and returns the current observation.
- `relocate` uses `moveItem` after confirming the destination path is absent; cross-device relocates are copy-verify-trash, never copy-delete.
- `trash`: native trash where `hasNativeTrash`, else quarantine to `/.aetherloom/trash/<ISO-8601 run date>/<relative path>` at the location root. If a native `trashItem` fails at runtime despite the frozen capability, fall back to quarantine — never fail into leaving content unpreserved when quarantine is possible.
- Trash receipts are written before native trash or quarantine movement and are part of the same owned operation. Existing receipt decoding remains unchanged.
- `fetch` copies content to the executor's staging URL through the same ownership coordinator; an indeterminate copy retains ownership of the temporary stage path until it finishes. On a placeholder it throws `placeholderOnly` ✅ rather than triggering a download (materialization policy belongs to the iCloud variant).
- The content stage keys late fetch temporary URLs and destination-store source pins by mutation receipt. Durable recovery releases them only after quiescence and journal reconciliation. A new stage owner removes only UUID-named `.tmp` files in its dedicated root left by a previous process, while preserving unrelated files and verified `.stage` cache entries.
- `currentState` re-reads one item's resource values; missing item at a healthy volume ⇒ `notFound`, anything doubtful ⇒ `unavailable` ([../../core/02-provider-abstraction.md §6](../../core/02-provider-abstraction.md)).

## 6. Blocking-I/O audit

| Operation | Deadline and ownership policy |
| --- | --- |
| Construction and capability probes | Read-only, deadline-bounded root lease; late work remains owned and blocks mutation admission until it returns. Enrollment identity discovery is separate because no configured root owner exists yet. |
| Availability and metadata probes | One compound owned read lease across mount, identity, responsiveness, directory/metadata, absence, and result construction. |
| Scan enumeration | One compound owned read lease across availability, enumeration, final validation, and snapshot construction; timeout is `.incomplete` while the late lease remains active. |
| Fetch copy and verification | One side-effecting owned mutation from source precondition through staging copy, byte verification, and final source check. |
| Store/replace and directory creation | Owned as one composite operation, including path checks, temporary copy, commit, and observation. |
| Same-volume relocate | Owned from source/destination validation through move and observation. |
| Cross-volume relocate | One owned composite copy → verify → source trash/quarantine operation; never nested coordinator work. |
| Native trash/quarantine and receipts | One owned composite operation; native move-then-throw is reconciled from receipt plus confirmed source absence, with no permanent-delete fallback. |

The enrollment identity read is the only local filesystem deadline helper outside an enrolled root owner: it cannot authorize sync or race a mutation for that not-yet-enrolled location. Every read used by an enrolled provider to authorize sync truth is retained by the root coordinator until physical completion. Any newly introduced local write, including metadata or staging writes, must route through the coordinator.

## 7. Open questions (resolve before or during the tasks that touch them)

1. **Stable IDs**: are APFS file IDs dependable across remounts for `hasStableItemIDs = true` on local volumes? Upgrade path: flag flip + conformance cases proving rename tracking. Until proven, `false`.
2. **mtime granularity on network filesystems**: SMB servers commonly truncate to 1–2 s. Does `ItemVersion` comparison need an explicit tolerance, or does size+mtime equality remain safe as-is? (Direction of error today: coarse mtimes make *fewer* `same` verdicts, which routes to preservation — acceptable, but noisy.) Belongs to 02 ⏭.
3. **Extended attributes, Finder tags, resource forks**: not preserved by the staging path today. Decide preserve-vs-document-loss before M4 ships a real sync.
4. **Packages** (`.app`, `.photoslibrary`): the core ADR excludes symlinks by default but is silent on packages. Treating a package as an ordinary folder tree is mechanically fine but semantically risky mid-edit. Needs a core-level decision; candidate: observe, exclude by default, visible warning — mirroring symlinks.
5. **Sandbox and security-scoped bookmarks**: the app is currently unsandboxed; real folder selection works with plain paths. Decide before M4 whether `WorkspaceEngineSession` persists security-scoped bookmarks now so later sandboxing needs no migration. Owned by 01-workspace-session.md ⏭ at the track level.
