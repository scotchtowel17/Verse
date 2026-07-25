import SwiftUI
import VerseModel
import VerseEngine

/// The Verse workspace: transport, multitrack mixer, recorded takes, and a playable keyboard
/// for the selected instrument track.
public struct ContentView: View {
    public init() {}
    @Environment(AppStore.self) private var store

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TransportBar()
            TrackListView()
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusedSceneValue(\.undoMenuState, UndoMenuState(
            canUndo: store.canUndo,
            undoName: store.undoName,
            canRedo: store.canRedo,
            redoName: store.redoName
        ))
        .alert("Recover unsaved work?",
               isPresented: Binding(get: { store.pendingRecovery != nil },
                                    set: { if !$0 { store.dismissRecovery() } })) {
            Button("Recover") { store.applyRecovery() }
            Button("Discard", role: .destructive) { store.dismissRecovery() }
        } message: {
            Text("Verse found work from a session that didn’t close normally — your last edits and any in-progress recording can be restored.")
        }
        .sheet(isPresented: Binding(get: { store.showCopilot }, set: { store.showCopilot = $0 })) {
            CopilotPanel()
        }
        .sheet(isPresented: Binding(get: { store.showTools }, set: { store.showTools = $0 })) {
            ToolsPanel()
        }
        .sheet(isPresented: Binding(
            get: { store.showPianoRoll },
            set: { newValue in
                store.showPianoRoll = newValue
                if !newValue { store.pianoRollClipID = nil }
            }
        )) {
            PianoRollView()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Verse").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("“\(store.documentName)”").foregroundStyle(.secondary)
            if let status = store.statusMessage {
                Text(status).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Label(store.midiConnectionStatus, systemImage: store.midiSourceNames.isEmpty
                  ? "pianokeys"
                  : "pianokeys.inverse")
                .font(.caption)
                .foregroundStyle(store.midiSourceNames.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .help(store.midiConnectionStatus)
            Button { store.showTools = true } label: { Label("Tune & Tools", systemImage: "slider.horizontal.3") }
                .help("Analyze a take, tap tempo, pick key, host Audio Units")
            Button { store.showCopilot = true } label: { Label("Ask Claude", systemImage: "sparkles") }
                .help("Songwriting copilot — uses your existing Claude, no API key")
            if let err = store.engineError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label(store.activeBankDisplayName, systemImage: "waveform.circle")
                    .font(.caption).foregroundStyle(.secondary)
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
                    if let err = store.recordError { Text(err).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var keyboardHint: some View {
        HStack {
            Text("Playing **\(store.currentPresetName)** — keys **A–K** / **W E T Y U**, **Z/X** octave, or click below.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button { store.panic() } label: { Label("Stop sound", systemImage: "stop.circle") }
                .controlSize(.small).help("Silence all notes (⌘.)")
        }
    }
}
