# 01 — Package and macOS Metadata Safety (Local MVP)

This is the normative local-provider fidelity boundary for the Local Workspace MVP. It resolves the package, extended-attribute, Finder metadata, and resource-fork questions left open in [00-overview.md](00-overview.md). The MVP synchronizes ordinary file data and directory structure. It does **not** claim round-trip fidelity for unsupported macOS metadata.

## 1. Positive scan exclusions

A complete local scan MUST report unsupported content as typed positive evidence, not omit it. `LocationSnapshot` therefore needs an exclusion collection equivalent to:

```swift
public struct ScanExclusion: Codable, Hashable, Sendable {
    public var path: SyncPath
    public var scope: Scope              // item | subtree
    public var reason: Reason

    public enum Scope: Codable, Hashable, Sendable { case item, subtree }
    public enum Reason: Codable, Hashable, Sendable {
        case packageDirectory
        case unsupportedMetadata(Set<MetadataKind>)
        case unsupportedPOSIXPermissions(actual: UInt16, required: UInt16)
        case accessControlList
        case unsupportedOwnership
    }
}

public enum MetadataKind: Codable, Hashable, Sendable {
    case extendedAttributes
    case finderTags
    case finderInfo
    case resourceFork
}
```

Names may change during implementation, but the semantics may not. An exclusion proves **present but unsupported** at a path. It is neither absence nor an ordinary observation. Duplicate reasons SHOULD be normalized into one stable exclusion per root path.

Planner/reconciler treatment is exclusion/waiting, not deletion: the path or subtree MUST NOT be transferred, base-recorded, overwritten, relocated, trashed, or described as converged. If an existing base record's path becomes excluded, its prior memory remains and the decision becomes visible waiting/excluded. It MUST never become a deletion candidate.

An exclusion at any location blocks mutations for the affected path or subtree at **all** locations. This prevents a supported-looking copy elsewhere from overwriting, deleting, or falsely converging content whose full truth is unsupported on one side. An approval cannot override an exclusion. A future scan that positively proves the exclusion is gone may return the scope to ordinary reconciliation; prior base memory is then evaluated against fresh truth.

Every exclusion MUST appear in preview and activity with its sync-relative path and a stable human-readable reason. A run containing exclusions MUST NOT use an all-synced/success presentation for the affected scope.

## 2. macOS package directories

The provider MUST request and inspect [`URLResourceKey.isPackageKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/ispackagekey) for the selected root and every enumerated directory.

- A selected root whose `isPackage` value is `true` is rejected during enrollment. No location or sync set is created.
- An encountered package is emitted as `.packageDirectory` with subtree scope.
- The enumerator MUST NOT descend into it.
- The provider, planner, and executor MUST NOT transfer, base-record, overwrite, relocate, or trash the package or any descendant in the MVP.
- A previously tracked ordinary directory that becomes a package is exclusion/waiting, never missing or deleted.

Package extensions or filename heuristics are insufficient. If the package resource value cannot be read reliably, the scan is incomplete or unavailable; it is not permission to descend.

## 3. Unsupported metadata and resource forks

Ordinary file data bytes and directory structure are supported. Before emitting an ordinary observation, the provider MUST inspect enough filesystem metadata to detect:

- any unsupported extended attribute;
- Finder tags;
- nonempty FinderInfo;
- a nonempty resource fork; and
- inability to determine whether any of the above is present.

Finder tags and FinderInfo are called out explicitly even when represented through extended attributes so preview/activity can name the reason users recognize. A file with any listed metadata is an item-scoped `.unsupportedMetadata` exclusion. A directory with any listed metadata is a subtree-scoped exclusion and MUST NOT be descended into, because propagating descendants while omitting container semantics would misrepresent the tree.

If metadata enumeration or resource-fork probing fails, the scan is incomplete; the provider MUST NOT silently emit an ordinary observation. Empty resource forks are not exclusions. The selected root's own metadata is container metadata outside synchronized content: it is inspected only as needed for access/package enrollment safety, is not transferred, and does not exclude otherwise supported descendants.

Apple's File Provider contract exposes extended attributes as explicit item state rather than ordinary data-fork bytes; see [`NSFileProviderItemProtocol.extendedAttributes`](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/extendedattributes). Apple's [`copyfile(3)` documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/copyfile.3.html) separately models data, metadata, extended attributes, ACLs, and resource forks. Aetherloom's current staging path has not proven that broader round trip, so the MVP MUST exclude rather than claim preservation.

## 4. POSIX permissions, ACLs, and ownership

The MVP supports one explicit baseline rather than claiming general Unix metadata fidelity:

- a regular file MUST have exactly `0644` permission bits; and
- a directory MUST have exactly `0755` permission bits.

Any deviation from those exact baselines—including an executable bit on a regular file or any setuid/setgid/sticky bit—is an `.unsupportedPOSIXPermissions` exclusion. Any access control list is an `.accessControlList` exclusion. A file exclusion is item-scoped; a directory exclusion is subtree-scoped and the provider MUST NOT descend into it. Inability to read mode or ACL state makes the scan incomplete rather than supported.

User and group ownership are not synchronized from a source item. The supported baseline is ownership by the process's effective user ID and effective primary group ID at both source and destination. Any other ownership is `.unsupportedOwnership` (item or subtree as above); inability to prove ownership fails closed. Provider-created files and directories MUST be created and post-write verified with the exact `0644`/`0755` mode and baseline ownership. A failure to establish or verify that baseline is a failed/refused operation, never convergence. The selected root's mode, ACL, and ownership remain container metadata outside synchronized content.

This baseline makes ordinary user-owned files usable without implying preservation of arbitrary permissions, ACLs, owners, or groups. General permission/ownership preservation remains outside L2.

## 5. All-location preflight, adjacent checks, and recovery

After preview and confirmation, but before the operation schedule's **first provider mutation**, execution MUST acquire live folder access and run one fail-closed classification preflight for every affected item or subtree at every participating location. “Affected” includes each operation's source, destination, item that may be displaced, and synchronized ancestors below the selected root. The classification covers packages, extended attributes, Finder tags/FinderInfo, resource forks, POSIX modes/special bits, ACLs, and ownership.

The entire preflight completes before any mutation is admitted. A new exclusion at any participating location, an unavailable location, or any ambiguous/failed classification aborts the entire schedule with zero mutations at every location and requires a fresh prepare and preview. Confirmation never overrides this result.

Mutation-adjacent provider checks remain mandatory defense in depth after the preflight. Immediately before each physical commit, the provider MUST re-check the applicable classification and ordinary version/absence preconditions. Drift arising after the all-location barrier stops the run; it never authorizes an overwrite or trash. Root container metadata remains outside synchronized content.

Recovery uses the same all-location, live-access classification rule before it accepts convergence, releases receipt-bound artifacts/barriers, or permits any new schedule mutation. An excluded path cannot be accepted as a successfully applied ordinary mutation or used to advance a base record. Any new exclusion, unavailable location, or ambiguous package/metadata/permissions/ACL/ownership truth leaves the journal unresolved and fails closed; recovery never replays the old schedule.

## 6. Fidelity claim and future upgrade

UI and documentation MUST say the item is excluded because Aetherloom cannot yet preserve that package or metadata safely. They MUST NOT say the item was synchronized, backed up, copied completely, or preserved.

Replacing exclusion with synchronization requires a later architecture decision, provider conformance cases, file/directory/package round-trip tests, interruption and conflict tests, and exact-head macOS evidence proving data-fork, metadata, extended-attribute, FinderInfo/tag, resource-fork, permissions/ACL, and recovery fidelity for the newly supported scope. This MVP does not authorize that work.
