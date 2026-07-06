import SwiftUI

struct SettingsView: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Settings",
                    subtitle: "Aetherloom always chooses the safest option by default."
                )

                Form {
                    Section("Safety") {
                        Toggle(isOn: $store.moveDeletesToTrash) {
                            Text("Move deleted files to provider trash")
                            Text("Files are never permanently deleted during normal sync.")
                        }
                        Toggle(isOn: $store.pauseOnMassChanges) {
                            Text("Pause on suspicious mass changes")
                            Text("Large numbers of deletions or edits wait for your review.")
                        }
                        Toggle(isOn: $store.requireReviewForWholeDrive) {
                            Text("Require review for whole-drive sync")
                            Text("Whole-drive mirrors never run for the first time unattended.")
                        }
                        Toggle(isOn: $store.keepConflictCopies) {
                            Text("Preserve both versions on conflict")
                            Text("When a file changes in two places, nothing is overwritten.")
                        }
                    }

                    Section("Sync Behavior") {
                        LabeledContent("Conflict behavior", value: "Both versions preserved")
                        LabeledContent("Delete behavior", value: "Move to trash, always recoverable")
                        LabeledContent("When a provider is unreachable", value: "Pause — never infer deletions")
                        LabeledContent("When a volume is asleep or unmounted", value: "Wait — never treat files as deleted")
                    }

                    Section("Excluded Files") {
                        LabeledContent("System files", value: ".DS_Store, .Trashes, temporary files")
                        LabeledContent("Custom exclusions", value: "None")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 700)
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }
}

#Preview {
    SettingsView()
        .environment(DemoStore())
        .tint(Theme.accent)
        .frame(width: 860, height: 700)
}
