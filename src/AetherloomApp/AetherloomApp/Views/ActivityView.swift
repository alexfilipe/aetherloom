import AetherloomBridge
import AetherloomCore
import AppKit
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var appModel

    private let loadsOnAppear: Bool
    @State private var selectedCategory: ActivityCategory?
    @State private var selectedSyncSetID: UUID?
    @State private var searchText: String
    @State private var selectedRunID: UUID?

    init(
        loadsOnAppear: Bool = true,
        initialCategory: ActivityCategory? = nil,
        initialSyncSetID: UUID? = nil,
        initialSearchText: String = ""
    ) {
        self.loadsOnAppear = loadsOnAppear
        _selectedCategory = State(initialValue: initialCategory)
        _selectedSyncSetID = State(initialValue: initialSyncSetID)
        _searchText = State(initialValue: initialSearchText)
        _selectedRunID = State(initialValue: nil)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(
                        title: "Activity",
                        subtitle: "Everything Aetherloom does, as it happens."
                    )

                    filterBar
                    feed(now: context.date)
                }
                .padding(28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(ContentBackdrop())
        .toolbar {
            ToolbarItemGroup {
                // 🎭 placeholder: activity log export — see architecture/ui/11-functioning-vs-placeholder.md.
                Button("Export…", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
                    .help("Activity log export is not available yet")
                PlaceholderChip(text: "Log export coming soon")
            }
        }
        .task {
            guard loadsOnAppear else { return }
            await consumeDeepLinkOrLoad()
        }
        .onChange(of: appModel.activityFilterRunID) { _, runID in
            guard loadsOnAppear, runID != nil else { return }
            Task { await consumeDeepLinkOrLoad() }
        }
        .onDisappear {
            guard loadsOnAppear else { return }
            appModel.deactivateActivityFeed()
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ActivityFilterChip(title: "All", isSelected: selectedCategory == nil && selectedRunID == nil) {
                        selectedCategory = nil
                        selectedRunID = nil
                        reload()
                    }

                    ForEach(ActivityCategory.allCases, id: \.self) { category in
                        ActivityFilterChip(
                            title: category.filterTitle,
                            presentation: category.presentation,
                            isSelected: selectedCategory == category && selectedRunID == nil
                        ) {
                            selectedCategory = category
                            selectedRunID = nil
                            reload()
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Picker("Sync set", selection: syncSetSelection) {
                    Text("All Sets").tag(UUID?.none)
                    ForEach(appModel.workspace?.syncSets ?? []) { state in
                        Text(state.syncSet.name).tag(Optional(state.id))
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .accessibilityLabel("Filter activity by sync set")

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search message or path", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 24, minHeight: 24)
                        .accessibilityLabel("Clear activity search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                )

                if hasActiveFilters {
                    Button("Clear Filters", action: clearFilters)
                        .buttonStyle(.borderless)
                }
            }

            if let selectedRunID {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    Text("Showing run \(selectedRunID.uuidString.prefix(8))")
                    Button("Clear") {
                        self.selectedRunID = nil
                        reload()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !trimmedSearch.isEmpty {
                Text("Searching recent activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card(hoverLift: false)
    }

    @ViewBuilder
    private func feed(now: Date) -> some View {
        let rows = activityRows(
            appModel.activityEntries,
            locations: appModel.workspace?.locations ?? [],
            now: now
        )
        let visibleRows = search(rows)
        let groups = runGroups(visibleRows)

        if appModel.activityIsLoading && appModel.activityEntries.isEmpty {
            ProgressView("Loading activity…")
                .frame(maxWidth: .infinity, minHeight: 220)
                .card(hoverLift: false)
        } else if groups.isEmpty {
            if hasActiveFilters {
                VStack(spacing: 12) {
                    EmptyStateView(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "Nothing matches these filters.",
                        message: "Try another category, sync set, run, or search."
                    )
                    Button("Clear Filters", action: clearFilters)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "No activity yet",
                    message: "Activity appears here the moment Aetherloom starts working."
                )
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if showsDaySeparator(for: group, at: index, in: groups) {
                        Text(dayLabel(for: group.finishedAt, now: now))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 8)
                            .accessibilityAddTraits(.isHeader)
                    }

                    ActivityRunGroup(
                        group: group,
                        syncSetName: syncSetName(for: group.syncSetID),
                        outcome: outcome(for: group),
                        now: now,
                        openConflict: { conflictID in
                            appModel.show(.conflicts, focusing: conflictID)
                        }
                    )
                }

                if appModel.activityCanLoadMore {
                    Button {
                        Task { await appModel.loadMoreActivity() }
                    } label: {
                        if appModel.activityIsLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Load More")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.activityIsLoading)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var syncSetSelection: Binding<UUID?> {
        Binding(
            get: { selectedSyncSetID },
            set: { newValue in
                selectedSyncSetID = newValue
                selectedRunID = nil
                reload()
            }
        )
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveFilters: Bool {
        selectedCategory != nil || selectedSyncSetID != nil || selectedRunID != nil || !trimmedSearch.isEmpty
    }

    private func search(_ rows: [ActivityRowDisplay]) -> [ActivityRowDisplay] {
        guard !trimmedSearch.isEmpty else { return rows }
        return rows.filter { row in
            row.message.localizedCaseInsensitiveContains(trimmedSearch)
                || row.path?.rawValue.localizedCaseInsensitiveContains(trimmedSearch) == true
        }
    }

    private func syncSetName(for id: UUID?) -> String {
        guard let id else { return "Aetherloom" }
        return appModel.workspace?.syncSets.first(where: { $0.id == id })?.syncSet.name ?? "Sync set"
    }

    private func outcome(for group: RunGroupDisplay) -> ActivityOutcomeBadge {
        guard let runID = group.runID,
              let digest = appModel.workspace?.syncSets
                .compactMap(\.lastRun)
                .first(where: { $0.runID == runID }) else {
            return ActivityOutcomeBadge(text: "Recorded", tone: .neutral)
        }
        switch digest.outcome {
        case .completed:
            return ActivityOutcomeBadge(text: "Completed", tone: .healthy)
        case .held:
            return ActivityOutcomeBadge(text: "Held", tone: .paused)
        case .refused:
            return ActivityOutcomeBadge(text: "Refused", tone: .paused)
        case .stoppedForReplan:
            return ActivityOutcomeBadge(text: "Stopped to replan", tone: .attention)
        case .cancelled:
            return ActivityOutcomeBadge(text: "Cancelled", tone: .neutral)
        case .failed:
            return ActivityOutcomeBadge(text: "Failed", tone: .attention)
        }
    }

    private func showsDaySeparator(
        for group: RunGroupDisplay,
        at index: Int,
        in groups: [RunGroupDisplay]
    ) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(group.finishedAt, inSameDayAs: groups[index - 1].finishedAt)
    }

    private func dayLabel(for date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
           Calendar.current.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func clearFilters() {
        selectedCategory = nil
        selectedSyncSetID = nil
        selectedRunID = nil
        searchText = ""
        reload()
    }

    private func reload() {
        Task {
            await appModel.loadActivity(
                categories: selectedCategory.map { [$0] },
                syncSetID: selectedSyncSetID,
                runID: selectedRunID
            )
        }
    }

    @MainActor
    private func consumeDeepLinkOrLoad() async {
        if let runID = appModel.consumeActivityRunFilter() {
            selectedCategory = nil
            selectedSyncSetID = nil
            searchText = ""
            selectedRunID = runID
        }
        await appModel.loadActivity(
            categories: selectedCategory.map { [$0] },
            syncSetID: selectedSyncSetID,
            runID: selectedRunID
        )
    }
}

private struct ActivityFilterChip: View {
    var title: String
    var presentation: ActivityCategoryPresentation?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let presentation {
                    Image(systemName: presentation.symbolName)
                        .foregroundStyle(presentation.tone.color)
                }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (presentation?.tone.color ?? Theme.accent).opacity(isSelected ? 0.16 : 0.06),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    (presentation?.tone.color ?? Theme.accent).opacity(isSelected ? 0.38 : 0.12),
                    lineWidth: isSelected ? 1 : 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ActivityOutcomeBadge {
    var text: String
    var tone: Tone
}

private struct ActivityRunGroup: View {
    var group: RunGroupDisplay
    var syncSetName: String
    var outcome: ActivityOutcomeBadge
    var now: Date
    var openConflict: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.runID != nil {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(syncSetName)
                        .font(.subheadline.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(runRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(absoluteRunRange)
                    Spacer(minLength: 12)
                    StatusBadge(text: outcome.text, tone: outcome.tone)
                }
                .padding(.bottom, 10)
            }

            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                ActivityEntryRow(row: row, openConflict: openConflict)
                    .padding(.vertical, 10)
                if index < group.rows.count - 1 {
                    Divider()
                        .padding(.leading, 38)
                }
            }
        }
        .card(hoverLift: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(syncSetName), \(outcome.text), \(group.rows.count) logged \(group.rows.count == 1 ? "event" : "events")")
    }

    private var runRange: String {
        let started = DisplayFormatting.relativeDate(group.startedAt, now: now)
        let finished = DisplayFormatting.relativeDate(group.finishedAt, now: now)
        return started == finished ? finished : "\(started) → \(finished)"
    }

    private var absoluteRunRange: String {
        let started = DisplayFormatting.absoluteDate(group.startedAt)
        let finished = DisplayFormatting.absoluteDate(group.finishedAt)
        return started == finished ? finished : "\(started) – \(finished)"
    }
}

private struct ActivityEntryRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var row: ActivityRowDisplay
    var openConflict: (UUID) -> Void

    @State private var isDetailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(row.tone.color)
                .frame(width: 26, height: 26)
                .background(row.tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(row.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(row.relativeTimestamp)
                        .help(row.absoluteTimestamp)
                    if let location = row.location {
                        Text("·")
                        Text(location.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let path = row.path {
                    PathText(path)
                        .font(.caption)
                }

                if let detail = row.detail {
                    if row.category == .advisory || isDetailExpanded {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }

                    if row.category != .advisory {
                        Button(isDetailExpanded ? "Hide Detail" : "Show Detail") {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                                isDetailExpanded.toggle()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .frame(minHeight: 24)
                    }
                }
            }

            Spacer(minLength: 10)

            if let conflictID = row.relatedConflictID {
                Button("Review Conflict", systemImage: "chevron.right") {
                    openConflict(conflictID)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Review this conflict")
                .accessibilityLabel("Review conflict")
                .frame(minWidth: 24, minHeight: 24)
            }
        }
        .padding(.leading, row.category == .safety ? 9 : 0)
        .overlay(alignment: .leading) {
            if row.category == .safety {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(row.tone.color.opacity(0.72))
                    .frame(width: 3)
            }
        }
        .contextMenu {
            Button("Copy Message") { copy(row.message) }
            if let path = row.path {
                Button("Copy Path") { copy(path.rawValue) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private extension ActivityCategory {
    var filterTitle: String {
        switch self {
        case .sync: "Sync"
        case .safety: "Safety"
        case .conflict: "Conflicts"
        case .advisory: "Suggestions"
        case .provider: "Providers"
        case .error: "Errors"
        }
    }
}

private struct ActivityPreviewFixture {
    var workspace: WorkspaceSnapshot
    var entries: [ActivityEntry]

    static let populated = makePopulated()

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makePopulated() -> ActivityPreviewFixture {
        let world = DemoWorld.standard
        let syncSet = world.syncSets.first!
        let locations = world.locations.map {
            LocationState(location: $0, availability: .available, lastCheckedAt: now)
        }
        let latestRunID = id(1)
        let olderRunID = id(2)
        let state = SyncSetState(
            syncSet: syncSet,
            isPaused: false,
            lastRun: RunDigest(runID: latestRunID, finishedAt: now.addingTimeInterval(-60), outcome: .completed),
            trackedItemCount: 12,
            openConflictCount: 1
        )
        let entries = [
            ActivityEntry(
                id: id(10),
                occurredAt: now.addingTimeInterval(-60),
                syncSetID: syncSet.id,
                runID: latestRunID,
                category: .sync,
                message: "Sync finished."
            ),
            ActivityEntry(
                id: id(11),
                occurredAt: now.addingTimeInterval(-90),
                syncSetID: syncSet.id,
                runID: latestRunID,
                category: .advisory,
                path: "/Documents/Budget.xlsx",
                message: "A suggestion is ready for this conflict.",
                detail: "Generated by Aetherloom Heuristic Advisor via heuristic analysis."
            ),
            ActivityEntry(
                id: id(12),
                occurredAt: now.addingTimeInterval(-120),
                syncSetID: syncSet.id,
                runID: latestRunID,
                category: .conflict,
                path: "/Documents/Budget.xlsx",
                message: ActivityMessageCatalog.conflictPreserved,
                relatedConflictID: id(90)
            ),
            ActivityEntry(
                id: id(13),
                occurredAt: now.addingTimeInterval(-180),
                syncSetID: syncSet.id,
                runID: latestRunID,
                category: .sync,
                message: "Sync started for 3 locations."
            ),
            ActivityEntry(
                id: id(20),
                occurredAt: now.addingTimeInterval(-86_400),
                syncSetID: syncSet.id,
                runID: olderRunID,
                category: .safety,
                message: ActivityMessageCatalog.providerUnavailable,
                detail: "The provider did not return a complete scan."
            ),
            ActivityEntry(
                id: id(21),
                occurredAt: now.addingTimeInterval(-86_460),
                syncSetID: syncSet.id,
                runID: olderRunID,
                category: .sync,
                message: "Sync started for 3 locations."
            ),
            ActivityEntry(
                id: id(30),
                occurredAt: now.addingTimeInterval(-172_800),
                category: .provider,
                message: "iCloud Drive became available."
            ),
        ]
        return ActivityPreviewFixture(
            workspace: WorkspaceSnapshot(
                locations: locations,
                syncSets: [state],
                openConflictCount: 1,
                status: .needsReview(count: 1)
            ),
            entries: entries
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "80000000-0000-0000-0000-%012d", suffix))!
    }
}

#Preview("Populated grouped feed") {
    let fixture = ActivityPreviewFixture.populated
    ActivityView(loadsOnAppear: false)
        .environment(
            AppModel(
                session: PreviewEngineSession(snapshot: fixture.workspace),
                bootstrapImmediately: false,
                initialWorkspace: fixture.workspace,
                initialPhase: .ready,
                initialActivity: fixture.entries
            )
        )
        .tint(Theme.accent)
        .frame(width: 900, height: 760)
}

#Preview("Filtered empty") {
    let fixture = ActivityPreviewFixture.populated
    ActivityView(loadsOnAppear: false, initialCategory: .error)
        .environment(
            AppModel(
                session: PreviewEngineSession(snapshot: fixture.workspace),
                bootstrapImmediately: false,
                initialWorkspace: fixture.workspace,
                initialPhase: .ready,
                initialActivity: []
            )
        )
        .tint(Theme.accent)
        .frame(width: 900, height: 680)
}

#Preview("Fresh empty") {
    ActivityView(loadsOnAppear: false)
        .environment(
            AppModel(
                session: PreviewEngineSession(snapshot: .previewReady),
                bootstrapImmediately: false,
                initialWorkspace: .previewReady,
                initialPhase: .ready
            )
        )
        .tint(Theme.accent)
        .frame(width: 900, height: 680)
}
