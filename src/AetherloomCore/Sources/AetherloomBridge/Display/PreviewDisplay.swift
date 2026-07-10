import AetherloomCore
import Foundation

public struct LocationDisplay: Sendable, Hashable, Identifiable {
    public var id: LocationID
    public var displayName: String
    public var provider: ProviderPresentation

    public init(id: LocationID, displayName: String, provider: ProviderPresentation) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
    }
}

public struct NoticeDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var message: String
    public var detail: String?
    public var location: LocationDisplay?

    public init(id: UUID, message: String, detail: String?, location: LocationDisplay?) {
        self.id = id
        self.message = message
        self.detail = detail
        self.location = location
    }
}

public struct HoldDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var reason: HoldReason
    public var message: String
    public var evidenceSummary: String?
    public var advisoryNote: String?
    public var advisoryAttribution: String?

    public init(
        id: UUID,
        reason: HoldReason,
        message: String,
        evidenceSummary: String?,
        advisoryNote: String?,
        advisoryAttribution: String? = nil
    ) {
        self.id = id
        self.reason = reason
        self.message = message
        self.evidenceSummary = evidenceSummary
        self.advisoryNote = advisoryNote
        self.advisoryAttribution = advisoryAttribution
    }
}

public struct PreviewEntryDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID { decisionID }
    public var decisionID: UUID
    public var path: SyncPath
    public var summary: String
    public var causality: String?
    public var destinations: [LocationDisplay]
    public var byteSize: Int64?
    public var isTrash: Bool

    public init(
        decisionID: UUID,
        path: SyncPath,
        summary: String,
        causality: String?,
        destinations: [LocationDisplay],
        byteSize: Int64?,
        isTrash: Bool
    ) {
        self.decisionID = decisionID
        self.path = path
        self.summary = summary
        self.causality = causality
        self.destinations = destinations
        self.byteSize = byteSize
        self.isTrash = isTrash
    }
}

public struct SectionDisplay: Sendable, Hashable, Identifiable {
    public var id: PreviewSectionKind { kind }
    public var kind: PreviewSectionKind
    public var title: String
    public var entryCount: Int
    public var entries: [PreviewEntryDisplay]

    public init(
        kind: PreviewSectionKind,
        title: String,
        entryCount: Int,
        entries: [PreviewEntryDisplay]
    ) {
        self.kind = kind
        self.title = title
        self.entryCount = entryCount
        self.entries = entries
    }
}

public struct PreviewTotals: Sendable, Hashable {
    public var counts: [PreviewSectionKind: Int]
    public var byteTotal: Int64

    public init(counts: [PreviewSectionKind: Int], byteTotal: Int64) {
        self.counts = counts
        self.byteTotal = byteTotal
    }

    public var changeCount: Int {
        counts.values.reduce(0, +)
    }
}

public struct ApprovalRequirement: Sendable, Hashable {
    public var fingerprint: PlanFingerprint
    public var trashCount: Int
    public var conflictCount: Int

    public init(fingerprint: PlanFingerprint, trashCount: Int, conflictCount: Int) {
        self.fingerprint = fingerprint
        self.trashCount = trashCount
        self.conflictCount = conflictCount
    }
}

public struct PreviewDisplay: Sendable, Hashable {
    public var headline: String
    public var refusals: [NoticeDisplay]
    public var holds: [HoldDisplay]
    public var sections: [SectionDisplay]
    public var totals: PreviewTotals
    public var approvalRequirement: ApprovalRequirement?

    public init(
        headline: String,
        refusals: [NoticeDisplay],
        holds: [HoldDisplay],
        sections: [SectionDisplay],
        totals: PreviewTotals,
        approvalRequirement: ApprovalRequirement?
    ) {
        self.headline = headline
        self.refusals = refusals
        self.holds = holds
        self.sections = sections
        self.totals = totals
        self.approvalRequirement = approvalRequirement
    }
}

public func previewDisplay(
    for preparation: SyncPreparation,
    locations: [LocationState]
) -> PreviewDisplay {
    let locationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
    let sections = preparation.preview.sections.compactMap { section -> SectionDisplay? in
        guard !section.entries.isEmpty else { return nil }
        let entries = section.entries.map { entry in
            PreviewEntryDisplay(
                decisionID: entry.decisionID,
                path: entry.path,
                summary: entry.summary,
                causality: entry.causality,
                destinations: entry.destinations.map { locationDisplay(for: $0, states: locationsByID) },
                byteSize: entry.byteSize,
                isTrash: entry.isTrash
            )
        }
        return SectionDisplay(
            kind: section.kind,
            title: section.title,
            entryCount: entries.count,
            entries: entries
        )
    }
    let totals = PreviewTotals(
        counts: Dictionary(uniqueKeysWithValues: PreviewSectionKind.allCases.map { kind in
            (kind, preparation.preview.sections.first(where: { $0.kind == kind })?.entries.count ?? 0)
        }),
        byteTotal: sections.flatMap(\.entries).compactMap(\.byteSize).reduce(0, +)
    )
    let requirement: ApprovalRequirement?
    if let plan = preparation.outcome.planValue, !plan.gate.isClear {
        requirement = ApprovalRequirement(
            fingerprint: plan.fingerprint,
            trashCount: plan.approvalTrashCount,
            conflictCount: plan.approvalConflictCount
        )
    } else {
        requirement = nil
    }
    return PreviewDisplay(
        headline: preparation.preview.headline,
        refusals: preparation.preview.refusals.map { notice in
            NoticeDisplay(
                id: notice.id,
                message: notice.message,
                detail: notice.detail,
                location: notice.locationID.map { locationDisplay(for: $0, states: locationsByID) }
            )
        },
        holds: preparation.preview.holds.map { hold in
            HoldDisplay(
                id: hold.id,
                reason: hold.reason,
                message: hold.message,
                evidenceSummary: hold.evidence.map(evidenceSummary),
                advisoryNote: hold.advisoryNote?.summary,
                advisoryAttribution: hold.advisoryNote.map {
                    "Suggested on-device by \($0.generatedBy.name)"
                }
            )
        },
        sections: sections,
        totals: totals,
        approvalRequirement: requirement
    )
}

public func makeApproval(_ requirement: ApprovalRequirement, at now: Date) -> PlanApproval {
    PlanApproval(
        planFingerprint: requirement.fingerprint,
        approvedAt: now,
        acknowledgedTrashCount: requirement.trashCount,
        acknowledgedConflictCount: requirement.conflictCount
    )
}

func locationDisplay(
    for id: LocationID,
    states: [LocationID: LocationState]
) -> LocationDisplay {
    if let state = states[id] {
        return LocationDisplay(
            id: id,
            displayName: state.location.displayName,
            provider: state.location.kind.presentation
        )
    }
    let kind = id.defaultKind
    return LocationDisplay(id: id, displayName: id.displayName, provider: kind.presentation)
}

private func evidenceSummary(_ evidence: MassChangeEvidence) -> String {
    guard !evidence.groups.isEmpty else {
        return "\(evidence.intentCount) of \(evidence.trackedCount) items"
    }
    if evidence.groups.count == 1, let group = evidence.groups.first, group.intentCount == evidence.intentCount {
        return "all \(group.intentCount) under \(group.ancestor.rawValue)"
    }
    return evidence.groups
        .map { "\($0.intentCount) under \($0.ancestor.rawValue)" }
        .joined(separator: ", ")
}
