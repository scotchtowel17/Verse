import SwiftUI
import VerseModel
import VerseEngine

/// The track list with per-track mix controls, instrument choice, and effect inserts.
struct TrackListView: View {
    @Environment(AppStore.self) private var store

    /// Enough height for at least one full track row (instrument, volume, pan, M/S, effect).
    /// Without a floor the flexible ScrollView collapses to zero at the default window size.
    private static let rowMinHeight: CGFloat = 72
    /// Cap tracks so the arrangement + inline piano roll keep room at the default window size.
    private static let listMaxHeight: CGFloat = 160

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
            .frame(minHeight: Self.rowMinHeight, maxHeight: Self.listMaxHeight)
            // Fixed band: do not compete with the timeline for leftover height.
            .layoutPriority(0)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                instrumentPicker
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

            if track.kind == .instrument {
                Button {
                    store.openPianoRoll(forTrack: track.id)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show piano roll for this track")
            }

            Button(role: .destructive) { store.deleteTrack(track.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Bound to program + bank (not track.name) so a new project's "Piano" track still shows
    /// Grand Piano selected, and renaming never blanks the instrument.
    @ViewBuilder
    private var instrumentPicker: some View {
        let selection = Binding(
            get: { store.presetSelectionKey(for: track) },
            set: { store.selectPreset(selectionKey: $0, for: track.id) }
        )
        Picker("", selection: selection) {
            ForEach(SoundBank.presetCategories, id: \.self) { category in
                Section(category) {
                    ForEach(SoundBank.presets(in: category), id: \.selectionKey) { preset in
                        Text(preset.name).tag(preset.selectionKey)
                    }
                }
            }
            // Off-list GM program (e.g. Claude setInstrument): show honestly, not blank.
            // Only present when this track's instrument is not in the curated list.
            if let inst = track.instrument, SoundBank.preset(matching: inst) == nil {
                Text(SoundBank.customLabel(for: inst))
                    .tag(SoundBank.selectionKey(for: inst))
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }
}
