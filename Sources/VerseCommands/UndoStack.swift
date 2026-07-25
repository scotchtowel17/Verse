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
/// trivially correct for the value-type `Project` model. Each entry carries a plain-language
/// label so the Edit menu can show “Undo Add Track” / “Redo Add Track”.
public final class UndoStack<State> {
    private struct Entry {
        let state: State
        let name: String
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let limit: Int

    public init(limit: Int = 100) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Label of the action that undo will reverse, if any (e.g. `"Add Track"`).
    public var undoName: String? { undoStack.last?.name }

    /// Label of the action that redo will re-apply, if any.
    public var redoName: String? { redoStack.last?.name }

    /// Record the current state BEFORE mutating it; clears the redo stack.
    /// `name` is the plain-language action label shown in the Edit menu.
    public func record(_ current: State, name: String) {
        undoStack.append(Entry(state: current, name: name))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public func undo(current: State) -> State? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(state: current, name: entry.name))
        return entry.state
    }

    public func redo(current: State) -> State? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(state: current, name: entry.name))
        return entry.state
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
