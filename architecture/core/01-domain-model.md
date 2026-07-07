# 01 — Domain Model

The vocabulary, designed clean. Sections marked *(current)* note what exists in `Models/CoreModels.swift` today; the full mapping is in [11-migration.md](11-migration.md).

## 1. Identity of places

```swift
/// What kind of storage backs a location. Used for display, capability
/// defaults, and provider construction ONLY — engine logic never branches on it.
public enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case localFolder, nasFolder, iCloudDrive, googleDrive, oneDrive, dropbox
}

/// Stable identity of ONE configured endpoint (an account+scope, a folder, a mount).
/// Minted when the user adds the location; survives renames and re-auth.
public struct LocationID: RawRepresentable, Codable, Hashable, Sendable { public var rawValue: UUID }

public struct SyncLocation: Codable, Hashable, Sendable, Identifiable {
    public var id: LocationID
    public var kind: ProviderKind
    public var displayName: String          // "Google Drive (alex@…)", "Media NAS" — embedded in conflict-copy names and log lines
    public var scope: SyncScope             // .selectedFolder(path:) | .entireDrive   (current ✅)
    public var configuration: [String: String]  // opaque provider config; never credentials
}
```

*(current)* `ProviderID` is a closed enum of three cloud services — no local, no NAS, no second account of anything. It is deleted, not deprecated: nothing outside the package consumes it yet.

## 2. Identity of things

```swift
/// Sync-set-relative path. Normalized ("/a/b", no trailing slash, NFC),
/// with parent/name/extension helpers and a case- and diacritic-folded
/// collision key. NEVER an absolute filesystem path.
public struct SyncPath: Codable, Hashable, Sendable, Comparable { … }   // (current ✅ as CloudPath — rename, keep logic)

public enum ItemKind: Codable, Hashable, Sendable {
    case file
    case folder
    case symlink(target: String)   // observed, reported, excluded from propagation by default
}
```

**Item identity across runs** = provider-native item ID when the provider has one (`hasStableItemIDs`), else canonical path. That ordering is what makes rename/move detection work; providers without stable IDs degrade to "delete+create", which is safe (create propagates; "delete" needs a base record and a healthy scan, and content-hash matching can upgrade it back to a move — [03 §5](03-reconciliation.md)).

## 3. Versions and observations — the split the current model needs

Today's `CloudItem` mixes *where something is*, *what it is*, and *which version it is* into one bag that gets embedded in actions and compared field-by-field in three different places. Split it:

```swift
/// WHICH version of content this is. The only thing comparison logic sees.
public struct ItemVersion: Codable, Hashable, Sendable {
    public var contentHash: String?      // provider hash or engine-computed
    public var size: Int64?
    public var modifiedAt: Date?
    public var revisionToken: String?    // provider-native (revision ID, eTag, cTag, …)
}

extension ItemVersion {
    /// hash ⇒ size+mtime ⇒ revisionToken, in that order.
    /// Two versions with NO comparable field in common are `unknown`,
    /// and unknown NEVER equals anything — ambiguity routes to preservation.
    public func comparison(to other: ItemVersion) -> VersionComparison  // same | different | unknown
}

/// What one scan saw for one item at one location. Pure data.
public struct ItemObservation: Codable, Hashable, Sendable {
    public var location: LocationID
    public var itemID: String?
    public var path: SyncPath
    public var kind: ItemKind
    public var version: ItemVersion
    public var isPlaceholder: Bool       // present but content not materialized (iCloud dataless, offloaded files)
    public var isTrashed: Bool
}
```

`VersionComparison.unknown` is the load-bearing case: the current `contentSignature` fallback returns a per-provider string for unknowns, which *accidentally* compares unequal — the new type makes that guarantee explicit and testable instead of incidental.

## 4. Base records — the hub's memory

The base record is what conflict detection judges against ([00 § Topology](00-overview.md)). One record per tracked item per sync set:

```swift
public struct BaseRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var syncSetID: UUID
    public var path: SyncPath                 // canonical path at last convergence
    public var kind: ItemKind
    public var version: ItemVersion           // converged content version
    public var perLocation: [LocationID: LocationMemory]
    public var tombstone: Tombstone?          // set when deletion propagated; kept ≥ 180 days
    public var lastConvergedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct LocationMemory: Codable, Hashable, Sendable {
    public var itemID: String?
    public var revisionToken: String?         // that location's token for the converged version
    public var lastSeenAt: Date?
}

public struct Tombstone: Codable, Hashable, Sendable {
    public var deletedAt: Date
    public var initiatedBy: LocationID?       // where the deletion was first observed
}
```

Semantics:

- Created on first successful propagation of a new item; updated **per item as its operations complete** (journal-driven, [05 §4](05-execution-and-orchestration.md)) — never as one bulk write at run end, so a crash can't desynchronize memory from reality.
- Tombstoned, not removed, when a delete propagates. A file re-appearing at a tombstoned path is *new* (create propagation), never "everyone else deleted it" — and the preview can say "this file previously moved to trash on ⟨date⟩".
- No base record for an item ⇒ the engine has no memory ⇒ **no deletion can ever be planned for it** (invariant 2's mechanical form).

*(current)* `SyncRecord` hardcodes `googleDriveItemID`, `oneDriveETag`, `iCloudBookmarkData`, … — replaced wholesale by `perLocation`.

## 5. Sync sets and settings

```swift
public struct SyncSet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var locations: [LocationID]            // ≥ 2 to sync
    public var mode: SyncMode                     // (current ✅) balancedMirror | askBeforeDeleting | noDeletePropagation
    public var settings: SyncSettings
    public var createdAt: Date, updatedAt: Date
}

public struct SyncSettings: Codable, Hashable, Sendable {
    public var exclusions: [SyncExclusion]        // (current ✅) + non-removable built-ins: "/.aetherloom/" prefix, symlinks
    public var thresholds: SafetyThresholds       // (current ✅) defaults: deletes 25/25%, edits 50/50%; clamped, never disable-able
}
```

## 6. Snapshots

A scan of one location, **indexed once at construction** — the current planner rebuilds three dictionaries from a flat `[CloudItem]` on every plan; the ideal snapshot owns its indexes:

```swift
public struct LocationSnapshot: Sendable {
    public var location: LocationID
    public var scope: SyncScope
    public var status: ScanStatus                     // complete | unavailable(reason) | incomplete(reason)
    public var scannedAt: Date
    public var observations: ObservationIndex          // byPath, byItemID, byCaseFoldedPath — O(1) lookups, built once
}

public enum ScanStatus: Codable, Hashable, Sendable {
    case complete
    case unavailable(LocationUnavailabilityReason)    // [02 §2]
    case incomplete(reason: String)
}
```

Rule: `status == .complete` is a *proof obligation* on the provider — "I positively enumerated everything in scope". Only complete snapshots ever participate in reconciliation; anything else refuses the run ([04 §2](04-planning-and-gating.md)).

## 7. Determinism envelope

Every pure layer takes an `Environment`-style value rather than reading globals:

```swift
public struct PlanningEnvironment: Sendable {
    public var now: Date                      // injected; no Date() below the orchestrator
    public var makeID: @Sendable () -> UUID   // injected; seedable in tests
    public var locationNames: [LocationID: String]
}
```

This is what makes golden-value tests of plans, previews, fingerprints, and conflict-copy names possible.

## 8. Changing the current code

Phase 1 of [11-migration.md](11-migration.md): rename `CloudPath → SyncPath`; split `CloudItem → ItemObservation + ItemVersion` (with `VersionComparison` centralizing the three comparison sites: planner `contentSignature`/`sameContent`, executor `sameContent`/`sameVersion`); replace `ProviderID` with `LocationID`/`ProviderKind`/`SyncLocation` everywhere; rebuild `SyncRecord → BaseRecord`. Purely mechanical plus one semantic upgrade (explicit `unknown` comparison). All 20 existing tests port with renamed constructors and identical assertions.
