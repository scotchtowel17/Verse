import SwiftUI
import VerseModel
import VerseEngine

/// Compact always-visible track controls for the arrangement lane gutter (Phase AA).
///
/// Always on the row: colour strip, name, record arm, mute, solo, volume, level.
/// Deliberate actions live in a one-click per-track menu: instrument, pan, effect,
/// colour, rename, piano roll, delete.
struct TrackLaneGutter: View {
    @Environment(AppStore.self) private var store
    let track: Track

    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showPanPopover = false

    /// Working track (Y2): roll binding from row selection, instrument or audio.
    private var isSelected: Bool { track.id == store.rollTrackID }
    private var identity: TrackIdentityColor.Swatch { TrackIdentityColor.swatch(for: track.colorIndex) }

    /// Record destination for the current global arm (AA3 will make arm multi-track).
    private var isRecordDestination: Bool {
        if track.kind == .instrument {
            return track.id == store.activeTrackID
        }
        // Audio takes land on the Recordings track; highlight that row while armed.
        return track.kind == .audio && track.name == "Recordings" && store.isRecording
    }

    private var isArmedVisual: Bool {
        store.isRecording && isRecordDestination
    }

    var body: some View {
        HStack(spacing: 0) {
            // Identity strip: thicker when selected so the working track is obvious (Y2).
            Rectangle()
                .fill(identity.solid)
                .frame(width: isSelected ? 6 : 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(track.name)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .help(track.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectTrack(track.id) }

                    armButton
                    muteButton
                    soloButton
                    trackMenu
                }

                HStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { track.volume },
                            set: { store.setVolume($0, track.id) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity)
                    .help("Volume")
                    .accessibilityLabel("Volume")

                    MeterBar(
                        level: store.trackLevel(track.id),
                        height: 5,
                        identityColor: identity.solid
                    )
                    .frame(width: 36)
                    .help("Level")
                    .accessibilityLabel("Level meter")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
        .frame(width: BeatTimeline.gutterWidth, height: ArrangementLanesView.laneHeight, alignment: .leading)
        .background(isSelected ? identity.solid.opacity(0.16) : Color.black.opacity(0.03))
        .overlay(alignment: .trailing) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selectTrack(track.id) }
        .alert("Rename Track", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                store.renameTrack(track.id, to: renameDraft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a short name for this track.")
        }
        .popover(isPresented: $showPanPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pan")
                    .font(.caption.weight(.semibold))
                Slider(
                    value: Binding(
                        get: { track.pan },
                        set: { store.setPan($0, track.id) }
                    ),
                    in: -1...1
                )
                .frame(width: 160)
                Text(panLabel(track.pan))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
    }

    // MARK: - Always-visible buttons

    private var armButton: some View {
        let blocked = store.copilotPreviewBlocksTransport
        return Button {
            armTapped()
        } label: {
            Text("R")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(minWidth: 16)
        }
        .buttonStyle(.bordered)
        .tint(isArmedVisual ? .red : nil)
        .controlSize(.mini)
        .disabled(blocked)
        .help(armHelp(blocked: blocked))
        .accessibilityLabel(isArmedVisual ? "Armed for recording" : "Record arm")
        .accessibilityValue(isArmedVisual ? "Armed" : "Not armed")
    }

    private var muteButton: some View {
        Button { store.toggleMute(track.id) } label: {
            Text("M")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(minWidth: 16)
        }
        .buttonStyle(.bordered)
        .tint(track.mute ? .orange : nil)
        .controlSize(.mini)
        .help(track.mute ? "Unmute track" : "Mute track")
        .accessibilityLabel("Mute")
        .accessibilityValue(track.mute ? "On" : "Off")
    }

    private var soloButton: some View {
        Button { store.toggleSolo(track.id) } label: {
            Text("S")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(minWidth: 16)
        }
        .buttonStyle(.bordered)
        .tint(track.solo ? .blue : nil)
        .controlSize(.mini)
        .help(track.solo ? "Unsolo track" : "Solo track")
        .accessibilityLabel("Solo")
        .accessibilityValue(track.solo ? "On" : "Off")
    }

    // MARK: - Per-track menu (one click)

    private var trackMenu: some View {
        Menu {
            if track.kind == .instrument {
                instrumentMenu
                Divider()
            }

            Button("Pan…") {
                store.selectTrack(track.id)
                showPanPopover = true
            }

            effectMenu

            colorMenu

            Divider()

            Button("Rename…") {
                renameDraft = track.name
                showRenameAlert = true
            }

            if track.kind == .instrument {
                Button("Show Piano Roll") {
                    store.openPianoRoll(forTrack: track.id)
                }
            }

            Divider()

            Button("Delete Track", role: .destructive) {
                store.deleteTrack(track.id)
            }
            .disabled(store.project.tracks.count <= 1)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help("Track options")
        .accessibilityLabel("Track menu")
    }

    @ViewBuilder
    private var instrumentMenu: some View {
        let selection = Binding(
            get: { store.presetSelectionKey(for: track) },
            set: { store.selectPreset(selectionKey: $0, for: track.id) }
        )
        Picker("Instrument", selection: selection) {
            ForEach(SoundBank.presetCategories, id: \.self) { category in
                Section(category) {
                    ForEach(SoundBank.presets(in: category), id: \.selectionKey) { preset in
                        Text(preset.name).tag(preset.selectionKey)
                    }
                }
            }
            // Off-list GM program (e.g. Claude setInstrument): show honestly, not blank.
            if let inst = track.instrument, SoundBank.preset(matching: inst) == nil {
                Text(SoundBank.customLabel(for: inst))
                    .tag(SoundBank.selectionKey(for: inst))
            }
        }
    }

    private var effectMenu: some View {
        Picker("Effect", selection: Binding(
            get: { store.effect(for: track.id) },
            set: { store.setEffect($0, track.id) }
        )) {
            ForEach(VerseAudioEngine.BuiltInEffect.allCases) { effect in
                Text(effect.label).tag(effect)
            }
        }
    }

    private var colorMenu: some View {
        Menu("Colour") {
            ForEach(0..<TrackPalette.count, id: \.self) { index in
                let swatch = TrackIdentityColor.swatch(for: index)
                Button {
                    store.setTrackColorIndex(index, track.id)
                } label: {
                    Label {
                        Text(swatch.name)
                    } icon: {
                        Image(systemName: track.colorIndex == index
                              ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(swatch.solid)
                    }
                }
            }
        }
    }

    // MARK: - Arm semantics (pre-AA3: one global arm, destination = active instrument)

    private func armTapped() {
        // Read destination before selectTrack so re-targeting does not look like "already
        // armed on this row" and accidentally disarm.
        let wasThisDestination = isRecordDestination
        store.selectTrack(track.id)
        if store.isRecording {
            if wasThisDestination {
                store.toggleRecording()
            }
            // Else: re-targeted. MIDI capture rebinds on the next note (ensureMIDICapture).
        } else {
            store.startRecording()
        }
    }

    private func armHelp(blocked: Bool) -> String {
        if blocked {
            return "Unavailable while reviewing Claude changes"
        }
        if isArmedVisual {
            if store.isPlaying {
                return "Recording this track. Click to stop, or ⌘R."
            }
            return "Armed for this track. Press play to capture, or click to disarm."
        }
        if track.kind == .audio {
            return "Arm recording (audio takes land on the Recordings track)"
        }
        return "Arm recording for this track (⌘R also arms the selected track)"
    }

    private func panLabel(_ pan: Double) -> String {
        if abs(pan) < 0.02 { return "Center" }
        if pan < 0 { return String(format: "L %.0f%%", abs(pan) * 100) }
        return String(format: "R %.0f%%", pan * 100)
    }
}
