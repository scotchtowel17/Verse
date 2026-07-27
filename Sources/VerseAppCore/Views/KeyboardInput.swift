import SwiftUI
import AppKit

/// Captures computer-keyboard input and maps it to MIDI note on/off (GarageBand-style
/// "musical typing": A row = white keys, W/E/T/Y/U = black keys; Z/X shift octave).
/// Uses an AppKit first-responder view because SwiftUI's `.onKeyPress` doesn't deliver
/// reliable key-up events needed for note-off.
struct KeyboardInput: NSViewRepresentable {
    var noteOn: (Int) -> Void
    var noteOff: (Int) -> Void
    var shiftOctave: (Int) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.noteOn = noteOn
        v.noteOff = noteOff
        v.shiftOctave = shiftOctave
        return v
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.noteOn = noteOn
        nsView.noteOff = noteOff
        nsView.shiftOctave = shiftOctave
    }
}

/// Rules for musical typing that do not depend on AppKit view state, so they are testable.
public enum MusicalTyping {
    /// Whether a key event is a menu/app shortcut rather than musical typing.
    ///
    /// This is load-bearing, not tidiness. macOS does not deliver `keyUp` while Command is
    /// held, so a Command chord reaching the note-on path left a note sounding forever with
    /// no matching note-off: an audible drone plus a stuck key on the on-screen keyboard,
    /// clearable only by "Stop sound". Reproduced with Cmd-G. Control and Option are shortcut
    /// modifiers too and have no musical meaning here, so they are excluded with it. Shift is
    /// not: it does not suppress key-up.
    public static func isShortcutChord(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }
}

final class KeyCaptureView: NSView {
    var noteOn: ((Int) -> Void)?
    var noteOff: ((Int) -> Void)?
    var shiftOctave: ((Int) -> Void)?

    /// Semitone offset from the base C for each typing key.
    private static let semitone: [Character: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5,
        "t": 6, "g": 7, "y": 8, "h": 9, "u": 10, "j": 11,
        "k": 12, "o": 13, "l": 14, "p": 15, ";": 16
    ]

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return } // hold = sustained note, not retrigger
        // Never claim a shortcut chord: Cmd-Z must reach Undo, not shift the octave.
        guard !MusicalTyping.isShortcutChord(event.modifierFlags) else { return super.keyDown(with: event) }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return super.keyDown(with: event) }
        if ch == "z" { shiftOctave?(-1); return }
        if ch == "x" { shiftOctave?(1); return }
        if let semi = Self.semitone[ch] { noteOn?(semi) } else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        guard !MusicalTyping.isShortcutChord(event.modifierFlags) else { return super.keyUp(with: event) }
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return super.keyUp(with: event) }
        if let semi = Self.semitone[ch] { noteOff?(semi) } else { super.keyUp(with: event) }
    }
}
