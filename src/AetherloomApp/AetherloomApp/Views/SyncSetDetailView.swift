import AetherloomBridge
import AetherloomCore
import SwiftUI

struct SyncSetDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var syncSetID: UUID

    @State private var mode = SyncMode.balancedMirror
    @State private var settings = SyncSettings()
    @State private var loaded = false
    @State private var isSaving = false
    @State private var confirmsDeletion = false
    @State private var newExclusionPattern = ""
    @State private var newExclusionStyle = SyncExclusionMatchStyle.filename

    private var state: SyncSetState? {
        appModel.workspace?.syncSets.first { $0.id == syncSetID }
    }

    private var locations: [LocationState] {
        guard let state else { return [] }
        return state.syncSet.locations.compactMap { id in
            appModel.workspace?.locations.first(where: { $0.id == id })
        }
    }

    private var isBusy: Bool {
        appModel.busySyncSets.contains(syncSetID) || state?.phase != .idle
    }

    private var hasUnsavedChanges: Bool {
        guard let state else { return false }
        return mode != state.syncSet.mode || settings != state.syncSet.settings
    }

    var body: some View {
        Group {
            if let state {
                VStack(spacing: 0) {
                    header(state)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            locationsSection
                            modeSection
                            safetySection
                            exclusionsSection
                            historySection(state)
                            dangerSection(state)
                        }
                        .padding(24)
                    }
                    Divider()
                    footer
                }
            } else {
                EmptyStateView(
                    systemImage: "folder.badge.questionmark",
                    title: "Sync Set Not Found",
                    message: "This sync set may have been deleted."
                )
                .padding(28)
            }
        }
        .frame(width: 680, height: 760)
        .onAppear { loadDraftIfNeeded() }
        .onExitCommand {
            if !isSaving {
                dismiss()
            }
        }
        .alert("Delete \(state?.syncSet.name ?? "this sync set")?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Sync Set", role: .destructive) {
                Task {
                    if await appModel.deleteSyncSet(syncSetID) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This stops syncing and removes Aetherloom's saved sync memory. It never touches files in any location.")
        }
    }

    private func header(_ state: SyncSetState) -> some View {
        let line = statusLine(for: state, now: Date())
        return HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.title2)
                .foregroundStyle(Theme.weave)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.syncSet.name)
                    .font(.title2.weight(.semibold))
                Text("Sync Set Details")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            StatusBadge(text: line.text, tone: line.tone)
        }
        .padding(20)
    }

    private var locationsSection: some View {
        detailSection(title: "Locations", subtitle: "The current engine scope is shown exactly as configured.") {
            VStack(spacing: 0) {
                ForEach(locations) { location in
                    HStack(spacing: 10) {
                        ServiceMark(provider: location.location.kind.presentation, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.location.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(scopeText(location.location.scope))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            text: statusLine(for: location, now: Date()).text,
                            tone: tone(for: location.availability)
                        )
                        // 🎭 placeholder: real folder/scope selection — see architecture/ui/11-functioning-vs-placeholder.md
                        Button("Change Folder…") {}
                            .disabled(true)
                        PlaceholderChip(text: "Arrives with real providers")
                    }
                    .padding(.vertical, 9)
                    if location.id != locations.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        detailSection(title: "Mode", subtitle: SyncModeChoice.choice(for: mode).detail) {
            Picker("Sync mode", selection: $mode) {
                ForEach(SyncModeChoice.all) { choice in
                    Text(choice.title).tag(choice.mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var safetySection: some View {
        detailSection(
            title: "Safety",
            subtitle: "Aetherloom pauses and asks when changes exceed these."
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Change type")
                    Text("Item count")
                    Text("Ratio")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                thresholdRow(
                    "Mass deletion",
                    absolute: $settings.thresholds.massDeleteAbsolute,
                    ratio: $settings.thresholds.massDeleteRatio
                )
                thresholdRow(
                    "Mass edit",
                    absolute: $settings.thresholds.massEditAbsolute,
                    ratio: $settings.thresholds.massEditRatio
                )
            }

            Label(
                "Raising either threshold weakens this safety pause. Because the engine holds when either limit is reached, raise both the item count and ratio only when you understand the larger change.",
                systemImage: "shield.lefthalf.filled.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func thresholdRow(
        _ title: String,
        absolute: Binding<Int>,
        ratio: Binding<Double>
    ) -> some View {
        GridRow {
            Text(title)
                .font(.subheadline)
            TextField("Count", value: absolute, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            HStack(spacing: 4) {
                TextField("Ratio", value: ratio, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("0–1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exclusionsSection: some View {
        detailSection(
            title: "Exclusions",
            subtitle: "Patterns are evaluated by the sync engine on the next preparation."
        ) {
            if settings.exclusions.isEmpty {
                Text("No custom exclusions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(settings.exclusions.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("Pattern", text: $settings.exclusions[index].pattern)
                                .textFieldStyle(.roundedBorder)
                            Picker("Match", selection: $settings.exclusions[index].matchStyle) {
                                ForEach(ExclusionStyleChoice.all) { choice in
                                    Text(choice.title).tag(choice.style)
                                }
                            }
                            .frame(width: 140)
                            Toggle("Case", isOn: $settings.exclusions[index].isCaseSensitive)
                                .toggleStyle(.checkbox)
                                .help("Case sensitive")
                            Button(role: .destructive) {
                                settings.exclusions.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .frame(minWidth: 24, minHeight: 24)
                            .accessibilityLabel("Remove exclusion")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("New pattern, such as .DS_Store", text: $newExclusionPattern)
                    .textFieldStyle(.roundedBorder)
                Picker("Match style", selection: $newExclusionStyle) {
                    ForEach(ExclusionStyleChoice.all) { choice in
                        Text(choice.title).tag(choice.style)
                    }
                }
                .frame(width: 140)
                Button("Add") { addExclusion() }
                    .disabled(newExclusionPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func historySection(_ state: SyncSetState) -> some View {
        let entries = appModel.recentActivity.filter { $0.syncSetID == syncSetID }
        let groups = runGroups(
            activityRows(entries, locations: appModel.workspace?.locations ?? [], now: Date())
        ).filter { $0.runID != nil }.prefix(10)

        return detailSection(
            title: "History",
            subtitle: "The latest runs recorded in the activity log."
        ) {
            if groups.isEmpty {
                Text("No runs recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups)) { group in
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(historyOutcome(group, state: state))
                                    .font(.subheadline.weight(.medium))
                                Text("\(group.rows.count) logged event\(group.rows.count == 1 ? "" : "s") · \(group.rows.first?.relativeTimestamp ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .liveNumericTransition()
                            }
                            Spacer()
                            if let runID = group.runID {
                                Button("Open Activity") {
                                    dismiss()
                                    appModel.show(.activity, filteredToRun: runID)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 9)
                        if group.id != groups.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func dangerSection(_ state: SyncSetState) -> some View {
        detailSection(
            title: "Danger Zone",
            subtitle: "Deleting a sync set never deletes or moves files."
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete \(state.syncSet.name)")
                        .font(.subheadline.weight(.semibold))
                    Text("Stops syncing and removes saved sync memory from Aetherloom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete Sync Set…", role: .destructive) {
                    confirmsDeletion = true
                }
                .disabled(isBusy)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if hasUnsavedChanges {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Apply Changes")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasUnsavedChanges || isBusy || isSaving || !settingsAreValid)
        }
        .padding(20)
    }

    private var settingsAreValid: Bool {
        let thresholds = settings.thresholds
        return thresholds.massDeleteAbsolute > 0
            && thresholds.massEditAbsolute > 0
            && (0 ... 1).contains(thresholds.massDeleteRatio)
            && (0 ... 1).contains(thresholds.massEditRatio)
            && settings.exclusions.allSatisfy {
                !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private func detailSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func loadDraftIfNeeded() {
        guard !loaded, let state else { return }
        mode = state.syncSet.mode
        settings = state.syncSet.settings
        loaded = true
    }

    private func addExclusion() {
        let pattern = newExclusionPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        settings.exclusions.append(
            SyncExclusion(pattern: pattern, matchStyle: newExclusionStyle)
        )
        newExclusionPattern = ""
    }

    private func save() {
        guard settingsAreValid else { return }
        isSaving = true
        Task {
            let saved = await appModel.updateSyncSet(
                mode: mode,
                settings: settings,
                syncSetID: syncSetID
            )
            isSaving = false
            if saved {
                loaded = false
                loadDraftIfNeeded()
            }
        }
    }

    private func historyOutcome(_ group: RunGroupDisplay, state: SyncSetState) -> String {
        if let run = state.lastRun, run.runID == group.runID {
            switch run.outcome {
            case .completed: return "Completed"
            case .held: return "Needs review"
            case .refused: return "Paused for safety"
            case .stoppedForReplan: return "Stopped to replan"
            case .cancelled: return "Cancelled"
            case .failed: return "Failed"
            }
        }
        return group.rows.first?.message ?? "Recorded run"
    }
}

private struct ExclusionStyleChoice: Identifiable {
    var style: SyncExclusionMatchStyle
    var title: String
    var id: SyncExclusionMatchStyle { style }

    static let all = [
        ExclusionStyleChoice(style: .exactPath, title: "Exact path"),
        ExclusionStyleChoice(style: .filename, title: "Filename"),
        ExclusionStyleChoice(style: .suffix, title: "Suffix"),
        ExclusionStyleChoice(style: .prefix, title: "Prefix"),
        ExclusionStyleChoice(style: .contains, title: "Contains"),
    ]
}

#Preview("Sync set detail") {
    let fixture = OverviewPreviewFixture.populated
    SyncSetDetailView(syncSetID: DemoWorld.documentsID)
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
}
