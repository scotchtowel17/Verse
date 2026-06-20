import SwiftUI
import VerseModel
import VerseAnalysis

/// M6 tools: analyze a take (Music Understanding when available, else manual), set tempo by
/// tapping, pick the key, and insert an installed Audio Unit effect on the active track.
struct ToolsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tonic: Tonic = .C
    @State private var mode: Mode = .major

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Tune & tools", systemImage: "slider.horizontal.3").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            // Analysis
            GroupBox("Analyze a take") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { store.analyzeLastTake() } label: { Label("Analyze last take", systemImage: "waveform.badge.magnifyingglass") }
                            .disabled(store.analysisBusy)
                        if store.analysisBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(store.musicUnderstandingAvailable ? "On-device analysis" : "Manual fallback")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let r = store.analysisResult {
                        Text(String(format: "Duration %.1fs · loudness %.0f dBFS", r.durationSec, r.loudnessDB))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(r.tempoPending ? "Tempo: tap it in below" : "Tempo: \(Int(r.tempoBPM ?? 0)) BPM")
                            .font(.caption)
                        Text(r.keyPending ? "Key: pick it below" : "Key: \(r.key?.tonic.rawValue ?? "") \(r.key?.mode.rawValue ?? "")")
                            .font(.caption)
                    }
                }.padding(6)
            }

            // Tap tempo
            GroupBox("Tempo") {
                HStack(spacing: 14) {
                    Button { store.tapTempo() } label: {
                        Text("TAP").font(.title3.bold()).frame(width: 80, height: 44)
                    }.buttonStyle(.borderedProminent)
                    Text("\(Int(store.project.tempoBPM ?? 120)) BPM").font(.title2).monospacedDigit()
                    Button("Reset") { store.resetTapTempo() }
                    Spacer()
                }.padding(6)
            }

            // Key picker
            GroupBox("Key") {
                HStack {
                    Picker("Tonic", selection: $tonic) { ForEach(Tonic.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .frame(width: 90)
                    Picker("Mode", selection: $mode) {
                        Text("major").tag(Mode.major); Text("minor").tag(Mode.minor)
                    }.frame(width: 110)
                    Button("Set key") { store.setKey(tonic: tonic, mode: mode) }
                    Spacer()
                    if let k = store.project.key {
                        Text("Current: \(k.tonic.rawValue) \(k.mode.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }

            // Hum → MIDI
            GroupBox("Hum to MIDI") {
                HStack {
                    Button { store.humToMIDIFromLastTake() } label: {
                        Label("Turn last take into MIDI notes", systemImage: "music.note.list")
                    }
                    Spacer()
                    Text(store.basicPitchAvailable ? "Basic Pitch" : "Melody (monophonic)")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }

            // AU hosting
            GroupBox("Insert an installed effect on “\(store.currentPresetName)”") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.installedEffects.count) Audio Units found on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.installedEffects.isEmpty {
                        Text("No installed Audio Units found.").font(.caption)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(store.installedEffects) { au in
                                    Button { store.hostEffect(au) } label: {
                                        HStack {
                                            Text(au.name)
                                            Text(au.manufacturer).font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Image(systemName: "plus.circle")
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(maxHeight: 120)
                    }
                }.padding(6)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .onAppear { if let k = store.project.key { tonic = k.tonic; mode = k.mode } }
    }
}
