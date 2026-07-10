import AetherloomBridge
import AppKit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isWindowOccluded = false
    @State private var frozenDate = Date()

    private var isPaused: Bool {
        reduceMotion || scenePhase != .active || isWindowOccluded
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
            let date = isPaused ? frozenDate : context.date
            let t = date.timeIntervalSinceReferenceDate
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
        .background {
            WindowOcclusionObserver { isVisible in
                isWindowOccluded = !isVisible
            }
        }
        .onChange(of: isPaused) { wasPaused, paused in
            if !wasPaused && paused {
                frozenDate = Date()
            }
        }
    }
}

private struct WindowOcclusionObserver: NSViewRepresentable {
    var visibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WindowOcclusionView {
        let view = WindowOcclusionView()
        view.visibilityChanged = visibilityChanged
        return view
    }

    func updateNSView(_ nsView: WindowOcclusionView, context: Context) {
        nsView.visibilityChanged = visibilityChanged
        nsView.reportVisibility()
    }
}

private final class WindowOcclusionView: NSView {
    var visibilityChanged: ((Bool) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow
            )
        }
    }

    func reportVisibility() {
        visibilityChanged?(window?.occlusionState.contains(.visible) == true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportVisibility()
    }

    @objc private func windowOcclusionChanged() {
        reportVisibility()
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

/// Calm, consistent status coloring across the whole app. Derivation remains
/// in AetherloomBridge; only concrete SwiftUI styling lives here.
typealias Tone = StatusTone

extension StatusTone {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                color: .black.opacity(isHovering && !reduceMotion ? 0.10 : 0.05),
                radius: isHovering && !reduceMotion ? 12 : 4,
                y: isHovering && !reduceMotion ? 5 : 2
            )
            .scaleEffect(isHovering && !reduceMotion ? 1.008 : 1)
            .onHover { hovering in
                guard hoverLift, !reduceMotion else { return }
                isHovering = hovering
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.25), value: isHovering)
            .onChange(of: reduceMotion) { _, shouldReduce in
                if shouldReduce {
                    isHovering = false
                }
            }
    }
}

extension View {
    func card(padding: CGFloat = 18, hoverLift: Bool = true) -> some View {
        modifier(CardBackground(padding: padding, hoverLift: hoverLift))
    }

    func liveNumericTransition() -> some View {
        modifier(LiveNumericTransition())
    }
}

private struct LiveNumericTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .opacity : .numericText())
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
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
        Image("LogoMarkFlat")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .background(Theme.weave, in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: Theme.accent.opacity(0.45), radius: 5, y: 2)
    }
}

// MARK: - Cloud service marks

// 🎭 placeholder: provider brand glyphs — see architecture/ui/11-functioning-vs-placeholder.md.
struct ServiceMark: View {
    private var symbolName: String
    private var displayName: String
    private var gradient: LinearGradient
    private var baseColor: Color
    var size: CGFloat = 32

    init(provider: ProviderPresentation, size: CGFloat = 32) {
        self.symbolName = provider.symbolName
        self.displayName = provider.displayName
        self.gradient = provider.paletteToken.gradient
        self.baseColor = provider.paletteToken.baseColor
        self.size = size
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: baseColor.opacity(0.4), radius: size * 0.12, y: size * 0.05)
            .help("Placeholder mark — official \(displayName) artwork arrives with the real provider integrations")
            .accessibilityLabel(displayName)
            .accessibilityHint("Official provider artwork arrives with the real provider integrations")
    }
}

private extension ProviderPalette {
    var baseColor: Color {
        switch self {
        case .iCloud: .cyan
        case .google: .green
        case .oneDrive: .blue
        case .dropbox: .indigo
        case .local: Color(red: 0.48, green: 0.53, blue: 0.60)
        case .nas: .purple
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .iCloud:
            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .google:
            LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .oneDrive:
            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dropbox:
            LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .local:
            LinearGradient(
                colors: [baseColor, Color(red: 0.28, green: 0.32, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .nas:
            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

// MARK: - Metrics

struct MetricTile: View {
    var value: String
    var label: String
    var onDark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .liveNumericTransition()
            Text(label)
                .font(.caption)
                .foregroundStyle(onDark ? .white.opacity(0.72) : .secondary)
        }
        .foregroundStyle(onDark ? .white : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            onDark ? Color.white.opacity(0.10) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(onDark ? Color.white.opacity(0.16) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

// MARK: - Safety banner

struct SafetyBanner: View {
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

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

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
            }
        }
        .padding(18)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}

// MARK: - Refusal banner

struct InlineBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var message: String
    var detail: String?

    @State private var isShowingDetail = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [.indigo, Theme.accent], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .shadow(color: Theme.accent.opacity(0.25), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isShowingDetail, let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 16)

            if detail != nil {
                Button(isShowingDetail ? "Hide Details" : "Details") {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth) {
                        isShowingDetail.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(isShowingDetail ? "Hide refusal details" : "Show refusal details")
            }
        }
        .padding(18)
        .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(.indigo.opacity(0.20), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}
