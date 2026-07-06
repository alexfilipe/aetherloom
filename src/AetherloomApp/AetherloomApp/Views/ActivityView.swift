import SwiftUI

struct ActivityView: View {
    @Environment(DemoStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Activity",
                    subtitle: "Everything Aetherloom did, and every time it paused to keep your files safe."
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.activity) { item in
                        ActivityRow(item: item)
                            .padding(.vertical, 12)
                        if item.id != store.activity.last?.id {
                            Divider()
                        }
                    }
                }
                .card()
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ContentBackdrop())
    }
}

struct ActivityRow: View {
    var item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.tone.systemImage)
                .font(.headline)
                .foregroundStyle(item.tone.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(item.time)
                    if let service = item.service {
                        Text("·")
                        Text(service.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
        }
    }
}

#Preview {
    ActivityView()
        .environment(DemoStore())
        .tint(Theme.accent)
        .frame(width: 860, height: 700)
}
