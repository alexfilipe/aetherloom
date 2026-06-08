import SwiftUI
import AetherloomCore

struct ConflictsView: View {
    var conflicts: [ConflictReviewItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Conflicts",
                    subtitle: "Both versions are preserved until review.",
                    systemImage: "exclamationmark.triangle"
                )

                if conflicts.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.seal",
                        title: "No Conflicts",
                        message: "Every tracked file is aligned."
                    )
                } else {
                    ForEach(conflicts) { conflict in
                        ConflictCard(conflict: conflict)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ConflictCard: View {
    var conflict: ConflictReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(conflict.filename)
                        .font(.title3.weight(.semibold))
                    Text(conflict.path.rawValue)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                StatusBadge(text: "Needs Review", tone: .attention)
            }

            Text("This file changed in more than one place. Aetherloom preserved both versions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Label(conflict.providers.map(\.displayName).joined(separator: " and "), systemImage: "cloud")
                Label(conflict.preservedCopyName, systemImage: "doc.badge.plus")
                Label(conflict.detectedAt, systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                Button {
                } label: {
                    Label("Keep Both", systemImage: "doc.on.doc")
                }
                Button {
                } label: {
                    Label("Resolve", systemImage: "checkmark.circle")
                }
                Spacer()
            }
            .buttonStyle(.bordered)
        }
        .aetherloomCard()
    }
}

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .aetherloomCard()
    }
}
