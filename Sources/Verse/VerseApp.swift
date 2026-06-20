import SwiftUI
import VerseModel

/// @main entry point. The window grows feature-by-feature across milestones; at M0 it
/// proves the SwiftUI app launches, links the model, and shows an empty untitled project.
@main
struct VerseApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Song") { store.newProject() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

/// Top-level observable application state. At M0 it just owns the in-memory project;
/// the engine, persistence, and command stack attach to it in later milestones.
@MainActor
@Observable
final class AppStore {
    var project: Project

    init() { self.project = .newUntitled() }

    func newProject() { project = .newUntitled() }
}
