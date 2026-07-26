import AppKit
import SwiftUI
import VerseModel

/// Piano-roll editor for a MIDI clip: pitch × time grid, piano-key gutter, note blocks,
/// snap control, and standard DAW editing (add / move / resize / delete / copy-paste)
/// with multi-note selection and one undo entry per completed gesture.
struct PianoRollView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Snap grid in beats: 0 (Off), 1 (1/4), 0.5 (1/8), 0.25 (1/16). Default 1/16.
    @State private var snapBeats: Double = 0.25
    /// Last non-zero grid choice; used as new-note length when snap is Off so clicks
    /// do not produce a 1/32 sliver.
    @State private var lastGridSnapBeats: Double = 0.25
    /// View-local selection (not persisted).
    @State private var selectedNoteIDs: Set<UUID> = []
    /// View-local clipboard for Cmd-C / Cmd-X / Cmd-V (relative paste uses startBeat).
    @State private var noteClipboard: [ClipboardNote] = []
    @FocusState private var isFocused: Bool

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

    private static let rowHeight: CGFloat = 18
    private static let beatWidth: CGFloat = 56
    private static let gutterWidth: CGFloat = 48
    private static let rulerHeight: CGFloat = 22
    private static let clickSlop: CGFloat = 4
    private static let doubleClickSeconds: TimeInterval = 0.4

    private var clipID: UUID? { store.pianoRollClipID }

    private var clip: Clip? {
        guard let clipID else { return nil }
        guard let loc = store.project.clipLocation(id: clipID) else { return nil }
        return store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
    }

    private var trackName: String {
        guard let clipID, let loc = store.project.clipLocation(id: clipID) else { return "" }
        return store.project.tracks[loc.trackIndex].name
    }

    private var notes: [Note] { clip?.midiNotes ?? [] }

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    /// Horizontal content length in beats: at least the clip length, any note end, and 4 bars.
    private var contentBeats: Double {
        let clipLen = clip?.lengthBeats ?? 0
        let noteEnd = notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        let fourBars = Double(beatsPerBar * 4)
        return max(clipLen, noteEnd, fourBars, 4)
    }

    /// Inclusive pitch rows drawn on the roll. All notes always fall inside this range so
    /// opening the roll shows existing content without any scrolling.
    private var pitchRange: ClosedRange<Int> {
        PianoRollLayout.displayPitchRange(notes: notes)
    }

    private var pitchLow: Int { pitchRange.lowerBound }
    private var pitchHigh: Int { pitchRange.upperBound }
    private var pitchCount: Int { pitchHigh - pitchLow + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if clip == nil {
                ContentUnavailableView(
                    "No clip to show",
                    systemImage: "music.note.list",
                    description: Text("Open the piano roll from an instrument track. A brand-new project creates an empty MIDI clip for you.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                snapBar
                rollScroll
            }
        }
        .padding(16)
        .frame(minWidth: 960, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 640, idealHeight: 720, maxHeight: .infinity)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onExitCommand {
            store.pianoRollAuditionStop()
            dismiss()
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

    private var header: some View {
        HStack {
            Label("Piano roll", systemImage: "rectangle.split.2x1")
                .font(.title3.bold())
            if let clip {
                Text("· \(clip.name.isEmpty ? "MIDI clip" : clip.name)")
                    .foregroundStyle(.secondary)
                if !trackName.isEmpty {
                    Text("on \(trackName)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            rollTransport
            Spacer().frame(width: 12)
            Button("Done") {
                store.pianoRollAuditionStop()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    /// Play / pause / rewind / loop inside the sheet so the main transport bar is not needed.
    private var rollTransport: some View {
        HStack(spacing: 8) {
            Button {
                store.rewindToStart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Rewind to start")
            .disabled(store.copilotPreviewBlocksTransport)

            Button {
                if store.isPlaying {
                    store.pausePlayback()
                } else {
                    store.startPlayback()
                }
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
            }
            .help(store.isPlaying ? "Pause (hold position)" : "Play from playhead")
            .disabled(store.copilotPreviewBlocksTransport)

            Toggle(isOn: Binding(get: { store.loopOn }, set: { store.loopOn = $0 })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop")
            .disabled(store.copilotPreviewBlocksTransport)
        }
        .buttonStyle(.borderless)
    }

    private var snapBar: some View {
        HStack(spacing: 10) {
            Text("Snap").font(.callout).foregroundStyle(.secondary)
            // labelsHidden avoids the duplicate “Snap Snap …” toolbar reading.
            Picker("Snap", selection: $snapBeats) {
                Text("Off").tag(0.0)
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .help("Grid snap for note start and length. Off allows free placement.")
            .onChange(of: snapBeats) { _, newValue in
                if newValue > 0 { lastGridSnapBeats = newValue }
            }
            Spacer()
            if !selectedNoteIDs.isEmpty {
                Text(selectedNoteIDs.count == 1
                     ? "Delete removes selection"
                     : "\(selectedNoteIDs.count) selected · Delete removes all")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rollScroll: some View {
        let rowH = Self.rowHeight
        let beatW = Self.beatWidth
        let gridHeight = CGFloat(pitchCount) * rowH
        let totalWidth = CGFloat(contentBeats) * beatW
        // Ruler + grid share the playhead height so the line spans both.
        let totalHeight = Self.rulerHeight + gridHeight

        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                // Gutter under a blank ruler corner so keys stay aligned with pitch rows.
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(width: Self.gutterWidth, height: Self.rulerHeight)
                    pianoGutter(rowHeight: rowH, totalHeight: gridHeight)
                }
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        beatRuler(beatWidth: beatW, totalWidth: totalWidth)
                        ZStack(alignment: .topLeading) {
                            gridLayer(beatWidth: beatW, rowHeight: rowH,
                                      totalWidth: totalWidth, totalHeight: gridHeight)
                            // Empty-grid: double-click adds, drag marquees, click clears.
                            emptyGridHitTarget(beatWidth: beatW, rowHeight: rowH,
                                               totalWidth: totalWidth, totalHeight: gridHeight)
                            notesLayer(beatWidth: beatW, rowHeight: rowH)
                            marqueeOverlay()
                        }
                        .frame(width: totalWidth, height: gridHeight, alignment: .topLeading)
                        .coordinateSpace(name: "pianoRollGrid")
                    }
                    // Playhead over ruler + grid (playing, paused, or scrubbed).
                    playheadLayer(beatWidth: beatW, totalHeight: totalHeight)
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
    }

    // MARK: - Beat ruler (scrub)

    /// Click or drag the ruler to move the playhead. Position is arrangement-absolute
    /// (clip start + local beat). Does not record undo.
    private func beatRuler(beatWidth: CGFloat, totalWidth: CGFloat) -> some View {
        Canvas { context, size in
            let beatCount = Int(ceil(contentBeats))
            for b in 0...beatCount {
                let x = CGFloat(b) * beatWidth
                let isBar = b % beatsPerBar == 0
                if isBar {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: size.height * 0.25))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
                    let barNumber = (b / beatsPerBar) + 1
                    context.draw(
                        Text("\(barNumber)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.secondary),
                        at: CGPoint(x: x + 3, y: 2),
                        anchor: .topLeading
                    )
                } else {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: size.height * 0.55))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(Color.black.opacity(0.12)), lineWidth: 0.5)
                }
            }
        }
        .frame(width: totalWidth, height: Self.rulerHeight)
        .background(Color.black.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.15)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrub(atX: value.location.x, beatWidth: beatWidth)
                }
                .onEnded { value in
                    scrub(atX: value.location.x, beatWidth: beatWidth)
                }
        )
        .help("Click or drag to move the playhead")
    }

    private func scrub(atX x: CGFloat, beatWidth: CGFloat) {
        guard let clip else { return }
        let local = max(0, min(contentBeats, Double(x / beatWidth)))
        let arrangement = clip.startBeat + local
        store.scrubPlayhead(to: arrangement)
    }

    /// Vertical playhead at the transport’s arrangement beat, mapped into clip-local time.
    /// Drawn while playing, paused, or after a scrub (not only during playback).
    @ViewBuilder
    private func playheadLayer(beatWidth: CGFloat, totalHeight: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isPlaying)) { _ in
            if let beat = store.playbackBeat,
               let clip {
                let local = beat - clip.startBeat
                if local >= 0 && local <= contentBeats {
                    let x = CGFloat(local) * beatWidth
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 1.5, height: totalHeight)
                        .offset(x: x)
                        .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gutter (piano keys)

    private func pianoGutter(rowHeight: CGFloat, totalHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach((pitchLow...pitchHigh).reversed(), id: \.self) { pitch in
                let y = yForPitch(pitch, rowHeight: rowHeight)
                Rectangle()
                    .fill(Self.isBlackKey(pitch) ? Color.black.opacity(0.78) : Color.white)
                    .frame(width: Self.gutterWidth, height: rowHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.black.opacity(0.12))
                            .frame(height: 0.5)
                    }
                    .overlay(alignment: .trailing) {
                        if pitch % 12 == 0 {
                            Text(Self.pitchLabel(pitch))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Self.isBlackKey(pitch)
                                                 ? Color.white.opacity(0.85)
                                                 : Color.black.opacity(0.55))
                                .padding(.trailing, 4)
                        }
                    }
                    .offset(y: y)
            }
        }
        .frame(width: Self.gutterWidth, height: totalHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1)
        }
    }

    // MARK: - Grid

    private func gridLayer(beatWidth: CGFloat, rowHeight: CGFloat,
                           totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        Canvas { context, size in
            for pitch in pitchLow...pitchHigh {
                let y = yForPitch(pitch, rowHeight: rowHeight)
                if Self.isBlackKey(pitch) {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.06)))
                }
                var rowLine = Path()
                rowLine.move(to: CGPoint(x: 0, y: y + rowHeight))
                rowLine.addLine(to: CGPoint(x: size.width, y: y + rowHeight))
                context.stroke(rowLine, with: .color(Color.black.opacity(0.06)), lineWidth: 0.5)
            }

            let beatCount = Int(ceil(contentBeats))
            for b in 0...beatCount {
                let x = CGFloat(b) * beatWidth
                let isBar = b % beatsPerBar == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    line,
                    with: .color(Color.black.opacity(isBar ? 0.28 : 0.10)),
                    lineWidth: isBar ? 1.2 : 0.6
                )
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    /// Empty grid: pure click clears selection; double-click adds a note; drag draws a
    /// marquee and selects every note it touches.
    private func emptyGridHitTarget(beatWidth: CGFloat, rowHeight: CGFloat,
                                    totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: totalWidth, height: totalHeight)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
                    .onChanged { value in
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
                            applyMarqueeSelection(beatWidth: beatWidth, rowHeight: rowHeight)
                            lastEmptyClickTime = nil
                            lastEmptyClickPoint = nil
                            return
                        }
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard moved < Self.clickSlop else { return }
                        handleEmptyGridClick(at: value.location,
                                             beatWidth: beatWidth, rowHeight: rowHeight)
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

    private func handleEmptyGridClick(at location: CGPoint,
                                      beatWidth: CGFloat, rowHeight: CGFloat) {
        let now = Date()
        if let lastTime = lastEmptyClickTime,
           let lastPoint = lastEmptyClickPoint,
           now.timeIntervalSince(lastTime) <= Self.doubleClickSeconds,
           hypot(location.x - lastPoint.x, location.y - lastPoint.y) < Self.clickSlop * 2 {
            addNote(at: location, beatWidth: beatWidth, rowHeight: rowHeight)
            lastEmptyClickTime = nil
            lastEmptyClickPoint = nil
            return
        }
        // Single click on empty grid: clear selection (does not add a note).
        selectedNoteIDs = []
        lastEmptyClickTime = now
        lastEmptyClickPoint = location
    }

    private func applyMarqueeSelection(beatWidth: CGFloat, rowHeight: CGFloat) {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let beatA = Double(start.x / beatWidth)
        let beatB = Double(current.x / beatWidth)
        let pitchA = pitchAt(y: start.y, rowHeight: rowHeight)
        let pitchB = pitchAt(y: current.y, rowHeight: rowHeight)
        let ids = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: beatA, beatB: beatB, pitchA: pitchA, pitchB: pitchB
        )
        selectedNoteIDs = Set(ids)
    }

    // MARK: - Notes

    private func notesLayer(beatWidth: CGFloat, rowHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(notes) { note in
                noteBlock(note, beatWidth: beatWidth, rowHeight: rowHeight)
            }
        }
    }

    @ViewBuilder
    private func noteBlock(_ note: Note, beatWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let x = CGFloat(note.startBeat) * beatWidth
        let y = yForPitch(note.pitch, rowHeight: rowHeight)
        let w = max(CGFloat(note.lengthBeats) * beatWidth, 6)
        let h = max(rowHeight - 2, 6)
        let selected = selectedNoteIDs.contains(note.id)
        // Proportional, capped resize zone so short notes (default 1/16) keep a move body.
        let handleW = PianoRollLayout.resizeHandleWidth(noteWidth: w)

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(selected ? 1.0 : 0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? Color.primary.opacity(0.55) : Color.accentColor,
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
                .highPriorityGesture(resizeGesture(for: note, beatWidth: beatWidth))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .offset(x: x, y: y + 1)
        .help("Pitch \(note.pitch) · beat \(formatBeat(note.startBeat)) · len \(formatBeat(note.lengthBeats))")
        // Move/select on the body. Pure click (below slop) selects + auditions without undo.
        .gesture(moveGesture(for: note, beatWidth: beatWidth, rowHeight: rowHeight))
    }

    // MARK: - Gestures

    private func moveGesture(for note: Note, beatWidth: CGFloat,
                             rowHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moveOrigin == nil {
                    // First update: update selection, snapshot the group that will move.
                    // Only begin undo once motion exceeds slop so a pure click does not
                    // leave a no-op move on the stack.
                    applyNoteClickSelection(note)
                    // If shift-deselect removed the note under the pointer, do not start a
                    // group move (toggle only). Otherwise move every currently selected note.
                    let moving: [Note]
                    if selectedNoteIDs.contains(note.id) {
                        moving = notes.filter { selectedNoteIDs.contains($0.id) }
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
                let beatDeltaRaw = Double(value.translation.width / beatWidth)
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
            if selectedNoteIDs.contains(note.id) {
                selectedNoteIDs.remove(note.id)
            } else {
                selectedNoteIDs.insert(note.id)
            }
        } else if !selectedNoteIDs.contains(note.id) {
            selectedNoteIDs = [note.id]
        }
    }

    private func resizeGesture(for note: Note, beatWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = ResizeOrigin(noteID: note.id, lengthBeats: note.lengthBeats)
                    if !selectedNoteIDs.contains(note.id) {
                        selectedNoteIDs = [note.id]
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
                let deltaBeats = Double(value.translation.width / beatWidth)
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

    private func addNote(at location: CGPoint, beatWidth: CGFloat, rowHeight: CGFloat) {
        let pitch = pitchAt(y: location.y, rowHeight: rowHeight)
        let start = max(0, PianoRollLayout.snap(Double(location.x / beatWidth), to: snapBeats))
        let length = PianoRollLayout.newNoteLengthBeats(snapBeats: snapBeats,
                                                        lastGridBeats: lastGridSnapBeats)
        if let id = store.pianoRollAddNote(pitch: pitch, startBeat: start, lengthBeats: length) {
            selectedNoteIDs = [id]
            store.pianoRollAuditionStart(pitch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                store.pianoRollAuditionStop()
            }
        }
    }

    private func deleteSelection() {
        guard !selectedNoteIDs.isEmpty else { return }
        store.pianoRollAuditionStop()
        let ids = Array(selectedNoteIDs)
        store.pianoRollDeleteNotes(ids: ids)
        selectedNoteIDs = []
    }

    private func copySelection() {
        let selected = notes.filter { selectedNoteIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        noteClipboard = selected.map {
            ClipboardNote(pitch: $0.pitch, startBeat: $0.startBeat,
                          lengthBeats: $0.lengthBeats, velocity: $0.velocity)
        }
    }

    private func cutSelection() {
        copySelection()
        guard !selectedNoteIDs.isEmpty else { return }
        store.pianoRollAuditionStop()
        let ids = Array(selectedNoteIDs)
        store.pianoRollDeleteNotes(ids: ids, undoName: ids.count == 1 ? "Cut Note" : "Cut Notes")
        selectedNoteIDs = []
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
            selectedNoteIDs = Set(newIDs)
        }
    }

    // MARK: - Coordinate helpers

    private func yForPitch(_ pitch: Int, rowHeight: CGFloat) -> CGFloat {
        // High pitches at the top of the stack (standard piano-roll orientation).
        CGFloat(pitchHigh - pitch) * rowHeight
    }

    private func pitchAt(y: CGFloat, rowHeight: CGFloat) -> Int {
        let idx = Int((y / rowHeight).rounded(.down))
        let pitch = pitchHigh - idx
        return min(pitchHigh, max(pitchLow, pitch))
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

    private static func pitchLabel(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let name = names[pitch % 12]
        let octave = (pitch / 12) - 1
        return "\(name)\(octave)"
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
/// “notes visible on open” contract without rendering.
public enum PianoRollLayout {
    /// About three octaves of pitch rows (minimum viewport height in pitch space).
    public static let minPitchSpan = 36

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

    /// Inclusive pitch window: always covers every note, at least ~3 octaves, clamped to 0…127.
    /// Opening the roll therefore shows existing notes without vertical scrolling.
    public static func displayPitchRange(notes: [Note]) -> ClosedRange<Int> {
        let minP: Int
        let maxP: Int
        if notes.isEmpty {
            minP = 60
            maxP = 60
        } else {
            minP = notes.map(\.pitch).min() ?? 60
            maxP = notes.map(\.pitch).max() ?? 60
        }
        var low = minP
        var high = maxP
        let span = high - low
        if span < minPitchSpan {
            let pad = (minPitchSpan - span) / 2
            low -= pad
            high = low + minPitchSpan
        } else {
            low -= 2
            high += 2
        }
        if low < 0 {
            high = min(127, high - low)
            low = 0
        }
        if high > 127 {
            low = max(0, low - (high - 127))
            high = 127
        }
        if low > high { return 48...84 }
        return low...high
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
        guard let anchor = clipboardStarts.min() else { return [] }
        return clipboardStarts.map { playheadLocalBeat + ($0 - anchor) }
    }

    /// Apply one pitch delta and one beat delta to every origin. Returns `nil` if any
    /// result would leave MIDI 0–127 or start before beat 0 (whole selection rejected).
    /// Formation (relative pitch and time) is preserved when the result is non-nil.
    public static func applyGroupDelta(
        origins: [(pitch: Int, startBeat: Double)],
        pitchDelta: Int,
        beatDelta: Double
    ) -> [(pitch: Int, startBeat: Double)]? {
        var result: [(pitch: Int, startBeat: Double)] = []
        result.reserveCapacity(origins.count)
        for o in origins {
            let pitch = o.pitch + pitchDelta
            let start = o.startBeat + beatDelta
            guard (0...127).contains(pitch), start >= 0 else { return nil }
            result.append((pitch: pitch, startBeat: start))
        }
        return result
    }
}
