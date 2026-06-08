import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AetherloomDashboardModel

    var body: some View {
        Form {
            Section {
                Toggle("Move deleted files to provider trash", isOn: $model.deletePropagationEnabled)
                Toggle("Pause on suspicious mass changes", isOn: $model.pauseOnMassChanges)
                Toggle("Require review for whole-drive sync", isOn: $model.requireReviewForWholeDrive)
            } header: {
                Text("Safety")
            }

            Section {
                LabeledContent("Conflict behavior", value: "Preserve both copies")
                LabeledContent("Delete behavior", value: "Never permanent in normal sync")
                LabeledContent("Default mode", value: "Balanced Mirror")
            } header: {
                Text("Balanced Mirror")
            }

            Section {
                LabeledContent("Excluded files", value: ".DS_Store, temporary files")
                LabeledContent("Provider adapters", value: "Fake providers")
            } header: {
                Text("Engine")
            }
        }
        .formStyle(.grouped)
        .padding(28)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
