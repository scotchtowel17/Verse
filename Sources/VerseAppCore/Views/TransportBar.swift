import SwiftUI

/// The main transport: play/stop, record, tempo, metronome, loop, monitoring, master meter.
struct TransportBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(store.copilotPreviewBlocksTransport)
            .help(store.copilotPreviewBlocksTransport
                  ? "Unavailable while reviewing Claude changes"
                  : (store.isPlaying ? "Pause (Space)" : "Play (Space)"))

            recordButton

            if let status = store.recordArmStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(store.isRecording && store.isPlaying ? Color.red : Color.secondary)
                    .lineLimit(1)
            } else if let err = store.recordError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

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
            }
            .toggleStyle(.button)
            .help(loopHelp)

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

    private var loopHelp: String {
        if let region = store.loopRegion {
            let label = "beats \(formatLoopBeat(region.lowerBound))-\(formatLoopBeat(region.upperBound))"
            return store.loopOn ? "Loop region on (\(label))" : "Loop off · region set (\(label))"
        }
        return store.loopOn
            ? "Loop whole arrangement on"
            : "Loop (set a region in the ruler or from a clip)"
    }

    private func formatLoopBeat(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    /// Three-state record control: unarmed, armed (waiting for play), capturing (armed + playing).
    @ViewBuilder
    private var recordButton: some View {
        let armed = store.isRecording
        let capturing = armed && store.isPlaying
        Button { store.toggleRecording() } label: {
            Image(systemName: capturing ? "stop.circle.fill" : (armed ? "record.circle.fill" : "record.circle"))
                .font(.title2)
                .foregroundStyle(armed ? Color.white : Color.primary)
                .padding(6)
                .background {
                    if capturing {
                        Circle().fill(Color.red)
                    } else if armed {
                        Circle().fill(Color.red.opacity(0.85))
                    }
                }
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(store.copilotPreviewBlocksTransport)
        .help(recordHelp(armed: armed, capturing: capturing))
        .accessibilityLabel(capturing ? "Stop recording" : (armed ? "Armed for recording" : "Record"))
        .accessibilityValue(store.recordArmStatus ?? (armed ? "Armed" : "Not armed"))
    }

    private func recordHelp(armed: Bool, capturing: Bool) -> String {
        if store.copilotPreviewBlocksTransport {
            return "Unavailable while reviewing Claude changes"
        }
        if capturing { return "Stop recording (⌘R)" }
        if armed {
            let names = store.armedTrackNames()
            if names.isEmpty {
                return "Take running. Press play to capture, or ⌘R to stop."
            }
            if names.count == 1 {
                return "Take running onto \(names[0]). Press play to capture, or ⌘R to stop."
            }
            return "Take running onto \(names.joined(separator: ", ")). Press play to capture, or ⌘R to stop."
        }
        if store.armedTrackIDs.isEmpty {
            return "Record (⌘R) — arm a track first (click R on a track row)"
        }
        let names = store.armedTrackNames()
        if names.count == 1 {
            return "Start recording onto \(names[0]) (⌘R)"
        }
        return "Start recording onto \(names.joined(separator: ", ")) (⌘R)"
    }
}
