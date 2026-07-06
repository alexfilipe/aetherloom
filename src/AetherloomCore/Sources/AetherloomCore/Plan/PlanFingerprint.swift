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
            decisions: decisions,
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
    var decisions: [ItemDecision]
    var schedule: OperationSchedule
    var gate: ExecutionGate
    var snapshots: [SnapshotFingerprintRollup]
}

private struct SnapshotFingerprintRollup: Codable, Hashable, Sendable, Comparable {
    var locationID: LocationID
    var scannedAt: Date
    var observationCount: Int
    var versionDigest: String

    init(_ snapshot: LocationSnapshot) {
        self.locationID = snapshot.location
        self.scannedAt = snapshot.scannedAt
        self.observationCount = snapshot.observations.all.count
        self.versionDigest = Self.versionDigest(for: snapshot.observations.all)
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
