# 04 — Planning & Gating

Planning turns verdicts into something executable and reviewable; gating decides whether it may run. Both are pure. This layer replaces today's `SyncPlanner`-emits-`[SyncAction]` + `SafetyAnalyzer`-mutates-the-plan + `.pause`-sentinel arrangement with three explicit concepts: **refusal**, **plan**, **hold**.

## 1. The outcome type

```swift
public enum PlanOutcome: Sendable {
    /// No executable plan can exist. Nothing to approve; only reality
    /// changing clears it. (Today: a fake "plan" whose actions == [.pause].)
    case refusal(SyncRefusal)

    /// A plan exists. Its gate says whether it may run unattended.
    case plan(SyncPlan)
}

public struct SyncRefusal: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var reasons: [RefusalReason]     // all of them, not just the first
    public var occurredAt: Date
}

public enum RefusalReason: Codable, Hashable, Sendable {
    case locationUnavailable(LocationID, LocationUnavailabilityReason)
    case scanIncomplete(LocationID, detail: String)
    case baseStateUnreadable(detail: String)   // corrupt record store ⇒ no deletion can be planned [09 §2]
}
```

Refusal messages use the canonical sentences verbatim ("Sync paused because this provider is unavailable. No files will be deleted while a provider is unreachable." / "…returned an incomplete scan. No files will be deleted from an incomplete scan.").

## 2. The plan

```swift
public struct SyncPlan: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var generatedAt: Date
    public var decisions: [ItemDecision]        // the reviewable unit: one per item
    public var schedule: OperationSchedule      // the executable unit: lowered, dependency-ordered
    public var conflicts: [ConflictDecision]
    public var waiting: [WaitingItem]           // placeholder-blocked items, reported not hidden
    public var gate: ExecutionGate
    public var fingerprint: PlanFingerprint
}

public struct ItemDecision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: SyncPath
    public var verdict: ItemVerdict             // from [03]
    public var operations: [OperationID]        // its share of the schedule
    public var explanation: String              // causal, calm: "Deleted from ⟨location⟩ since last sync on ⟨date⟩."
}
```

Plans are **per-item first, operations second**. The preview, the approval counts, the thresholds, and the activity log all key off decisions; only the executor cares about operations. (Today's flat `[SyncAction]` with embedded `CloudItem`s serves both masters and serves neither well.)

## 3. Operations & the schedule

```swift
public struct Operation: Codable, Hashable, Sendable, Identifiable {
    public var id: OperationID
    public var location: LocationID
    public var kind: OperationKind
    public var precondition: Precondition
    public var dependsOn: [OperationID]
}

public enum OperationKind: Codable, Hashable, Sendable {
    case makeFolder(at: SyncPath)
    case transfer(content: ContentRef, to: SyncPath, overwrite: OverwritePolicy)  // upload & conflict-copy are both transfers
    case relocate(itemRef: ItemRef, to: SyncPath)
    case trash(itemRef: ItemRef)
}

public enum Precondition: Codable, Hashable, Sendable {
    case pathAbsent                       // creations, conflict copies
    case versionMatches(ItemVersion)      // overwrites, relocates, trashes — the anti-stale check
    case folderPresent                    // child operations
}
```

`ContentRef` names content by `(sourceLocation, itemID/path, expected ItemVersion)` — the staging store resolves it once per distinct content, however many destinations fan out ([05 §2](05-execution-and-orchestration.md)). `ItemRef` names an existing destination item the same way. Operations embed **references and expectations, not snapshots** — the executor always re-reads reality.

**Schedule invariants** (constructed, then asserted by a validator that runs in tests and debug builds):

1. Parents before children (`makeFolder` DAG order).
2. Every `transfer`/`relocate` precedes any `trash` — globally, not per item: an interrupted run errs toward extra copies, never missing ones.
3. All operations of one item form a chain (no intra-item parallelism).
4. Case-collision guard: no two operations target paths equal under case-folding at one location.

## 4. Gating

```swift
public enum ExecutionGate: Codable, Hashable, Sendable {
    case clear                          // executable; production still requires bridge confirmation
    case hold([HoldReason])             // executable only when permitsApproval is true
}

public enum HoldReason: Codable, Hashable, Sendable {
    case conflicts(count: Int)
    case massDeletion(MassChangeEvidence)
    case reviewedMassDeletion(ReviewedMassDeletionEvidence)
    case massEdit(MassChangeEvidence)
    case deletionsNeedReview(count: Int)     // SyncMode.askBeforeDeleting
    case opaqueRelocation(OpaqueRelocationEvidence)
}

public struct OpaqueRelocationEvidence: Codable, Hashable, Sendable {
    public var trackedPath: SyncPath
    public var exclusions: [LocatedScanExclusion] // exact missing location/root/scope/reason
}

public struct MassChangeEvidence: Codable, Hashable, Sendable {
    public var intentCount: Int              // DECISIONS, not fan-out operations
    public var trackedCount: Int
    public var groups: [ChangeGroup]         // nearest-common-ancestor attribution: "all 312 under /Photos/2019"
    public var evidenceDigest: String        // canonical sorted affected records/paths/locations/counts
}

public struct ReviewedMassDeletionEvidence: Codable, Hashable, Sendable {
    public var originalUnreviewedFingerprint: PlanFingerprint
    public var deletionEvidenceDigest: String
    public var intentCount: Int
    public var trackedCount: Int
    public var settingsSnapshotDigest: String
    public var worldSnapshotDigest: String
    public var authorizationDigest: String   // audit binding, never bearer/reservation authority
}

public struct MassDeletionSafetyLatch: Codable, Hashable, Sendable {
    public var syncSetID: UUID
    public var deletionEvidenceDigest: String
    public var intentCount: Int
    public var trackedCount: Int
    public var latchedAt: Date
}
```

Threshold rule (semantics ✅ today, counting fixed): an intent count trips when

```
intents ≥ absoluteThreshold
or (trackedCount ≥ absoluteThreshold and intents/trackedCount ≥ ratioThreshold)
```

Defaults are also the hard maximums: mass-delete absolute is normalized to `1...25` and ratio to `0.01...0.25`; mass-edit absolute is normalized to `1...50` and ratio to `0.01...0.50`. One canonical `SafetyThresholds` initializer applies those clamps to direct construction, decoding, bridge preferences, sync-set creation, and updates. Users may tighten the defaults, and later restore an in-range value only as far as the default maximum; no persistent setting can weaken these ceilings. The ratio formula above is unchanged. Consequently, **Review intentional deletions** is the sole path for a legitimate deletion at or above an otherwise tripped hard ceiling. Counting **decisions** means "user deleted 30 files" gates identically whether the set has 2 or 5 locations (today, fan-out operations are counted, so the same act trips differently by topology). `SyncMode.noDeletePropagation` converts `propagateDeletion` verdicts into informational decisions with zero operations — visible in the preview, nothing trashed.

`opaqueRelocation` is a non-approvable **Needs review** hold, not deletion intent. It is derived only after observation and move matching when a tracked path remains missing at a location whose complete snapshot contains opaque subtree evidence. Existing conflict, edit, deletion, mass-deletion, or bridge confirmation approval cannot override it. It carries one deterministic entry per held tracked path and every exact current subtree root at the missing location; the held decision schedules no mutation and authorizes no base or recovery convergence.

A pure execution-admission proof may select the plan's existing non-empty schedule as an independent safe subset without changing the gate or fingerprint. Admission requires exact one-to-one operation ownership, zero operations for held decisions, no dependency crossing held ownership, participating-location membership for every operation touch, and component-aware source/destination disjointness from held tracked paths at every participating location and from exact opaque roots at their evidence locations. Duplicate evidence, decision/schedule mismatch, unowned or multiply owned operations, overlap, an empty subset, or any other global non-approvable hold blocks executor and WAL construction. Approvable non-opaque holds still require the normal exact approval bindings. This proof does not approve, remove, or converge the opaque hold.

Safe-subset proof is necessary but not execution authority. Before evaluating admission, approval, provider classification, or WAL construction, the orchestrator MUST authenticate the complete caller-supplied preparation against the one exact preparation it retained for that sync set. The retained truth binds the outcome, membership, decisions and their unique IDs/ownership, schedule, gate and evidence, exclusions/waiting/conflicts, fingerprint, preview, and approval-relevant counts. A changed or reconstructed value that merely reuses the prepared run ID or fingerprint requires a fresh preparation. An exactly value-identical copy may proceed. The orchestrator retains at most one current preparation per sync set, so a new prepare invalidates the prior value without an unbounded authority history.

### Durable mass-deletion safety latch

Pure planning derives candidate deletion evidence from the canonical sorted deletion decisions, affected base-record identities/versions, initiating and destination locations, grouped roots, and exact intent/tracked counts. Pure gating receives the orchestrator-loaded existing latch as an injected value and returns the candidate gate plus a typed latch transition (`unchanged`, `upsert/replace`, or `clear`); neither planner nor gate code reads or writes a store. A matching injected latch forces the ordinary `massDeletion` hold even if an earlier tighter threshold was later increased within the permitted range. Threshold settings are not part of deletion evidence and cannot authorize or clear a previously latched deletion set.

The orchestrator/store layer loads the latch before the pure call and MUST durably apply its returned upsert, replacement, or clear before exposing the preparation. A prepare that newly trips `massDeletion` therefore exposes nothing until the exact sync-set/evidence latch is durable; a load or transition failure refuses deletion planning. Out-of-range persisted settings are normalized to the hard maxima before planning and fingerprinting, so corrupt or legacy values cannot weaken the stop for future deletion evidence.

The latch is durable **safety state, never durable authority**. It clears only after (a) successful execution and journal/base-record reconciliation of the matching reviewed mass-deletion plan, or (b) a fresh complete prepare proves that the underlying deletion evidence digest or counts changed. A stopped, partial, expired, cancelled, failed, unreconciled, or merely confirmed run leaves it in place. When evidence changes, the old latch is cleared and the new plan is evaluated normally; if the changed evidence trips the rule, a new latch is created. Latch creation, replacement, and clearing are journaled and logged as `safety` activity.

### One-shot review for intentional deletions

An ordinary `massDeletion` reason never permits approval. Arbitrarily large legitimate deletions are reachable only through this explicit flow:

1. The user inspects the ordinary non-approvable preview and chooses **Review intentional deletions**. The original preparation remains non-approvable.
2. The orchestrator issues an opaque, single-use review authorization with a unique nonce and `issuedAt`/`expiresAt` (default 15 minutes). It is bound to the exact sync-set ID and canonical location membership, original unreviewed `PlanFingerprint`, deletion-evidence digest and exact intent/tracked counts, complete settings snapshot digest, and complete world snapshot digest. It is process-memory only, non-`Codable`, never written to a manifest/store, and cannot be restored after relaunch. Issuance is recorded in safety activity and the safety journal with only the authorization digest and bindings, never the bearer value.
3. The review authorization can be consumed only by one fresh full `prepare`. That prepare repeats recovery, availability, complete scans, reconciliation, planning, and ordinary gating. Before the transition it recomputes the ordinary unreviewed plan and MUST match the original unreviewed fingerprint, deletion evidence/counts, exact sync set, settings snapshot, and world snapshot. Expiry, prior use, or any mismatch consumes/rejects the authorization, emits no reviewed plan or reservation, mutates no provider, and returns the fresh ordinary outcome for display.
4. On an exact match, the orchestrator derives `reviewedMassDeletion(binding)`, computes a reviewed fingerprint that differs from the unreviewed one, and atomically transitions the bearer review authorization into a new opaque `MassDeletionExecutionReservation` before exposing the reviewed preparation. The reservation is actor-owned process memory, non-`Codable`, expiring (default 15 minutes), one-shot, and bound to the exact reviewed fingerprint, run ID, and preparation identity. Neither the bearer reservation nor a way to fabricate it crosses the core/session boundary. Only authorization/reservation digests, bindings, expiries, and transition results are recorded durably in safety activity/journal.
5. The reviewed plan remains only evidence: its Codable `reviewedMassDeletion` value, fingerprint, audit digest, confirmation, durable latch, and journal records are not execution authority individually or together. The user must still inspect the fresh reviewed preview, acknowledge its exact trash/conflict counts, and provide an unexpired confirmation bound to the reviewed fingerprint. After validating that normal approval/confirmation, core `execute` MUST find and atomically consume the exact live reservation immediately before executor construction. A missing, expired, reused, relaunch-restored, wrong-run, wrong-preparation, or wrong-fingerprint reservation returns held/rejected with zero executor construction and zero executor/provider calls. Any other non-approvable reason still blocks execution.

An executable preparation is exactly `gate == .clear`, or `gate == .hold && gate.permitsApproval`, with the additional live-reservation requirement above for any `reviewedMassDeletion`. `permitsApproval` is true only when every hold reason permits approval. `conflicts`, `massEdit`, `deletionsNeedReview`, and `reviewedMassDeletion` permit approval; ordinary `massDeletion` does not, so any mixed hold containing ordinary `massDeletion` is non-approvable. Confirmation cannot create, persist, or substitute for the review authorization or execution reservation.

The gate is **monotone within a preparation**: computed from plan contents plus the durable latch, never downgraded by the advisor, confirmation, settings UI, or re-rendering. The separate reviewed plan is produced only by the fresh, exact-match transition above; it does not mutate or downgrade the original gate. Confirmation cannot convert a non-approvable hold into an executable plan. There is no third "paused" risk level — refusals and holds retain their distinct typed meanings.

## 5. Fingerprints

```swift
public struct PlanFingerprint: Codable, Hashable, Sendable { public var rawValue: String }
```

SHA-256 over a dedicated canonical semantic projection, not a serialization of the runtime structs. It contains: exact sync-set ID and canonically sorted location membership; normalized mode/settings; semantic decisions; semantic operation DAG; gate/evidence; relevant base/conflict-resolution state; and, per location, canonical sorted observation and exclusion evidence (identity, normalized path, kind, version/placeholder/trash state, exclusion scope/reason). Every unordered collection is sorted by stable semantic keys. Dependencies reference deterministic semantic operation keys, so array/DAG traversal order is not material.

The projection excludes ephemeral `runID`, preparation identity, `ItemDecision.id`, `Operation.id`, and other values produced by `makeID`; display/localization strings and display timestamps; `generatedAt`, `scannedAt`, and other sampling timestamps; and collection/traversal ordering accidents. An implementation MAY instead generate deterministic semantic decision/operation IDs, but such IDs MUST be derived solely from the same canonical semantic material. The same projection rules produce the `settingsSnapshotDigest`, `worldSnapshotDigest`, and deletion-evidence digest. Thus a fresh complete prepare with identical truth reproduces the original unreviewed fingerprint even when generated IDs, `generatedAt`/`scannedAt`, and input enumeration order differ, while any semantic change to what would run, settings, membership, base intent, provider truth, or exclusion evidence changes it. A reviewed mass-deletion binding and explicit marker are additional fingerprint inputs, guaranteeing that its reviewed fingerprint differs from the original unreviewed fingerprint. Confirmations/internal approvals bind that fingerprint; reviewed execution additionally requires the live reservation, preserving the "what you saw is what runs" guarantee without making a Codable plan authority.

## 6. Changing the current code

Phase 4 of [11-migration.md](11-migration.md): introduce `PlanOutcome`/`SyncRefusal` and delete the `.pause` action case (compiler finds every consumer — each becomes an explicit refusal or hold check); rebuild `SyncPlan` around decisions + schedule, with a temporary adapter that renders decisions back to the old flat action list so existing executor tests keep passing until Phase 6; move `SafetyAnalyzer`'s math into the pure gate computation, switching counts from operations to decisions (two existing threshold tests update their expected counts — a deliberate, documented behavior change); add fingerprints. `riskLevel` maps: `.safe → gate == .clear`, `.needsReview → .hold`, `.paused → refusal`.
