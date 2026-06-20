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
            masterMeterRow
            instrumentRow
            transportRow
            if !store.takes.isEmpty { takesList }
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

    private var masterMeterRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            MeterBar(level: store.masterLevel)
            Text("Main").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button {
                store.toggleRecording()
            } label: {
                Label(store.isRecording ? "Stop" : "Record",
                      systemImage: store.isRecording ? "stop.fill" : "record.circle")
                    .foregroundStyle(store.isRecording ? .red : .primary)
            }
            .keyboardShortcut("r", modifiers: [.command])

            // Input meter (only meaningful while recording)
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").foregroundStyle(store.isRecording ? .red : .secondary)
                MeterBar(level: store.inputLevel).frame(width: 160)
            }

            Toggle("Hear input", isOn: Binding(
                get: { store.monitoring }, set: { store.setMonitoring($0) }))
                .toggleStyle(.switch)
                .help("Monitor the microphone. Use headphones to avoid feedback.")

            Spacer()
            if let err = store.recordError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private var takesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorded takes").font(.caption).foregroundStyle(.secondary)
            ForEach(store.takes) { take in
                HStack {
                    Button { store.play(take) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                    Text(take.label).font(.callout)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var keyboardHint: some View {
        Text("Play with the keys **A–K** (white) and **W E T Y U** (black). Press **Z/X** to change octave. Or click the piano below.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
