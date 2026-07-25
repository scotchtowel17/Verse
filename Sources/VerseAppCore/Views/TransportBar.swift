import SwiftUI

/// The main transport: play/stop, record, tempo, metronome, loop, monitoring, master meter.
struct TransportBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title2)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(store.copilotPreviewBlocksTransport)
            .help(store.copilotPreviewBlocksTransport
                  ? "Unavailable while reviewing Claude changes"
                  : (store.isPlaying ? "Stop (Space)" : "Play (Space)"))

            Button { store.toggleRecording() } label: {
                Image(systemName: store.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(store.isRecording ? .red : .primary)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(store.copilotPreviewBlocksTransport)
            .help(store.copilotPreviewBlocksTransport
                  ? "Unavailable while reviewing Claude changes"
                  : (store.isRecording ? "Stop recording" : "Record (⌘R)"))

            Divider().frame(height: 22)

            // Tempo
            HStack(spacing: 4) {
                Text("Tempo").font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { store.project.tempoBPM ?? 120 },
                                       set: { store.setTempo($0) }), in: 40...260, step: 1) {
                    Text("\(Int(store.project.tempoBPM ?? 120)) BPM").monospacedDigit().frame(width: 64)
                }
            }

            Toggle(isOn: Binding(get: { store.metronomeOn }, set: { store.setMetronome($0) })) {
                Image(systemName: "metronome")
            }.toggleStyle(.button).help("Metronome")

            Toggle(isOn: Binding(get: { store.loopOn }, set: { store.loopOn = $0 })) {
                Image(systemName: "repeat")
            }.toggleStyle(.button).help("Loop")

            Toggle(isOn: Binding(get: { store.monitoring }, set: { store.setMonitoring($0) })) {
                Image(systemName: "headphones")
            }.toggleStyle(.button).help("Hear input (use headphones)")

            Spacer()

            // Master meter
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                MeterBar(level: store.masterLevel).frame(width: 120)
            }
        }
        .padding(8)
        .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
