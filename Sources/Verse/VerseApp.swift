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
                Button("Open…") { store.open() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Save As…") { store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoName.map { "Undo \($0)" } ?? "Undo") { store.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!store.canUndo)
                Button(store.redoName.map { "Redo \($0)" } ?? "Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
            CommandMenu("Play") {
                Button("All Notes Off (panic)") { store.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Ask Claude…") { store.showCopilot = true }
                    .keyboardShortcut("j", modifiers: [.command])
            }
        }
    }
}
