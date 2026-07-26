import SwiftUI
import VerseModel

/// Which timeline surface owns selection-based actions (mirrors Cmd-C/V focus routing).
public enum EditSurface: String, Equatable, Sendable {
    case arrangement
    case pianoRoll
}

/// Pure enablement + tooltip text for the action bar. Free of SwiftUI so VerseCheck can cover it.
public enum ActionBarLogic {
    public static func undoHelp(canUndo: Bool, name: String?) -> (enabled: Bool, help: String) {
        if canUndo {
            if let name, !name.isEmpty {
                return (true, "Undo \(name)")
            }
            return (true, "Undo")
        }
        return (false, "Nothing to undo")
    }

    public static func redoHelp(canRedo: Bool, name: String?) -> (enabled: Bool, help: String) {
        if canRedo {
            if let name, !name.isEmpty {
                return (true, "Redo \(name)")
            }
            return (true, "Redo")
        }
        return (false, "Nothing to redo")
    }

    /// Split: one selected MIDI clip with the playhead strictly inside it.
    public static func splitHelp(
        selectedClipIDs: Set<UUID>,
        project: Project,
        playheadBeat: Double
    ) -> (enabled: Bool, help: String) {
        guard !selectedClipIDs.isEmpty else {
            return (false, "Select one clip to split")
        }
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else {
            return (false, "Select one clip to split")
        }
        guard let loc = project.clipLocation(id: id) else {
            return (false, "Select one clip to split")
        }
        let clip = project.tracks[loc.trackIndex].clips[loc.clipIndex]
        if clip.kind != .midi {
            return (false, "Audio clips can’t be split yet")
        }
        let local = playheadBeat - clip.startBeat
        guard local > 0, local < clip.lengthBeats else {
            return (false, "Move the playhead inside the clip to split")
        }
        return (true, "Split at playhead (⌘E)")
    }

    /// Duplicate: one or more selected arrangement clips.
    public static func duplicateHelp(selectedClipIDs: Set<UUID>) -> (enabled: Bool, help: String) {
        if selectedClipIDs.isEmpty {
            return (false, "Select a clip to duplicate")
        }
        let n = selectedClipIDs.count
        return (true, n == 1 ? "Duplicate clip" : "Duplicate \(n) clips")
    }

    /// Delete: notes when the roll is focused, clips when the arrangement is focused.
    public static func deleteHelp(
        surface: EditSurface,
        selectedClipIDs: Set<UUID>,
        selectedNoteIDs: Set<UUID>
    ) -> (enabled: Bool, help: String) {
        switch surface {
        case .pianoRoll:
            if selectedNoteIDs.isEmpty {
                return (false, "Select notes to delete")
            }
            let n = selectedNoteIDs.count
            return (true, n == 1 ? "Delete note" : "Delete \(n) notes")
        case .arrangement:
            if selectedClipIDs.isEmpty {
                return (false, "Select a clip to delete")
            }
            let n = selectedClipIDs.count
            return (true, n == 1 ? "Delete clip" : "Delete \(n) clips")
        }
    }

    /// Quantize: needs a MIDI clip with notes and snap on (1 / 0.5 / 0.25).
    public static func quantizeHelp(
        snapBeats: Double,
        openClip: Clip?,
        isAudioTrack: Bool,
        selectedNoteIDs: Set<UUID>
    ) -> (enabled: Bool, help: String) {
        if isAudioTrack {
            return (false, "Audio tracks don’t have notes to quantize")
        }
        guard let clip = openClip, clip.kind == .midi else {
            return (false, "Open a MIDI clip to quantize notes")
        }
        let notes = clip.midiNotes ?? []
        guard !notes.isEmpty else {
            return (false, "No notes to quantize")
        }
        guard snapBeats > 0 else {
            return (false, "Turn on snap (1/4, 1/8, or 1/16) to quantize")
        }
        let allowed: Set<Double> = [1.0, 0.5, 0.25]
        guard allowed.contains(snapBeats) else {
            return (false, "Turn on snap (1/4, 1/8, or 1/16) to quantize")
        }
        if selectedNoteIDs.isEmpty {
            return (true, "Quantize all notes in clip to snap")
        }
        let n = selectedNoteIDs.count
        return (true, n == 1 ? "Quantize selected note to snap" : "Quantize \(n) selected notes to snap")
    }

    public static func zoomInHelp(zoom: Double) -> (enabled: Bool, help: String) {
        if zoom >= BeatTimeline.maxZoom - 1e-12 {
            return (false, "Already zoomed in all the way")
        }
        return (true, "Zoom in")
    }

    public static func zoomOutHelp(zoom: Double) -> (enabled: Bool, help: String) {
        if zoom <= BeatTimeline.minZoom + 1e-12 {
            return (false, "Already zoomed out all the way")
        }
        return (true, "Zoom out")
    }

    public static func zoomFitHelp(contentBeats: Double) -> (enabled: Bool, help: String) {
        if contentBeats <= 0 {
            return (false, "Nothing to fit")
        }
        return (true, "Fit timeline to content")
    }
}

/// Compact icon-led action bar: undo/redo, split, duplicate, delete, quantize, and timeline zoom.
/// Disabled buttons keep an explanatory tooltip (V4: never silent no-ops).
struct ActionBar: View {
    @Environment(AppStore.self) private var store
    /// Viewport width available for the shared timeline (gutter already subtracted). Fit uses this.
    var fitAvailableWidth: CGFloat = 600

    private var openMIDIClip: Clip? {
        guard let id = store.effectivePianoRollClipID,
              let loc = store.project.clipLocation(id: id) else { return nil }
        let c = store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
        return c.kind == .midi ? c : nil
    }

    private var contentBeats: Double {
        BeatTimeline.contentBeats(
            tracks: store.project.tracks,
            beatsPerBar: max(1, store.project.timeSignature.num),
            openClip: openMIDIClip
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            editGroup
            Divider().frame(height: 18)
            zoomGroup
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Edit actions

    private var editGroup: some View {
        HStack(spacing: 2) {
            actionButton(
                systemImage: "arrow.uturn.backward",
                state: ActionBarLogic.undoHelp(canUndo: store.canUndo, name: store.undoName)
            ) {
                store.undo()
            }
            actionButton(
                systemImage: "arrow.uturn.forward",
                state: ActionBarLogic.redoHelp(canRedo: store.canRedo, name: store.redoName)
            ) {
                store.redo()
            }

            Divider().frame(height: 18).padding(.horizontal, 2)

            actionButton(
                systemImage: "scissors",
                state: ActionBarLogic.splitHelp(
                    selectedClipIDs: store.selectedClipIDs,
                    project: store.project,
                    playheadBeat: store.playbackBeat ?? store.playheadBeat
                )
            ) {
                performSplit()
            }
            actionButton(
                systemImage: "plus.square.on.square",
                state: ActionBarLogic.duplicateHelp(selectedClipIDs: store.selectedClipIDs)
            ) {
                performDuplicate()
            }
            actionButton(
                systemImage: "trash",
                state: ActionBarLogic.deleteHelp(
                    surface: store.editSurface,
                    selectedClipIDs: store.selectedClipIDs,
                    selectedNoteIDs: store.selectedNoteIDs
                )
            ) {
                performDelete()
            }
            actionButton(
                systemImage: "music.note.list",
                state: ActionBarLogic.quantizeHelp(
                    snapBeats: store.pianoRollSnapBeats,
                    openClip: openMIDIClip,
                    isAudioTrack: store.pianoRollIsAudioTrack,
                    selectedNoteIDs: store.selectedNoteIDs
                )
            ) {
                store.pianoRollQuantizeNotes()
            }
        }
    }

    // MARK: - Zoom

    private var zoomGroup: some View {
        HStack(spacing: 2) {
            actionButton(
                systemImage: "minus.magnifyingglass",
                state: ActionBarLogic.zoomOutHelp(zoom: store.timelineZoom)
            ) {
                store.zoomTimelineOut()
            }
            actionButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                state: ActionBarLogic.zoomFitHelp(contentBeats: contentBeats)
            ) {
                store.zoomTimelineToFit(
                    contentBeats: contentBeats,
                    availableWidth: max(1, fitAvailableWidth)
                )
            }
            actionButton(
                systemImage: "plus.magnifyingglass",
                state: ActionBarLogic.zoomInHelp(zoom: store.timelineZoom)
            ) {
                store.zoomTimelineIn()
            }
            Text(zoomLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
                .help("Timeline zoom (shared by arrangement and piano roll)")
        }
    }

    private var zoomLabel: String {
        let pct = Int((store.timelineZoom * 100).rounded())
        return "\(pct)%"
    }

    // MARK: - Button helper

    private func actionButton(
        systemImage: String,
        state: (enabled: Bool, help: String),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!state.enabled)
        .help(state.help)
    }

    // MARK: - Performers (selection comes from store, focus-routed)

    private func performSplit() {
        let state = ActionBarLogic.splitHelp(
            selectedClipIDs: store.selectedClipIDs,
            project: store.project,
            playheadBeat: store.playbackBeat ?? store.playheadBeat
        )
        guard state.enabled, let id = store.selectedClipIDs.first else { return }
        let playhead = store.playbackBeat ?? store.playheadBeat
        if let pair = store.arrangementSplitClip(id: id, atArrangementBeat: playhead) {
            store.selectedClipIDs = [pair.left, pair.right]
        }
    }

    private func performDuplicate() {
        guard !store.selectedClipIDs.isEmpty else { return }
        let ids = Array(store.selectedClipIDs)
        let newIDs = store.arrangementDuplicateClips(ids: ids)
        if !newIDs.isEmpty {
            store.selectedClipIDs = Set(newIDs)
        }
    }

    private func performDelete() {
        switch store.editSurface {
        case .pianoRoll:
            guard !store.selectedNoteIDs.isEmpty else { return }
            let ids = Array(store.selectedNoteIDs)
            store.pianoRollDeleteNotes(ids: ids)
            store.selectedNoteIDs = []
        case .arrangement:
            guard !store.selectedClipIDs.isEmpty else { return }
            let ids = Array(store.selectedClipIDs)
            store.arrangementDeleteClips(ids: ids)
            store.selectedClipIDs = []
        }
    }
}
