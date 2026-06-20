import SwiftUI
import VerseModel
import VerseEngine

/// M1 workspace: pick an instrument, then play it with the on-screen piano or the computer
/// keyboard. Grows into the full multitrack workspace in later milestones.
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            instrumentRow
            Spacer(minLength: 0)
            keyboardHint
            PianoKeyboardView(
                baseC: store.baseOctaveC,
                octaves: 2,
                held: store.heldNotes,
                noteOn: { store.noteOn($0) },
                noteOff: { store.noteOff($0) }
            )
            // Invisible first-responder view that turns computer keystrokes into notes.
            KeyboardInput(
                noteOn: { semi in store.noteOn(store.baseOctaveC + semi) },
                noteOff: { semi in store.noteOff(store.baseOctaveC + semi) },
                shiftOctave: { delta in
                    store.panic()
                    store.baseOctaveC = max(24, min(96, store.baseOctaveC + delta * 12))
                }
            )
            .frame(height: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Verse").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("“\(store.project.title)”").foregroundStyle(.secondary)
            Spacer()
            if let err = store.engineError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label(store.sf2Bundled ? "GeneralUser GS" : "Built-in voice",
                      systemImage: "pianokeys")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var instrumentRow: some View {
        HStack(spacing: 10) {
            Text("Sound:").foregroundStyle(.secondary)
            Picker("Sound", selection: Binding(
                get: { store.currentPresetName },
                set: { name in
                    if let p = store.presets.first(where: { $0.name == name }) { store.selectPreset(p) }
                })) {
                ForEach(store.presets, id: \.name) { p in
                    Text(p.name).tag(p.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer()
            Button { store.panic() } label: { Label("Stop sound", systemImage: "stop.circle") }
                .help("Silence all notes (⌘.)")
        }
    }

    private var keyboardHint: some View {
        Text("Play with the keys **A–K** (white) and **W E T Y U** (black). Press **Z/X** to change octave. Or click the piano below.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
