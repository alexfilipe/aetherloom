import AetherloomBridge
import AppKit
import SwiftUI

struct AetherloomCommands: Commands {
    var appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Aetherloom") {
                AboutWindowController.shared.show()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Sync Set") {
                guard appModel.activeSheet == nil else { return }
                appModel.activeSheet = .newSyncSet
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Scan Now") {
                Task { await appModel.scanAll() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appModel.isScanning)

            Button("Preview Changes") {
                if let preparation = appModel.pendingPreparations.first {
                    appModel.showCachedPreview(preparation)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(appModel.pendingPreparations.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            Button("Go to Overview") { appModel.show(.overview) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Go to Sync Sets") { appModel.show(.syncSets) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Go to Activity") { appModel.show(.activity) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Go to Conflicts") { appModel.show(.conflicts) }
                .keyboardShortcut("4", modifiers: .command)
        }

        if appModel.isDemoSession {
            CommandMenu("Demo") {
                Button(appModel.oneDriveIsReachable
                       ? "Make OneDrive Unreachable"
                       : "Make OneDrive Reachable") {
                    Task { await appModel.performDemoAction(.toggleOneDrive) }
                }
                Button(appModel.nasIsMounted ? "Unmount NAS “Tank”" : "Mount NAS “Tank”") {
                    Task { await appModel.performDemoAction(.toggleNAS) }
                }
                Divider()
                Button("Edit a File in Two Places") {
                    Task { await appModel.performDemoAction(.makeConflict) }
                }
                Button("Delete Many Files in “Projects”") {
                    Task { await appModel.performDemoAction(.makeMassDeletion) }
                }
                Button("Simulate Interrupted Run") {
                    Task { await appModel.performDemoAction(.simulateInterruptedRun) }
                }
                Divider()
                Button("Reset Demo World") {
                    Task { await appModel.performDemoAction(.reset) }
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Aetherloom Help") {
                NSWorkspace.shared.open(URL(string: "https://aetherloom.app")!)
            }
        }
    }
}
