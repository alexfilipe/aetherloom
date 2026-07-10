import AetherloomBridge
import AetherloomCore
import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("selectedDestination") private var selectedDestination = SidebarDestination.overview

    var body: some View {
        Group {
            switch appModel.bootstrapPhase {
            case .loading:
                BrandedLoadingView()
            case .ready:
                readyShell
            case let .failed(message):
                BootstrapFailedView(message: message)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(WindowTitleVisibilityConfigurator())
        .sheet(item: $appModel.activeSheet) { sheet in
            sheetContent(sheet)
        }
        .alert(
            "Aetherloom",
            isPresented: Binding(
                get: { appModel.presentedError != nil },
                set: { if !$0 { appModel.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appModel.presentedError = nil
            }
        } message: {
            Text(appModel.presentedError ?? "")
        }
        .onAppear {
            restoreNavigation()
            appModel.startBootstrapIfNeeded()
        }
        .onChange(of: appModel.selectedDestination) { _, destination in
            guard destination != .settings else {
                appModel.selectedDestination = .overview
                openSettings()
                return
            }
            selectedDestination = destination
        }
    }

    private var readyShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
                .frame(minWidth: 760, minHeight: 560)
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .bottomTrailing) {
            if let toast = appModel.pendingToast {
                RunResultToast(
                    model: toast,
                    openActivity: {
                        appModel.pendingToast = nil
                        appModel.show(.activity, filteredToRun: toast.runID)
                    },
                    dismiss: {
                        if appModel.pendingToast?.id == toast.id {
                            appModel.pendingToast = nil
                        }
                    }
                )
                .padding(22)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth, value: appModel.pendingToast)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $appModel.selectedDestination) {
            Section {
                ForEach(SidebarDestination.allCases.filter { $0 != .settings }) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .badge(badge(for: destination))
                        .tag(destination)
                        .accessibilityLabel(sidebarAccessibilityLabel(for: destination))
                }
            }

            Section {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Settings")
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

    @ViewBuilder
    private var sidebarFooter: some View {
        let status = appModel.workspace?.status ?? .busy(stage: "Preparing")
        HStack(spacing: 8) {
            switch status {
            case let .busy(stage):
                ProgressView()
                    .controlSize(.small)
                Text(stage)
            case .needsReview:
                ToneDot(tone: .attention)
                Text("Needs review")
            case .pausedForSafety:
                ToneDot(tone: .paused)
                Text("Paused for safety")
            case .allInSync:
                ToneDot(tone: .healthy)
                Text("Everything in sync")
            }
            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private func badge(for destination: SidebarDestination) -> Int {
        switch destination {
        case .conflicts:
            appModel.workspace?.openConflictCount ?? 0
        case .syncSets:
            appModel.workspace?.syncSets.filter {
                let statusTone = AetherloomBridge.tone(for: $0)
                return statusTone == .paused || statusTone == .attention
            }.count ?? 0
        default:
            0
        }
    }

    private func sidebarAccessibilityLabel(for destination: SidebarDestination) -> String {
        let count = badge(for: destination)
        return count == 0 ? destination.title : "\(destination.title), \(count)"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await appModel.scanAll() }
            } label: {
                if appModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Scan Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help("Scan all unpaused sync sets for changes without applying them")
            .disabled(appModel.isScanning)
            .accessibilityLabel(appModel.isScanning ? "Scanning" : "Scan Now")

            if appModel.pendingPreparations.count > 1 {
                Menu {
                    ForEach(appModel.pendingPreparations, id: \.runID) { preparation in
                        Button(preparation.syncSetName) {
                            appModel.showCachedPreview(preparation)
                        }
                    }
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                }
                .help("Choose a sync set to preview")
            } else {
                Button {
                    if let preparation = appModel.pendingPreparations.first {
                        appModel.showCachedPreview(preparation)
                    }
                } label: {
                    Label("Preview Changes", systemImage: "doc.text.magnifyingglass")
                }
                .help(appModel.pendingPreparations.isEmpty
                      ? "Scan first to prepare changes for preview"
                      : "Review every planned change before it happens")
                .disabled(appModel.pendingPreparations.isEmpty)
            }

            Button {
                guard appModel.activeSheet == nil else { return }
                appModel.activeSheet = .newSyncSet
            } label: {
                Label("New Sync Set", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Choose folders to keep in sync")
        }
    }

    // MARK: Detail and routing

    @ViewBuilder
    private var detailView: some View {
        switch appModel.selectedDestination {
        case .overview:
            OverviewView()
        case .syncSets:
            SyncSetsView()
        case .activity:
            ActivityView()
        case .conflicts:
            ConflictsView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case let .previewChanges(preparation):
            PreviewChangesSheet(preparation: preparation)
        case .newSyncSet:
            NewSyncSetSheet()
        case let .syncSetDetail(id):
            SyncSetDetailView(syncSetID: id)
        case let .connectProvider(kind):
            ConnectProviderSheet(kind: kind)
        }
    }

    private func restoreNavigation() {
        if selectedDestination == .settings {
            selectedDestination = .overview
            appModel.selectedDestination = .overview
            openSettings()
        } else {
            appModel.selectedDestination = selectedDestination
        }
    }
}

private struct BrandedLoadingView: View {
    var body: some View {
        ZStack {
            WeaveMesh()
                .ignoresSafeArea()
            VStack(spacing: 18) {
                AppLogoMark(size: 72)
                Text("Preparing your weave…")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing your weave")
    }
}

private struct BootstrapFailedView: View {
    var message: String

    var body: some View {
        ZStack {
            ContentBackdrop()
            VStack(spacing: 12) {
                AppLogoMark(size: 56)
                Text("Aetherloom could not prepare the workspace")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(28)
            .card(hoverLift: false)
        }
    }
}

#Preview("Loading shell") {
    let session = PreviewEngineSession(snapshot: .previewReady)
    let model = AppModel(
        session: session,
        bootstrapImmediately: false,
        initialWorkspace: .previewReady,
        initialPhase: .loading
    )
    ContentView(appModel: model)
        .environmentObject(model)
        .tint(Theme.accent)
}

#Preview("Ready shell") {
    let session = PreviewEngineSession(snapshot: .previewReady)
    let model = AppModel(
        session: session,
        bootstrapImmediately: false,
        initialWorkspace: .previewReady,
        initialPhase: .ready
    )
    ContentView(appModel: model)
        .environmentObject(model)
        .tint(Theme.accent)
}

private struct WindowTitleVisibilityConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowTitleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowTitleHidingView)?.hideWindowTitle()
    }
}

private final class WindowTitleHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideWindowTitle()
    }

    func hideWindowTitle() {
        window?.title = ""
        window?.subtitle = ""
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
    }
}
