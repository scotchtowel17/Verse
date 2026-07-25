import SwiftUI
import VerseModel

/// Read-only piano-roll for a MIDI clip: pitch × time grid, piano-key gutter, note blocks,
/// snap control, and two-axis scrolling. Editing gestures land in Phase P3.
struct PianoRollView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Snap grid in beats: 1 (1/4), 0.5 (1/8), 0.25 (1/16). Held for layout / future edit.
    @State private var snapBeats: Double = 0.25

    private static let rowHeight: CGFloat = 14
    private static let beatWidth: CGFloat = 48
    private static let gutterWidth: CGFloat = 44
    private static let pitchCount = 128

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

    /// Pitch to center on open: mean of existing notes, else middle C.
    private var focusPitch: Int {
        guard !notes.isEmpty else { return 60 }
        let sum = notes.reduce(0) { $0 + $1.pitch }
        return min(127, max(0, sum / notes.count))
    }

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
        .frame(minWidth: 720, minHeight: 480)
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
            Text("Read-only preview; drawing notes comes next")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
        }
    }

    private var snapBar: some View {
        HStack(spacing: 10) {
            Text("Snap").font(.callout).foregroundStyle(.secondary)
            Picker("Snap", selection: $snapBeats) {
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .help("Grid snap for note editing (editing arrives in a later step)")
            Spacer()
            Text("\(notes.count) note\(notes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rollScroll: some View {
        let rowH = Self.rowHeight
        let beatW = Self.beatWidth
        let totalHeight = CGFloat(Self.pitchCount) * rowH
        let totalWidth = CGFloat(contentBeats) * beatW

        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    pianoGutter(rowHeight: rowH, totalHeight: totalHeight)
                    ZStack(alignment: .topLeading) {
                        gridLayer(beatWidth: beatW, rowHeight: rowH,
                                  totalWidth: totalWidth, totalHeight: totalHeight)
                        notesLayer(beatWidth: beatW, rowHeight: rowH)
                    }
                    .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
            .onAppear {
                // Center the default viewport on the clip’s notes (about 3 octaves of context).
                proxy.scrollTo(pitchRowID(focusPitch), anchor: .center)
            }
        }
    }

    // MARK: - Gutter (piano keys)

    private func pianoGutter(rowHeight: CGFloat, totalHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach((0..<Self.pitchCount).reversed(), id: \.self) { pitch in
                let y = CGFloat(Self.pitchCount - 1 - pitch) * rowHeight
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
                                .foregroundStyle(Self.isBlackKey(pitch) ? Color.white.opacity(0.85) : Color.black.opacity(0.55))
                                .padding(.trailing, 4)
                        }
                    }
                    .offset(y: y)
                    .id(pitchRowID(pitch))
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
            // Horizontal pitch lanes (black-key rows slightly shaded).
            for pitch in 0..<Self.pitchCount {
                let y = CGFloat(Self.pitchCount - 1 - pitch) * rowHeight
                if Self.isBlackKey(pitch) {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                    context.fill(Path(rect), with: .color(Color.black.opacity(0.06)))
                }
                var rowLine = Path()
                rowLine.move(to: CGPoint(x: 0, y: y + rowHeight))
                rowLine.addLine(to: CGPoint(x: size.width, y: y + rowHeight))
                context.stroke(rowLine, with: .color(Color.black.opacity(0.06)), lineWidth: 0.5)
            }

            // Vertical beat / bar lines.
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
    }

    // MARK: - Notes

    private func notesLayer(beatWidth: CGFloat, rowHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(notes) { note in
                let x = CGFloat(note.startBeat) * beatWidth
                let y = CGFloat(Self.pitchCount - 1 - note.pitch) * rowHeight
                let w = max(CGFloat(note.lengthBeats) * beatWidth, 4)
                let h = max(rowHeight - 2, 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor, lineWidth: 0.5)
                    )
                    .frame(width: w, height: h)
                    .offset(x: x, y: y + 1)
                    .help("Pitch \(note.pitch) · beat \(formatBeat(note.startBeat)) · len \(formatBeat(note.lengthBeats))")
            }
        }
    }

    // MARK: - Helpers

    private func pitchRowID(_ pitch: Int) -> String { "pitch-\(pitch)" }

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
}
