import SwiftUI
import AppKit
import AetherloomBridge

@main
struct AetherloomAppApp: App {
    @StateObject private var appModel = AppModel(session: DemoEngineSession.standard())

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .environmentObject(appModel)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AetherloomCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .tint(Theme.accent)
        }
    }
}

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let contentView = NSHostingView(rootView: AboutAetherloomView())
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 224),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.title = "About Aetherloom"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutAetherloomView: View {
    private let width: CGFloat = 520
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    // App icon bitmaps include ~10% transparent margin around the
                    // squircle; trim it from layout so gaps read evenly.
                    .padding(-7)
                    .accessibilityHidden(true)

                Text("Aetherloom")
                    .font(.system(size: 17, weight: .semibold))

                Text("Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 132)

            VStack(alignment: .leading, spacing: 12) {
                Text("Safe folder sync across clouds, local folders, and NAS-backed storage.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    AboutLink(title: "aetherloom.app", destination: URL(string: "https://aetherloom.app")!)
                    AboutLink(title: "hello@aetherloom.app", destination: URL(string: "mailto:hello@aetherloom.app")!)
                }
                .font(.system(size: 12))

                Spacer()
                    .frame(height: 14)

                Text("Created by [Álex Filipe Santos](https://alexfili.pe) in San Francisco.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 26)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: width, height: 224)
    }
}

private struct AboutLink: View {
    let title: String
    let destination: URL

    var body: some View {
        Text(title)
            .foregroundStyle(.link)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
            .onTapGesture {
                NSWorkspace.shared.open(destination)
            }
            .accessibilityAddTraits(.isLink)
    }
}
