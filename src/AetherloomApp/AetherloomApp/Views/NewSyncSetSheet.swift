import SwiftUI

struct NewSyncSetSheet: View {
    @Environment(DemoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedServices: Set<CloudService> = [.iCloudDrive, .googleDrive]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Theme.weave)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Sync Set")
                        .font(.title2.weight(.semibold))
                    Text("Choose a folder from each cloud to weave together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Name") {
                    TextField("e.g. Documents, Photos, Projects", text: $name)
                }

                Section("Clouds") {
                    ForEach(CloudService.allCases) { service in
                        Toggle(isOn: binding(for: service)) {
                            HStack(spacing: 10) {
                                ServiceMark(service: service, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(service.displayName)
                                    Text(selectedServices.contains(service)
                                         ? "Folder: /\(name.isEmpty ? "…" : name)"
                                         : "Not included")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }

                Section {
                    Label("Aetherloom will scan first and show you a preview. Nothing syncs until you review it.", systemImage: "shield.checkered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create Sync Set") {
                    store.addSyncSet(named: name.isEmpty ? "New Sync Set" : name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedServices.count < 2)
            }
            .padding(20)
        }
        .frame(width: 480, height: 620)
    }

    private func binding(for service: CloudService) -> Binding<Bool> {
        Binding {
            selectedServices.contains(service)
        } set: { included in
            if included {
                selectedServices.insert(service)
            } else {
                selectedServices.remove(service)
            }
        }
    }
}

#Preview {
    NewSyncSetSheet()
        .environment(DemoStore())
        .tint(Theme.accent)
}
