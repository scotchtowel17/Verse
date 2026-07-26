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
        guard let id = store.effectivePianoRollClipID,
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

    /// Shared zoom: arrangement and roll must use the same scale (Step X2).
    private var zoom: Double { store.timelineZoom }

    private var beatW: CGFloat { BeatTimeline.beatWidth(zoom: zoom) }

    private var totalWidth: CGFloat {
        BeatTimeline.width(forBeats: contentBeats, zoom: zoom)
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
                Text("Select · drag to move · right edge to resize · click MIDI for piano roll")
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
            if store.pianoRollIsAudioTrack {
                Text(store.project.track(id: store.rollTrackID)?.name ?? "Audio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Audio tracks don’t have notes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if let clip = openClip {
                Text(store.project.track(id: store.rollTrackID)?.name ?? "Track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(clip.name.isEmpty ? "MIDI clip" : clip.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(store.project.track(id: store.rollTrackID)?.name ?? "Track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Double-click to add a note")
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
        let beatW = self.beatW
        let zoom = self.zoom
        let gutter = BeatTimeline.gutterWidth
        let rulerH = BeatTimeline.rulerHeight
        let totalW = totalWidth
        let dividerH: CGFloat = rollExpanded ? 8 : 0

        return GeometryReader { geo in
            // Fit preferred band heights to the real viewport so the roll is not laid out
            // taller than the pane and then clipped (X3: range label vs visible rows).
            let fitted = PianoRollLayout.fitBandHeights(
                availableHeight: geo.size.height,
                rulerHeight: rulerH,
                dividerHeight: dividerH,
                rollExpanded: rollExpanded,
                preferredArrangement: arrangementBandHeight,
                preferredRoll: rollBandHeight,
                minArrangement: Self.arrangementMinHeight,
                minRoll: Self.rollMinHeight
            )
            let arrH = fitted.arrangement
            let rollH = fitted.roll
            let stackH = rulerH + arrH + dividerH + rollH

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
                                    snapBeats: arrangementSnapBeats,
                                    zoom: zoom
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
                                showsGutter: true,
                                zoom: zoom
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
        let beat = max(0, min(contentBeats, BeatTimeline.beat(atX: x, zoom: zoom)))
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
                HStack(spacing: 0) {
                    // Thin identity accent on the lane header.
                    Rectangle()
                        .fill(TrackIdentityColor.solid(for: track.colorIndex))
                        .frame(width: 4)
                    Text(track.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                .frame(width: BeatTimeline.gutterWidth, height: laneH, alignment: .leading)
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
/// Selection lives on `AppStore` so the action bar can target it. Clipboard stays view-local.
/// Cmd-C/X/V when keyboard-focused (the piano roll owns those shortcuts when *it* is focused).
struct ArrangementLanesView: View {
    @Environment(AppStore.self) private var store

    let contentBeats: Double
    let totalWidth: CGFloat
    let snapBeats: Double
    /// Shared timeline zoom (must match piano roll).
    let zoom: Double

    /// View-local clipboard for Cmd-C / Cmd-X / Cmd-V.
    @State private var clipClipboard: [ClipboardClip] = []
    @FocusState private var isFocused: Bool

    @State private var session = GestureSession()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeLive = false

    static let laneHeight: CGFloat = 44
    private static let clickSlop: CGFloat = 4

    private var beatsPerBar: Int {
        max(1, store.project.timeSignature.num)
    }

    private var trackCount: Int { store.project.tracks.count }

    /// Flat list of every clip with its track index (for marquee / group ops).
    private var allClips: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int, clip: Clip)] {
        var result: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int, clip: Clip)] = []
        for (ti, track) in store.project.tracks.enumerated() {
            for clip in track.clips {
                result.append((id: clip.id, startBeat: clip.startBeat,
                               lengthBeats: clip.lengthBeats, trackIndex: ti, clip: clip))
            }
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.project.tracks.enumerated()), id: \.element.id) { ti, track in
                    lane(track: track, trackIndex: ti)
                }
            }
            marqueeOverlay()
        }
        .frame(width: totalWidth, alignment: .topLeading)
        .coordinateSpace(name: "arrangementGrid")
        // Empty-lane marquee / clear-selection behind clips (clips own their own gestures).
        .contentShape(Rectangle())
        .gesture(emptyBackgroundGesture())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // Focus ring: arrangement owns Cmd-C/X/V only when this surface is focused.
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.85 : 0), lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false)
        )
        .onChange(of: isFocused) { _, focused in
            if focused { store.editSurface = .arrangement }
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
        // Cmd-E: split the single selected MIDI clip at the playhead (arrangement focus only).
        .onKeyPress(keys: [KeyEquivalent("e")], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            splitSelectionAtPlayhead()
            return .handled
        }
        .onDisappear {
            if session.continuousGestureLive {
                store.endArrangementGesture()
                session.continuousGestureLive = false
            }
        }
        // Drop selection entries that no longer exist (undo, delete, track remove).
        .onChange(of: store.project.tracks) { _, _ in
            let live = Set(store.project.tracks.flatMap(\.clips).map(\.id))
            store.selectedClipIDs = store.selectedClipIDs.intersection(live)
        }
    }

    private func lane(track: Track, trackIndex: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let beatCount = Int(ceil(contentBeats))
                let bw = BeatTimeline.beatWidth(zoom: zoom)
                for b in 0...beatCount {
                    let x = CGFloat(b) * bw
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
                clipBlock(clip, trackIndex: trackIndex)
            }
        }
        .frame(width: totalWidth, height: Self.laneHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func clipBlock(_ clip: Clip, trackIndex: Int) -> some View {
        let x = BeatTimeline.x(forBeat: clip.startBeat, zoom: zoom)
        let w = max(BeatTimeline.width(forBeats: clip.lengthBeats, zoom: zoom), 6)
        let h = Self.laneHeight - 8
        let handleW = ArrangementLayout.resizeHandleWidth(clipWidth: w)
        let colorIndex = store.project.tracks.indices.contains(trackIndex)
            ? store.project.tracks[trackIndex].colorIndex : 0
        let identity = TrackIdentityColor.swatch(for: colorIndex)
        // Identity fill (soft), not kind-based accent/orange. Selection stays a border.
        let fill = identity.fill
        let label = clip.name.isEmpty
            ? (clip.kind == .midi ? "MIDI" : "Audio")
            : clip.name
        let selected = store.selectedClipIDs.contains(clip.id)
        let openInRoll = store.effectivePianoRollClipID == clip.id && clip.kind == .midi

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .overlay(alignment: .leading) {
                    // Thin solid identity strip on the clip leading edge.
                    Rectangle()
                        .fill(identity.solid)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            selected
                                ? Color.accentColor
                                : (openInRoll
                                   ? Color.primary.opacity(0.55)
                                   : Color.primary.opacity(0.25)),
                            lineWidth: selected ? 2.0 : (openInRoll ? 1.5 : 0.5)
                        )
                )
                .overlay(alignment: .leading) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(identity.label)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.leading, 3)
                        .padding(.trailing, handleW + 2)
                }
            Rectangle()
                .fill(Color.primary.opacity(selected ? 0.35 : 0.22))
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
        .gesture(moveGesture(for: clip, trackIndex: trackIndex))
        .contextMenu {
            if clip.kind == .midi {
                Button("Split at Playhead") {
                    store.selectedClipIDs = [clip.id]
                    splitSelectionAtPlayhead()
                }
            } else {
                Button("Split at Playhead") {
                    store.statusMessage = MutationError.cannotSplitAudioClip.description
                }
                .disabled(true)
            }
        }
    }

    // MARK: - Empty background (marquee + clear selection)

    private func emptyBackgroundGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                isFocused = true
                let moved = hypot(value.translation.width, value.translation.height)
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeCurrent = value.location
                    return
                }
                marqueeCurrent = value.location
                if moved >= Self.clickSlop {
                    marqueeLive = true
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if marqueeLive {
                    applyMarqueeSelection(additive: NSEvent.modifierFlags.contains(.shift))
                } else if moved < Self.clickSlop {
                    // Pure click on empty: clear selection (does not deselect the roll clip
                    // pointer unless the open clip was only selected here).
                    if !NSEvent.modifierFlags.contains(.shift) {
                        store.selectedClipIDs = []
                    }
                }
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeLive = false
            }
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

    private func applyMarqueeSelection(additive: Bool) {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let beatA = BeatTimeline.beat(atX: start.x, zoom: zoom)
        let beatB = BeatTimeline.beat(atX: current.x, zoom: zoom)
        let trackA = trackIndex(atY: start.y)
        let trackB = trackIndex(atY: current.y)
        let hits = ArrangementSelection.clipsTouchingMarquee(
            clips: allClips.map {
                (id: $0.id, startBeat: $0.startBeat, lengthBeats: $0.lengthBeats,
                 trackIndex: $0.trackIndex)
            },
            beatA: beatA, beatB: beatB, trackA: trackA, trackB: trackB
        )
        if additive {
            store.selectedClipIDs.formUnion(hits)
        } else {
            store.selectedClipIDs = Set(hits)
        }
        // Load a single MIDI hit into the roll so the pane stays useful.
        if hits.count == 1, let only = hits.first,
           let entry = allClips.first(where: { $0.id == only }),
           entry.clip.kind == .midi {
            store.openPianoRoll(clipID: only)
        }
    }

    private func trackIndex(atY y: CGFloat) -> Int {
        guard trackCount > 0 else { return 0 }
        let raw = Int(floor(y / Self.laneHeight))
        return min(max(0, raw), trackCount - 1)
    }

    // MARK: - Move / select

    private func moveGesture(for clip: Clip, trackIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                isFocused = true
                let moved = hypot(value.translation.width, value.translation.height)
                if session.moveOrigin == nil {
                    applyClipClickSelection(clip)
                    // If shift-deselect removed the clip under the pointer, do not start a
                    // group move. Otherwise move every currently selected clip.
                    let moving: [(id: UUID, startBeat: Double, trackIndex: Int)]
                    if store.selectedClipIDs.contains(clip.id) {
                        moving = allClips
                            .filter { store.selectedClipIDs.contains($0.id) }
                            .map { (id: $0.id, startBeat: $0.startBeat, trackIndex: $0.trackIndex) }
                    } else {
                        moving = []
                    }
                    session.moveOrigin = MultiMoveOrigin(clips: moving, primaryID: clip.id)
                    return
                }
                guard moved >= Self.clickSlop else { return }
                guard let origin = session.moveOrigin, origin.primaryID == clip.id,
                      !origin.clips.isEmpty else { return }
                if !session.continuousGestureLive {
                    let name = origin.clips.count > 1 ? "Move Clips" : "Move Clip"
                    store.beginArrangementGesture(name: name)
                    session.continuousGestureLive = true
                }
                guard let primary = origin.clips.first(where: { $0.id == origin.primaryID })
                        ?? origin.clips.first else { return }
                let beatDeltaRaw = Double(value.translation.width / BeatTimeline.beatWidth(zoom: zoom))
                let snappedPrimaryStart = ArrangementLayout.snap(
                    primary.startBeat + beatDeltaRaw, to: snapBeats)
                let beatDelta = snappedPrimaryStart - primary.startBeat
                let trackDelta = Int((value.translation.height / Self.laneHeight).rounded())
                guard let proposed = ArrangementSelection.applyGroupDelta(
                    origins: origin.clips.map { (startBeat: $0.startBeat, trackIndex: $0.trackIndex) },
                    beatDelta: beatDelta,
                    trackDelta: trackDelta,
                    trackCount: trackCount
                ) else {
                    // Would go before beat 0 or off the track list: reject as a whole.
                    return
                }
                // Kind check before mutating: refuse incompatible track landings clearly.
                // Clip identity (and kind) is stable for the gesture; look up live locations.
                let trackKinds = store.project.tracks.map(\.kind)
                var kindsToCheck: [ClipKind] = []
                kindsToCheck.reserveCapacity(origin.clips.count)
                for entry in origin.clips {
                    guard let loc = store.project.clipLocation(id: entry.id) else { return }
                    kindsToCheck.append(
                        store.project.tracks[loc.trackIndex].clips[loc.clipIndex].kind)
                }
                let compatible = ArrangementSelection.placementsCompatible(
                    clipKinds: kindsToCheck,
                    trackKinds: trackKinds,
                    trackIndices: proposed.map(\.trackIndex)
                )
                if !compatible {
                    for (i, k) in kindsToCheck.enumerated() {
                        let ti = proposed[i].trackIndex
                        if !Project.trackAccepts(clipKind: k, trackKind: trackKinds[ti]) {
                            store.statusMessage = MutationError.incompatibleClipTrack(
                                clipKind: k, trackKind: trackKinds[ti]).description
                            break
                        }
                    }
                    return
                }
                let placements = zip(origin.clips, proposed).map {
                    (id: $0.0.id, startBeat: $0.1.startBeat, trackIndex: $0.1.trackIndex)
                }
                store.arrangementMoveClips(placements)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if session.continuousGestureLive {
                    store.endArrangementGesture()
                    session.continuousGestureLive = false
                } else if moved < Self.clickSlop {
                    // Pure click: selection already applied; open MIDI in the roll.
                    if clip.kind == .midi, store.selectedClipIDs.contains(clip.id) {
                        store.openPianoRoll(clipID: clip.id)
                    }
                }
                session.moveOrigin = nil
            }
    }

    /// Click a clip: select it. Shift-click toggles membership. Clicking an already-selected
    /// clip without shift keeps the whole selection (so a drag can move the group).
    private func applyClipClickSelection(_ clip: Clip) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift {
            if store.selectedClipIDs.contains(clip.id) {
                store.selectedClipIDs.remove(clip.id)
            } else {
                store.selectedClipIDs.insert(clip.id)
            }
        } else if !store.selectedClipIDs.contains(clip.id) {
            store.selectedClipIDs = [clip.id]
        }
    }

    private func resizeGesture(for clip: Clip) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("arrangementGrid"))
            .onChanged { value in
                isFocused = true
                if session.resizeOrigin == nil {
                    session.resizeOrigin = ResizeOrigin(clipID: clip.id, lengthBeats: clip.lengthBeats)
                    if !store.selectedClipIDs.contains(clip.id) {
                        store.selectedClipIDs = [clip.id]
                    }
                    return
                }
                let moved = abs(value.translation.width)
                guard moved >= Self.clickSlop else { return }
                if !session.continuousGestureLive {
                    store.beginArrangementGesture(name: "Resize Clip")
                    session.continuousGestureLive = true
                }
                guard let origin = session.resizeOrigin, origin.clipID == clip.id else { return }
                let deltaBeats = Double(value.translation.width / BeatTimeline.beatWidth(zoom: zoom))
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

    // MARK: - Clipboard actions

    /// Split the single selected clip at the playhead. Multiple selection is refused with a
    /// clear message; audio and out-of-bounds playheads surface via the store (never silent).
    private func splitSelectionAtPlayhead() {
        guard !store.selectedClipIDs.isEmpty else { return }
        guard store.selectedClipIDs.count == 1, let id = store.selectedClipIDs.first else {
            store.statusMessage = "Select one clip to split."
            return
        }
        let playhead = store.playbackBeat ?? 0
        if let pair = store.arrangementSplitClip(id: id, atArrangementBeat: playhead) {
            store.selectedClipIDs = [pair.left, pair.right]
        }
    }

    private func deleteSelection() {
        guard !store.selectedClipIDs.isEmpty else { return }
        let ids = Array(store.selectedClipIDs)
        store.arrangementDeleteClips(ids: ids)
        store.selectedClipIDs = []
    }

    private func copySelection() {
        let selected = allClips.filter { store.selectedClipIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        clipClipboard = selected.map {
            ClipboardClip(
                clip: $0.clip,
                startBeat: $0.startBeat,
                sourceTrackIndex: $0.trackIndex,
                sourceTrackID: store.project.tracks[$0.trackIndex].id
            )
        }
    }

    private func cutSelection() {
        copySelection()
        guard !store.selectedClipIDs.isEmpty else { return }
        let ids = Array(store.selectedClipIDs)
        store.arrangementDeleteClips(ids: ids, undoName: "Cut Clips")
        store.selectedClipIDs = []
    }

    private func pasteClipboard() {
        guard !clipClipboard.isEmpty else { return }
        let playhead = store.playbackBeat ?? 0
        let starts = ArrangementSelection.pasteStartBeats(
            clipboardStarts: clipClipboard.map(\.startBeat),
            playheadBeat: playhead
        )
        guard starts.count == clipClipboard.count else { return }
        guard starts.allSatisfy({ $0 >= 0 }) else {
            store.statusMessage = "Those clips can’t paste before beat 0."
            return
        }

        // Default: each clip returns to its source track. If the active (selected) track is
        // different from the first clipboard clip’s source, paste the whole set onto that
        // track (kind rules still apply).
        let preferActive: Int? = {
            guard let idx = store.project.trackIndex(id: store.activeTrackID) else { return nil }
            guard let firstSource = clipClipboard.first?.sourceTrackID else { return nil }
            return firstSource == store.activeTrackID ? nil : idx
        }()

        var specs: [(clip: Clip, startBeat: Double, trackIndex: Int)] = []
        specs.reserveCapacity(clipClipboard.count)
        for (i, item) in clipClipboard.enumerated() {
            let trackIndex: Int
            if let preferActive {
                trackIndex = preferActive
            } else if let live = store.project.trackIndex(id: item.sourceTrackID) {
                trackIndex = live
            } else if store.project.tracks.indices.contains(item.sourceTrackIndex) {
                trackIndex = item.sourceTrackIndex
            } else {
                store.statusMessage = "That track isn’t in this project."
                return
            }
            let destKind = store.project.tracks[trackIndex].kind
            guard Project.trackAccepts(clipKind: item.clip.kind, trackKind: destKind) else {
                store.statusMessage = MutationError.incompatibleClipTrack(
                    clipKind: item.clip.kind, trackKind: destKind).description
                return
            }
            specs.append((clip: item.clip, startBeat: starts[i], trackIndex: trackIndex))
        }
        let newIDs = store.arrangementPasteClips(specs)
        if !newIDs.isEmpty {
            store.selectedClipIDs = Set(newIDs)
            // Open the first MIDI paste in the roll when present.
            if let firstMIDI = newIDs.first(where: { id in
                guard let loc = store.project.clipLocation(id: id) else { return false }
                return store.project.tracks[loc.trackIndex].clips[loc.clipIndex].kind == .midi
            }) {
                store.openPianoRoll(clipID: firstMIDI)
            }
        }
    }

    private func formatBeat(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    // MARK: - Gesture bookkeeping

    private final class GestureSession {
        var moveOrigin: MultiMoveOrigin?
        var resizeOrigin: ResizeOrigin?
        var continuousGestureLive = false
    }

    private struct MultiMoveOrigin {
        let clips: [(id: UUID, startBeat: Double, trackIndex: Int)]
        let primaryID: UUID
    }

    private struct ResizeOrigin {
        let clipID: UUID
        let lengthBeats: Double
    }

    private struct ClipboardClip {
        /// Snapshot of clip content (notes, media, kind, name, length). Paste deep-copies it.
        var clip: Clip
        var startBeat: Double
        var sourceTrackIndex: Int
        var sourceTrackID: UUID
    }
}
