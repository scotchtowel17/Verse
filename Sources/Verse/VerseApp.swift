import SwiftUI
import VerseModel

/// @main entry point. The window grows feature-by-feature across milestones.
@main
struct VerseApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { store.startEngineIfNeeded() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Song") { store.newProject() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("Play") {
                Button("All Notes Off (panic)") { store.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}
