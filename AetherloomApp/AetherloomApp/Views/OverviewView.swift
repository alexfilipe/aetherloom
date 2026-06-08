import SwiftUI
import AetherloomCore

struct OverviewView: View {
    @ObservedObject var model: AetherloomDashboardModel

    private let gridColumns = [
        GridItem(.adaptive(minimum: 230), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Aetherloom",
                    subtitle: "Keep your clouds interwoven.",
                    systemImage: "sparkles"
                )

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    MetricTile(
                        title: "Providers healthy",
                        value: "\(model.healthyProviderCount) of \(model.providers.count)",
                        systemImage: "checkmark.shield",
                        tone: model.healthyProviderCount == model.providers.count ? .healthy : .attention
                    )
                    MetricTile(
                        title: "Pending plan actions",
                        value: "\(model.pendingActionCount)",
                        systemImage: "list.bullet.rectangle",
                        tone: .neutral
                    )
                    MetricTile(
                        title: "Conflicts preserved",
                        value: "\(model.conflicts.count)",
                        systemImage: "doc.on.doc",
                        tone: model.conflicts.isEmpty ? .healthy : .attention
                    )
                    MetricTile(
                        title: "Paused sync sets",
                        value: "\(model.pausedSyncSetCount)",
                        systemImage: "pause.circle",
                        tone: model.pausedSyncSetCount == 0 ? .healthy : .paused
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Providers", accessory: "Selected folders")
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(model.providers) { provider in
                            ProviderCard(provider: provider)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Plan Preview", accessory: SyncRiskLevel.needsReview.displayName)
                        PlanPreviewCard(lines: model.planPreview, riskLevel: .needsReview)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Recent Activity", accessory: "Today")
                        RecentActivityCard(activity: Array(model.activity.prefix(4)))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProviderCard: View {
    var provider: ProviderCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderMark(provider: provider.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.id.displayName)
                        .font(.headline)
                    Text(provider.status.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                StatusBadge(text: provider.health, tone: provider.tone)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let account = provider.account {
                    Label(account, systemImage: "person.crop.circle")
                }
                if let selectedLocation = provider.selectedLocation {
                    Label(selectedLocation, systemImage: "folder")
                }
                Label(provider.permissions, systemImage: "lock.shield")
                Label("Last checked \(provider.lastChecked)", systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            if let warning = provider.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
            } label: {
                Label(provider.actionTitle, systemImage: buttonIcon)
            }
            .buttonStyle(.bordered)
        }
        .aetherloomCard()
    }

    private var buttonIcon: String {
        switch provider.tone {
        case .paused, .attention:
            "eye"
        case .healthy, .neutral:
            "slider.horizontal.3"
        }
    }
}

struct PlanPreviewCard: View {
    var lines: [PlanPreviewLine]
    var riskLevel: SyncRiskLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadge(
                    text: riskLevel.displayName,
                    tone: riskLevel == .safe ? .healthy : riskLevel == .needsReview ? .attention : .paused
                )
                Spacer()
                Button {
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            ForEach(lines) { line in
                HStack(spacing: 10) {
                    Image(systemName: line.systemImage)
                        .foregroundStyle(color(for: line.tone))
                        .frame(width: 22)
                    Text(line.title)
                    Spacer()
                    Text("\(line.count)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherloomCard()
    }

    private func color(for tone: AetherloomTone) -> Color {
        switch tone {
        case .healthy:
            .green
        case .attention:
            .orange
        case .paused:
            .red
        case .neutral:
            .secondary
        }
    }
}

struct RecentActivityCard: View {
    var activity: [ActivityLogItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(activity) { item in
                ActivityRow(item: item)
                if item.id != activity.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherloomCard()
    }
}
