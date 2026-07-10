import AetherloomBridge
import AetherloomCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var appModel: AppModel

    private let gridColumns = [
        GridItem(.adaptive(minimum: 250), spacing: 14)
    ]

    var body: some View {
        if let workspace = appModel.workspace {
            let display = overviewDisplay(
                workspace: workspace,
                preparations: appModel.preparations,
                activity: appModel.recentActivity,
                now: Date()
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PageHeader(
                        title: "Overview",
                        subtitle: "Your files, safely woven across every drive."
                    )

                    ForEach(display.holdBanners) { banner in
                        SafetyBanner(
                            title: "\(banner.syncSetName) · Needs review",
                            message: banner.message,
                            actionTitle: "Review"
                        ) {
                            appModel.showCachedPreview(for: banner.syncSetID)
                        }
                    }
                    .accessibilitySortPriority(3)

                    ForEach(display.refusalBanners) { banner in
                        InlineBanner(
                            title: "\(banner.syncSetName) · Paused for safety",
                            message: banner.message,
                            detail: banner.detail
                        )
                    }
                    .accessibilitySortPriority(3)

                    OverviewHero(display: display)
                        .accessibilitySortPriority(4)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Services", accessory: display.locationSummary)
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(display.locations) { location in
                                OverviewServiceTile(location: location)
                            }
                        }
                    }
                    .accessibilitySortPriority(2)

                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Pending changes", accessory: display.pending?.syncSetName)
                            PendingChangesCard(display: display)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Recent activity", accessory: nil)
                            RecentActivityCard(rows: display.recentActivity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilitySortPriority(1)
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ContentBackdrop())
        } else {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Preparing Overview",
                message: "Aetherloom is loading the current workspace state."
            )
            .padding(24)
            .background(ContentBackdrop())
        }
    }
}

// MARK: - Hero

private struct OverviewHero: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var display: OverviewDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 84, height: 84)
                    Circle()
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        .frame(width: 84, height: 84)
                    if display.isBusy {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                            .symbolEffect(.rotate, isActive: !reduceMotion)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    } else {
                        Image("LogoMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(display.headline)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

                    StatusBadge(
                        text: display.statusText,
                        tone: display.statusTone,
                        onDark: true
                    )

                    if let lastScanText = display.lastScanText {
                        Text("Last scan \(lastScanText)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                Spacer(minLength: 20)

                if display.isEmpty {
                    Button {
                        guard appModel.activeSheet == nil else { return }
                        appModel.activeSheet = .newSyncSet
                    } label: {
                        Label("Create Sync Set", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .frame(minWidth: 172)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Create your first sync set")
                } else {
                    Button {
                        Task { await appModel.syncAll() }
                    } label: {
                        Label("Sync All Now", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .frame(minWidth: 172)
                            .background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(display.isBusy)
                    .accessibilityLabel(display.isBusy ? display.statusText : "Sync All Now")
                }
            }

            HStack(spacing: 10) {
                ForEach(display.metrics) { metric in
                    MetricTile(value: metric.value, label: metric.label, onDark: true)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            WeaveMesh()
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(display.headline). \(display.statusText)")
    }
}

// MARK: - Services

private struct OverviewServiceTile: View {
    @EnvironmentObject private var appModel: AppModel
    var location: OverviewLocationDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                ServiceMark(provider: location.provider, size: 36)
                Spacer(minLength: 8)
                if location.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(location.status.text)
                }
                StatusBadge(text: location.status.text, tone: location.status.tone)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(location.displayName)
                    .font(.headline)
                    .lineLimit(1)
                // 🎭 placeholder: scripted account labels — see architecture/ui/11-functioning-vs-placeholder.md.
                Text(location.accountLabel.map { "Demo account · \($0)" } ?? "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label(location.scopeText, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Checked \(location.lastCheckedText)", systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let note = location.status.safetyNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(location.status.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onTapGesture {
            appModel.showSyncSets(using: location.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(location.displayName), \(location.status.text)")
        .accessibilityHint("Open Sync Sets using this location")
    }

    @ViewBuilder
    private var action: some View {
        switch location.action {
        case .none:
            EmptyView()
        case let .connectProvider(kind):
            HStack {
                Button("Connect…") {
                    guard appModel.activeSheet == nil else { return }
                    appModel.activeSheet = .connectProvider(kind)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Preview connecting \(kind.displayName)")
                PlaceholderChip(text: "Provider connection coming soon")
            }
            // 🎭 placeholder: provider connection — see architecture/ui/11-functioning-vs-placeholder.md
        case .wakeAndMount:
            HStack {
                Button("Wake & Mount") {
                    Task { await appModel.wakeAndMountNAS() }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Wake and mount the demo NAS")
                PlaceholderChip(text: "Demo control · real NAS mounting coming soon")
            }
            // 🎭 placeholder: NAS wake and mount control — see architecture/ui/11-functioning-vs-placeholder.md
        }
    }
}

// MARK: - Pending changes

private struct PendingChangesCard: View {
    @EnvironmentObject private var appModel: AppModel
    var display: OverviewDisplay

    var body: some View {
        if let pending = display.pending {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pending.headline)
                        .font(.headline)
                    Spacer()
                    Text(pending.totalsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .liveNumericTransition()
                }

                ForEach(pending.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text(entry.path.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if entry.id != pending.entries.last?.id {
                        Divider()
                    }
                }

                Divider()
                HStack {
                    Label("Nothing is applied without preview", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        appModel.showCachedPreview(for: pending.syncSetID)
                    } label: {
                        Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.busySyncSets.contains(pending.syncSetID))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else {
            EmptyStateView(
                systemImage: "checkmark.seal.fill",
                title: "Up to date",
                message: display.pendingEmptyMessage
            )
        }
    }
}

// MARK: - Recent activity

private struct RecentActivityCard: View {
    @EnvironmentObject private var appModel: AppModel
    var rows: [ActivityRowDisplay]

    var body: some View {
        if rows.isEmpty {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: "No activity yet",
                message: "Run a scan to start the accountability trail."
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    OverviewActivityRow(row: row)
                        .padding(.vertical, 8)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
                Divider()
                Button("Open Activity") {
                    appModel.show(.activity)
                }
                .buttonStyle(.link)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

private struct OverviewActivityRow: View {
    var row: ActivityRowDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbolName)
                .foregroundStyle(row.tone.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.message)
                    .font(.subheadline)
                    .lineLimit(2)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(row.relativeTimestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(row.absoluteTimestamp)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private struct OverviewPreviewHost: View {
    @State private var model: AppModel

    init(_ fixture: OverviewPreviewFixture) {
        _model = State(initialValue: AppModel(
            session: PreviewEngineSession(snapshot: fixture.workspace),
            bootstrapImmediately: false,
            initialWorkspace: fixture.workspace,
            initialPhase: .ready,
            initialActivity: fixture.activity,
            initialPreparations: fixture.preparations,
            initialBusySyncSets: fixture.busySyncSets
        ))
    }

    var body: some View {
        OverviewView()
            .environmentObject(model)
            .tint(Theme.accent)
            .frame(width: 1100, height: 900)
    }
}

#Preview("Populated") {
    OverviewPreviewHost(.populated)
}

#Preview("All in sync") {
    OverviewPreviewHost(.allInSync)
}

#Preview("Busy") {
    OverviewPreviewHost(.busy)
}

#Preview("Empty") {
    OverviewPreviewHost(.empty)
}
