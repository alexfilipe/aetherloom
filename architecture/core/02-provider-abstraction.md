# 02 — Provider Abstraction

One protocol separates the engine from every backend. Its contract carries the safety proof: the engine can only refuse correctly if providers report failure truthfully. This layer is where "local and NAS are first-class" becomes real — a folder on a disk and a Google Drive account satisfy the same protocol and differ only in capabilities and availability behavior.

## 1. `StorageProvider`

```swift
public protocol StorageProvider: Sendable {
    var locationID: LocationID { get }
    var capabilities: ProviderCapabilities { get }

    /// Cheap, side-effect-free. MUST distinguish "reachable" from every
    /// flavor of "cannot know right now".
    func checkAvailability() async -> LocationAvailability

    /// Full accounting of the scope. Non-throwing: every failure is encoded
    /// in ScanStatus. `.complete` proves every path is an observation or is
    /// covered by a typed exclusion, with no unaccounted path.
    func scan(_ scope: SyncScope) async -> LocationSnapshot

    /// Optional narrowing: which subtrees changed since the cursor. Advisory
    /// only — reconciliation always runs on complete snapshots ([00 § scan model]).
    func changedSubtrees(in scope: SyncScope, since cursor: ChangeCursor?) async throws -> ChangeHint

    // Content
    func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws
    func store(from stagingURL: URL, at path: SyncPath, options: StoreOptions) async throws -> ItemObservation

    // Structure
    func makeFolder(at path: SyncPath) async throws -> ItemObservation
    func relocate(_ observation: ItemObservation, to newPath: SyncPath) async throws -> ItemObservation

    /// Trash / recycle bin / quarantine. A permanent-delete path must not
    /// exist on this protocol or be wrapped by any implementation.
    func trash(_ observation: ItemObservation) async throws

    /// Current truth for one item; the executor's precondition probe.
    func currentState(of observation: ItemObservation) async throws -> ItemObservation
}

public struct StoreOptions: Codable, Hashable, Sendable {
    public var overwrite: OverwritePolicy   // .neverOverwrite | .ifVersionMatches(ItemVersion)
}
```

Notes vs today's `CloudProvider` ✅: `scan` joins the protocol (today only the fake has `snapshot`); `checkAvailability`/`capabilities` are new; `move`+`rename` collapse into `relocate` (a rename is a relocate within the parent — one code path, one test surface); `upload(allowOverwrite:expectedRevision:)` becomes a closed `OverwritePolicy` so "overwrite without a version check" is unrepresentable; `authenticateIfNeeded` folds into `checkAvailability` (`notAuthenticated` is just an unavailability reason until real OAuth work exists).

## 2. Availability taxonomy

```swift
public enum LocationAvailability: Codable, Hashable, Sendable {
    case available
    case unavailable(LocationUnavailabilityReason)
}

public enum LocationUnavailabilityReason: Codable, Hashable, Sendable {
    case notAuthenticated(detail: String)
    case networkUnreachable(detail: String)
    case volumeNotMounted(detail: String)      // external disk unplugged, share not mounted
    case volumeUnreachable(detail: String)     // mounted but hanging (sleeping NAS)
    case scopeMissing(detail: String)          // chosen folder gone at a HEALTHY backend — still never deletion-inference; surfaces for review
    case rateLimited(retryAfter: Date?)
    case unknown(detail: String)
}
```

Normative provider behavior:

- **Failure never masquerades as emptiness.** A `.complete` snapshot with zero observations is legal only after positively verifying the scope exists and is empty, or that typed exclusions account for every present in-scope path.
- **Local folders:** verify the scope root exists *and* its volume is mounted before enumerating. Root missing on a mounted system volume ⇒ `scopeMissing`; missing because the disk is gone ⇒ `volumeNotMounted`.
- **NAS:** enumeration runs under timeouts; a hang ⇒ `volumeUnreachable`; an error midway ⇒ `.incomplete`, never `.complete` with an unaccounted path. A smaller observation count is complete only when every omitted path is positively covered by a typed item/subtree exclusion.
- **iCloud local folder:** dataless files appear as observations with `isPlaceholder = true` — included, never omitted, never treated as edited.
- **Symlinks:** observed with `ItemKind.symlink`, reported, excluded from propagation by default ([01 §5](01-domain-model.md)).
- **Packages and unsupported macOS metadata:** the local MVP reports typed positive scan exclusions and never silently omits or descends into an excluded subtree; see [the local fidelity contract](../providers/local/01-package-and-metadata-safety.md). An exclusion is presence and cannot support deletion inference.

## 3. Capabilities

```swift
public struct ProviderCapabilities: Codable, Hashable, Sendable {
    public var hasNativeTrash: Bool           // false ⇒ quarantine (§4)
    public var hasStableItemIDs: Bool         // false ⇒ path identity; renames degrade safely
    public var hasContentHashes: Bool         // false ⇒ comparisons degrade; unknown routes to preservation
    public var hasChangeHints: Bool
    public var supportsVersionCheckedStore: Bool  // can honor .ifVersionMatches natively
    public var isCaseSensitive: Bool?         // nil ⇒ assume insensitive (detects MORE collisions — safer)
    public static let fullFidelity: ProviderCapabilities
}
```

Engine logic branches on capabilities and availability, never on `ProviderKind`. When `supportsVersionCheckedStore == false`, the executor emulates the check (probe `currentState`, compare, store) and accepts the small race — documented, and mitigated by post-write verification ([05 §5](05-execution-and-orchestration.md)).

## 4. Trash & quarantine

- Local volumes: `FileManager.trashItem(at:resultingItemURL:)`.
- Backends without reliable trash (NAS over SMB/NFS): quarantine to `/.aetherloom/trash/<ISO-8601 run date>/<relative path>` at the location root. The `/.aetherloom/` prefix is a built-in, non-removable exclusion.
- Cloud APIs: native trash endpoint only; the permanent-delete endpoint is never wrapped.

## 5. Fakes — the engine's test rig

`FakeStorageProvider` (evolves today's `FakeCloudProvider` ✅, which is already strong: actor, content-addressed by fake hash, monotonic revision tokens, precondition-enforcing writes):

- Constructor: `init(location: SyncLocation, capabilities: ProviderCapabilities = .fullFidelity, items: …)`.
- Scriptable states: full `LocationAvailability` taxonomy, incomplete scans, placeholders, per-call fault injection (`failNext(.store, with: …)`), artificial latency (for timeout tests), capability degradation (`hasContentHashes = false` ⇒ observations carry no hash).
- Records a **call log** (operation, path, order) — execution-ordering and read-only-phase tests assert against it.
- Maintains a **fake trash**: trashed content stays retrievable so preservation properties can be asserted end-to-end ([10 §4](10-testing-strategy.md)).

`FlakyStorageProvider` 🆕 wraps any provider and mutates/faults between orchestration steps — the tool for "destination changed after planning" and mid-run unavailability tests.

## 6. Errors

`ProviderError` ✅ keeps its taxonomy (`unavailable`, `itemUnavailable`, `placeholderOnly`, `notFound`, `itemAlreadyExists`, `preconditionFailed`, `unsupported`), keyed by `LocationID`. Discipline: `notFound` requires *positively confirmed absence at a healthy backend*; if the backend can't answer, throw `unavailable` — the executor treats them oppositely (replan vs abort-run).

Mutation deadlines add two distinct errors:

- `mutationDeadlineExpiredBeforeStart` proves the provider did not begin the side effect. It is a confirmed, terminal failure for that attempt.
- `mutationIndeterminate(receipt)` means the deadline expired after blocking work began. It does **not** mean the syscall stopped. The receipt identifies the provider, operation kind, affected paths, and actual coordinator start time so the journal can retain the uncertainty. Stable recovery identity is the receipt ID plus provider, kind, and ordered paths; `startedAt` is timestamp evidence rather than identity because canonical date encoding may round sub-millisecond precision. `affectedPaths` is ordered: the first entry is the receipt provider's primary path (for relocate, source then destination). Caller-visible activity, execution records, and outcomes use that receipt attribution; destination operation context remains in the journaled intent.

Providers with blocking calls refine `StorageProvider` through `IndeterminateMutationRecovering`. The refinement reports whether owned late work is still in flight, has reached quiescence with a retained success/failure, or belongs to a previous process. It also exposes the in-process indeterminate receipt so recovery can repair a failed journal-event append before it probes or releases anything. Each live receipt carries the exact run/operation correlation that authorized it; discovery rejects an unbound or differently bound same-shape receipt. `beginIndeterminateMutationRecovery` atomically returns an exclusive claim for a quiescent or genuinely restarted receipt; an unrelated same-process owner, read, or recovery claim reports in-flight instead of masquerading as restart. Every recovery probe requires that claim, which remains held through durable journal reconciliation. Probe or journal failure abandons only the session claim while retaining the receipt barrier for a safe retry. Ordinary availability, scans, probes, and mutations remain blocked until the engine durably reconciles the receipt.

## 7. Mutation ownership contract

Every provider mutation has one durable owner from its atomic queued-to-started transition until the underlying operation actually returns. Caller cancellation or deadline expiry never releases that ownership. The provider must:

1. prevent a timed-out queued operation from starting; if active work becomes indeterminate, invalidate every operation queued under the old authorization as pre-start and reject new mutation calls until recovery finishes;
2. retain started work and its late success or failure;
3. atomically serialize reads that authorize sync truth against mutation admission, and keep each read lease until the underlying work returns even when its caller times out or cancels;
4. expose recovery truth without authorizing ordinary planning; and
5. release its barrier only after the engine has marked the journal reconciled.

This contract includes writes to caller-supplied staging URLs (`fetch`) because abandoned late copies can race stage cleanup and later materialization. Local availability, scan, metadata, and recovery probes are coordinator-owned compound reads. Already-admitted reads may overlap; the first queued mutation closes ordinary read admission, waits for every physical read to drain, and then starts. A timed-out read therefore blocks mutation until its late completion rather than producing hybrid scan truth.

Local root ownership is process-wide, keyed by canonical root path plus the configured enrollment volume identity; `LocationID` is deliberately not part of the key. The registry also retains every configured-path alias, so a symlinked root keeps its original owner while its target is temporarily unavailable. A previously unseen alias that cannot be resolved is rejected when another root on that enrolled volume already exists in-process; ambiguity never creates a second owner. Reconstructed providers and orchestrators for the same physical root share the coordinator and recovery artifacts, while different roots or volume identities cannot inherit stale state. Registry entries are retained for the process lifetime rather than risk evicting an owner with an unobservable blocking syscall. Only an actual process restart may create `unknownAfterRestart`.

## 8. Changing the current code

Phase 2 of [11-migration.md](11-migration.md): rename protocol and fake; add availability/capabilities/scan; collapse move/rename → `relocate`; convert `UploadOptions` → `StoreOptions.OverwritePolicy`; add call log + fault scripting + fake trash to the fake; add `FlakyStorageProvider`. The existing fake's revision/precondition behavior carries over unchanged — it is the part most worth keeping.
