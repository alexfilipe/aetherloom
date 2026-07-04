import SwiftUI

@main
struct AetherloomAppApp: App {
    @State private var store = DemoStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1180, height: 760)
    }
}
