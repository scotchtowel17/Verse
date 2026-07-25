import Foundation
import VerseModel
import VerseCommands

func runUndoChecks(_ tk: TestKit) {
    tk.suite("UndoStack: labels and capacity") {
        let stack = UndoStack<Int>(limit: 3)
        tk.expect(!stack.canUndo, "empty stack cannot undo")
        tk.expect(stack.undoName == nil, "empty stack has no undoName")
        tk.expect(stack.redoName == nil, "empty stack has no redoName")

        stack.record(1, name: "First")
        stack.record(2, name: "Second")
        stack.record(3, name: "Third")
        stack.record(4, name: "Fourth")  // pushes First out (limit 3)

        tk.expectEqual(stack.undoName, "Fourth", "undoName is the latest action")
        tk.expect(stack.canUndo, "stack can undo after record")

        // record stores pre-mutation state: stack is [2,3,4] after the limit trim.
        // undo(current: 5) returns 4 and labels redo "Fourth".
        let afterUndo1 = stack.undo(current: 5)
        tk.expectEqual(afterUndo1, 4, "undo returns the prior state")
        tk.expectEqual(stack.undoName, "Third", "undoName moves to previous action")
        tk.expectEqual(stack.redoName, "Fourth", "redoName is the undone action")

        let redone = stack.redo(current: 4)
        tk.expectEqual(redone, 5, "redo restores the post-action state")
        tk.expectEqual(stack.undoName, "Fourth", "after redo, undoName is the re-applied action")
        tk.expect(stack.redoName == nil, "redo stack empty after redo")
    }

    tk.suite("UndoStack: record clears redo") {
        let stack = UndoStack<String>()
        stack.record("a", name: "A")
        _ = stack.undo(current: "b")
        tk.expectEqual(stack.redoName, "A", "redo available after undo")
        stack.record("c", name: "C")
        tk.expect(stack.redoName == nil, "new record clears redo")
        tk.expectEqual(stack.undoName, "C", "new record is the only undo")
    }

    tk.suite("UndoStack: clear") {
        let stack = UndoStack<Int>()
        stack.record(0, name: "X")
        _ = stack.undo(current: 1)
        stack.clear()
        tk.expect(!stack.canUndo, "clear empties undo")
        tk.expect(!stack.canRedo, "clear empties redo")
        tk.expect(stack.undoName == nil && stack.redoName == nil, "names nil after clear")
    }
}
