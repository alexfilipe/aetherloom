import SwiftUI

struct ContentView: View {
    @StateObject private var model = AetherloomDashboardModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $model.selectedDestination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Aetherloom")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detailView
                .frame(minWidth: 780, minHeight: 560)
        }
        .toolbar {
            ToolbarItemGroup {
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
                    Label("Create Sync Set", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selectedScreen {
        case .overview:
            OverviewView(model: model)
        case .syncSets:
            SyncSetsView(model: model)
        case .activity:
            ActivityLogView(activity: model.activity)
        case .conflicts:
            ConflictsView(conflicts: model.conflicts)
        case .settings:
            SettingsView(model: model)
        }
    }
}

#Preview {
    ContentView()
}
