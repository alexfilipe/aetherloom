import AetherloomCore
import Foundation

public struct OverviewMetricDisplay: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct OverviewBannerDisplay: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var syncSetID: UUID
    public var syncSetName: String
    public var message: String
    public var detail: String?

    public init(
        id: UUID,
        syncSetID: UUID,
        syncSetName: String,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.syncSetID = syncSetID
        self.syncSetName = syncSetName
        self.message = message
        self.detail = detail
    }
}

public enum OverviewLocationAction: Sendable, Hashable {
    case none
    case connectProvider(ProviderKind)
    case wakeAndMount
}

public struct OverviewLocationDisplay: Sendable, Hashable, Identifiable {
    public var id: LocationID
    public var provider: ProviderPresentation
    public var displayName: String
    public var accountLabel: String?
    public var scopeText: String
    public var status: StatusLine
    public var lastCheckedText: String
    public var isBusy: Bool
    public var action: OverviewLocationAction

    public init(
        id: LocationID,
        provider: ProviderPresentation,
        displayName: String,
        accountLabel: String?,
        scopeText: String,
        status: StatusLine,
        lastCheckedText: String,
        isBusy: Bool,
        action: OverviewLocationAction
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.accountLabel = accountLabel
        self.scopeText = scopeText
        self.status = status
        self.lastCheckedText = lastCheckedText
        self.isBusy = isBusy
        self.action = action
    }
}

public struct OverviewPendingDisplay: Sendable, Hashable {
    public var syncSetID: UUID
    public var syncSetName: String
    public var headline: String
    public var entries: [PreviewEntryDisplay]
    public var totalsText: String

    public init(
        syncSetID: UUID,
        syncSetName: String,
        headline: String,
        entries: [PreviewEntryDisplay],
        totalsText: String
    ) {
        self.syncSetID = syncSetID
        self.syncSetName = syncSetName
        self.headline = headline
        self.entries = entries
        self.totalsText = totalsText
    }
}

public struct OverviewDisplay: Sendable, Hashable {
    public var headline: String
    public var statusText: String
    public var statusTone: StatusTone
    public var metrics: [OverviewMetricDisplay]
    public var lastScanText: String?
    public var holdBanners: [OverviewBannerDisplay]
    public var refusalBanners: [OverviewBannerDisplay]
    public var locations: [OverviewLocationDisplay]
    public var locationSummary: String
    public var pending: OverviewPendingDisplay?
    public var pendingEmptyMessage: String
    public var recentActivity: [ActivityRowDisplay]
    public var isBusy: Bool
    public var isEmpty: Bool

    public init(
        headline: String,
        statusText: String,
        statusTone: StatusTone,
        metrics: [OverviewMetricDisplay],
        lastScanText: String?,
        holdBanners: [OverviewBannerDisplay],
        refusalBanners: [OverviewBannerDisplay],
        locations: [OverviewLocationDisplay],
        locationSummary: String,
        pending: OverviewPendingDisplay?,
        pendingEmptyMessage: String,
        recentActivity: [ActivityRowDisplay],
        isBusy: Bool,
        isEmpty: Bool
    ) {
        self.headline = headline
        self.statusText = statusText
        self.statusTone = statusTone
        self.metrics = metrics
        self.lastScanText = lastScanText
        self.holdBanners = holdBanners
        self.refusalBanners = refusalBanners
        self.locations = locations
        self.locationSummary = locationSummary
        self.pending = pending
        self.pendingEmptyMessage = pendingEmptyMessage
        self.recentActivity = recentActivity
        self.isBusy = isBusy
        self.isEmpty = isEmpty
    }
}

public func overviewDisplay(
    workspace: WorkspaceSnapshot,
    preparations: [UUID: SyncPreparation],
    activity: [ActivityEntry],
    now: Date
) -> OverviewDisplay {
    let orderedPreparations = preparations.values.sorted {
        if $0.syncSetName != $1.syncSetName {
            return $0.syncSetName.localizedStandardCompare($1.syncSetName) == .orderedAscending
        }
        return $0.runID.uuidString < $1.runID.uuidString
    }
    let preparationDisplays = orderedPreparations.map { preparation in
        (preparation, previewDisplay(for: preparation, locations: workspace.locations))
    }
    let pendingCount = preparationDisplays.reduce(0) { $0 + $1.1.totals.changeCount }
    let trackedItemCount = workspace.syncSets.reduce(0) { $0 + $1.trackedItemCount }
    let latestScan = workspace.locations.compactMap(\.lastCheckedAt).max()
    let lastScanText = latestScan.map { DisplayFormatting.relativeDate($0, now: now) }
    let status = overviewStatus(workspace.status, isEmpty: workspace.syncSets.isEmpty)

    let holds = orderedPreparations.flatMap { preparation in
        preparation.preview.holds.map { notice in
            OverviewBannerDisplay(
                id: notice.id,
                syncSetID: preparation.preview.syncSetID,
                syncSetName: preparation.syncSetName,
                message: notice.message
            )
        }
    }
    let refusals = orderedPreparations.flatMap { preparation in
        preparation.preview.refusals.map { notice in
            OverviewBannerDisplay(
                id: notice.id,
                syncSetID: preparation.preview.syncSetID,
                syncSetName: preparation.syncSetName,
                message: notice.message,
                detail: notice.detail
            )
        }
    }

    let busyLocationIDs = Set(workspace.syncSets.filter { $0.phase != .idle }.flatMap(\.syncSet.locations))
    let locations = workspace.locations.map { state in
        OverviewLocationDisplay(
            id: state.id,
            provider: state.location.kind.presentation,
            displayName: state.location.displayName,
            accountLabel: state.accountLabel,
            scopeText: locationScopeText(state.location),
            status: statusLine(for: state, now: now),
            lastCheckedText: state.lastCheckedAt.map { DisplayFormatting.relativeDate($0, now: now) } ?? "Not checked yet",
            isBusy: busyLocationIDs.contains(state.id),
            action: locationAction(for: state)
        )
    }
    let availableCount = workspace.locations.filter { $0.availability == .available }.count
    let pending = preparationDisplays.first(where: { $0.1.totals.changeCount > 0 }).map { preparation, display in
        OverviewPendingDisplay(
            syncSetID: preparation.preview.syncSetID,
            syncSetName: preparation.syncSetName,
            headline: display.headline,
            entries: Array(display.sections.flatMap(\.entries).prefix(4)),
            totalsText: overviewTotalsText(display.totals)
        )
    }

    return OverviewDisplay(
        headline: status.headline,
        statusText: status.text,
        statusTone: status.tone,
        metrics: [
            OverviewMetricDisplay(value: String(trackedItemCount), label: "Tracked items"),
            OverviewMetricDisplay(value: String(workspace.locations.count), label: "Connected locations"),
            OverviewMetricDisplay(value: String(pendingCount), label: "Pending changes"),
            OverviewMetricDisplay(value: String(workspace.openConflictCount), label: "Open conflicts"),
        ],
        lastScanText: lastScanText,
        holdBanners: holds,
        refusalBanners: refusals,
        locations: locations,
        locationSummary: "\(availableCount) of \(workspace.locations.count) available",
        pending: pending,
        pendingEmptyMessage: lastScanText.map { "Nothing waiting — Aetherloom checked \($0)." }
            ?? "Nothing waiting — run a scan to check for changes.",
        recentActivity: Array(activityRows(activity, locations: workspace.locations, now: now).prefix(6)),
        isBusy: status.isBusy,
        isEmpty: workspace.syncSets.isEmpty
    )
}

private func overviewStatus(
    _ status: WorkspaceStatus,
    isEmpty: Bool
) -> (headline: String, text: String, tone: StatusTone, isBusy: Bool) {
    if isEmpty {
        return ("Create your first sync set", "Ready to begin", .neutral, false)
    }
    switch status {
    case let .busy(stage):
        let label = activeStageLabel(stage)
        return ("Aetherloom is checking your weave", label, .neutral, true)
    case let .needsReview(count):
        let text = count == 1 ? "1 item needs review" : "\(count) items need review"
        return ("Changes need your review", text, .attention, false)
    case .pausedForSafety:
        return ("Sync is paused for safety", "Paused for safety", .paused, false)
    case .allInSync:
        return ("Everything in sync", "Everything in sync", .healthy, false)
    }
}

private func activeStageLabel(_ stage: String) -> String {
    switch stage {
    case "Availability": "Checking availability…"
    case "Scan": "Scanning…"
    case "Plan": "Planning…"
    case "Preview": "Preparing preview…"
    case "Execute", "Executing": "Syncing…"
    default: "\(stage)…"
    }
}

private func locationAction(for state: LocationState) -> OverviewLocationAction {
    if state.accountLabel == nil {
        switch state.location.kind {
        case .iCloudDrive, .googleDrive, .oneDrive, .dropbox:
            return .connectProvider(state.location.kind)
        case .localFolder, .nasFolder:
            break
        }
    }
    if state.location.kind == .nasFolder,
       case .unavailable(.volumeNotMounted) = state.availability {
        return .wakeAndMount
    }
    return .none
}

private func locationScopeText(_ location: SyncLocation) -> String {
    switch location.scope {
    case let .selectedFolder(path):
        return path.rawValue
    case .entireDrive:
        return location.configuration["path"]
            ?? location.configuration["url"]
            ?? "Entire drive"
    }
}

private func overviewTotalsText(_ totals: PreviewTotals) -> String {
    let count = DisplayFormatting.itemCount(totals.changeCount)
    guard totals.byteTotal > 0 else { return count }
    return "\(count) · \(DisplayFormatting.byteCount(totals.byteTotal))"
}
