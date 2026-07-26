import SwiftUI
import VerseModel
import VerseEngine

/// The Verse workspace: transport, multitrack mixer, recorded takes, and a playable keyboard
/// for the selected instrument track.
public struct ContentView: View {
    public init() {}
    @Environment(AppStore.self) private var store

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TransportBar()
            // Frequent actions + shared timeline zoom (Step X2).
            GeometryReader { geo in
                ActionBar(fitAvailableWidth: max(1, geo.size.width - BeatTimeline.gutterWidth))
            }
            .frame(height: 32)
            // Track controls live in the arrangement lane gutter (AA1): one row per track.
            // Shared arrangement + inline piano roll (one time axis, one H scroll).
            TimelineWorkspaceView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !store.takes.isEmpty { takesList }
            keyboardChrome
            if store.showOnscreenKeyboard {
                PianoKeyboardView(
                    preferredBaseC: store.baseOctaveC,
                    held: store.heldNotes,
                    noteOn: { store.noteOn($0) },
                    noteOff: { store.noteOff($0) },
                    onOctavesChanged: { store.keyboardOctaveCount = $0 }
                )
            }
            // Musical typing stays live even when the on-screen keyboard is hidden.
            KeyboardInput(
                noteOn: { semi in store.noteOn(store.effectiveKeyboardBaseC + semi) },
                noteOff: { semi in store.noteOff(store.effectiveKeyboardBaseC + semi) },
                shiftOctave: { delta in store.shiftKeyboardOctave(delta) }
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
        .alert(store.pendingRecovery?.projectLoadFailureMessage == nil
               ? "Recover unsaved work?"
               : "Couldn’t restore all unsaved work",
               isPresented: Binding(get: { store.pendingRecovery != nil },
                                    set: { if !$0 { store.dismissRecovery() } })) {
            Button(store.pendingRecovery?.project != nil
                   || store.pendingRecovery?.inProgressTakeURL != nil
                   ? "Recover" : "OK") { store.applyRecovery() }
            Button("Discard", role: .destructive) { store.dismissRecovery() }
        } message: {
            if let fail = store.pendingRecovery?.projectLoadFailureMessage {
                if store.pendingRecovery?.inProgressTakeURL != nil {
                    Text("\(fail) An in-progress recording can still be restored.")
                } else {
                    Text(fail)
                }
            } else {
                Text("Verse found work from a session that didn’t close normally — your last edits and any in-progress recording can be restored.")
            }
        }
        .sheet(isPresented: Binding(get: { store.showCopilot }, set: { store.showCopilot = $0 })) {
            CopilotPanel()
        }
        .sheet(isPresented: Binding(get: { store.showTools }, set: { store.showTools = $0 })) {
            ToolsPanel()
        }
        // Piano roll is inline in TimelineWorkspaceView (no modal sheet).
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

    /// Hint row plus hide/show control. When the keyboard is hidden this stays compact so
    /// the owner can bring it back without a menu hunt; the piano itself is not drawn.
    private var keyboardChrome: some View {
        HStack {
            if store.showOnscreenKeyboard {
                Text("Playing **\(store.currentPresetName)** — keys **A–K** / **W E T Y U**, **Z/X** octave, or click below.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Keyboard hidden — keys **A–K** / **W E T Y U** and **Z/X** still work.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.showOnscreenKeyboard.toggle()
            } label: {
                Label(
                    store.showOnscreenKeyboard ? "Hide keyboard" : "Show keyboard",
                    systemImage: store.showOnscreenKeyboard
                        ? "keyboard.chevron.compact.down"
                        : "keyboard"
                )
            }
            .controlSize(.small)
            .help(store.showOnscreenKeyboard
                  ? "Hide the on-screen keyboard and give space to the roll"
                  : "Show the on-screen keyboard")
            if store.showOnscreenKeyboard {
                Button { store.panic() } label: { Label("Stop sound", systemImage: "stop.circle") }
                    .controlSize(.small).help("Silence all notes (⌘.)")
            }
        }
    }
}
