import AppKit
import SwiftUI
import VerseModel

// MARK: - Chrome (header / snap / collapse) above or below the shared grid band

/// Piano-roll controls that sit outside the shared horizontal scroll so they do not drift.
struct PianoRollChrome: View {
    @Environment(AppStore.self) private var store

    private var track: Track? {
        store.project.track(id: store.rollTrackID)
    }

    private var clip: Clip? {
        guard let id = store.effectivePianoRollClipID,
              let loc = store.project.clipLocation(id: id) else { return nil }
        let c = store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
        return c.kind == .midi ? c : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Label("Piano roll", systemImage: "rectangle.split.2x1")
                .font(.subheadline.weight(.semibold))
            if let track, track.kind == .audio {
                Text("· \(track.name)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Audio tracks don’t have notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if let track {
                Text("· \(track.name)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let clip {
                    Text(clip.name.isEmpty ? "MIDI clip" : clip.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Double-click the grid to add a note")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text("Select a track to edit notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.pianoRollAuditionStop()
                store.showPianoRoll = false
            } label: {
                Label("Collapse", systemImage: "chevron.down")
            }
            .controlSize(.small)
            .help("Hide the piano roll (track stays selected)")
        }
    }
}

// MARK: - Embedded roll grid (shared BeatTimeline + parent H scroll)

/// Note grid for the open MIDI clip. Horizontal time uses `BeatTimeline` in arrangement-
/// absolute coordinates so notes line up under the arrangement lanes. Vertical pitch is a
/// bounded window (no inner ScrollView): only the rows that fit the pane, recomputed from
/// height and focus (T4).
struct PianoRollEmbeddedView: View {
    @Environment(AppStore.self) private var store

    let contentBeats: Double
    let totalWidth: CGFloat
    let showsGutter: Bool
    /// Shared timeline zoom (must match arrangement).
    let zoom: Double

    /// Last non-zero grid choice; used as new-note length when snap is Off so clicks
    /// do not produce a 1/32 sliver.
    @State private var lastGridSnapBeats: Double = 0.25
    /// View-local clipboard for Cmd-C / Cmd-X / Cmd-V (relative paste uses startBeat).
    @State private var noteClipboard: [ClipboardNote] = []
    @FocusState private var isFocused: Bool

    /// Snap grid in beats (shared with quantize on the action bar).
    private var snapBeats: Double { store.pianoRollSnapBeats }

    private var snapBeatsBinding: Binding<Double> {
        Binding(
            get: { store.pianoRollSnapBeats },
            set: { store.pianoRollSnapBeats = $0 }
        )
    }

    /// Drag-move bookkeeping (gesture-local). Origins for the whole selection.
    @State private var moveOrigin: MoveOrigin?
    /// Drag-resize bookkeeping.
    @State private var resizeOrigin: ResizeOrigin?
    /// True while a continuous move/resize gesture is live (guards double-begin).
    @State private var continuousGestureLive = false
    /// Marquee rubber-band on empty grid (view-local).
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeLive = false
    /// Double-click detection on empty grid (add note).
    @State private var lastEmptyClickTime: Date?
    @State private var lastEmptyClickPoint: CGPoint?
    /// Measured pitch-pane height. Drives `visiblePitchRange` (no scroll offset).
    @State private var pitchPaneHeight: CGFloat = 0
    /// User pitch navigation relative to the clip focus pitch (octave buttons / gutter drag).
    /// Reset to 0 when the open clip changes so the window re-centres on the music.
    @State private var pitchNavOffset: Int = 0
    /// Gutter-drag bookkeeping: pitchNavOffset snapshot at drag start.
    @State private var gutterDragStartOffset: Int?

    private static let clickSlop: CGFloat = 4
    private static let doubleClickSeconds: TimeInterval = 0.4

    private var clipID: UUID? { store.effectivePianoRollClipID }

    private var clip: Clip? {
        guard let clipID else { return nil }
        guard let loc = store.project.clipLocation(id: clipID) else { return nil }
        let c = store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
        return c.kind == .midi ? c : nil
    }

    private var isAudioTrack: Bool { store.pianoRollIsAudioTrack }

    private var clipStart: Double { clip?.startBeat ?? 0 }

    private var notes: [Note] { clip?.midiNotes ?? [] }

    /// Live pitch-row height (vertical zoom). Must feed every layout/hit path (Y2 / T4).
    private var rowHeight: CGFloat { store.pianoRollRowHeight }

    /// Identity colour of the track that owns the open clip (notes match that track at a glance).
    private var trackColorIndex: Int {
        if let clipID, let loc = store.project.clipLocation(id: clipID) {
            return store.project.tracks[loc.trackIndex].colorIndex
        }
        if let t = store.project.track(id: store.rollTrackID) {
            return t.colorIndex
        }
        return 0
    }

    private var trackIdentity: TrackIdentityColor.Swatch {
        TrackIdentityColor.swatch(for: trackColorIndex)
    }

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    /// Mean pitch of the open clip (middle C when empty). Unchanged by navigation.
    private var focusPitch: Int { PianoRollLayout.focusPitch(notes: notes) }

    /// Window centre after explicit octave / gutter navigation.
    private var windowCenterPitch: Int {
        min(127, max(0, focusPitch + pitchNavOffset))
    }

    /// Inclusive pitch rows drawn on the roll. Pure function of focus, pane height, and
    /// row height: no scroll offset, so expand / resize cannot go stale.
    ///
    /// Uses the measured pitch-pane height only (never a larger default while a shorter pane
    /// is what was drawn). Until the first measure, falls back to the default pane so the
    /// chrome has a stable label.
    private var pitchRange: ClosedRange<Int> {
        let h = pitchPaneHeight > 0 ? pitchPaneHeight : PianoRollLayout.defaultPitchPaneHeight
        return PianoRollLayout.visiblePitchRange(
            focusPitch: windowCenterPitch,
            paneHeight: h,
            rowHeight: rowHeight
        )
    }

    /// Other tracks' notes in overlapping clips (empty when ghosts are off or no open clip).
    private var ghostNotes: [PianoRollGhosts.GhostNote] {
        guard store.showPianoRollGhosts, let clip else { return [] }
        return PianoRollGhosts.notes(
            openClipStart: clip.startBeat,
            openClipLength: clip.lengthBeats,
            openTrackID: store.rollTrackID,
            tracks: store.project.tracks
        )
    }

    var body: some View {
        let rowH = rowHeight
        // Snap toolbar stays above the pitch pane. Horizontal time scroll stays with the
        // parent workspace (shared axis). No vertical ScrollView on pitch (T4).
        VStack(alignment: .leading, spacing: 0) {
            // Snap + pitch nav + zoom stay available whenever the roll can draw (instrument track).
            if !isAudioTrack {
                snapBar
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            GeometryReader { geo in
                // Measure first, then derive the range from that height so the label
                // (via pitchPaneHeight) and the grid always share one row count (X3 / Y2).
                let paneH = geo.size.height
                let range = PianoRollLayout.visiblePitchRange(
                    focusPitch: windowCenterPitch,
                    paneHeight: paneH,
                    rowHeight: rowH
                )
                let rowCount = range.upperBound - range.lowerBound + 1
                let gridHeight = CGFloat(max(1, rowCount)) * rowH
                pitchGrid(
                    rowHeight: rowH,
                    gridHeight: gridHeight,
                    pitchLow: range.lowerBound,
                    pitchHigh: range.upperBound
                )
                .frame(width: (showsGutter ? BeatTimeline.gutterWidth : 0) + totalWidth,
                       height: paneH,
                       alignment: .topLeading)
                .onAppear {
                    isFocused = true
                    pitchPaneHeight = paneH
                }
                .onChange(of: geo.size.height) { _, newHeight in
                    pitchPaneHeight = newHeight
                }
                // Keep the measured height in sync when the reader reports a non-zero size
                // on the first layout pass (onAppear can race a zero proposal).
                .onChange(of: paneH) { _, newHeight in
                    if newHeight > 0 { pitchPaneHeight = newHeight }
                }
            }
        }
        .frame(width: (showsGutter ? BeatTimeline.gutterWidth : 0) + totalWidth,
               alignment: .topLeading)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // Focus ring: roll owns Cmd-C/X/V for notes only when this surface is focused
        // (arrangement has its own ring and clip shortcuts when focused).
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.85 : 0), lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false)
        )
        .onChange(of: isFocused) { _, focused in
            if focused { store.editSurface = .pianoRoll }
        }
        .onChange(of: clipID) { _, _ in
            store.selectedNoteIDs = []
            pitchNavOffset = 0
            gutterDragStartOffset = nil
            // Do not steal keyboard focus here: selecting a clip in the arrangement must
            // leave arrangement focus so Cmd-C/X/V still copy clips. The roll takes focus
            // when the user clicks/drags inside it (or on first appear of the pane).
        }
        // Drop selection entries that no longer exist (undo, delete).
        .onChange(of: store.project.tracks) { _, _ in
            guard let clipID, let loc = store.project.clipLocation(id: clipID) else {
                store.selectedNoteIDs = []
                return
            }
            let live = Set(store.project.tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes?.map(\.id) ?? [])
            store.selectedNoteIDs = store.selectedNoteIDs.intersection(live)
        }
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(.delete) {
            deleteSelection()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            deleteSelection()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("c")], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            copySelection()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("x")], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            cutSelection()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("v")], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            pasteClipboard()
            return .handled
        }
        .onDisappear {
            store.pianoRollAuditionStop()
            if continuousGestureLive {
                store.endPianoRollGesture()
                continuousGestureLive = false
            }
        }
    }

    /// Pitch rows + note grid for the computed visible range only (no vertical scroll).
    @ViewBuilder
    private func pitchGrid(
        rowHeight: CGFloat,
        gridHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if showsGutter {
                pianoGutter(
                    rowHeight: rowHeight,
                    totalHeight: gridHeight,
                    pitchLow: pitchLow,
                    pitchHigh: pitchHigh
                )
            }
            ZStack(alignment: .topLeading) {
                if isAudioTrack {
                    audioTrackPlaceholder(totalHeight: max(gridHeight, 80),
                                          pitchLow: pitchLow, pitchHigh: pitchHigh,
                                          rowHeight: rowHeight)
                } else {
                    gridLayer(rowHeight: rowHeight, totalHeight: gridHeight,
                              pitchLow: pitchLow, pitchHigh: pitchHigh)
                    // Clip span highlight under notes (arrangement-absolute).
                    clipSpanOverlay(totalHeight: gridHeight)
                    // Other tracks: dimmed, non-interactive context (Y2). Behind editable notes.
                    ghostNotesLayer(rowHeight: rowHeight, pitchLow: pitchLow, pitchHigh: pitchHigh)
                    if clip == nil {
                        emptyInstrumentHint(totalHeight: max(gridHeight, 80))
                    }
                    emptyGridHitTarget(rowHeight: rowHeight, totalHeight: gridHeight,
                                       pitchLow: pitchLow, pitchHigh: pitchHigh)
                    notesLayer(rowHeight: rowHeight, pitchLow: pitchLow, pitchHigh: pitchHigh)
                    marqueeOverlay()
                }
            }
            .frame(width: totalWidth, height: max(gridHeight, 80), alignment: .topLeading)
            .coordinateSpace(name: "pianoRollGrid")
        }
    }

    /// Pinned controls above the pitch pane (Y3): never wrap into multi-line labels.
    /// Wide layout shows everything; narrower widths collapse secondary chrome into a menu.
    private var snapBar: some View {
        ViewThatFits(in: .horizontal) {
            snapBarContents(includeStatus: true, includeSnapLabel: true, snapWidth: 200)
            snapBarContents(includeStatus: false, includeSnapLabel: false, snapWidth: 180)
            snapBarMinimal
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Full / medium toolbar row. All groups use `fixedSize` so labels never stack one letter per line.
    private func snapBarContents(
        includeStatus: Bool,
        includeSnapLabel: Bool,
        snapWidth: CGFloat
    ) -> some View {
        HStack(spacing: 6) {
            snapPickerGroup(showLabel: includeSnapLabel, width: snapWidth)
            toolbarDivider
            pitchNavGroup
            toolbarDivider
            // Distinct axes: time = left/right, pitch = up/down (not four identical magnifiers).
            timeZoomGroup
            pitchZoomGroup
            ghostsToggle
            if includeStatus {
                Spacer(minLength: 4)
                noteStatusText
            } else {
                Spacer(minLength: 0)
                overflowMenu(includeStatus: true)
            }
        }
    }

    /// Narrowest layout: snap + pitch range + overflow for zooms / ghosts / status.
    private var snapBarMinimal: some View {
        HStack(spacing: 6) {
            snapPickerGroup(showLabel: false, width: 160)
            pitchNavGroup
            Spacer(minLength: 0)
            overflowMenu(includeStatus: true)
        }
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 16)
    }

    private func snapPickerGroup(showLabel: Bool, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            if showLabel {
                Text("Snap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Picker("Snap", selection: snapBeatsBinding) {
                Text("Off").tag(0.0)
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: width)
            .help("Grid snap for note start and length. Off allows free placement.")
            .onChange(of: store.pianoRollSnapBeats) { _, newValue in
                if newValue > 0 { lastGridSnapBeats = newValue }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(2)
    }

    /// Octave shift + visible range label (always single-line).
    private var pitchNavGroup: some View {
        HStack(spacing: 2) {
            Button {
                shiftPitchWindow(by: 12)
            } label: {
                Image(systemName: "chevron.up")
            }
            .controlSize(.small)
            .help("Raise pitch window by one octave")
            Button {
                shiftPitchWindow(by: -12)
            } label: {
                Image(systemName: "chevron.down")
            }
            .controlSize(.small)
            .help("Lower pitch window by one octave")
            Text(PianoRollLayout.rangeLabel(pitchRange))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Visible pitch range (drag the key gutter to shift)")
        }
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(1)
    }

    /// Horizontal (time) zoom: same `timelineZoom` as arrangement. Axis icon is left/right.
    private var timeZoomGroup: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Time zoom (shared with arrangement)")
            Button {
                store.zoomTimelineOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .controlSize(.small)
            .disabled(store.timelineZoom <= BeatTimeline.minZoom + 1e-9)
            .help(ActionBarLogic.zoomOutHelp(zoom: store.timelineZoom).help)
            Text(horizontalZoomLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .trailing)
                .fixedSize()
                .help("Timeline zoom (shared with arrangement)")
            Button {
                store.zoomTimelineIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .controlSize(.small)
            .disabled(store.timelineZoom >= BeatTimeline.maxZoom - 1e-9)
            .help(ActionBarLogic.zoomInHelp(zoom: store.timelineZoom).help)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time zoom")
    }

    /// Vertical (pitch) zoom: row height only. Axis icon is up/down, not another magnifier pair.
    private var pitchZoomGroup: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Pitch zoom (row height)")
            Button {
                store.zoomPianoRollPitchOut()
            } label: {
                Image(systemName: "minus")
            }
            .controlSize(.small)
            .disabled(store.pianoRollRowHeight <= PianoRollLayout.minRowHeight + 0.01)
            .help("Show more pitches (shorter rows)")
            Button {
                store.zoomPianoRollPitchIn()
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .disabled(store.pianoRollRowHeight >= PianoRollLayout.maxRowHeight - 0.01)
            .help("Show fewer pitches (taller rows)")
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pitch zoom")
    }

    /// Icon-only ghosts control so the old “G / h / o / s / t / s” vertical crush cannot return.
    private var ghostsToggle: some View {
        Toggle(isOn: Binding(
            get: { store.showPianoRollGhosts },
            set: { store.showPianoRollGhosts = $0 }
        )) {
            Image(systemName: store.showPianoRollGhosts
                  ? "rectangle.on.rectangle"
                  : "rectangle.dashed")
                .font(.system(size: 12, weight: .medium))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(store.showPianoRollGhosts
              ? "Hide other tracks’ overlapping notes"
              : "Show other tracks’ notes that overlap this clip (dimmed, not editable)")
        .accessibilityLabel("Ghost notes")
        .fixedSize()
    }

    @ViewBuilder
    private var noteStatusText: some View {
        if !store.selectedNoteIDs.isEmpty {
            Text(store.selectedNoteIDs.count == 1
                 ? "Delete removes selection"
                 : "\(store.selectedNoteIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
        Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }

    /// Overflow for zooms / ghosts / status when the row cannot fit them inline.
    private func overflowMenu(includeStatus: Bool) -> some View {
        Menu {
            Section("Time zoom") {
                Button("Zoom time out") { store.zoomTimelineOut() }
                    .disabled(store.timelineZoom <= BeatTimeline.minZoom + 1e-9)
                Button("Zoom time in") { store.zoomTimelineIn() }
                    .disabled(store.timelineZoom >= BeatTimeline.maxZoom - 1e-9)
                Text(horizontalZoomLabel)
            }
            Section("Pitch zoom") {
                Button("Show more pitches") { store.zoomPianoRollPitchOut() }
                    .disabled(store.pianoRollRowHeight <= PianoRollLayout.minRowHeight + 0.01)
                Button("Show fewer pitches") { store.zoomPianoRollPitchIn() }
                    .disabled(store.pianoRollRowHeight >= PianoRollLayout.maxRowHeight - 0.01)
            }
            Section("Ghosts") {
                Button(store.showPianoRollGhosts ? "Hide ghost notes" : "Show ghost notes") {
                    store.showPianoRollGhosts.toggle()
                }
            }
            if includeStatus {
                Section("Notes") {
                    Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                    if !store.selectedNoteIDs.isEmpty {
                        Text("\(store.selectedNoteIDs.count) selected")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("More piano-roll controls")
        .fixedSize()
    }

    private var horizontalZoomLabel: String {
        let pct = Int((store.timelineZoom * 100).rounded())
        return "\(pct)%"
    }

    private func shiftPitchWindow(by delta: Int) {
        pitchNavOffset = min(127 - focusPitch, max(-focusPitch, pitchNavOffset + delta))
    }

    /// Instrument track with no MIDI clip yet: show what to do, keep the grid clickable.
    private func emptyInstrumentHint(totalHeight: CGFloat) -> some View {
        Text("Double-click to add a note")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(width: totalWidth, height: totalHeight)
            .allowsHitTesting(false)
    }

    /// Audio track: plain language, no interactive note grid.
    private func audioTrackPlaceholder(
        totalHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int,
        rowHeight: CGFloat
    ) -> some View {
        ZStack {
            gridLayer(rowHeight: rowHeight, totalHeight: totalHeight,
                      pitchLow: pitchLow, pitchHigh: pitchHigh)
                .opacity(0.35)
            Text("Audio tracks don’t have notes. Select an instrument track to draw MIDI.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
        .frame(width: totalWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    /// Dim the region outside the open clip so its span lines up with the arrangement block.
    @ViewBuilder
    private func clipSpanOverlay(totalHeight: CGFloat) -> some View {
        if let clip {
            let x = BeatTimeline.x(forBeat: clip.startBeat, zoom: zoom)
            let w = max(BeatTimeline.width(forBeats: clip.lengthBeats, zoom: zoom), 2)
            Rectangle()
                .fill(trackIdentity.solid.opacity(0.08))
                .frame(width: w, height: totalHeight)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Gutter (piano keys)

    private func pianoGutter(
        rowHeight: CGFloat,
        totalHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach((pitchLow...pitchHigh).reversed(), id: \.self) { pitch in
                let y = yForPitch(pitch, pitchHigh: pitchHigh, rowHeight: rowHeight)
                let black = Self.isBlackKey(pitch)
                Rectangle()
                    // Quiet reference strip (X3): soft surfaces, not pure white/black that
                    // dominate the pane in dark mode or wash out in light mode.
                    .fill(black ? Self.gutterBlackKey : Self.gutterWhiteKey)
                    .frame(width: BeatTimeline.gutterWidth, height: rowHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 0.5)
                    }
                    .overlay(alignment: .trailing) {
                        if pitch % 12 == 0 {
                            Text(PianoRollLayout.pitchLabel(pitch))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(black ? 0.75 : 0.45))
                                .padding(.trailing, 4)
                        }
                    }
                    .offset(y: y)
            }
        }
        .frame(width: BeatTimeline.gutterWidth, height: totalHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(gutterPitchDragGesture(rowHeight: rowHeight))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1)
        }
        .help("Drag up or down to shift the pitch window")
    }

    /// Vertical drag on the key gutter shifts the pitch window (explicit navigation, T4).
    private func gutterPitchDragGesture(rowHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gutterDragStartOffset == nil {
                    gutterDragStartOffset = pitchNavOffset
                }
                guard let startOffset = gutterDragStartOffset else { return }
                // Drag up (negative y) raises the window (higher pitches), matching
                // the roll orientation (high pitches at the top).
                let rowDelta = Int((-value.translation.height / rowHeight).rounded())
                pitchNavOffset = min(127 - focusPitch, max(-focusPitch, startOffset + rowDelta))
            }
            .onEnded { _ in
                gutterDragStartOffset = nil
            }
    }

    // MARK: - Grid (arrangement-absolute beat columns)

    private func gridLayer(
        rowHeight: CGFloat,
        totalHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        // Adaptive strokes/fills (Color.primary) so rows read in both light and dark (X3).
        // Fixed Color.black.opacity(...) vanishes on a dark text background.
        Canvas { context, size in
            // Base fill so the note grid is the readable surface, not a black void.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Self.gridBaseFill))
            for pitch in pitchLow...pitchHigh {
                let y = yForPitch(pitch, pitchHigh: pitchHigh, rowHeight: rowHeight)
                if Self.isBlackKey(pitch) {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.07)))
                }
                var rowLine = Path()
                rowLine.move(to: CGPoint(x: 0, y: y + rowHeight))
                rowLine.addLine(to: CGPoint(x: size.width, y: y + rowHeight))
                context.stroke(rowLine, with: .color(Color.primary.opacity(0.14)), lineWidth: 0.5)
            }

            let beatCount = Int(ceil(contentBeats))
            for b in 0...beatCount {
                let x = CGFloat(b) * BeatTimeline.beatWidth(zoom: zoom)
                let isBar = b % beatsPerBar == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    line,
                    with: .color(Color.primary.opacity(isBar ? 0.30 : 0.12)),
                    lineWidth: isBar ? 1.2 : 0.6
                )
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    /// Empty grid: pure click clears selection; double-click adds a note; drag draws a
    /// marquee and selects every note it touches.
    private func emptyGridHitTarget(
        rowHeight: CGFloat,
        totalHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: totalWidth, height: totalHeight)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
                    .onChanged { value in
                        isFocused = true
                        if marqueeStart == nil {
                            marqueeStart = value.startLocation
                            marqueeCurrent = value.location
                        } else {
                            marqueeCurrent = value.location
                        }
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved >= Self.clickSlop {
                            marqueeLive = true
                        }
                    }
                    .onEnded { value in
                        defer {
                            marqueeStart = nil
                            marqueeCurrent = nil
                            marqueeLive = false
                        }
                        if marqueeLive {
                            applyMarqueeSelection(
                                rowHeight: rowHeight, pitchLow: pitchLow, pitchHigh: pitchHigh)
                            lastEmptyClickTime = nil
                            lastEmptyClickPoint = nil
                            return
                        }
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard moved < Self.clickSlop else { return }
                        handleEmptyGridClick(
                            at: value.location, rowHeight: rowHeight,
                            pitchLow: pitchLow, pitchHigh: pitchHigh)
                    }
            )
    }

    @ViewBuilder
    private func marqueeOverlay() -> some View {
        if marqueeLive, let start = marqueeStart, let current = marqueeCurrent {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func handleEmptyGridClick(
        at location: CGPoint,
        rowHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) {
        let now = Date()
        if let lastTime = lastEmptyClickTime,
           let lastPoint = lastEmptyClickPoint,
           now.timeIntervalSince(lastTime) <= Self.doubleClickSeconds,
           hypot(location.x - lastPoint.x, location.y - lastPoint.y) < Self.clickSlop * 2 {
            addNote(at: location, rowHeight: rowHeight, pitchLow: pitchLow, pitchHigh: pitchHigh)
            lastEmptyClickTime = nil
            lastEmptyClickPoint = nil
            return
        }
        // Single click on empty grid: clear selection (does not add a note).
        store.selectedNoteIDs = []
        lastEmptyClickTime = now
        lastEmptyClickPoint = location
    }

    private func applyMarqueeSelection(
        rowHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        // Grid x is arrangement-absolute; selection helpers use clip-local starts.
        let localA = BeatTimeline.localBeat(
            absolute: BeatTimeline.beat(atX: start.x, zoom: zoom), clipStart: clipStart)
        let localB = BeatTimeline.localBeat(
            absolute: BeatTimeline.beat(atX: current.x, zoom: zoom), clipStart: clipStart)
        let pitchA = pitchAt(y: start.y, pitchLow: pitchLow, pitchHigh: pitchHigh,
                             rowHeight: rowHeight)
        let pitchB = pitchAt(y: current.y, pitchLow: pitchLow, pitchHigh: pitchHigh,
                             rowHeight: rowHeight)
        let ids = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: localA, beatB: localB, pitchA: pitchA, pitchB: pitchB
        )
        store.selectedNoteIDs = Set(ids)
    }

    // MARK: - Notes

    private func notesLayer(
        rowHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Only notes inside the visible pitch window are drawn; navigate to reach others.
            ForEach(notes.filter { $0.pitch >= pitchLow && $0.pitch <= pitchHigh }) { note in
                noteBlock(note, rowHeight: rowHeight, pitchHigh: pitchHigh)
            }
        }
    }

    /// Dimmed notes from other tracks: context only, never selectable or draggable (Y2).
    private func ghostNotesLayer(
        rowHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ghostNotes.filter { $0.pitch >= pitchLow && $0.pitch <= pitchHigh }) { ghost in
                ghostNoteBlock(ghost, rowHeight: rowHeight, pitchHigh: pitchHigh)
            }
        }
        .allowsHitTesting(false)
    }

    private func ghostNoteBlock(
        _ ghost: PianoRollGhosts.GhostNote,
        rowHeight: CGFloat,
        pitchHigh: Int
    ) -> some View {
        let x = BeatTimeline.x(forBeat: ghost.absoluteStartBeat, zoom: zoom)
        let y = yForPitch(ghost.pitch, pitchHigh: pitchHigh, rowHeight: rowHeight)
        let w = max(BeatTimeline.width(forBeats: ghost.lengthBeats, zoom: zoom), 4)
        let h = max(rowHeight - 4, 4)
        let identity = TrackIdentityColor.swatch(for: ghost.colorIndex)
        return RoundedRectangle(cornerRadius: 2)
            .fill(identity.solid.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(identity.solid.opacity(0.35), lineWidth: 0.5)
            )
            .frame(width: w, height: h)
            .offset(x: x, y: y + 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func noteBlock(_ note: Note, rowHeight: CGFloat, pitchHigh: Int) -> some View {
        // Arrangement-absolute x so beat N sits under arrangement beat N.
        let absStart = BeatTimeline.absoluteStart(
            clipStart: clipStart, noteLocalStart: note.startBeat)
        let x = BeatTimeline.x(forBeat: absStart, zoom: zoom)
        let y = yForPitch(note.pitch, pitchHigh: pitchHigh, rowHeight: rowHeight)
        let w = max(BeatTimeline.width(forBeats: note.lengthBeats, zoom: zoom), 6)
        let h = max(rowHeight - 2, 6)
        let selected = store.selectedNoteIDs.contains(note.id)
        // Proportional, capped resize zone so short notes (default 1/16) keep a move body.
        let handleW = PianoRollLayout.resizeHandleWidth(noteWidth: w)

        ZStack(alignment: .trailing) {
            // Note fill matches track identity; selection is a border (system accent), not identity.
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? trackIdentity.solid.opacity(0.92) : trackIdentity.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? Color.accentColor : trackIdentity.solid.opacity(0.7),
                                      lineWidth: selected ? 1.5 : 0.5)
                )
            // Right-edge resize handle (high priority so it wins over body move).
            Rectangle()
                .fill(Color.primary.opacity(selected ? 0.35 : 0.18))
                .frame(width: handleW)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .highPriorityGesture(resizeGesture(for: note))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .offset(x: x, y: y + 1)
        .help("Pitch \(note.pitch) · beat \(formatBeat(note.startBeat)) · len \(formatBeat(note.lengthBeats))")
        // Move/select on the body. Pure click (below slop) selects + auditions without undo.
        .gesture(moveGesture(for: note, rowHeight: rowHeight))
    }

    // MARK: - Gestures

    private func moveGesture(for note: Note, rowHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
            .onChanged { value in
                isFocused = true
                let moved = hypot(value.translation.width, value.translation.height)
                if moveOrigin == nil {
                    // First update: update selection, snapshot the group that will move.
                    // Only begin undo once motion exceeds slop so a pure click does not
                    // leave a no-op move on the stack.
                    applyNoteClickSelection(note)
                    // If shift-deselect removed the note under the pointer, do not start a
                    // group move (toggle only). Otherwise move every currently selected note.
                    let moving: [Note]
                    if store.selectedNoteIDs.contains(note.id) {
                        moving = notes.filter { store.selectedNoteIDs.contains($0.id) }
                    } else {
                        moving = []
                    }
                    let origins = moving.map {
                        (id: $0.id, pitch: $0.pitch, startBeat: $0.startBeat)
                    }
                    moveOrigin = MoveOrigin(notes: origins, primaryID: note.id)
                    store.pianoRollAuditionStart(note.pitch)
                    return
                }
                guard moved >= Self.clickSlop else { return }
                guard let origin = moveOrigin, origin.primaryID == note.id,
                      !origin.notes.isEmpty else { return }
                if !continuousGestureLive {
                    let name = origin.notes.count > 1 ? "Move Notes" : "Move Note"
                    store.beginPianoRollGesture(name: name)
                    continuousGestureLive = true
                }
                // Same pitch and time delta for every selected note (formation preserved).
                // Snap the primary note’s start; apply that beat delta to the whole group.
                let pitchDelta = Int((-value.translation.height / rowHeight).rounded())
                let beatDeltaRaw = Double(value.translation.width / BeatTimeline.beatWidth(zoom: zoom))
                guard let primary = origin.notes.first(where: { $0.id == origin.primaryID })
                        ?? origin.notes.first else { return }
                let snappedPrimaryStart = PianoRollLayout.snap(
                    primary.startBeat + beatDeltaRaw, to: snapBeats)
                let beatDelta = snappedPrimaryStart - primary.startBeat
                guard let proposed = PianoRollSelection.applyGroupDelta(
                    origins: origin.notes.map { (pitch: $0.pitch, startBeat: $0.startBeat) },
                    pitchDelta: pitchDelta,
                    beatDelta: beatDelta
                ) else {
                    // Any note would leave 0–127 or go before beat 0: reject as a whole.
                    return
                }
                let moves = zip(origin.notes, proposed).map {
                    (id: $0.0.id, toPitch: $0.1.pitch, toStartBeat: $0.1.startBeat)
                }
                store.pianoRollMoveNotes(moves)
                if let idx = origin.notes.firstIndex(where: { $0.id == origin.primaryID }) {
                    store.pianoRollAuditionStart(proposed[idx].pitch)
                } else if let first = proposed.first {
                    store.pianoRollAuditionStart(first.pitch)
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if continuousGestureLive {
                    store.endPianoRollGesture()
                    continuousGestureLive = false
                    store.pianoRollAuditionStop()
                } else if moved < Self.clickSlop {
                    // Pure click: selection + short audition already started in onChanged.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        store.pianoRollAuditionStop()
                    }
                } else {
                    store.pianoRollAuditionStop()
                }
                moveOrigin = nil
            }
    }

    /// Click a note: select it. Shift-click toggles membership. Clicking an already-selected
    /// note without shift keeps the whole selection (so a drag can move the group).
    private func applyNoteClickSelection(_ note: Note) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift {
            if store.selectedNoteIDs.contains(note.id) {
                store.selectedNoteIDs.remove(note.id)
            } else {
                store.selectedNoteIDs.insert(note.id)
            }
        } else if !store.selectedNoteIDs.contains(note.id) {
            store.selectedNoteIDs = [note.id]
        }
    }

    private func resizeGesture(for note: Note) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
            .onChanged { value in
                isFocused = true
                if resizeOrigin == nil {
                    resizeOrigin = ResizeOrigin(noteID: note.id, lengthBeats: note.lengthBeats)
                    if !store.selectedNoteIDs.contains(note.id) {
                        store.selectedNoteIDs = [note.id]
                    }
                    store.pianoRollAuditionStart(note.pitch)
                    return
                }
                let moved = abs(value.translation.width)
                guard moved >= Self.clickSlop else { return }
                if !continuousGestureLive {
                    store.beginPianoRollGesture(name: "Resize Note")
                    continuousGestureLive = true
                }
                guard let origin = resizeOrigin, origin.noteID == note.id else { return }
                let deltaBeats = Double(value.translation.width / BeatTimeline.beatWidth(zoom: zoom))
                let raw = origin.lengthBeats + deltaBeats
                let snapped = max(Project.minimumNoteLengthBeats,
                                  PianoRollLayout.snap(raw, to: snapBeats))
                // Keep strictly positive so the model never rejects mid-drag.
                store.pianoRollResizeNote(id: note.id, toLengthBeats: max(snapped, Project.minimumNoteLengthBeats))
            }
            .onEnded { _ in
                if continuousGestureLive {
                    store.endPianoRollGesture()
                    continuousGestureLive = false
                }
                store.pianoRollAuditionStop()
                resizeOrigin = nil
            }
    }

    // MARK: - Actions

    private func addNote(
        at location: CGPoint,
        rowHeight: CGFloat,
        pitchLow: Int,
        pitchHigh: Int
    ) {
        let pitch = pitchAt(y: location.y, pitchLow: pitchLow, pitchHigh: pitchHigh,
                            rowHeight: rowHeight)
        let absBeat = BeatTimeline.beat(atX: location.x, zoom: zoom)
        let localRaw = BeatTimeline.localBeat(absolute: absBeat, clipStart: clipStart)
        // Notes before the clip start cannot be stored (model uses clip-local ≥ 0).
        guard localRaw >= -0.000_1 else {
            store.statusMessage = "Notes must sit inside the clip’s time range."
            return
        }
        let start = max(0, PianoRollLayout.snap(localRaw, to: snapBeats))
        let length = PianoRollLayout.newNoteLengthBeats(snapBeats: snapBeats,
                                                        lastGridBeats: lastGridSnapBeats)
        if let id = store.pianoRollAddNote(pitch: pitch, startBeat: start, lengthBeats: length) {
            store.selectedNoteIDs = [id]
            store.pianoRollAuditionStart(pitch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                store.pianoRollAuditionStop()
            }
        }
    }

    private func deleteSelection() {
        guard !store.selectedNoteIDs.isEmpty else { return }
        store.pianoRollAuditionStop()
        let ids = Array(store.selectedNoteIDs)
        store.pianoRollDeleteNotes(ids: ids)
        store.selectedNoteIDs = []
    }

    private func copySelection() {
        let selected = notes.filter { store.selectedNoteIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        noteClipboard = selected.map {
            ClipboardNote(pitch: $0.pitch, startBeat: $0.startBeat,
                          lengthBeats: $0.lengthBeats, velocity: $0.velocity)
        }
    }

    private func cutSelection() {
        copySelection()
        guard !store.selectedNoteIDs.isEmpty else { return }
        store.pianoRollAuditionStop()
        let ids = Array(store.selectedNoteIDs)
        store.pianoRollDeleteNotes(ids: ids, undoName: ids.count == 1 ? "Cut Note" : "Cut Notes")
        store.selectedNoteIDs = []
    }

    private func pasteClipboard() {
        guard !noteClipboard.isEmpty, let clip else { return }
        let absBeat = store.playbackBeat ?? 0
        let playheadLocal = max(0, absBeat - clip.startBeat)
        let starts = PianoRollSelection.pasteStartBeats(
            clipboardStarts: noteClipboard.map(\.startBeat),
            playheadLocalBeat: playheadLocal
        )
        guard starts.count == noteClipboard.count else { return }
        // Reject whole paste if any start would go negative (formation would break).
        guard starts.allSatisfy({ $0 >= 0 }) else {
            store.statusMessage = "Those notes can’t paste before beat 0."
            return
        }
        let specs = zip(noteClipboard, starts).map {
            (pitch: $0.0.pitch, startBeat: $0.1,
             lengthBeats: $0.0.lengthBeats, velocity: $0.0.velocity)
        }
        let newIDs = store.pianoRollPasteNotes(specs)
        if !newIDs.isEmpty {
            store.selectedNoteIDs = Set(newIDs)
        }
    }

    // MARK: - Coordinate helpers

    /// High pitches at the top of the stack (standard piano-roll orientation).
    /// Uses the same pitchHigh as `visiblePitchRange` so paint and hit-testing agree.
    private func yForPitch(_ pitch: Int, pitchHigh: Int, rowHeight: CGFloat) -> CGFloat {
        PianoRollLayout.yForPitch(pitch, pitchHigh: pitchHigh, rowHeight: rowHeight)
    }

    /// Map a y in the pitch grid to a MIDI pitch using the same window as painting.
    private func pitchAt(y: CGFloat, pitchLow: Int, pitchHigh: Int, rowHeight: CGFloat) -> Int {
        PianoRollLayout.pitchAt(y: y, pitchLow: pitchLow, pitchHigh: pitchHigh,
                                rowHeight: rowHeight)
    }

    private func formatBeat(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    /// MIDI black-key pitches within an octave (C=0).
    private static func isBlackKey(_ pitch: Int) -> Bool {
        switch pitch % 12 {
        case 1, 3, 6, 8, 10: return true
        default: return false
        }
    }

    // MARK: - Appearance-aware roll colours (light and dark)

    /// Soft white-key surface for the gutter (not pure white, which blinds in dark mode).
    private static var gutterWhiteKey: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedWhite: 0.30, alpha: 1)
            }
            return NSColor(calibratedWhite: 0.93, alpha: 1)
        })
    }

    /// Soft black-key surface for the gutter (quiet reference strip, not the main event).
    private static var gutterBlackKey: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedWhite: 0.14, alpha: 1)
            }
            return NSColor(calibratedWhite: 0.22, alpha: 1)
        })
    }

    /// Note-grid base fill: readable in both appearances (slightly lifted off pure black/white).
    private static var gridBaseFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedWhite: 0.11, alpha: 1)
            }
            return NSColor(calibratedWhite: 0.99, alpha: 1)
        })
    }

    // MARK: - Gesture origin snapshots

    private struct MoveOrigin {
        /// Selection snapshot at drag start (id, pitch, startBeat).
        let notes: [(id: UUID, pitch: Int, startBeat: Double)]
        let primaryID: UUID
    }

    private struct ResizeOrigin {
        let noteID: UUID
        let lengthBeats: Double
    }

    private struct ClipboardNote: Equatable {
        var pitch: Int
        var startBeat: Double
        var lengthBeats: Double
        var velocity: Int
    }
}

// MARK: - Layout (testable)

/// Pure layout helpers for the piano roll. Kept free of SwiftUI so VerseCheck can lock the
/// visible pitch window without rendering.
public enum PianoRollLayout {
    /// Pixel height of one pitch row at default vertical zoom (shared by default band sizing).
    public static let rowHeight: CGFloat = 18
    /// Shortest pitch row (max pitches visible). Vertical zoom clamp (Y2 / Y3).
    /// Low enough that zoom-out can expose distant ghost notes (e.g. bass under a lead clip)
    /// without leaving the T4 whole-row invariant.
    public static let minRowHeight: CGFloat = 5
    /// Tallest pitch row (fewest pitches visible). Vertical zoom clamp (Y2).
    public static let maxRowHeight: CGFloat = 36
    /// Multiplicative step for pitch-row zoom in / out buttons.
    public static let rowHeightZoomStep: CGFloat = 1.25

    /// Default expanded roll viewport: about two octaves of pitch rows.
    public static let defaultViewportPitchRows = 24

    /// Space reserved above the pitch pane for the pinned Snap / pitch-nav / zoom toolbar.
    /// Single-line only (Y3): multi-line chrome steals pane height and defeats pitch zoom-out.
    public static let snapToolbarHeight: CGFloat = 36

    /// Default pitch-pane height (~2 octaves of rows), used before GeometryReader measures.
    public static var defaultPitchPaneHeight: CGFloat {
        CGFloat(defaultViewportPitchRows) * rowHeight
    }

    /// Default expanded roll band height (pinned toolbar + ~2 octaves of rows).
    public static var defaultBandHeight: CGFloat {
        defaultPitchPaneHeight + snapToolbarHeight
    }

    /// Clamp a pitch row height into the supported vertical-zoom range.
    public static func clampedRowHeight(_ height: CGFloat) -> CGFloat {
        min(maxRowHeight, max(minRowHeight, height))
    }

    /// Next taller row height after zooming pitch in one step.
    public static func zoomedInRowHeight(from height: CGFloat) -> CGFloat {
        clampedRowHeight(height * rowHeightZoomStep)
    }

    /// Next shorter row height after zooming pitch out one step.
    public static func zoomedOutRowHeight(from height: CGFloat) -> CGFloat {
        clampedRowHeight(height / rowHeightZoomStep)
    }

    /// Whole pitch rows that fit in `paneHeight` at `rowHeight` (at least one).
    ///
    /// This is the count of rows the roll will draw, and must equal the span of
    /// `visiblePitchRange` (and therefore of `rangeLabel`) for the same inputs (X3 / Y2).
    public static func drawnRowCount(paneHeight: CGFloat, rowHeight: CGFloat) -> Int {
        let rh = max(rowHeight, 1)
        return max(1, Int(floor(paneHeight / rh)))
    }

    /// Shrink preferred arrangement/roll band heights so the shared timeline stack fits the
    /// workspace viewport. Without this, a tall default roll (plus the X2 action bar and other
    /// chrome) is laid out full-size and then clipped by the workspace, so the range label
    /// claims more rows than the user can see.
    ///
    /// When `rollExpanded` is false, all band budget goes to the arrangement.
    /// When the budget is tight, both bands share it proportionally above their minima;
    /// if even the minima cannot fit, the budget is split by the minima ratio so the stack
    /// height never exceeds the viewport (honest range, no clipped half-rows).
    public static func fitBandHeights(
        availableHeight: CGFloat,
        rulerHeight: CGFloat,
        dividerHeight: CGFloat,
        rollExpanded: Bool,
        preferredArrangement: CGFloat,
        preferredRoll: CGFloat,
        minArrangement: CGFloat,
        minRoll: CGFloat
    ) -> (arrangement: CGFloat, roll: CGFloat) {
        let arrPref = max(minArrangement, preferredArrangement)
        if !rollExpanded {
            let budget = max(0, availableHeight - rulerHeight)
            return (min(arrPref, max(minArrangement, budget)), 0)
        }
        let rollPref = max(minRoll, preferredRoll)
        let budget = max(0, availableHeight - rulerHeight - dividerHeight)
        if arrPref + rollPref <= budget {
            return (arrPref, rollPref)
        }
        let minSum = minArrangement + minRoll
        if budget <= minSum {
            guard budget > 0, minSum > 0 else {
                return (max(0, budget), 0)
            }
            let arrShare = budget * (minArrangement / minSum)
            return (arrShare, budget - arrShare)
        }
        // Keep minima; distribute remaining pixels by how far each preferred sits above min.
        let extra = budget - minSum
        let arrHeadroom = arrPref - minArrangement
        let rollHeadroom = rollPref - minRoll
        let headroom = arrHeadroom + rollHeadroom
        if headroom <= 0 {
            return (minArrangement, minRoll)
        }
        let arrExtra = extra * (arrHeadroom / headroom)
        return (minArrangement + arrExtra, minRoll + (extra - arrExtra))
    }

    /// Max pixel width of the right-edge resize handle on a note block.
    public static let resizeHandleMaxWidth: CGFloat = 10
    /// Fraction of note width used for resize when the note is shorter than the fixed max.
    public static let resizeHandleFraction: CGFloat = 0.3

    /// Resize hit zone for a note of the given pixel width.
    ///
    /// Fixed-width handles cover the whole block on short notes (default snap is 1/16), so
    /// every newly drawn note became unmovable. Cap the zone at 30% of note width so the
    /// middle always moves.
    public static func resizeHandleWidth(noteWidth: CGFloat) -> CGFloat {
        guard noteWidth > 0 else { return 0 }
        return min(resizeHandleMaxWidth, noteWidth * resizeHandleFraction)
    }

    /// Round `beats` to the snap grid. `snapBeats == 0` means Off: return the value unchanged.
    public static func snap(_ beats: Double, to snapBeats: Double) -> Double {
        guard snapBeats > 0 else { return beats }
        return (beats / snapBeats).rounded() * snapBeats
    }

    /// Length used when the user clicks to add a note.
    ///
    /// With snap on, length is one grid unit. With snap Off, use the last non-zero grid so
    /// a click does not collapse to the 1/32 minimum and produce an invisible sliver.
    /// Always floored at `Project.minimumNoteLengthBeats`.
    public static func newNoteLengthBeats(snapBeats: Double, lastGridBeats: Double) -> Double {
        let grid = snapBeats > 0 ? snapBeats : lastGridBeats
        return max(grid, Project.minimumNoteLengthBeats)
    }

    /// Contiguous pitch range to draw for a pane of the given height.
    ///
    /// Returns as many whole rows as fit `paneHeight`, centred on `focusPitch`, clamped so
    /// the range never leaves 0…127. When clamped at either end the window shifts rather
    /// than shrinking, so the pane stays full (until the full MIDI keyboard is shown).
    /// This is the single source of truth for paint and hit-testing (T4).
    public static func visiblePitchRange(
        focusPitch: Int,
        paneHeight: CGFloat,
        rowHeight: CGFloat
    ) -> ClosedRange<Int> {
        let rowCount = drawnRowCount(paneHeight: paneHeight, rowHeight: rowHeight)
        let focus = min(127, max(0, focusPitch))
        // Prefer equal space above and below; when odd count, the extra row sits below.
        let below = (rowCount - 1) / 2
        var low = focus - below
        var high = low + rowCount - 1
        if low < 0 {
            high -= low
            low = 0
        }
        if high > 127 {
            low -= (high - 127)
            high = 127
        }
        if low < 0 { low = 0 }
        if high > 127 { high = 127 }
        if low > high { return 0...0 }
        return low...high
    }

    /// Pitch that should sit at the vertical centre of the viewport when a clip opens.
    /// Empty clip (no notes) falls back to middle C (60).
    public static func focusPitch(notes: [Note]) -> Int {
        guard !notes.isEmpty else { return 60 }
        let sum = notes.reduce(0) { $0 + $1.pitch }
        return Int((Double(sum) / Double(notes.count)).rounded())
    }

    /// Y of the top of a pitch row (high pitches at y = 0, standard piano-roll orientation).
    public static func yForPitch(_ pitch: Int, pitchHigh: Int, rowHeight: CGFloat) -> CGFloat {
        CGFloat(pitchHigh - pitch) * rowHeight
    }

    /// Map a y coordinate in the pitch grid to a MIDI pitch. Uses the same window bounds
    /// as painting so clicks land on the row the user sees.
    public static func pitchAt(
        y: CGFloat,
        pitchLow: Int,
        pitchHigh: Int,
        rowHeight: CGFloat
    ) -> Int {
        let rh = max(rowHeight, 1)
        let idx = Int((y / rh).rounded(.down))
        let pitch = pitchHigh - idx
        return min(pitchHigh, max(pitchLow, pitch))
    }

    /// Short label for a MIDI pitch, e.g. "C4".
    public static func pitchLabel(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = min(127, max(0, pitch))
        let name = names[clamped % 12]
        let octave = (clamped / 12) - 1
        return "\(name)\(octave)"
    }

    /// Visible-range label for the toolbar, e.g. "C2-C4".
    public static func rangeLabel(_ range: ClosedRange<Int>) -> String {
        "\(pitchLabel(range.lowerBound))-\(pitchLabel(range.upperBound))"
    }
}

// MARK: - Ghost notes from other tracks (Step Y2, testable)

/// Dimmed, non-interactive notes from other tracks' clips that time-overlap the open clip.
/// Pure so VerseCheck can lock overlap and exclusion without rendering.
public enum PianoRollGhosts {
    /// One ghost note drawn in arrangement-absolute time, in its source track's colour.
    public struct GhostNote: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let pitch: Int
        public let absoluteStartBeat: Double
        public let lengthBeats: Double
        public let colorIndex: Int
        public let sourceTrackID: UUID

        public init(
            id: UUID,
            pitch: Int,
            absoluteStartBeat: Double,
            lengthBeats: Double,
            colorIndex: Int,
            sourceTrackID: UUID
        ) {
            self.id = id
            self.pitch = pitch
            self.absoluteStartBeat = absoluteStartBeat
            self.lengthBeats = lengthBeats
            self.colorIndex = colorIndex
            self.sourceTrackID = sourceTrackID
        }
    }

    /// Whether two half-open beat ranges `[aStart, aEnd)` and `[bStart, bEnd)` overlap.
    public static func rangesOverlap(
        aStart: Double, aEnd: Double,
        bStart: Double, bEnd: Double
    ) -> Bool {
        aStart < bEnd && bStart < aEnd
    }

    /// Notes from every track other than `openTrackID` whose MIDI clips overlap
    /// `[openClipStart, openClipStart + openClipLength)`.
    ///
    /// Notes keep their own UUIDs so ForEach is stable. They are never selectable: the view
    /// draws them with `allowsHitTesting(false)` only.
    public static func notes(
        openClipStart: Double,
        openClipLength: Double,
        openTrackID: UUID,
        tracks: [Track]
    ) -> [GhostNote] {
        let openEnd = openClipStart + openClipLength
        guard openClipLength > 0 else { return [] }
        var result: [GhostNote] = []
        for track in tracks where track.id != openTrackID {
            for clip in track.clips where clip.kind == .midi {
                let clipEnd = clip.startBeat + clip.lengthBeats
                guard rangesOverlap(
                    aStart: openClipStart, aEnd: openEnd,
                    bStart: clip.startBeat, bEnd: clipEnd
                ) else { continue }
                for note in clip.midiNotes ?? [] {
                    result.append(GhostNote(
                        id: note.id,
                        pitch: note.pitch,
                        absoluteStartBeat: BeatTimeline.absoluteStart(
                            clipStart: clip.startBeat,
                            noteLocalStart: note.startBeat
                        ),
                        lengthBeats: note.lengthBeats,
                        colorIndex: track.colorIndex,
                        sourceTrackID: track.id
                    ))
                }
            }
        }
        return result
    }
}

// MARK: - Selection helpers (Phase S2, testable)

/// Pure multi-note selection helpers for the piano roll. Free of SwiftUI so VerseCheck can
/// lock marquee hit-testing, group-move rejection, and paste offsets without rendering.
public enum PianoRollSelection {
    /// Whether a note’s pitch × time rectangle intersects the marquee. Pitch bounds are
    /// inclusive (one row per MIDI pitch). Time ranges touch if they overlap at all.
    public static func noteTouchesMarquee(
        note: Note,
        beatA: Double, beatB: Double,
        pitchA: Int, pitchB: Int
    ) -> Bool {
        let beatLo = min(beatA, beatB)
        let beatHi = max(beatA, beatB)
        let pitchLo = min(pitchA, pitchB)
        let pitchHi = max(pitchA, pitchB)
        let noteBeatLo = note.startBeat
        let noteBeatHi = note.startBeat + note.lengthBeats
        let timeOverlap = noteBeatLo < beatHi && noteBeatHi > beatLo
        let pitchOverlap = note.pitch >= pitchLo && note.pitch <= pitchHi
        return timeOverlap && pitchOverlap
    }

    /// IDs of notes whose blocks touch the marquee rectangle in beat/pitch space.
    public static func notesTouchingMarquee(
        notes: [Note],
        beatA: Double, beatB: Double,
        pitchA: Int, pitchB: Int
    ) -> [UUID] {
        notes.filter {
            noteTouchesMarquee(note: $0, beatA: beatA, beatB: beatB, pitchA: pitchA, pitchB: pitchB)
        }.map(\.id)
    }

    /// Paste starts: the earliest clipboard note maps to `playheadLocalBeat`; others keep
    /// their relative offsets. Starts are never forced below 0 (caller should pass a
    /// non-negative playhead; offsets that would go negative are still returned so the
    /// paste API can reject with a readable message).
    public static func pasteStartBeats(
        clipboardStarts: [Double],
        playheadLocalBeat: Double
    ) -> [Double] {
        guard let earliest = clipboardStarts.min() else { return [] }
        let delta = playheadLocalBeat - earliest
        return clipboardStarts.map { $0 + delta }
    }

    /// Apply the same pitch and beat delta to every origin. Returns nil if any result would
    /// leave MIDI pitch 0…127 or start before beat 0 (whole group rejected, formation kept).
    public static func applyGroupDelta(
        origins: [(pitch: Int, startBeat: Double)],
        pitchDelta: Int,
        beatDelta: Double
    ) -> [(pitch: Int, startBeat: Double)]? {
        var result: [(pitch: Int, startBeat: Double)] = []
        result.reserveCapacity(origins.count)
        for o in origins {
            let p = o.pitch + pitchDelta
            let s = o.startBeat + beatDelta
            guard p >= 0, p <= 127, s >= 0 else { return nil }
            result.append((pitch: p, startBeat: s))
        }
        return result
    }

    // MARK: Track-first clip resolution (W1)

    /// Which MIDI clip the roll edits when the user has not selected one explicitly.
    /// Order: clip under the playhead, else nearest earlier (latest start at or before the
    /// playhead), else the first MIDI clip in track order. Nil when the track has none.
    public static func resolvedMIDIClip(
        clips: [Clip],
        playheadBeat: Double
    ) -> Clip? {
        let midi = clips.filter { $0.kind == .midi }
        guard !midi.isEmpty else { return nil }
        if midi.count == 1 { return midi[0] }
        if let under = midi.first(where: {
            playheadBeat >= $0.startBeat && playheadBeat < $0.startBeat + $0.lengthBeats
        }) {
            return under
        }
        let earlier = midi.filter { $0.startBeat <= playheadBeat }
        if let nearest = earlier.max(by: { $0.startBeat < $1.startBeat }) {
            return nearest
        }
        return midi.first
    }

    /// Placement for a MIDI clip created on demand when the user draws a note on a track
    /// that has none. Clip is bar-aligned to contain the note; length is at least
    /// `minimumBars` bars and long enough to cover the note.
    public static func onDemandClipPlacement(
        absoluteNoteStart: Double,
        noteLengthBeats: Double,
        beatsPerBar: Int,
        minimumBars: Int = 4
    ) -> (clipStart: Double, clipLength: Double, localNoteStart: Double) {
        let bpb = max(1, beatsPerBar)
        let absStart = max(0, absoluteNoteStart)
        let clipStart = floor(absStart / Double(bpb)) * Double(bpb)
        let localStart = absStart - clipStart
        let noteEndLocal = localStart + max(noteLengthBeats, 0)
        let minLength = Double(bpb * max(1, minimumBars))
        let barsCoveringNote = ceil(noteEndLocal / Double(bpb)) * Double(bpb)
        let clipLength = max(minLength, barsCoveringNote)
        return (clipStart, clipLength, localStart)
    }
}
