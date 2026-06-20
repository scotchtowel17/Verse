import Foundation
import VerseModel

/// Command pattern + undo/redo (Build Contract §11). Every model mutation can be expressed as
/// a `ProjectCommand`; the Claude bridge applies a whole patch as ONE command (one undo group),
/// so applying or undoing AI changes is atomic and fully reversible.

public protocol ProjectCommand {
    /// Plain-language name shown in Edit ▸ Undo.
    var name: String { get }
    /// Apply to a working copy. Throwing leaves the original untouched (transactional).
    func apply(to project: inout Project) throws
}

/// Snapshot-based undo stack. Recording the prior state before each command keeps undo/redo
/// trivially correct for the value-type `Project` model.
public final class UndoStack<State> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 100) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Record the current state BEFORE mutating it; clears the redo stack.
    public func record(_ current: State) {
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public func undo(current: State) -> State? {
        guard let s = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return s
    }

    public func redo(current: State) -> State? {
        guard let s = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return s
    }

    public func clear() { undoStack.removeAll(); redoStack.removeAll() }
}
