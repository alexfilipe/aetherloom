import SwiftUI
import AetherloomCore

struct ActivityLogView: View {
    var activity: [ActivityLogItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Activity",
                    subtitle: "Recent sync work and safety pauses.",
                    systemImage: "clock.arrow.circlepath"
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activity) { item in
                        ActivityRow(item: item)
                            .padding(.vertical, 12)
                        if item.id != activity.last?.id {
                            Divider()
                        }
                    }
                }
                .aetherloomCard()
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ActivityRow: View {
    var item: ActivityLogItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(item.time)
                    if let provider = item.provider {
                        Text(provider.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
        }
    }

    private var iconName: String {
        switch item.tone {
        case .healthy:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .neutral:
            "circle.fill"
        }
    }

    private var color: Color {
        switch item.tone {
        case .healthy:
            .green
        case .attention:
            .orange
        case .paused:
            .red
        case .neutral:
            .secondary
        }
    }
}
