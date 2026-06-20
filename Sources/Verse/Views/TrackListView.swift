import SwiftUI
import VerseModel
import VerseEngine

/// The track list with per-track mix controls, instrument choice, and effect inserts.
struct TrackListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Button { store.addInstrumentTrack() } label: { Label("Instrument", systemImage: "pianokeys") }
                    .controlSize(.small)
                Button { store.addAudioTrack() } label: { Label("Audio", systemImage: "waveform") }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.project.tracks) { track in
                        TrackRow(track: track)
                    }
                }
            }
            .frame(maxHeight: 230)
        }
    }
}

private struct TrackRow: View {
    @Environment(AppStore.self) private var store
    let track: Track

    private var isActive: Bool { track.id == store.activeTrackID && track.kind == .instrument }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: track.kind == .instrument ? "pianokeys" : "waveform")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.callout).fontWeight(isActive ? .semibold : .regular)
                MeterBar(level: store.trackLevel(track.id), height: 5).frame(width: 130)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { store.selectTrack(track.id) }

            if track.kind == .instrument {
                Picker("", selection: Binding(
                    get: { track.name },
                    set: { name in if let p = store.presets.first(where: { $0.name == name }) {
                        store.selectPreset(p, for: track.id) } })) {
                    ForEach(store.presets, id: \.name) { Text($0.name).tag($0.name) }
                }.labelsHidden().frame(width: 130)
            } else {
                Text("\(track.clips.count) clip(s)").font(.caption).foregroundStyle(.secondary).frame(width: 130)
            }

            // Volume
            Slider(value: Binding(get: { track.volume }, set: { store.setVolume($0, track.id) }), in: 0...1)
                .frame(width: 90)
            // Pan
            Slider(value: Binding(get: { track.pan }, set: { store.setPan($0, track.id) }), in: -1...1)
                .frame(width: 60)
                .help("Pan")

            Button { store.toggleMute(track.id) } label: { Text("M") }
                .buttonStyle(.bordered).tint(track.mute ? .orange : nil).controlSize(.small)
            Button { store.toggleSolo(track.id) } label: { Text("S") }
                .buttonStyle(.bordered).tint(track.solo ? .blue : nil).controlSize(.small)

            Picker("", selection: Binding(
                get: { store.effect(for: track.id) },
                set: { store.setEffect($0, track.id) })) {
                ForEach(VerseAudioEngine.BuiltInEffect.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 90).help("Insert effect")

            Button(role: .destructive) { store.deleteTrack(track.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}
