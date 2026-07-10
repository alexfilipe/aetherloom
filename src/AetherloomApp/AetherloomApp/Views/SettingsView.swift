import AetherloomBridge
import AetherloomCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsPane()
                .tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
            SuggestionsSettingsPane()
                .tabItem { Label("Suggestions", systemImage: "sparkles") }
            ProvidersSettingsPane()
                .tabItem { Label("Providers", systemImage: "externaldrive") }
            if appModel.isDemoSession {
                DemoSettingsPane()
                    .tabItem { Label("Demo", systemImage: "slider.horizontal.3") }
            }
        }
        .frame(width: 720, height: 540)
    }
}

private struct GeneralSettingsPane: View {
    @AppStorage("aetherloom.menu-bar.visible") private var showInMenuBar = true

    var body: some View {
        SettingsPaneContainer(title: "General", subtitle: "Choose how Aetherloom appears on this Mac.") {
            Form {
                Section("Startup") {
                    // 🎭 placeholder: launch at login — see architecture/ui/11-functioning-vs-placeholder.md
                    LabeledContent {
                        HStack {
                            PlaceholderChip(text: "Arrives with background sync")
                            Toggle("Launch at login", isOn: .constant(false))
                                .labelsHidden()
                                .disabled(true)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Launch at login")
                            Text("Starts Aetherloom automatically when background sync arrives.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $showInMenuBar) {
                        Text("Show in menu bar")
                        Text("Show Aetherloom’s current workspace status in the menu bar.")
                    }
                }

                Section("Appearance") {
                    LabeledContent("Appearance", value: "Follows System Settings")
                    Text("Aetherloom follows your Mac’s light or dark appearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct SafetySettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var thresholds = SafetyThresholds()

    var body: some View {
        SettingsPaneContainer(
            title: "Safety",
            subtitle: "These defaults apply only to sync sets you create next."
        ) {
            Form {
                Section("Default thresholds for new sync sets") {
                    Stepper(value: countBinding(\.massDeleteAbsolute), in: 1...100_000) {
                        thresholdLabel(
                            "Mass-delete count",
                            detail: "Pause and ask when more than \(thresholds.massDeleteAbsolute) files would be deleted at once."
                        )
                    }
                    Stepper(value: ratioBinding(\.massDeleteRatio), in: 0.01...1, step: 0.01) {
                        thresholdLabel(
                            "Mass-delete ratio · \(percentage(thresholds.massDeleteRatio))",
                            detail: "Pause and ask when more than this share of tracked files would be deleted at once."
                        )
                    }
                    Stepper(value: countBinding(\.massEditAbsolute), in: 1...100_000) {
                        thresholdLabel(
                            "Mass-edit count",
                            detail: "Pause and ask when more than \(thresholds.massEditAbsolute) files would be edited at once."
                        )
                    }
                    Stepper(value: ratioBinding(\.massEditRatio), in: 0.01...1, step: 0.01) {
                        thresholdLabel(
                            "Mass-edit ratio · \(percentage(thresholds.massEditRatio))",
                            detail: "Pause and ask when more than this share of tracked files would be edited at once."
                        )
                    }
                }

                Section("Always protected") {
                    lockedInvariant("Deletes always go to each provider’s trash")
                    lockedInvariant("Conflicting versions are always preserved")
                    lockedInvariant("An unreachable provider never causes deletions")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task {
            thresholds = appModel.defaultSafetyThresholds
        }
        .onChange(of: appModel.defaultSafetyThresholds) { _, value in
            thresholds = value
        }
    }

    private func countBinding(_ keyPath: WritableKeyPath<SafetyThresholds, Int>) -> Binding<Int> {
        Binding {
            thresholds[keyPath: keyPath]
        } set: { value in
            thresholds[keyPath: keyPath] = value
            persist()
        }
    }

    private func ratioBinding(_ keyPath: WritableKeyPath<SafetyThresholds, Double>) -> Binding<Double> {
        Binding {
            thresholds[keyPath: keyPath]
        } set: { value in
            thresholds[keyPath: keyPath] = value
            persist()
        }
    }

    private func persist() {
        let value = thresholds
        Task { await appModel.saveDefaultSafetyThresholds(value) }
    }

    private func percentage(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    private func thresholdLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .liveNumericTransition()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func lockedInvariant(_ text: String) -> some View {
        Label(text, systemImage: "lock.fill")
            .foregroundStyle(.primary)
            .accessibilityLabel("Always protected: \(text)")
    }
}

private struct SuggestionsSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppModel.suggestionsPreferenceKey) private var storedSuggestionsEnabled = true

    var body: some View {
        SettingsPaneContainer(
            title: "Suggestions",
            subtitle: "On-device guidance that never acts on your files."
        ) {
            Form {
                Section {
                    Toggle("Suggest conflict resolutions on this Mac", isOn: suggestionsBinding)
                        .disabled(appModel.isScanning)
                    Text("Suggestions stay on this Mac, are advisory only, and are never applied automatically. You always decide.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Learn how Aetherloom uses on-device suggestions", destination: URL(string: "https://aetherloom.app/ai")!)
                        .font(.caption)
                }

                Section("Advisor backend") {
                    HStack {
                        Label("Heuristic (built-in)", systemImage: "sparkles")
                        Spacer()
                        StatusBadge(
                            text: appModel.suggestionsEnabled ? "Active" : "Off",
                            tone: appModel.suggestionsEnabled ? .healthy : .neutral
                        )
                    }

                    // 🎭 placeholder: Apple Intelligence advisor — see architecture/ui/11-functioning-vs-placeholder.md
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Intelligence")
                            Text("Requires Apple Silicon; arrives with the Foundation Models integration.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PlaceholderChip(text: "Foundation Models integration")
                    }
                    .disabled(true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var suggestionsBinding: Binding<Bool> {
        Binding {
            appModel.suggestionsEnabled
        } set: { enabled in
            Task {
                await appModel.setSuggestionsEnabled(enabled)
                storedSuggestionsEnabled = appModel.suggestionsEnabled
            }
        }
    }
}

private struct ProvidersSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var connectProvider: ProviderKind?

    var body: some View {
        SettingsPaneContainer(
            title: "Providers",
            subtitle: "The demo world shows provider state without touching real files or accounts."
        ) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        providerRow(kind)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: connectSheetBinding) {
            ConnectProviderSheet(kind: connectProvider ?? .googleDrive)
        }
    }

    private var connectSheetBinding: Binding<Bool> {
        Binding {
            connectProvider != nil
        } set: { isPresented in
            if !isPresented {
                connectProvider = nil
            }
        }
    }

    private func providerRow(_ kind: ProviderKind) -> some View {
        let state = appModel.workspace?.locations.first { $0.location.kind == kind }
        return HStack(spacing: 14) {
            ServiceMark(provider: kind.presentation, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName)
                    .font(.headline)
                providerCaption(kind, state: state)
            }
            Spacer()
            providerActions(kind, state: state)
        }
        .padding(14)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.displayName). \(providerAccessibilityStatus(kind, state: state))")
    }

    @ViewBuilder
    private func providerCaption(_ kind: ProviderKind, state: LocationState?) -> some View {
        switch kind {
        case .localFolder:
            Text("Built in")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .nasFolder:
            if let state {
                let status = statusLine(for: state, now: Date())
                Label(status.text, systemImage: status.tone.systemImage)
                    .font(.caption)
                    .foregroundStyle(status.tone.color)
            } else {
                Text("No demo mount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .iCloudDrive, .googleDrive, .oneDrive:
            // 🎭 placeholder: scripted account labels — see architecture/ui/11-functioning-vs-placeholder.md.
            Text("Demo account · \(state?.accountLabel ?? "No account")")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .dropbox:
            Text("Planned")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func providerAccessibilityStatus(_ kind: ProviderKind, state: LocationState?) -> String {
        switch kind {
        case .localFolder:
            "Built in; real folder picker coming soon"
        case .nasFolder:
            state.map { statusLine(for: $0, now: Date()).text } ?? "No demo mount"
        case .iCloudDrive, .googleDrive, .oneDrive:
            "Demo account; provider connection coming soon"
        case .dropbox:
            "Planned provider"
        }
    }

    @ViewBuilder
    private func providerActions(_ kind: ProviderKind, state: LocationState?) -> some View {
        switch kind {
        case .localFolder:
            // 🎭 placeholder: local folder picker — see architecture/ui/11-functioning-vs-placeholder.md
            HStack {
                PlaceholderChip(text: "Real folder picker")
                Button("Choose Folder…") {}
                    .disabled(true)
            }
        case .nasFolder:
            // 🎭 placeholder: NAS mount settings — see architecture/ui/11-functioning-vs-placeholder.md
            HStack {
                PlaceholderChip(text: "NAS mount settings")
                Button("Mount Settings…") {}
                    .disabled(true)
            }
        case .iCloudDrive, .googleDrive, .oneDrive:
            // 🎭 placeholder: provider connection and disconnection — see architecture/ui/11-functioning-vs-placeholder.md
            HStack {
                PlaceholderChip(text: "Demo account")
                Button("Disconnect") {}
                    .disabled(true)
                Button("Connect…") {
                    connectProvider = kind
                }
                .accessibilityLabel("Preview connecting \(kind.displayName)")
            }
        case .dropbox:
            // 🎭 placeholder: Dropbox provider — see architecture/ui/11-functioning-vs-placeholder.md
            HStack {
                PlaceholderChip(text: "Planned provider")
                Button("Connect…") {}
                    .disabled(true)
            }
        }
    }
}

private struct DemoSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SettingsPaneContainer(title: "Demo", subtitle: "Exercise the real safety engine over fake providers.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        "You’re exploring Aetherloom’s demo world — real files are never touched.",
                        systemImage: "sparkles"
                    )
                    .font(.subheadline.weight(.medium))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

                    demoAction(
                        appModel.oneDriveIsReachable ? "Make OneDrive Unreachable" : "Make OneDrive Reachable",
                        detail: "Change the fake provider’s availability and observe the next safety check.",
                        action: .toggleOneDrive
                    )
                    demoAction(
                        appModel.nasIsMounted ? "Unmount NAS “Tank”" : "Mount NAS “Tank”",
                        detail: "Change the fake NAS mount state without touching a real volume.",
                        action: .toggleNAS
                    )
                    demoAction(
                        "Edit a File in Two Places",
                        detail: "Create an independent edit conflict for the next scan.",
                        action: .makeConflict
                    )
                    demoAction(
                        "Delete Many Files in “Projects”",
                        detail: "Trigger the real mass-deletion safety hold on the next scan.",
                        action: .makeMassDeletion
                    )
                    demoAction(
                        "Simulate Interrupted Run",
                        detail: "Write an unfinished journal run for real recovery on the next prepare.",
                        action: .simulateInterruptedRun
                    )

                    Button("Reset Demo World", role: .destructive) {
                        Task { await appModel.performDemoAction(.reset) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func demoAction(_ title: String, detail: String, action: DemoAction) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run") {
                Task { await appModel.performDemoAction(action) }
            }
            .accessibilityLabel(title)
        }
        .padding(12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SettingsPaneContainer<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func settingsPreviewModel(demo: Bool = false) -> AppModel {
    let fixture = OverviewPreviewFixture.populated
    return AppModel(
        session: demo ? DemoEngineSession() : PreviewEngineSession(snapshot: fixture.workspace),
        bootstrapImmediately: false,
        initialWorkspace: fixture.workspace,
        initialPhase: .ready
    )
}

#Preview("Settings · General") {
    GeneralSettingsPane()
        .environment(settingsPreviewModel())
        .tint(Theme.accent)
        .frame(width: 720, height: 500)
}

#Preview("Settings · Safety") {
    SafetySettingsPane()
        .environment(settingsPreviewModel())
        .tint(Theme.accent)
        .frame(width: 720, height: 500)
}

#Preview("Settings · Suggestions") {
    SuggestionsSettingsPane()
        .environment(settingsPreviewModel())
        .tint(Theme.accent)
        .frame(width: 720, height: 500)
}

#Preview("Settings · Providers") {
    ProvidersSettingsPane()
        .environment(settingsPreviewModel())
        .tint(Theme.accent)
        .frame(width: 720, height: 500)
}

#Preview("Settings · Demo") {
    DemoSettingsPane()
        .environment(settingsPreviewModel(demo: true))
        .tint(Theme.accent)
        .frame(width: 720, height: 500)
}
