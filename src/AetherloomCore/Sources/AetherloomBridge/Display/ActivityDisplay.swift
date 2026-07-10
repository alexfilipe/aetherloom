import AetherloomCore
import Foundation

public struct ActivityCategoryPresentation: Sendable, Hashable {
    public var symbolName: String
    public var tone: StatusTone

    public init(symbolName: String, tone: StatusTone) {
        self.symbolName = symbolName
        self.tone = tone
    }
}

public extension ActivityCategory {
    var presentation: ActivityCategoryPresentation {
        switch self {
        case .sync:
            ActivityCategoryPresentation(symbolName: "arrow.triangle.2.circlepath", tone: .neutral)
        case .safety:
            ActivityCategoryPresentation(symbolName: "shield.lefthalf.filled", tone: .paused)
        case .conflict:
            ActivityCategoryPresentation(symbolName: "doc.on.doc", tone: .attention)
        case .advisory:
            ActivityCategoryPresentation(symbolName: "sparkles", tone: .neutral)
        case .provider:
            ActivityCategoryPresentation(symbolName: "externaldrive", tone: .neutral)
        case .error:
            ActivityCategoryPresentation(symbolName: "exclamationmark.triangle", tone: .attention)
        }
    }
}

public struct ActivityRowDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var occurredAt: Date
    public var relativeTimestamp: String
    public var absoluteTimestamp: String
    public var category: ActivityCategory
    public var symbolName: String
    public var tone: StatusTone
    public var message: String
    public var detail: String?
    public var location: LocationDisplay?
    public var path: SyncPath?
    public var syncSetID: UUID?
    public var runID: UUID?
    public var relatedConflictID: UUID?

    public init(
        id: UUID,
        occurredAt: Date,
        relativeTimestamp: String,
        absoluteTimestamp: String,
        category: ActivityCategory,
        symbolName: String,
        tone: StatusTone,
        message: String,
        detail: String?,
        location: LocationDisplay?,
        path: SyncPath?,
        syncSetID: UUID?,
        runID: UUID?,
        relatedConflictID: UUID?
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.relativeTimestamp = relativeTimestamp
        self.absoluteTimestamp = absoluteTimestamp
        self.category = category
        self.symbolName = symbolName
        self.tone = tone
        self.message = message
        self.detail = detail
        self.location = location
        self.path = path
        self.syncSetID = syncSetID
        self.runID = runID
        self.relatedConflictID = relatedConflictID
    }
}

public struct RunGroupDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var runID: UUID?
    public var syncSetID: UUID?
    public var startedAt: Date
    public var finishedAt: Date
    public var rows: [ActivityRowDisplay]

    public init(
        id: UUID,
        runID: UUID?,
        syncSetID: UUID?,
        startedAt: Date,
        finishedAt: Date,
        rows: [ActivityRowDisplay]
    ) {
        self.id = id
        self.runID = runID
        self.syncSetID = syncSetID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rows = rows
    }
}

public func activityRows(
    _ entries: [ActivityEntry],
    locations: [LocationState],
    now: Date
) -> [ActivityRowDisplay] {
    let locationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
    return entries.map { entry in
        let category = entry.category.presentation
        return ActivityRowDisplay(
            id: entry.id,
            occurredAt: entry.occurredAt,
            relativeTimestamp: DisplayFormatting.relativeDate(entry.occurredAt, now: now),
            absoluteTimestamp: DisplayFormatting.absoluteDate(entry.occurredAt),
            category: entry.category,
            symbolName: category.symbolName,
            tone: category.tone,
            message: entry.message,
            detail: entry.detail,
            location: entry.locationID.map { locationDisplay(for: $0, states: locationsByID) },
            path: entry.path,
            syncSetID: entry.syncSetID,
            runID: entry.runID,
            relatedConflictID: entry.relatedConflictID
        )
    }.sorted(by: rowIsNewer)
}

public func runGroups(_ rows: [ActivityRowDisplay]) -> [RunGroupDisplay] {
    var grouped: [UUID: [ActivityRowDisplay]] = [:]
    var standalone: [RunGroupDisplay] = []
    for row in rows {
        if let runID = row.runID {
            grouped[runID, default: []].append(row)
        } else {
            standalone.append(
                RunGroupDisplay(
                    id: row.id,
                    runID: nil,
                    syncSetID: row.syncSetID,
                    startedAt: row.occurredAt,
                    finishedAt: row.occurredAt,
                    rows: [row]
                )
            )
        }
    }
    let runGroups = grouped.map { runID, groupRows in
        let ordered = groupRows.sorted(by: rowIsNewer)
        return RunGroupDisplay(
            id: runID,
            runID: runID,
            syncSetID: ordered.first?.syncSetID,
            startedAt: ordered.map(\.occurredAt).min()!,
            finishedAt: ordered.map(\.occurredAt).max()!,
            rows: ordered
        )
    }
    return (runGroups + standalone).sorted {
        if $0.finishedAt != $1.finishedAt {
            return $0.finishedAt > $1.finishedAt
        }
        return $0.id.uuidString < $1.id.uuidString
    }
}

private func rowIsNewer(_ lhs: ActivityRowDisplay, _ rhs: ActivityRowDisplay) -> Bool {
    if lhs.occurredAt != rhs.occurredAt {
        return lhs.occurredAt > rhs.occurredAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
}
