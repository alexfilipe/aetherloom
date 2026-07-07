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
    case clear                          // may run unattended
    case hold([HoldReason])             // plan withheld; PlanApproval unlocks [06 §3]
}

public enum HoldReason: Codable, Hashable, Sendable {
    case conflicts(count: Int)
    case massDeletion(MassChangeEvidence)
    case massEdit(MassChangeEvidence)
    case deletionsNeedReview(count: Int)     // SyncMode.askBeforeDeleting
}

public struct MassChangeEvidence: Codable, Hashable, Sendable {
    public var intentCount: Int              // DECISIONS, not fan-out operations
    public var trackedCount: Int
    public var groups: [ChangeGroup]         // nearest-common-ancestor attribution: "all 312 under /Photos/2019"
}
```

Threshold rule (semantics ✅ today, counting fixed): an intent count trips when

```
intents ≥ absoluteThreshold
or (trackedCount ≥ absoluteThreshold and intents/trackedCount ≥ ratioThreshold)
```

Defaults: deletions 25 / 25 %, edits 50 / 50 %. Counting **decisions** means "user deleted 30 files" gates identically whether the set has 2 or 5 locations (today, fan-out operations are counted, so the same act trips differently by topology). `SyncMode.noDeletePropagation` converts `propagateDeletion` verdicts into informational decisions with zero operations — visible in the preview, nothing trashed.

The gate is **monotone**: computed once from plan contents by a pure function, never downgraded by anything (not the orchestrator, not the advisor, not re-rendering). There is no third "paused" risk level — refusals took that role, typed.

## 5. Fingerprints

```swift
public struct PlanFingerprint: Codable, Hashable, Sendable { public var rawValue: String }
```

SHA-256 over the canonical encoding (sorted-keys JSON, ISO-8601 dates) of: sync set ID, decisions, schedule, gate, and a per-snapshot roll-up `(locationID, scannedAt, observation count, sorted version-token digest)`. Properties: identical inputs ⇒ stable across processes; any change to *what would run* or *what the world looked like* ⇒ different fingerprint. The fingerprint is what approvals bind to and what execution re-checks — it is the "what you saw is what runs" guarantee.

## 6. Changing the current code

Phase 4 of [11-migration.md](11-migration.md): introduce `PlanOutcome`/`SyncRefusal` and delete the `.pause` action case (compiler finds every consumer — each becomes an explicit refusal or hold check); rebuild `SyncPlan` around decisions + schedule, with a temporary adapter that renders decisions back to the old flat action list so existing executor tests keep passing until Phase 6; move `SafetyAnalyzer`'s math into the pure gate computation, switching counts from operations to decisions (two existing threshold tests update their expected counts — a deliberate, documented behavior change); add fingerprints. `riskLevel` maps: `.safe → gate == .clear`, `.needsReview → .hold`, `.paused → refusal`.
