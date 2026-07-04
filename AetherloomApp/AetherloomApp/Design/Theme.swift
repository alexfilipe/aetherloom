import SwiftUI

// MARK: - Palette

enum Theme {
    /// Primary brand accent — an indigo "loom thread" hue.
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.92)

    /// Brand gradient used for marks and small accents.
    static let weave = LinearGradient(
        colors: [accent, Color.teal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardCornerRadius: CGFloat = 14

    /// Deep, rich mesh colors for the hero card. Same in light and dark —
    /// the hero is intentionally a vivid, branded surface.
    static let meshColors: [Color] = [
        Color(red: 0.13, green: 0.10, blue: 0.38),
        Color(red: 0.24, green: 0.16, blue: 0.55),
        Color(red: 0.10, green: 0.16, blue: 0.42),
        Color(red: 0.33, green: 0.20, blue: 0.66),
        Color(red: 0.22, green: 0.18, blue: 0.60),
        Color(red: 0.09, green: 0.33, blue: 0.48),
        Color(red: 0.16, green: 0.11, blue: 0.42),
        Color(red: 0.12, green: 0.25, blue: 0.52),
        Color(red: 0.05, green: 0.38, blue: 0.44)
    ]
}

// MARK: - Woven mesh (hero surface)

/// A slowly drifting mesh gradient — the "aether" the app is named for.
struct WeaveMesh: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5],
                    [0.5 + 0.14 * Float(sin(t / 3.1)), 0.5 + 0.14 * Float(cos(t / 3.7))],
                    [1, 0.5],
                    [0, 1], [0.5 + 0.1 * Float(sin(t / 4.3)), 1], [1, 1]
                ],
                colors: Theme.meshColors
            )
        }
    }
}

// MARK: - Backdrop

/// Soft ambient wash behind every screen — depth without noise.
struct ContentBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Theme.accent.opacity(0.07), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 900
            )
            RadialGradient(
                colors: [Color.teal.opacity(0.05), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Tone

/// Calm, consistent status coloring across the whole app.
enum Tone {
    case healthy
    case attention
    case paused
    case neutral

    var color: Color {
        switch self {
        case .healthy: .green
        case .attention: .orange
        case .paused: .red
        case .neutral: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .neutral: "circle.fill"
        }
    }
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    var hoverLift = true

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.10),
                                Color.primary.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovering ? 0.10 : 0.05),
                radius: isHovering ? 12 : 4,
                y: isHovering ? 5 : 2
            )
            .scaleEffect(isHovering ? 1.008 : 1)
            .onHover { hovering in
                guard hoverLift else { return }
                isHovering = hovering
            }
            .animation(.smooth(duration: 0.25), value: isHovering)
    }
}

extension View {
    func card(padding: CGFloat = 18, hoverLift: Bool = true) -> some View {
        modifier(CardBackground(padding: padding, hoverLift: hoverLift))
    }
}

// MARK: - Badges

struct StatusBadge: View {
    var text: String
    var tone: Tone
    /// Set for badges sitting on the dark hero mesh.
    var onDark = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(onDark ? Color.white.opacity(0.9) : tone.color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .background(background, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                onDark ? Color.white.opacity(0.22) : tone.color.opacity(0.25),
                lineWidth: 0.5
            )
        )
        .lineLimit(1)
        .fixedSize()
    }

    private var foreground: Color {
        if onDark { return .white }
        return tone == .neutral ? .secondary : tone.color
    }

    private var background: some ShapeStyle {
        onDark ? Color.white.opacity(0.14) : tone.color.opacity(0.12)
    }
}

// MARK: - Brand mark

struct AppLogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: "circle.hexagongrid.fill")
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.weave, in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: Theme.accent.opacity(0.45), radius: 5, y: 2)
    }
}

// MARK: - Cloud service marks

struct ServiceMark: View {
    var service: CloudService
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: service.systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(service.gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: service.baseColor.opacity(0.4), radius: size * 0.12, y: size * 0.05)
            .accessibilityLabel(service.displayName)
    }
}

// MARK: - Headers

struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    var title: String
    var accessory: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
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

// MARK: - Empty state

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.weave)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .card(hoverLift: false)
    }
}

// MARK: - Safety banner

struct SafetyBanner: View {
    var title: String
    var message: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .shadow(color: .orange.opacity(0.4), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
        }
        .padding(18)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
