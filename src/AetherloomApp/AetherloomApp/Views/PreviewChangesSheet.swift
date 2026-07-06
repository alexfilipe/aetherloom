import SwiftUI

struct PreviewChangesSheet: View {
    @Environment(DemoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.plannedChanges.isEmpty {
                emptyState
            } else {
                changeList
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 620)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Theme.weave)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preview Changes")
                    .font(.title2.weight(.semibold))
                Text(store.plannedChanges.isEmpty
                     ? "Nothing is waiting"
                     : "\(store.plannedChanges.count) changes planned · nothing happens until you apply")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !store.plannedChanges.isEmpty {
                StatusBadge(text: "Needs review", tone: .attention)
            }
        }
        .padding(20)
    }

    // MARK: Change list

    private var changeList: some View {
        List {
            ForEach(PlannedChange.Kind.allCases, id: \.self) { kind in
                let changes = store.plannedChanges.filter { $0.kind == kind }
                if !changes.isEmpty {
                    Section {
                        ForEach(changes) { change in
                            ChangeRow(change: change)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.systemImage)
                                .foregroundStyle(kind.tone.color)
                            Text("\(kind.title) · \(changes.count)")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("You're all caught up")
                .font(.title3.weight(.semibold))
            Text("When files change in any cloud, the plan appears here first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            Label("Nothing is deleted permanently. Deletions go to each provider's trash, and conflicting versions are both preserved.", systemImage: "shield.checkered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Not Now") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    store.applyPlannedChanges()
                    dismiss()
                } label: {
                    Label("Apply Changes", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.plannedChanges.isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Row

private struct ChangeRow: View {
    var change: PlannedChange

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: change.kind.systemImage)
                .foregroundStyle(change.kind.tone.color)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.filename)
                    .font(.body.weight(.medium))
                Text(change.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(change.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PreviewChangesSheet()
        .environment(DemoStore())
        .tint(Theme.accent)
}
