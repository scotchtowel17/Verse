import AppKit
import SwiftUI
import VerseModel

/// Arrangement lanes + inline piano roll sharing one beats-to-x mapping and one horizontal
/// scroll offset. One ruler, one playhead. The roll collapses to a thin bar when hidden.
struct TimelineWorkspaceView: View {
    @Environment(AppStore.self) private var store

    /// Arrangement snap (clips). Independent of the roll’s note snap.
    @State private var arrangementSnapBeats: Double = 0.25
    /// Drag-resizable band heights (viewport, not content).
    @State private var arrangementBandHeight: CGFloat = 150
    /// Default is ~2 octaves of pitch rows plus the pinned snap toolbar (T2).
    @State private var rollBandHeight: CGFloat = PianoRollLayout.defaultBandHeight
    @State private var dividerDragStart: CGFloat?

    private static let arrangementMinHeight: CGFloat = 100
    private static let rollMinHeight: CGFloat = 140
    private static let rollCollapsedBarHeight: CGFloat = 30
    private static let workspaceMinHeight: CGFloat = 180

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    private var openClip: Clip? {
        guard let id = store.pianoRollClipID,
              let loc = store.project.clipLocation(id: id) else { return nil }
        let clip = store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
        return clip.kind == .midi ? clip : nil
    }

    private var contentBeats: Double {
        BeatTimeline.contentBeats(
            tracks: store.project.tracks,
            beatsPerBar: beatsPerBar,
            openClip: openClip
        )
    }

    private var totalWidth: CGFloat {
        BeatTimeline.width(forBeats: contentBeats)
    }

    private var rollExpanded: Bool { store.showPianoRoll }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            arrangementChrome
            if rollExpanded {
                // Clip name + collapse stay outside the shared H scroll (not time-aligned).
                PianoRollChrome()
            }
            sharedTimeline
            if !rollExpanded {
                collapsedRollBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Chrome

    private var arrangementChrome: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Arrangement", systemImage: "rectangle.split.3x1")
                    .font(.headline)
                Spacer()
                let clipCount = store.project.tracks.flatMap(\.clips).count
                Text("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Snap").font(.callout).foregroundStyle(.secondary)
                Picker("Snap", selection: $arrangementSnapBeats) {
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
    }

    private var collapsedRollBar: some View {
        HStack(spacing: 8) {
            Label("Piano roll", systemImage: "rectangle.split.2x1")
                .font(.subheadline.weight(.semibold))
            if let clip = openClip {
                Text(clip.name.isEmpty ? "MIDI clip" : clip.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Click a MIDI clip or the track’s roll button to edit notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.showPianoRoll = true
            } label: {
                Label("Expand", systemImage: "chevron.up")
            }
            .controlSize(.small)
            .help("Show the piano roll under the arrangement")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: Self.rollCollapsedBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.1)))
    }

    // MARK: - Shared timeline (one H scroll, one ruler, one playhead)

    private var sharedTimeline: some View {
        let beatW = BeatTimeline.beatWidth
        let gutter = BeatTimeline.gutterWidth
        let rulerH = BeatTimeline.rulerHeight
        let totalW = totalWidth
        let arrH = arrangementBandHeight
        let rollH = rollExpanded ? rollBandHeight : 0
        let dividerH: CGFloat = rollExpanded ? 8 : 0
        let stackH = rulerH + arrH + dividerH + rollH

        return GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Ruler row: blank gutter corner + scrubbable beat ruler.
                        HStack(alignment: .top, spacing: 0) {
                            Color.clear.frame(width: gutter, height: rulerH)
                            sharedRuler(beatWidth: beatW, totalWidth: totalW)
                        }

                        // Arrangement lanes (vertical scroll independent of the roll).
                        ScrollView(.vertical, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 0) {
                                arrangementGutter
                                ArrangementLanesView(
                                    contentBeats: contentBeats,
                                    totalWidth: totalW,
                                    snapBeats: arrangementSnapBeats
                                )
                            }
                        }
                        .frame(width: gutter + totalW, height: arrH, alignment: .topLeading)

                        if rollExpanded {
                            divider
                            // Piano roll owns a bounded pitch window (no vertical ScrollView).
                            // Time still uses the shared horizontal offset from this parent.
                            PianoRollEmbeddedView(
                                contentBeats: contentBeats,
                                totalWidth: totalW,
                                showsGutter: true
                            )
                            .frame(width: gutter + totalW, height: rollH, alignment: .topLeading)
                        }
                    }

                    // Single playhead through ruler + arrangement (+ roll when open).
                    sharedPlayhead(
                        beatWidth: beatW,
                        gutter: gutter,
                        totalHeight: stackH
                    )
                }
                .frame(minWidth: max(geo.size.width, gutter + totalW),
                       minHeight: geo.size.height,
                       alignment: .topLeading)
            }
        }
        .frame(minHeight: rollExpanded
               ? Self.arrangementMinHeight + Self.rollMinHeight + BeatTimeline.rulerHeight + 8
               : Self.workspaceMinHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.12)))
        .layoutPriority(1)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 36, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dividerDragStart == nil {
                            dividerDragStart = arrangementBandHeight
                        }
                        guard let start = dividerDragStart else { return }
                        let next = start + value.translation.height
                        let maxArr = max(Self.arrangementMinHeight,
                                         arrangementBandHeight + rollBandHeight - Self.rollMinHeight)
                        arrangementBandHeight = min(max(Self.arrangementMinHeight, next), maxArr)
                        // Keep the pair’s total roughly stable so the window layout does not jump.
                        let pair = start + rollBandHeight
                        rollBandHeight = max(Self.rollMinHeight, pair - arrangementBandHeight)
                    }
                    .onEnded { _ in
                        dividerDragStart = nil
                    }
            )
            .help("Drag to resize arrangement and piano roll")
    }

    // MARK: - Ruler + playhead

    private func sharedRuler(beatWidth: CGFloat, totalWidth: CGFloat) -> some View {
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
        .frame(width: totalWidth, height: BeatTimeline.rulerHeight)
        .background(Color.black.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.15)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in scrub(atX: value.location.x) }
                .onEnded { value in scrub(atX: value.location.x) }
        )
        .help("Click or drag to move the playhead")
    }

    private func scrub(atX x: CGFloat) {
        let beat = max(0, min(contentBeats, BeatTimeline.beat(atX: x)))
        store.scrubPlayhead(to: beat)
    }

    @ViewBuilder
    private func sharedPlayhead(beatWidth: CGFloat, gutter: CGFloat, totalHeight: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isPlaying)) { _ in
            if let beat = store.playbackBeat, beat >= 0, beat <= contentBeats {
                let x = gutter + CGFloat(beat) * beatWidth
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 1.5, height: totalHeight)
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }

    private var arrangementGutter: some View {
        let laneH = ArrangementLanesView.laneHeight
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(store.project.tracks) { track in
                Text(track.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: BeatTimeline.gutterWidth, height: laneH, alignment: .leading)
                    .padding(.leading, 4)
                    .background(Color.black.opacity(0.03))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                    }
            }
        }
    }
}

// MARK: - Arrangement lanes (no own scroll or ruler; uses BeatTimeline)

/// Clip lanes only. Horizontal time comes from the parent’s shared scroll + `BeatTimeline`.
struct ArrangementLanesView: View {
    @Environment(AppStore.self) private var store

    let contentBeats: Double
    let totalWidth: CGFloat
    let snapBeats: Double

    @State private var session = GestureSession()

    static let laneHeight: CGFloat = 44
    private static let clickSlop: CGFloat = 4

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.project.tracks.enumerated()), id: \.element.id) { _, track in
                lane(track: track)
            }
        }
        .frame(width: totalWidth, alignment: .topLeading)
        .coordinateSpace(name: "arrangementGrid")
        .onDisappear {
            if session.continuousGestureLive {
                store.endArrangementGesture()
                session.continuousGestureLive = false
            }
        }
    }

    private func lane(track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let beatCount = Int(ceil(contentBeats))
                for b in 0...beatCount {
                    let x = CGFloat(b) * BeatTimeline.beatWidth
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
                clipBlock(clip)
            }
        }
        .frame(width: totalWidth, height: Self.laneHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func clipBlock(_ clip: Clip) -> some View {
        let x = BeatTimeline.x(forBeat: clip.startBeat)
        let w = max(BeatTimeline.width(forBeats: clip.lengthBeats), 6)
        let h = Self.laneHeight - 8
        let handleW = ArrangementLayout.resizeHandleWidth(clipWidth: w)
        let fill = clip.kind == .midi
            ? Color.accentColor.opacity(0.88)
            : Color.orange.opacity(0.82)
        let label = clip.name.isEmpty
            ? (clip.kind == .midi ? "MIDI" : "Audio")
            : clip.name
        let selected = store.pianoRollClipID == clip.id && clip.kind == .midi

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            selected ? Color.primary.opacity(0.55) : Color.primary.opacity(0.25),
                            lineWidth: selected ? 1.5 : 0.5
                        )
                )
                .overlay(alignment: .leading) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.trailing, handleW + 2)
                }
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
                .highPriorityGesture(resizeGesture(for: clip))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .offset(x: x, y: 4)
        .help("\(label) · beat \(formatBeat(clip.startBeat)) · len \(formatBeat(clip.lengthBeats))")
        .gesture(moveGesture(for: clip))
    }

    private func moveGesture(for clip: Clip) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if session.moveOrigin == nil {
                    session.moveOrigin = MoveOrigin(clipID: clip.id, startBeat: clip.startBeat)
                    return
                }
                guard moved >= Self.clickSlop else { return }
                if !session.continuousGestureLive {
                    store.beginArrangementGesture(name: "Move Clip")
                    session.continuousGestureLive = true
                }
                guard let origin = session.moveOrigin, origin.clipID == clip.id else { return }
                let beatDelta = Double(value.translation.width / BeatTimeline.beatWidth)
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
                    if clip.kind == .midi {
                        store.openPianoRoll(clipID: clip.id)
                    }
                }
                session.moveOrigin = nil
            }
    }

    private func resizeGesture(for clip: Clip) -> some Gesture {
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
                let deltaBeats = Double(value.translation.width / BeatTimeline.beatWidth)
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
