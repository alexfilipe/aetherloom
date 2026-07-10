import AetherloomBridge
import AetherloomCore
import SwiftUI

struct NewSyncSetSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: WizardStep
    @State private var name = "New Sync Set"
    @State private var mode = SyncMode.balancedMirror
    @State private var selectedLocationIDs: Set<LocationID> = [.iCloudDrive, .googleDrive]
    @State private var isCreating = false

    init(initialStep: WizardStep = .nameAndMode) {
        _step = State(initialValue: initialStep)
    }

    private var locations: [LocationState] {
        appModel.workspace?.locations ?? []
    }

    private var selectedLocations: [LocationState] {
        locations.filter { selectedLocationIDs.contains($0.id) }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameValidationMessage: String? {
        if trimmedName.isEmpty {
            return "Give this sync set a name."
        }
        if appModel.workspace?.syncSets.contains(where: {
            $0.syncSet.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) == true {
            return "A sync set with this name already exists."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepProgress
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()

            Group {
                switch step {
                case .nameAndMode:
                    nameAndModeStep
                case .locations:
                    locationsStep
                case .review:
                    reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            footer
        }
        .frame(width: 520, height: 660)
        .onExitCommand {
            if !isCreating {
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(Theme.weave)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Sync Set")
                    .font(.title2.weight(.semibold))
                Text("Choose what Aetherloom should keep safely aligned.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var stepProgress: some View {
        HStack(spacing: 8) {
            ForEach(WizardStep.allCases) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle.fill")
                        .foregroundStyle(item.rawValue <= step.rawValue ? Theme.accent : .secondary)
                    Text(item.title)
                        .font(.caption.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item.rawValue <= step.rawValue ? .primary : .secondary)
                }
                if item != .review {
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .frame(height: 1)
                }
            }
        }
    }

    private var nameAndModeStep: some View {
        Form {
            Section("Name") {
                TextField("Sync set name", text: $name)
                    .textFieldStyle(.roundedBorder)
                if let nameValidationMessage {
                    Label(nameValidationMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Mode") {
                Picker("Sync mode", selection: $mode) {
                    ForEach(SyncModeChoice.all) { choice in
                        Text(choice.title).tag(choice.mode)
                    }
                }
                .pickerStyle(.radioGroup)
                ForEach(SyncModeChoice.all) { choice in
                    if choice.mode == mode {
                        Text(choice.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var locationsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose at least two locations. Unavailable locations remain selectable so you can configure the intended sync set now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(locations) { location in
                    locationChoice(location)
                }

                if selectedLocationIDs.count < 2 {
                    Label("Choose \(2 - selectedLocationIDs.count) more location\(selectedLocationIDs.count == 1 ? "" : "s").", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .liveNumericTransition()
                }
            }
            .padding(24)
        }
    }

    private func locationChoice(_ state: LocationState) -> some View {
        let isSelected = selectedLocationIDs.contains(state.id)
        let availability = statusLine(for: state, now: Date())
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: selectionBinding(for: state.id)) {
                HStack(spacing: 10) {
                    ServiceMark(provider: state.location.kind.presentation, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.location.displayName)
                            .font(.subheadline.weight(.medium))
                        // 🎭 placeholder: scripted account labels — see architecture/ui/11-functioning-vs-placeholder.md.
                        Text(state.accountLabel.map { "Demo account · \($0)" } ?? state.location.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: availability.text, tone: availability.tone)
                }
            }
            .toggleStyle(.checkbox)

            if case let .unavailable(reason) = state.availability {
                Label("Will pause sync until reachable. \(reason.detail)", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scope")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("Folder scope", text: .constant(scopeText(state.location.scope)))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        // 🎭 placeholder: real folder/scope selection — see architecture/ui/11-functioning-vs-placeholder.md
                        PlaceholderChip(text: "Picker arrives with real providers")
                    }
                    Text("The demo uses this location's existing scope. Folder selection is not written to the engine yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
        }
        .padding(14)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trimmedName)
                                .font(.title3.weight(.semibold))
                            Text(SyncModeChoice.choice(for: mode).title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(text: "Never synced", tone: .neutral)
                    }

                    ForEach(selectedLocations) { location in
                        HStack(spacing: 10) {
                            ServiceMark(provider: location.location.kind.presentation, size: 24)
                            Text(location.location.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(scopeText(location.location.scope))
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .card(hoverLift: false)

                Label(
                    "Nothing syncs until you preview and approve the first plan.",
                    systemImage: "shield.checkered"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

                if selectedLocations.contains(where: { $0.location.scope == .entireDrive }) {
                    Label(
                        "Whole-drive sync always requires review before each first run.",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(24)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .nameAndMode {
                Button("Back") {
                    step = WizardStep(rawValue: step.rawValue - 1) ?? .nameAndMode
                }
            }
            if step == .review {
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create Sync Set")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || nameValidationMessage != nil || selectedLocationIDs.count < 2)
            } else {
                Button("Continue") {
                    step = WizardStep(rawValue: step.rawValue + 1) ?? .review
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .nameAndMode ? nameValidationMessage != nil : selectedLocationIDs.count < 2)
            }
        }
        .padding(20)
    }

    private func selectionBinding(for id: LocationID) -> Binding<Bool> {
        Binding {
            selectedLocationIDs.contains(id)
        } set: { selected in
            if selected {
                selectedLocationIDs.insert(id)
            } else {
                selectedLocationIDs.remove(id)
            }
        }
    }

    private func create() {
        isCreating = true
        Task {
            let created = await appModel.createSyncSet(
                name: trimmedName,
                locationIDs: selectedLocationIDs.sorted(),
                mode: mode
            )
            isCreating = false
            if created {
                dismiss()
            }
        }
    }
}

enum WizardStep: Int, CaseIterable, Identifiable {
    case nameAndMode
    case locations
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nameAndMode: "Name & Mode"
        case .locations: "Locations"
        case .review: "Review"
        }
    }
}

struct SyncModeChoice: Identifiable {
    var mode: SyncMode
    var title: String
    var detail: String
    var id: SyncMode { mode }

    static let all = [
        SyncModeChoice(
            mode: .balancedMirror,
            title: "Balanced mirror",
            detail: "Keep every location aligned. Safety thresholds still pause suspicious changes."
        ),
        SyncModeChoice(
            mode: .askBeforeDeleting,
            title: "Ask before deleting",
            detail: "Always ask before moving matching files to provider trash."
        ),
        SyncModeChoice(
            mode: .noDeletePropagation,
            title: "Don't propagate deletes",
            detail: "Keep missing files in other locations instead of propagating deletion."
        ),
    ]

    static func choice(for mode: SyncMode) -> SyncModeChoice {
        all.first(where: { $0.mode == mode })!
    }
}

private func wizardPreview(_ step: WizardStep) -> some View {
    let fixture = OverviewPreviewFixture.populated
    return NewSyncSetSheet(initialStep: step)
        .environmentObject(
            AppModel(
                session: PreviewEngineSession(snapshot: fixture.workspace),
                bootstrapImmediately: false,
                initialWorkspace: fixture.workspace,
                initialPhase: .ready
            )
        )
        .tint(Theme.accent)
}

#Preview("Wizard · Name & Mode") { wizardPreview(.nameAndMode) }
#Preview("Wizard · Locations") { wizardPreview(.locations) }
#Preview("Wizard · Review") { wizardPreview(.review) }
