# 01 — Local Workspace and `WorkspaceEngineSession`

This document is the normative production contract for Aetherloom's local-folder MVP. It defines the bridge seam, folder authority, workspace persistence, enrollment safety, relaunch, and recovery. The provider-specific treatment of packages and macOS metadata is defined in [local/01-package-and-metadata-safety.md](local/01-package-and-metadata-safety.md). The ordered implementation and acceptance ownership are defined once in [agents/local-workspace-mvp.md](agents/local-workspace-mvp.md).

## 1. Current state and target boundary

**Current state at the L1 base:** `AetherloomCore` contains a real `LocalFolderStorageProvider`, provider conformance coverage, conservative local mutation/recovery machinery, file-backed base-record, journal, and activity stores, and temporary-directory local end-to-end tests. The production app still constructs `DemoEngineSession.standard()`. It does not select real folders, persist security-scoped bookmarks, reconstruct a durable workspace, or compose the real provider for app use.

**Target:** `WorkspaceEngineSession` is the production `EngineSession` implementation in `AetherloomBridge`. It composes real local providers and durable stores without moving sync policy out of core.

| Owner | MUST own | MUST NOT own |
| --- | --- | --- |
| `AetherloomCore` | Provider-independent scan, reconciliation, planning, gating, preview, approval validation, execution, conflict preservation, journaling, and provider protocols | App bootstrap, folder pickers, bookmark bytes, workspace manifests, or SwiftUI state |
| `WorkspaceEngineSession` and bridge support | Durable workspace bootstrap; folder-access capabilities; location/provider construction; sync-set metadata; pause state; preparation/confirmation/execution orchestration; recovery presentation | Re-deriving verdicts, weakening gates, fabricating approvals, or deciding sync rules |
| SwiftUI and `AppModel` | Presentation, user intent, `NSOpenPanel` invocation through an app adapter, preview display, and explicit confirmation collection | Provider construction, filesystem access, persistence rules, conflict policy, automatic approval, or automatic execution |

The bridge MAY map typed engine and workspace failures into calm display errors, but it MUST preserve refusal/hold meaning, fingerprints, counts, paths, and reasons.

The production seam uses these bridge-owned semantic shapes (member spelling may follow repository conventions, but no member or method may be omitted or weakened):

```swift
public struct LocalFolderDraft: Sendable, Hashable {
    public var displayName: String
    public var kind: ProviderKind             // localFolder for this MVP
}

/// Opaque to AppModel/UI: encapsulates the selected root URL and bookmark
/// capability created by the L5 macOS adapter. Only the adapter factory and
/// session may access its stored payload; it exposes no raw path or bytes.
public struct FolderAccessGrant: Sendable { /* opaque capability payload */ }

public struct WorkspaceExecutionConfirmation: Codable, Hashable, Sendable {
    public var planFingerprint: PlanFingerprint
    public var confirmedAt: Date
    public var expiresAt: Date
    public var acknowledgedTrashCount: Int
    public var acknowledgedConflictCount: Int
}

public protocol EngineSession: Sendable { // production-authority methods excerpt
    func enrollLocalFolder(_ draft: LocalFolderDraft, access: FolderAccessGrant) async throws -> LocationState
    func reauthorizeLocalFolder(_ locationID: LocationID, access: FolderAccessGrant) async throws -> LocationState
    func prepare(syncSetID: UUID) async throws -> SyncPreparation
    func execute(
        _ preparation: SyncPreparation,
        confirmation: WorkspaceExecutionConfirmation
    ) async throws -> SyncRunSummary
}
```

Enrollment and reauthorization accept a metadata draft plus a separate opaque capability, never an absolute-path string. `AppModel` may pass a grant from the L5 adapter directly to the session but MUST NOT retain or inspect its URL/bookmark payload.

The bridge validates fingerprint equality; `confirmedAt <= now < expiresAt`; `expiresAt > confirmedAt`; and exact acknowledgement counts against the preparation. It then deterministically derives the core call: a held plan receives `PlanApproval(planFingerprint: confirmation.planFingerprint, approvedAt: confirmation.confirmedAt, expiresAt: confirmation.expiresAt, acknowledgedTrashCount: confirmation.acknowledgedTrashCount, acknowledgedConflictCount: confirmation.acknowledgedConflictCount)`; a clear plan passes `nil` **only inside the bridge** after the same confirmation validation. Refusals remain unexecutable. The `EngineSession` protocol consumed by `AppModel`, including `DemoEngineSession` and `WorkspaceEngineSession`, exposes no nullable `PlanApproval?`, Boolean approval, path enrollment, or other production escape hatch.

## 2. Manual lifecycle and mutation authority

Workspace bootstrap, location enrollment, sync-set creation, sync-set editing, pause changes, and conflict-resolution selection are metadata operations. They MUST NOT recursively scan or mutate synchronized content. Enrollment may perform only the bounded root resource, package, access, canonicalization, and volume-identity probes required by §§3–4.

Every user-triggered run follows one path:

1. The user chooses **Sync Now**.
2. `WorkspaceEngineSession` runs `prepare` and returns the real `SyncPreparation`.
3. The app presents that preparation, including an empty plan, refusal, hold, exclusion, or recovery notice.
4. If the preparation contains an executable plan, the user explicitly confirms that exact preparation. Refusals remain visible and unconfirmable.
5. The session validates a non-optional confirmation bound to the preparation fingerprint and then calls the core executor. A held plan also carries the exact acknowledgements required by `PlanApproval`.

The first run of a newly created set MUST use this path, even when its gate is clear. No production run, first or later, may mutate a provider without an explicit confirmation of the displayed preparation. A refusal has no executable plan and cannot be confirmed. A stale, missing, expired, or mismatched confirmation fails without mutation. Core's ability to execute a clear plan without a `PlanApproval` is not automatic authority for the production bridge; the bridge MUST enforce the stronger manual-product boundary.

Conflict resolution records durable intent only. Selecting **Keep both** or **Make canonical** MUST NOT mutate a provider. The next explicit **Sync Now** performs fresh recovery/truth checks and scanning, creates a new preview containing the resolution's effect, and requires a new explicit confirmation. Preserved losing versions remain ordinary synchronized content until a later reviewed trash decision.

## 3. Folder access is a separate capability

The app remains sandboxed. Production folder enrollment MUST use a read/write `NSOpenPanel`, the `com.apple.security.files.user-selected.read-write` entitlement, and app-scoped security-scoped bookmarks with the `com.apple.security.files.bookmarks.app-scope` entitlement, created using `.withSecurityScope`. See Apple's documentation for the [user-selected read/write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write), [security-scoped bookmark and URL access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access), [`URL.BookmarkCreationOptions.withSecurityScope`](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope), [bookmark-data creation](https://developer.apple.com/documentation/foundation/nsurl/bookmarkdata%28options%3Aincludingresourcevaluesforkeys%3Arelativeto%3A%29), and [`startAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource%28%29).

`FolderAccessRecord` is a bridge-owned record with its own stable identifier, an associated `LocationID`, a schema version, and opaque bookmark/capability bytes. Those bytes MUST live in separate capability files. They MUST NOT appear in `SyncLocation`, the workspace manifest, logs, UI values, activity entries, diagnostics, crash descriptions, or exported support data. The manifest stores only the access-record reference.

Resolving an access record MUST be non-interactive: it may not display UI, prompt, mount a volume, wake a NAS, or search for a replacement folder. Resolution MUST report stale bookmark data. A stale bookmark requires explicit reauthorization through a new picker selection before any scan or mutation; silently refreshing or adopting it is forbidden.

The session/provider composition owner MUST balance every successful `startAccessingSecurityScopedResource()` with exactly one `stopAccessingSecurityScopedResource()`. The scope remains active for the complete lifetime of all provider I/O it authorizes, including availability, scan, staging, execution, truth probes, and late indeterminate work. Cancellation, a caller timeout, or loss of a UI task does not end a scope while provider-owned work or recovery evidence remains live.

Missing access data, denied scope, a stale bookmark, a removed root, an unmounted volume, an unreadable root, a wrong persisted volume, a wrong canonical/physical identity, or an incomplete scan yields a typed unavailable/refusal or fail-closed bootstrap state. It yields zero provider mutation and zero deletion inference. The user reauthorizes stale or denied access explicitly; no condition is repaired by treating the location as empty.

## 4. Enrollment identity and root overlap

The physical identity of an enrolled root is the persisted volume identity plus its canonical resolved root path. Enrollment MUST:

1. resolve bookmark access and the selected root under a live security scope;
2. reject a selected package root per [the local policy](local/01-package-and-metadata-safety.md);
3. call `LocalFolderStorageProvider.locationByRecordingVolumeIdentity`;
4. durably save the returned `SyncLocation`, including the recorded volume identity and canonical resolved root path, and its separate access-record reference; and
5. construct the provider only after those writes commit.

Before creating or updating a sync set, the session MUST compare every proposed pair on the recorded volume. It rejects:

- the same canonical root;
- two aliases or symlinks resolving to the same root; and
- either ancestor/descendant ordering on the same volume.

Paths on demonstrably different persisted volumes do not overlap. If canonical resolution, alias identity, volume identity, or disjointness cannot be proved, enrollment or sync-set creation fails closed before a set is created, before a scan, and before any mutation. Display names and raw selected path strings are never identity evidence.

Bootstrap repeats identity and overlap validation. A root that now resolves to a different volume or physical identity is unavailable; the session MUST NOT adopt it.

## 5. Durable workspace boundary and layout

The app injects one owned Application Support workspace root into the bridge. Core and bridge tests MUST inject roots under test-created temporary directories; tests MUST NOT use the developer's or user's Application Support directory.

The durable layout has these ownership zones (exact per-record filenames are an implementation detail):

```text
<workspace-root>/
  manifest.json                 bridge-owned authority and references
  stores/
    base-records/               core file-backed store
    journals/                   core write-ahead journals
    conflicts/                  core file-backed conflict store
    advice/                     core file-backed advice cache
    activity/                   core file-backed activity store
    locations/                  core file-backed location registry
  folder-access/                opaque capability files; never copied into other zones
  stage/                        persistent bridge-owned content stage and pins
  quarantine/                   preserved corrupt workspace metadata and owned recovery artifacts
```

The versioned bridge-owned manifest is authoritative for:

- sync sets and pause state;
- a durable never-run/first-run/last-run marker and their digests/version references;
- location IDs and folder-access record references;
- store schema/version references; and
- unfinished recovery and stage-pin references needed to locate durable core evidence.

The core stores remain authoritative for base records, run journals, conflicts and resolution intent, advice, activity, and locations. Capability bytes are authoritative only in `folder-access/`. Stage and quarantine are persistent owned directories, not caches placed beside user content.

Manifest and replaceable store writes MUST use a sibling temporary file, `fsync`/flush its contents, atomically rename/replace it, and durably synchronize the containing directory where the platform permits. Append-only journals retain their fsync-before-side-effect discipline. A failed write MUST leave either the old valid generation or the new valid generation, never a silently accepted partial generation.

Unreadable or corrupt bytes MUST be preserved in place or copied/moved into owned quarantine before any repair replaces them. An unsupported schema, a manifest referencing missing/corrupt location or access data, inconsistent generations, or any partial state fails closed. Bootstrap MUST NOT silently discard, reseed, or reinterpret that workspace as empty.

An absent manifest means a fresh workspace only when no recognized manifest, store, access, stage-pin, recovery, or quarantine artifact exists under the injected root. A missing manifest alongside any recognized artifact is corrupt/partial state and fails closed. The manifest wins over orphan metadata; future cleanup MAY remove unreferenced owned metadata after safety review, but it MUST NOT infer or change provider contents.

Deleting a sync set changes owned metadata only. It MUST NOT scan, delete, trash, move, rename, or overwrite synchronized content. Location/access records still referenced by another set remain. Unreferenced location/access/store metadata may be retained for later cleanup.

Stage artifacts and pins associated with an intent or indeterminate receipt remain receipt-bound until journal recovery establishes current truth and durably reconciles that journal. Relaunch, sync-set deletion, UI cancellation, and ordinary cache cleanup MUST NOT release them early.

## 6. Bootstrap, relaunch, and recovery

`WorkspaceEngineSession.bootstrap()` MUST reconstruct the manifest, sync sets, pause state, run/preparation digests, locations, access references, core stores, stage pins, and unfinished recovery references. It then re-resolves folder access without implicit UI and revalidates volume identity and root overlap enough to present truthful state.

Bootstrap MUST NOT automatically prepare, scan all sets, execute, replay an old operation schedule, or request an approval. It exposes unavailable locations, corrupt workspace state, and unfinished recovery as state requiring a later explicit manual prepare.

On the next explicit prepare, recovery uses retained journal/receipt evidence plus current provider truth probes. Once recovery is durably reconciled, the session performs fresh availability checks and fresh scans and creates a new preview. It never resumes or reapplies the old schedule. If truth cannot be established, recovery remains visible and provider mutation stays blocked.

A set that converged before relaunch MUST reconstruct its base state so its next explicit prepare produces an empty plan when provider truth is unchanged. Pause state survives relaunch and prevents prepare until the user explicitly resumes the set.

## 7. Package and metadata fidelity boundary

The production session composes only a local provider that implements the typed exclusion contract in [local/01-package-and-metadata-safety.md](local/01-package-and-metadata-safety.md). Positive exclusions participate in the snapshot as evidence; they are not dropped paths. Any package or unsupported-metadata scope is visibly waiting/excluded, is non-mutating at every location, and cannot be approved into execution or marked converged.

## 8. Explicit MVP exclusions

This contract does not add OAuth, cloud APIs, background or scheduled sync, FSEvents, whole-drive enrollment, NAS qualification, automatic approval/execution, migration UI, SQLite, App Store distribution work, or full metadata/resource-fork preservation. NAS remains a future use of the local provider architecture, not part of local-alpha qualification. Full metadata preservation may replace exclusion only after a separate architecture decision and proven round-trip fidelity.
