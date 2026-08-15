import Foundation

public struct PlanFingerprint: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func compute(
        syncSetID: UUID,
        decisions: [ItemDecision],
        schedule: OperationSchedule,
        gate: ExecutionGate,
        snapshots: [LocationSnapshot]
    ) -> PlanFingerprint {
        let payload = PlanFingerprintPayload(
            syncSetID: syncSetID,
            decisions: decisions.map(DecisionFingerprintRollup.init),
            schedule: schedule,
            gate: gate,
            snapshots: snapshots.map(SnapshotFingerprintRollup.init).sorted()
        )
        let data = (try? CanonicalCoding.encoder().encode(payload)) ?? Data()
        return PlanFingerprint(rawValue: CanonicalCoding.sha256Hex(data))
    }
}

private struct PlanFingerprintPayload: Codable, Hashable, Sendable {
    var syncSetID: UUID
    var decisions: [DecisionFingerprintRollup]
    var schedule: OperationSchedule
    var gate: ExecutionGate
    var snapshots: [SnapshotFingerprintRollup]
}

private struct DecisionFingerprintRollup: Codable, Hashable, Sendable {
    var id: UUID
    var path: SyncPath
    var verdict: VerdictFingerprintRollup
    var operations: [OperationID]
    var explanation: String

    init(_ decision: ItemDecision) {
        self.id = decision.id
        self.path = decision.path
        self.verdict = VerdictFingerprintRollup(decision.verdict)
        self.operations = decision.operations
        self.explanation = decision.explanation
    }
}

private indirect enum VerdictFingerprintRollup: Codable, Hashable, Sendable {
    case inSync
    case propagateContent(from: LocationID, to: [LocationID])
    case propagateCreation(from: LocationID, to: [LocationID])
    case propagatePath(to: [LocationID], newPath: SyncPath)
    case propagateDeletion(to: [LocationID], initiatedBy: LocationID)
    case conflict(ConflictDecision)
    case waiting(WaitingReason, locations: [LocationID])
    case excluded([LocatedScanExclusion], locations: [LocationID])
    case compound([VerdictFingerprintRollup])

    init(_ verdict: ItemVerdict) {
        switch verdict {
        case .inSync:
            self = .inSync
        case let .propagateContent(from, to):
            self = .propagateContent(from: from, to: to.sorted())
        case let .propagateCreation(from, to):
            self = .propagateCreation(from: from, to: to.sorted())
        case let .propagatePath(to, newPath):
            self = .propagatePath(to: to.sorted(), newPath: newPath)
        case let .propagateDeletion(to, initiatedBy):
            self = .propagateDeletion(
                to: to.sorted(),
                initiatedBy: initiatedBy
            )
        case let .conflict(conflict):
            self = .conflict(conflict)
        case let .waiting(reason, locations):
            self = .waiting(reason, locations: locations.sorted())
        case let .excluded(exclusions, locations):
            self = .excluded(
                exclusions.sorted(),
                locations: locations.sorted()
            )
        case let .compound(verdicts):
            self = .compound(verdicts.map(Self.init))
        }
    }
}

private struct SnapshotFingerprintRollup: Codable, Hashable, Sendable, Comparable {
    var locationID: LocationID
    var scannedAt: Date
    var observationCount: Int
    var versionDigest: String
    var exclusions: [ScanExclusion]

    init(_ snapshot: LocationSnapshot) {
        self.locationID = snapshot.location
        self.scannedAt = snapshot.scannedAt
        self.observationCount = snapshot.observations.all.count
        self.versionDigest = Self.versionDigest(for: snapshot.observations.all)
        self.exclusions = snapshot.exclusions.sorted { $0.stableKey < $1.stableKey }
    }

    static func < (lhs: SnapshotFingerprintRollup, rhs: SnapshotFingerprintRollup) -> Bool {
        lhs.locationID < rhs.locationID
    }

    private static func versionDigest(for observations: [ItemObservation]) -> String {
        let tokens = observations.sorted { lhs, rhs in
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.location < rhs.location
        }.map { observation in
            [
                observation.location.rawValue.uuidString,
                observation.itemID ?? "",
                observation.path.rawValue,
                String(describing: observation.kind),
                observation.version.contentHash ?? "",
                observation.version.size.map(String.init) ?? "",
                observation.version.modifiedAt.map(CanonicalCoding.dateString) ?? "",
                observation.version.revisionToken ?? "",
                observation.isPlaceholder ? "placeholder" : "materialized",
                observation.isTrashed ? "trashed" : "active"
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return CanonicalCoding.sha256Hex(tokens)
    }
}
