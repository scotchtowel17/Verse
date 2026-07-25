import AppKit
import SwiftUI
import VerseModel

/// Arrangement timeline: one horizontal lane per track, shared beat ruler, clip blocks
/// that move and resize with one undo entry per completed gesture. MIDI clips open the
/// piano roll on a pure click.
struct ArrangementView: View {
    @Environment(AppStore.self) private var store

    /// Snap grid in beats: 0 (Off), 1 (1/4), 0.5 (1/8), 0.25 (1/16). Default 1/16.
    @State private var snapBeats: Double = 0.25
    /// Live gesture bookkeeping lives on a class so mid-gesture writes do not re-render the
    /// view hierarchy (a re-render mid-drag cancels the gesture and made pure click need two
    /// tries to open the piano roll).
    @State private var session = GestureSession()

    private static let laneHeight: CGFloat = 44
    private static let beatWidth: CGFloat = 28
    private static let gutterWidth: CGFloat = 100
    private static let rulerHeight: CGFloat = 22
    private static let clickSlop: CGFloat = 4
    private static let timelineMinHeight: CGFloat = 120

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    /// Horizontal content length in beats: at least 4 bars, any clip end, and a little pad.
    private var contentBeats: Double {
        ArrangementLayout.contentBeats(
            tracks: store.project.tracks,
            beatsPerBar: beatsPerBar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            snapBar
            timeline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            if session.continuousGestureLive {
                store.endArrangementGesture()
                session.continuousGestureLive = false
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Arrangement", systemImage: "rectangle.split.3x1")
                .font(.headline)
            Spacer()
            let clipCount = store.project.tracks.flatMap(\.clips).count
            Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var snapBar: some View {
        HStack(spacing: 10) {
            Text("Snap").font(.callout).foregroundStyle(.secondary)
            Picker("Snap", selection: $snapBeats) {
                Text("Off").tag(0.0)
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .help("Grid snap for clip start and length. Off allows free placement.")
            Spacer()
            Text("Drag to move · right edge to resize · click MIDI to open piano roll")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var timeline: some View {
        let beatW = Self.beatWidth
        let laneH = Self.laneHeight
        let totalWidth = CGFloat(contentBeats) * beatW
        let lanesHeight = CGFloat(max(1, store.project.tracks.count)) * laneH
        let contentHeight = Self.rulerHeight + lanesHeight

        // GeometryReader so the scroll content can pin top-leading when the grid is narrower
        // than the viewport (macOS ScrollView otherwise centres short content).
        return GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    // Track-name gutter (aligned under ruler padding).
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(width: Self.gutterWidth, height: Self.rulerHeight)
                        ForEach(store.project.tracks) { track in
                            Text(track.name)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: Self.gutterWidth, height: laneH, alignment: .leading)
                                .padding(.leading, 4)
                                .background(Color.black.opacity(0.03))
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                                }
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            ruler(beatWidth: beatW, totalWidth: totalWidth)
                            ForEach(Array(store.project.tracks.enumerated()), id: \.element.id) { _, track in
                                lane(track: track, beatWidth: beatW, totalWidth: totalWidth)
                            }
                        }
                        playheadLayer(beatWidth: beatW,
                                      totalHeight: contentHeight)
                    }
                    .frame(width: totalWidth,
                           height: contentHeight,
                           alignment: .topLeading)
                    .coordinateSpace(name: "arrangementGrid")
                }
                // Fill the viewport so short timelines stay left-aligned, not centred.
                .frame(minWidth: geo.size.width,
                       minHeight: geo.size.height,
                       alignment: .topLeading)
            }
        }
        .frame(minHeight: Self.timelineMinHeight, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
    }

    // MARK: - Ruler

    private func ruler(beatWidth: CGFloat, totalWidth: CGFloat) -> some View {
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
        .allowsHitTesting(false)
    }

    // MARK: - Lanes & clips

    private func lane(track: Track, beatWidth: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Grid background
            Canvas { context, size in
                let beatCount = Int(ceil(contentBeats))
                for b in 0...beatCount {
                    let x = CGFloat(b) * beatWidth
                    let isBar = b % beatsPerBar == 0
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        line,
                        with: .color(Color.black.opacity(isBar ? 0.18 : 0.06)),
                        lineWidth: isBar ? 1.0 : 0.5
                    )
                }
            }
            .frame(width: totalWidth, height: Self.laneHeight)
            .allowsHitTesting(false)

            ForEach(track.clips) { clip in
                clipBlock(clip, beatWidth: beatWidth)
            }
        }
        .frame(width: totalWidth, height: Self.laneHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func clipBlock(_ clip: Clip, beatWidth: CGFloat) -> some View {
        let x = CGFloat(clip.startBeat) * beatWidth
        let w = max(CGFloat(clip.lengthBeats) * beatWidth, 6)
        let h = Self.laneHeight - 8
        // Proportional, capped resize zone so short clips keep a move body (same lesson as
        // the piano roll: a fixed handle swallowed the whole short block).
        let handleW = ArrangementLayout.resizeHandleWidth(clipWidth: w)
        let fill = clip.kind == .midi
            ? Color.accentColor.opacity(0.88)
            : Color.orange.opacity(0.82)
        let label = clip.name.isEmpty
            ? (clip.kind == .midi ? "MIDI" : "Audio")
            : clip.name

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                )
                .overlay(alignment: .leading) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.trailing, handleW + 2)
                }
            // Right-edge resize handle (high priority so it wins over body move).
            Rectangle()
                .fill(Color.primary.opacity(0.22))
                .frame(width: handleW)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .highPriorityGesture(resizeGesture(for: clip, beatWidth: beatWidth))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .offset(x: x, y: 4)
        .help("\(label) · beat \(formatBeat(clip.startBeat)) · len \(formatBeat(clip.lengthBeats))")
        .gesture(moveGesture(for: clip, beatWidth: beatWidth))
    }

    /// Vertical playhead at the transport’s current arrangement beat.
    @ViewBuilder
    private func playheadLayer(beatWidth: CGFloat, totalHeight: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isPlaying)) { _ in
            if store.isPlaying, let beat = store.playbackBeat {
                if beat >= 0 && beat <= contentBeats {
                    let x = CGFloat(beat) * beatWidth
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

    // MARK: - Gestures

    private func moveGesture(for clip: Clip, beatWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if session.moveOrigin == nil {
                    // First update: bookkeep origin. Only begin undo once motion exceeds slop
                    // so a pure click does not leave a no-op “Move Clip” on the stack.
                    session.moveOrigin = MoveOrigin(clipID: clip.id, startBeat: clip.startBeat)
                    return
                }
                guard moved >= Self.clickSlop else { return }
                if !session.continuousGestureLive {
                    store.beginArrangementGesture(name: "Move Clip")
                    session.continuousGestureLive = true
                }
                guard let origin = session.moveOrigin, origin.clipID == clip.id else { return }
                let beatDelta = Double(value.translation.width / beatWidth)
                let rawStart = origin.startBeat + beatDelta
                let newStart = max(0, ArrangementLayout.snap(rawStart, to: snapBeats))
                store.arrangementMoveClip(id: clip.id, toStartBeat: newStart)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if session.continuousGestureLive {
                    store.endArrangementGesture()
                    session.continuousGestureLive = false
                } else if moved < Self.clickSlop {
                    // Pure click on a MIDI clip opens the piano roll.
                    if clip.kind == .midi {
                        store.openPianoRoll(clipID: clip.id)
                    }
                }
                session.moveOrigin = nil
            }
    }

    private func resizeGesture(for clip: Clip, beatWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                if session.resizeOrigin == nil {
                    session.resizeOrigin = ResizeOrigin(clipID: clip.id, lengthBeats: clip.lengthBeats)
                    return
                }
                let moved = abs(value.translation.width)
                guard moved >= Self.clickSlop else { return }
                if !session.continuousGestureLive {
                    store.beginArrangementGesture(name: "Resize Clip")
                    session.continuousGestureLive = true
                }
                guard let origin = session.resizeOrigin, origin.clipID == clip.id else { return }
                let deltaBeats = Double(value.translation.width / beatWidth)
                let raw = origin.lengthBeats + deltaBeats
                let snapped = max(Project.minimumClipLengthBeats,
                                  ArrangementLayout.snap(raw, to: snapBeats))
                store.arrangementResizeClip(
                    id: clip.id,
                    toLengthBeats: max(snapped, Project.minimumClipLengthBeats)
                )
            }
            .onEnded { _ in
                if session.continuousGestureLive {
                    store.endArrangementGesture()
                    session.continuousGestureLive = false
                }
                session.resizeOrigin = nil
            }
    }

    private func formatBeat(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    // MARK: - Gesture origin snapshots

    /// Reference-type session so gesture fields can update without invalidating the view.
    private final class GestureSession {
        var moveOrigin: MoveOrigin?
        var resizeOrigin: ResizeOrigin?
        var continuousGestureLive = false
    }

    private struct MoveOrigin {
        let clipID: UUID
        let startBeat: Double
    }

    private struct ResizeOrigin {
        let clipID: UUID
        let lengthBeats: Double
    }
}

// MARK: - Layout (testable)

/// Pure layout helpers for the arrangement timeline. Kept free of SwiftUI so VerseCheck
/// can lock the proportional resize-handle contract without rendering.
public enum ArrangementLayout {
    /// Max pixel width of the right-edge resize handle on a clip block.
    public static let resizeHandleMaxWidth: CGFloat = 10
    /// Fraction of clip width used for resize when the clip is shorter than the fixed max.
    public static let resizeHandleFraction: CGFloat = 0.3
    /// Minimum timeline length in bars when the project is empty or short.
    public static let minimumBars: Int = 4

    /// Resize hit zone for a clip of the given pixel width.
    ///
    /// Fixed-width handles cover the whole block on short clips, so every short clip became
    /// unmovable. Cap the zone at 30% of clip width so the body always moves.
    public static func resizeHandleWidth(clipWidth: CGFloat) -> CGFloat {
        guard clipWidth > 0 else { return 0 }
        return min(resizeHandleMaxWidth, clipWidth * resizeHandleFraction)
    }

    /// Round `beats` to the snap grid. `snapBeats == 0` means Off: return the value unchanged.
    public static func snap(_ beats: Double, to snapBeats: Double) -> Double {
        guard snapBeats > 0 else { return beats }
        return (beats / snapBeats).rounded() * snapBeats
    }

    /// Horizontal content length in beats: max of 4 bars, any clip end, plus one bar of pad.
    public static func contentBeats(tracks: [Track], beatsPerBar: Int) -> Double {
        let bpb = max(1, beatsPerBar)
        let fourBars = Double(bpb * minimumBars)
        let clipEnd = tracks.flatMap(\.clips)
            .map { $0.startBeat + $0.lengthBeats }
            .max() ?? 0
        // One bar of empty tail so the last clip is not flush against the edge.
        return max(fourBars, clipEnd + Double(bpb), 4)
    }
}
