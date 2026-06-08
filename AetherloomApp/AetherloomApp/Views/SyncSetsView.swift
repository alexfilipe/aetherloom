import SwiftUI
import AetherloomCore

struct SyncSetsView: View {
    @ObservedObject var model: AetherloomDashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Sync Sets",
                    subtitle: "Selected folders and drives grouped by mirror.",
                    systemImage: "folder.badge.gearshape"
                )

                ForEach(model.syncSets) { syncSet in
                    SyncSetCard(syncSet: syncSet)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SyncSetCard: View {
    var syncSet: SyncSetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(syncSet.name)
                        .font(.title3.weight(.semibold))
                    Text("\(syncSet.trackedFiles.formatted()) files tracked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(text: syncSet.status, tone: syncSet.tone)
            }

            VStack(spacing: 8) {
                ForEach(syncSet.providers) { provider in
                    ProviderLocationRow(provider: provider.provider, location: provider.location)
                }
            }

            Divider()

            HStack(spacing: 16) {
                Label("Last sync \(syncSet.lastSync)", systemImage: "clock")
                Label(syncSet.pendingSummary, systemImage: "list.bullet")
                Label("\(syncSet.conflicts) conflicts", systemImage: "exclamationmark.triangle")
                Label("\(syncSet.warnings) warnings", systemImage: "shield.lefthalf.filled")
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            HStack {
                Button {
                } label: {
                    Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                } label: {
                    Label("Apply Sync Plan", systemImage: "play.circle")
                }
                .disabled(syncSet.riskLevel != .safe)
                Spacer()
                Button {
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            .buttonStyle(.bordered)
        }
        .aetherloomCard()
    }
}
