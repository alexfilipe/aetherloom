import SwiftUI

struct ContentView: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            sidebar
        } detail: {
            detailView
                .frame(minWidth: 760, minHeight: 560)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $store.showingPreviewChanges) {
            PreviewChangesSheet()
        }
        .sheet(isPresented: $store.showingNewSyncSet) {
            NewSyncSetSheet()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var store = store

        return List(selection: $store.selectedDestination) {
            Section {
                ForEach(SidebarDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .badge(badge(for: destination))
                        .tag(destination)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        .safeAreaInset(edge: .top) {
            sidebarHeader
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            AppLogoMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aetherloom")
                    .font(.headline.weight(.bold))
                    .fontDesign(.rounded)
                Text("Every drive, one weave")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func badge(for destination: SidebarDestination) -> Int {
        switch destination {
        case .conflicts: store.unresolvedConflictCount
        case .syncSets: store.pausedSyncSetCount
        default: 0
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
            } else {
                Circle()
                    .fill(store.everythingInSync ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: (store.everythingInSync ? Color.green : Color.orange).opacity(0.6),
                        radius: 3
                    )
                Text(store.everythingInSync ? "Everything in sync" : "Needs review")
            }
            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.scan()
            } label: {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Scan Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help("Scan all connected clouds for changes")
            .disabled(store.isScanning)

            Button {
                store.showingPreviewChanges = true
            } label: {
                Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
            }
            .help("Review every planned change before it happens")

            Button {
                store.showingNewSyncSet = true
            } label: {
                Label("New Sync Set", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Choose folders to keep in sync")
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        switch store.selectedDestination ?? .overview {
        case .overview:
            OverviewView()
        case .syncSets:
            SyncSetsView()
        case .activity:
            ActivityView()
        case .conflicts:
            ConflictsView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(DemoStore())
        .tint(Theme.accent)
}
