import SwiftUI

/// Snapshot of undo/redo menu labels and enablement, published from ContentView
/// via FocusedValue so the Edit menu can update without reading AppStore from
/// Scene.commands (which freezes values at scene-build time).
struct UndoMenuState: Equatable {
    var canUndo: Bool
    var undoName: String?
    var canRedo: Bool
    var redoName: String?
}

struct UndoMenuStateKey: FocusedValueKey {
    typealias Value = UndoMenuState
}

extension FocusedValues {
    var undoMenuState: UndoMenuState? {
        get { self[UndoMenuStateKey.self] }
        set { self[UndoMenuStateKey.self] = newValue }
    }
}
