import SwiftUI
import AetherloomCore

struct PageHeader: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var accessory: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if let accessory {
                Text(accessory)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    var text: String
    var tone: AetherloomTone

    var body: some View {
        Label(text, systemImage: iconName)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var color: Color {
        switch tone {
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

    private var iconName: String {
        switch tone {
        case .healthy:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .neutral:
            "circle"
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tone: AetherloomTone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch tone {
        case .healthy:
            .green
        case .attention:
            .orange
        case .paused:
            .red
        case .neutral:
            .accentColor
        }
    }
}

struct ProviderMark: View {
    var provider: ProviderID

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(provider.displayName)
    }

    private var systemImage: String {
        switch provider {
        case .iCloudDrive:
            "icloud"
        case .googleDrive:
            "g.circle"
        case .oneDrive:
            "cloud"
        }
    }

    private var backgroundColor: Color {
        switch provider {
        case .iCloudDrive:
            .cyan
        case .googleDrive:
            .green
        case .oneDrive:
            .blue
        }
    }
}

struct ProviderLocationRow: View {
    var provider: ProviderID
    var location: String

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider)
                .frame(width: 22, height: 22)
                .scaleEffect(0.78)
            Text(provider.displayName)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 10)
            Text(location)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            )
    }
}

extension View {
    func aetherloomCard() -> some View {
        modifier(CardBackground())
    }
}

extension SyncRiskLevel {
    var displayName: String {
        switch self {
        case .safe:
            "Safe"
        case .needsReview:
            "Needs Review"
        case .paused:
            "Paused"
        }
    }
}
