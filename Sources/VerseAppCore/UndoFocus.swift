import SwiftUI

/// Snapshot of undo/redo menu labels and enablement, published from ContentView
/// via FocusedValue so the Edit menu can update without reading AppStore from
/// Scene.commands (which freezes values at scene-build time).
public struct UndoMenuState: Equatable {
    public var canUndo: Bool
    public var undoName: String?
    public var canRedo: Bool
    public var redoName: String?

    public init(canUndo: Bool, undoName: String?, canRedo: Bool, redoName: String?) {
        self.canUndo = canUndo
        self.undoName = undoName
        self.canRedo = canRedo
        self.redoName = redoName
    }
}

struct UndoMenuStateKey: FocusedValueKey {
    typealias Value = UndoMenuState
}

extension FocusedValues {
    public var undoMenuState: UndoMenuState? {
        get { self[UndoMenuStateKey.self] }
        set { self[UndoMenuStateKey.self] = newValue }
    }
}
