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

## 4. Mutation and recovery checks

Positive scan evidence is necessary but not sufficient because reality can change after preview. Immediately before any local provider mutation affecting a path, the provider/executor boundary MUST re-check that the source, destination, synchronized ancestors below the selected root, and item being displaced have not become a package or acquired unsupported metadata. Root container metadata remains outside synchronized content. A newly detected condition stops the run for fresh planning and performs no mutation at that path.

Recovery truth probes use the same classification. An excluded path cannot be accepted as a successfully applied ordinary mutation or used to advance a base record. Ambiguous metadata truth leaves the journal unresolved and fails closed.

## 5. Fidelity claim and future upgrade

UI and documentation MUST say the item is excluded because Aetherloom cannot yet preserve that package or metadata safely. They MUST NOT say the item was synchronized, backed up, copied completely, or preserved.

Replacing exclusion with synchronization requires a later architecture decision, provider conformance cases, file/directory/package round-trip tests, interruption and conflict tests, and exact-head macOS evidence proving data-fork, metadata, extended-attribute, FinderInfo/tag, resource-fork, permissions/ACL, and recovery fidelity for the newly supported scope. This MVP does not authorize that work.
