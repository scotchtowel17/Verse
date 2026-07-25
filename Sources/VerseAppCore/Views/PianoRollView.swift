import SwiftUI
import VerseModel

/// Piano-roll editor for a MIDI clip: pitch × time grid, piano-key gutter, note blocks,
/// snap control, and standard DAW editing (add / move / resize / delete) with one undo
/// entry per completed gesture.
struct PianoRollView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Snap grid in beats: 1 (1/4), 0.5 (1/8), 0.25 (1/16).
    @State private var snapBeats: Double = 0.25
    @State private var selectedNoteID: UUID?
    @FocusState private var isFocused: Bool

    /// Drag-move bookkeeping (gesture-local).
    @State private var moveOrigin: MoveOrigin?
    /// Drag-resize bookkeeping.
    @State private var resizeOrigin: ResizeOrigin?
    /// True while a continuous move/resize gesture is live (guards double-begin).
    @State private var continuousGestureLive = false

    private static let rowHeight: CGFloat = 18
    private static let beatWidth: CGFloat = 56
    private static let gutterWidth: CGFloat = 48
    private static let resizeHandleWidth: CGFloat = 10
    private static let clickSlop: CGFloat = 4

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
                    description: Text("Open the piano roll from a track that has a MIDI clip.")
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
            Button("Done") {
                store.pianoRollAuditionStop()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var snapBar: some View {
        HStack(spacing: 10) {
            Text("Snap").font(.callout).foregroundStyle(.secondary)
            // labelsHidden avoids the duplicate “Snap Snap …” toolbar reading.
            Picker("Snap", selection: $snapBeats) {
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help("Grid snap for note start and length")
            Spacer()
            if selectedNoteID != nil {
                Text("Delete removes selection")
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
        let totalHeight = CGFloat(pitchCount) * rowH
        let totalWidth = CGFloat(contentBeats) * beatW

        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                pianoGutter(rowHeight: rowH, totalHeight: totalHeight)
                ZStack(alignment: .topLeading) {
                    gridLayer(beatWidth: beatW, rowHeight: rowH,
                              totalWidth: totalWidth, totalHeight: totalHeight)
                    // Empty-grid click target (under notes so note gestures win).
                    emptyGridHitTarget(beatWidth: beatW, rowHeight: rowH,
                                       totalWidth: totalWidth, totalHeight: totalHeight)
                    notesLayer(beatWidth: beatW, rowHeight: rowH)
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
                .coordinateSpace(name: "pianoRollGrid")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
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

    /// Click empty grid to add a note at that pitch / snapped beat.
    private func emptyGridHitTarget(beatWidth: CGFloat, rowHeight: CGFloat,
                                    totalWidth: CGFloat, totalHeight: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: totalWidth, height: totalHeight)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
                    .onEnded { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard moved < Self.clickSlop else { return }
                        addNote(at: value.location, beatWidth: beatWidth, rowHeight: rowHeight)
                    }
            )
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
        let selected = note.id == selectedNoteID

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
                .frame(width: Self.resizeHandleWidth)
                .contentShape(Rectangle())
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
                    // First update: bookkeep origin. Only begin undo once motion exceeds slop
                    // so a pure click does not leave a no-op “Move Note” on the stack.
                    moveOrigin = MoveOrigin(noteID: note.id,
                                            pitch: note.pitch,
                                            startBeat: note.startBeat)
                    selectedNoteID = note.id
                    store.pianoRollAuditionStart(note.pitch)
                    return
                }
                guard moved >= Self.clickSlop else { return }
                if !continuousGestureLive {
                    store.beginPianoRollGesture(name: "Move Note")
                    continuousGestureLive = true
                }
                guard let origin = moveOrigin, origin.noteID == note.id else { return }
                let pitchDelta = Int((-value.translation.height / rowHeight).rounded())
                let beatDelta = Double(value.translation.width / beatWidth)
                let rawPitch = origin.pitch + pitchDelta
                let rawStart = origin.startBeat + beatDelta
                let newPitch = min(127, max(0, rawPitch))
                let newStart = max(0, snap(rawStart))
                store.pianoRollMoveNote(id: note.id, toPitch: newPitch, toStartBeat: newStart)
                // Keep audition on the live pitch while dragging.
                store.pianoRollAuditionStart(newPitch)
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

    private func resizeGesture(for note: Note, beatWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pianoRollGrid"))
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = ResizeOrigin(noteID: note.id, lengthBeats: note.lengthBeats)
                    selectedNoteID = note.id
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
                let snapped = max(Project.minimumNoteLengthBeats, snap(raw))
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
        let start = max(0, snap(Double(location.x / beatWidth)))
        let length = max(snapBeats, Project.minimumNoteLengthBeats)
        if let id = store.pianoRollAddNote(pitch: pitch, startBeat: start, lengthBeats: length) {
            selectedNoteID = id
            store.pianoRollAuditionStart(pitch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                store.pianoRollAuditionStop()
            }
        }
    }

    private func deleteSelection() {
        guard let id = selectedNoteID else { return }
        store.pianoRollAuditionStop()
        store.pianoRollDeleteNote(id: id)
        selectedNoteID = nil
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

    private func snap(_ beats: Double) -> Double {
        guard snapBeats > 0 else { return beats }
        return (beats / snapBeats).rounded() * snapBeats
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
        let noteID: UUID
        let pitch: Int
        let startBeat: Double
    }

    private struct ResizeOrigin {
        let noteID: UUID
        let lengthBeats: Double
    }
}

// MARK: - Layout (testable)

/// Pure layout helpers for the piano roll. Kept free of SwiftUI so VerseCheck can lock the
/// “notes visible on open” contract without rendering.
public enum PianoRollLayout {
    /// About three octaves of pitch rows (minimum viewport height in pitch space).
    public static let minPitchSpan = 36

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
