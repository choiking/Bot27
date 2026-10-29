import SwiftUI

struct Bot27App: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot…") { store.newBot() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.light)
        }
    }
}
