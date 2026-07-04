import SwiftUI

struct SyncSetsView: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Sync Sets",
                    subtitle: "Folders and drives you chose to keep in sync, grouped by mirror."
                )

                ForEach(store.syncSets) { syncSet in
                    SyncSetCard(syncSet: syncSet)
                }

                Button {
                    store.showingNewSyncSet = true
                } label: {
                    Label("New Sync Set", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }
}

struct SyncSetCard: View {
    @Environment(DemoStore.self) private var store
    var syncSet: SyncSet

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncSet.name)
                        .font(.title3.weight(.semibold))
                    Text(syncSet.trackedFiles > 0
                         ? "\(syncSet.trackedFiles.formatted()) files tracked"
                         : "Not scanned yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(text: syncSet.statusText, tone: syncSet.tone)
            }

            VStack(spacing: 8) {
                ForEach(syncSet.folders) { folder in
                    HStack(spacing: 10) {
                        ServiceMark(service: folder.service, size: 22)
                        Text(folder.service.displayName)
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 10)
                        Text(folder.location)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if let note = syncSet.safetyNote {
                Label {
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.orange)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack(spacing: 14) {
                Label("Last sync \(syncSet.lastSync.lowercased())", systemImage: "clock")
                Label(syncSet.pendingSummary, systemImage: "list.bullet")
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            HStack {
                Button {
                    store.scan()
                } label: {
                    Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    store.showingPreviewChanges = true
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                }
                Spacer()
                Button {
                    store.togglePause(syncSet)
                } label: {
                    Label(syncSet.isPaused ? "Resume" : "Pause",
                          systemImage: syncSet.isPaused ? "play.circle" : "pause.circle")
                }
            }
            .buttonStyle(.bordered)
        }
        .card()
    }
}

#Preview {
    SyncSetsView()
        .environment(DemoStore())
        .tint(Theme.accent)
        .frame(width: 900, height: 900)
}
