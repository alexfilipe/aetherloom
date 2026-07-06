import SwiftUI

struct ConflictsView: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Conflicts",
                    subtitle: "When a file changes in more than one place, Aetherloom keeps both versions until you decide."
                )

                if store.conflicts.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "No Conflicts",
                        message: "Every tracked file is aligned across your clouds."
                    )
                } else {
                    ForEach(store.conflicts) { conflict in
                        ConflictCard(conflict: conflict)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }
}

struct ConflictCard: View {
    @Environment(DemoStore.self) private var store
    var conflict: FileConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(conflict.isResolved ? .green : .orange)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.filename)
                        .font(.title3.weight(.semibold))
                    Text(conflict.path)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                StatusBadge(
                    text: conflict.isResolved ? "Resolved" : "Needs review",
                    tone: conflict.isResolved ? .healthy : .attention
                )
            }

            Text("This file changed in more than one place. Aetherloom preserved both versions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(conflict.versions) { version in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ServiceMark(service: version.service, size: 24)
                            Text(version.service.displayName)
                                .font(.subheadline.weight(.semibold))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Modified \(version.modified)")
                            Text(version.size)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )
                }
            }

            Label {
                Text("Preserved copy: \(conflict.preservedCopyName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "doc.badge.plus")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !conflict.isResolved {
                HStack {
                    Button {
                        store.resolveConflict(conflict, choice: "kept both versions")
                    } label: {
                        Label("Keep Both", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    ForEach(conflict.versions) { version in
                        Button("Use \(version.service.displayName) Version") {
                            store.resolveConflict(conflict, choice: "kept the \(version.service.displayName) version")
                        }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
            } else {
                Label("Both versions preserved — nothing was overwritten.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
        .card()
    }
}

#Preview {
    ConflictsView()
        .environment(DemoStore())
        .tint(Theme.accent)
        .frame(width: 860, height: 640)
}
