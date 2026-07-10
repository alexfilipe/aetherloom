import AetherloomBridge
import AetherloomCore
import SwiftUI

// 🎭 placeholder: provider connection flow — see architecture/ui/11-functioning-vs-placeholder.md
struct ConnectProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var kind: ProviderKind

    var body: some View {
        VStack(spacing: 22) {
            ServiceMark(provider: kind.presentation, size: 64)
            VStack(spacing: 5) {
                Text("Connect \(kind.displayName)")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text("Preview the steps a real provider connection will use.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            stepRail

            VStack(spacing: 8) {
                Text("Aetherloom will ask for access only to the folders you choose. It won’t inspect unrelated files or change anything until you preview and approve a sync plan.")
                Text("Aetherloom only sees folders you choose.")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 430)

            PlaceholderChip(text: "Preview — provider connections arrive with the real integrations")

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Link("Learn More", destination: URL(string: "https://aetherloom.app")!)
            }
        }
        .padding(28)
        .frame(width: 520, height: 430)
    }

    private var stepRail: some View {
        HStack(spacing: 8) {
            ForEach(Array(["Sign in", "Grant access", "Choose folders"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Image(systemName: "\(index + 1).circle.fill")
                        .foregroundStyle(index == 0 ? Theme.accent : .secondary)
                    Text(title)
                        .font(.caption.weight(index == 0 ? .semibold : .regular))
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                }
                if index < 2 {
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .frame(height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection preview steps: Sign in, Grant access, Choose folders")
    }
}

#Preview("Connect Google Drive") {
    ConnectProviderSheet(kind: .googleDrive)
        .tint(Theme.accent)
}

#Preview("Connect iCloud Drive") {
    ConnectProviderSheet(kind: .iCloudDrive)
        .tint(Theme.accent)
}
