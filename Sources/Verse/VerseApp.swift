import SwiftUI
import VerseAppCore

/// @main entry point. The window grows feature-by-feature across milestones.
/// AppStore, views, and domain logic live in VerseAppCore so VerseCheck can test them.
@main
struct VerseApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                // Tall enough that Tracks (min one row) and Arrangement both fit; R3.
                .frame(minWidth: 760, minHeight: 640)
                .onAppear { store.startEngineIfNeeded() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // File commands call store methods only; they do not read canX / name
            // properties for labels or .disabled, so they are not frozen like undo was.
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
            UndoRedoCommands(store: store)
            // Play menu: same pattern as File (actions only, no reactive labels/disabled).
            CommandMenu("Play") {
                Button("All Notes Off (panic)") { store.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Ask Claude…") { store.showCopilot = true }
                    .keyboardShortcut("j", modifiers: [.command])
            }
        }
    }
}

/// Undo/redo menu items. Labels and enablement come from FocusedValue published by
/// ContentView (a real View body that re-evaluates on @Observable changes). Reading
/// AppStore from Scene.commands freezes values at scene-build time; nesting Views
/// inside Commands (attempt 1) also failed to re-evaluate.
struct UndoRedoCommands: Commands {
    let store: AppStore
    @FocusedValue(\.undoMenuState) private var undoState

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoState?.undoName.map { "Undo \($0)" } ?? "Undo") {
                store.undo()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!(undoState?.canUndo ?? false))

            Button(undoState?.redoName.map { "Redo \($0)" } ?? "Redo") {
                store.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(undoState?.canRedo ?? false))
        }
    }
}
