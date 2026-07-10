import AetherloomBridge
import AetherloomCore
import SwiftUI

struct SyncSetsView: View {
    @EnvironmentObject private var appModel: AppModel

    private var displayedStates: [SyncSetState] {
        guard let states = appModel.workspace?.syncSets else { return [] }
        guard let locationID = appModel.syncSetsLocationFilter else { return states }
        return states.filter { $0.syncSet.locations.contains(locationID) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Sync Sets",
                    subtitle: "Folders and drives you chose to keep in sync, grouped by mirror."
                )

                if let locationID = appModel.syncSetsLocationFilter {
                    filterBanner(locationID)
                }

                if appModel.workspace?.syncSets.isEmpty == true {
                    EmptyStateView(
                        systemImage: "folder.badge.plus",
                        title: "No Sync Sets Yet",
                        message: "Create a sync set to choose at least two locations to keep aligned."
                    )
                    newSyncSetButton
                } else if displayedStates.isEmpty {
                    EmptyStateView(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No Matching Sync Sets",
                        message: "No sync set currently uses this location."
                    )
                } else {
                    ForEach(displayedStates) { state in
                        SyncSetCard(
                            state: state,
                            locations: appModel.workspace?.locations ?? [],
                            isBusy: appModel.busySyncSets.contains(state.id)
                        )
                    }
                    newSyncSetButton
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }

    private func filterBanner(_ locationID: LocationID) -> some View {
        let name = appModel.workspace?.locations.first(where: { $0.id == locationID })?.location.displayName
            ?? locationID.displayName
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.accent)
            Text("Showing sync sets that use \(name)")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Show All") {
                appModel.syncSetsLocationFilter = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var newSyncSetButton: some View {
        Button {
            guard appModel.activeSheet == nil else { return }
            appModel.activeSheet = .newSyncSet
        } label: {
            Label("New Sync Set", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

private struct SyncSetCard: View {
    @EnvironmentObject private var appModel: AppModel
    var state: SyncSetState
    var locations: [LocationState]
    var isBusy: Bool

    @State private var confirmsDeletion = false

    private var line: StatusLine {
        statusLine(for: state, now: Date())
    }

    private var stateLocations: [LocationState] {
        state.syncSet.locations.compactMap { id in locations.first(where: { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.syncSet.name)
                        .font(.title3.weight(.semibold))
                    Text(state.trackedItemCount > 0
                         ? "\(state.trackedItemCount.formatted()) items tracked"
                         : "Not scanned yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .liveNumericTransition()
                }

                Spacer()
                StatusBadge(text: line.text, tone: line.tone)
                overflowMenu
            }

            VStack(spacing: 8) {
                ForEach(stateLocations) { location in
                    locationRow(location)
                }
            }

            if let note = line.safetyNote {
                Label {
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(line.tone.color)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()
            metrics
            actions
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onTapGesture {
            guard appModel.activeSheet == nil else { return }
            appModel.activeSheet = .syncSetDetail(state.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.syncSet.name), \(line.text)")
        .alert("Delete \(state.syncSet.name)?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Sync Set", role: .destructive) {
                Task { await appModel.deleteSyncSet(state.id) }
            }
        } message: {
            Text("This stops syncing and removes Aetherloom's saved sync memory. It never touches files in any location.")
        }
    }

    private func locationRow(_ location: LocationState) -> some View {
        let unavailableReason: String? = switch location.availability {
        case .available: nil
        case let .unavailable(reason): reason.detail
        }
        return HStack(spacing: 10) {
            ServiceMark(provider: location.location.kind.presentation, size: 24)
            Text(location.location.displayName)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 10)
            Text(scopeText(location.location.scope))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if unavailableReason != nil {
                StatusBadge(
                    text: statusLine(for: location, now: Date()).text,
                    tone: tone(for: location.availability)
                )
            }
        }
        .opacity(unavailableReason == nil ? 1 : 0.55)
        .help(unavailableReason ?? "Available")
    }

    @ViewBuilder
    private var metrics: some View {
        if isBusy || state.phase != .idle {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(state.phase == .executing ? "Syncing changes…" : "Preparing changes…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 14) {
                Label(
                    state.trackedItemCount > 0 ? DisplayFormatting.fileCount(state.trackedItemCount) : "—",
                    systemImage: "doc.on.doc"
                )
                Label(lastSyncText, systemImage: "clock")
                Label(pendingText, systemImage: "list.bullet")
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .liveNumericTransition()
        }
    }

    private var lastSyncText: String {
        guard let finishedAt = state.lastRun?.finishedAt else { return "Never synced" }
        return "Last sync \(DisplayFormatting.relativeDate(finishedAt, now: Date()))"
    }

    private var pendingText: String {
        guard let digest = state.lastPreparation else {
            return "Preview changes after the first scan"
        }
        return DisplayFormatting.preparationSummary(digest)
    }

    private var actions: some View {
        HStack {
            Button {
                Task { await appModel.preview(state.id) }
            } label: {
                Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(isBusy || state.isPaused)

            Button {
                Task { await appModel.syncNow(state.id) }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || state.isPaused)

            Spacer()
            Button {
                Task { await appModel.setPaused(!state.isPaused, syncSetID: state.id) }
            } label: {
                Label(
                    state.isPaused ? "Resume" : "Pause",
                    systemImage: state.isPaused ? "play.circle" : "pause.circle"
                )
            }
            .disabled(isBusy)
        }
        .buttonStyle(.bordered)
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                guard appModel.activeSheet == nil else { return }
                appModel.activeSheet = .syncSetDetail(state.id)
            } label: {
                Label("Edit Sync Set…", systemImage: "slider.horizontal.3")
            }

            // 🎭 placeholder: Finder reveal — see architecture/ui/11-functioning-vs-placeholder.md
            Button {} label: {
                HStack {
                    Label("Reveal in Finder", systemImage: "finder")
                    PlaceholderChip(text: "Arrives with real providers")
                }
            }
            .disabled(true)

            Divider()
            Button("Delete Sync Set…", systemImage: "trash", role: .destructive) {
                confirmsDeletion = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 24, minHeight: 24)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(state.syncSet.name)")
    }
}

func scopeText(_ scope: SyncScope) -> String {
    switch scope {
    case .entireDrive:
        "Entire drive"
    case let .selectedFolder(path):
        path.rawValue
    }
}

#Preview("Standard four cards") {
    let fixture = OverviewPreviewFixture.populated
    SyncSetsView()
        .environmentObject(
            AppModel(
                session: PreviewEngineSession(snapshot: fixture.workspace),
                bootstrapImmediately: false,
                initialWorkspace: fixture.workspace,
                initialPhase: .ready,
                initialActivity: fixture.activity,
                initialPreparations: fixture.preparations
            )
        )
        .tint(Theme.accent)
        .frame(width: 900, height: 900)
}

#Preview("Empty") {
    SyncSetsView()
        .environmentObject(
            AppModel(
                session: PreviewEngineSession(snapshot: .previewReady),
                bootstrapImmediately: false,
                initialWorkspace: .previewReady,
                initialPhase: .ready
            )
        )
        .tint(Theme.accent)
        .frame(width: 900, height: 700)
}
