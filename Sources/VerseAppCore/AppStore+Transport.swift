import Foundation
import VerseModel
import VerseEngine

// MARK: - Loop region pure logic (Z3)

/// Pure helpers for the transport loop region. Free of SwiftUI so VerseCheck can cover them.
/// Loop state is transport-only: never project data, never undo.
public enum LoopRegionLogic {
    /// Minimum region length in beats (matches clip floor so a region stays usable).
    public static let minimumLengthBeats: Double = 0.125

    /// Normalize two beat positions into a valid loop range, or `nil` if too short.
    public static func normalized(start: Double, end: Double) -> ClosedRange<Double>? {
        let a = max(0, start)
        let b = max(0, end)
        let lo = min(a, b)
        let hi = max(a, b)
        guard hi - lo >= minimumLengthBeats - 1e-12 else { return nil }
        return lo...hi
    }

    /// Loop range matching a clip's arrangement bounds.
    public static func fromClip(startBeat: Double, lengthBeats: Double) -> ClosedRange<Double>? {
        normalized(start: startBeat, end: startBeat + lengthBeats)
    }

    /// Effective transport loop when the toggle is on. With no region, fall back to the
    /// whole-arrangement range used before Z3 (`0...max(4, arrangementEnd)`).
    public static func playbackLoop(
        loopOn: Bool,
        region: ClosedRange<Double>?,
        arrangementEnd: Double
    ) -> ClosedRange<Double>? {
        guard loopOn else { return nil }
        if let region { return region }
        return 0...max(4, arrangementEnd)
    }

    /// Where play should begin. With a loop range: resume inside it, otherwise jump to the
    /// loop start. With no loop: hold the playhead (legacy).
    public static func playbackStart(playhead: Double, loop: ClosedRange<Double>?) -> Double {
        let p = max(0, playhead)
        guard let loop else { return p }
        if p >= loop.lowerBound && p < loop.upperBound { return p }
        return loop.lowerBound
    }

    /// Move a region by `delta` beats, clamping start to ≥ 0 and preserving length.
    public static func moved(_ region: ClosedRange<Double>, by delta: Double) -> ClosedRange<Double> {
        let len = region.upperBound - region.lowerBound
        let lo = max(0, region.lowerBound + delta)
        return lo...(lo + len)
    }

    /// Resize by dragging one edge to `edgeBeat`, keeping the other edge fixed.
    public static func resized(
        _ region: ClosedRange<Double>,
        edge: LoopRegionEdge,
        to edgeBeat: Double
    ) -> ClosedRange<Double>? {
        switch edge {
        case .start:
            return normalized(start: edgeBeat, end: region.upperBound)
        case .end:
            return normalized(start: region.lowerBound, end: edgeBeat)
        }
    }

    /// Format a loop-region beat for status, help, and accessibility labels.
    /// Whole numbers render as integers; fractional values keep two decimals.
    public static func formatLoopBeat(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }
}

public enum LoopRegionEdge: Equatable, Sendable {
    case start
    case end
}

// MARK: - Transport, tracks, mix, effects

extension AppStore {
    // MARK: Transport (M4 / S1 / Z3)

    // Transport actions never record undo: moving the playhead is not an edit.
    // Loop region mutations are also transport-only and never record undo (Z3).

    public func togglePlay() {
        // Copilot preview sheet does not disable menu/keyboard shortcuts on its own.
        guard !copilotPreviewBlocksTransport else {
            statusMessage = "Finish or cancel the Claude preview before playing."
            return
        }
        isPlaying ? pausePlayback() : startPlayback()
    }

    /// Start or resume playback from the held playhead position (`playheadBeat`).
    /// When loop is on, uses the loop region if set; otherwise the whole arrangement.
    public func startPlayback() {
        guard !copilotPreviewBlocksTransport else {
            statusMessage = "Finish or cancel the Claude preview before playing."
            return
        }
        transport.metronomeEnabled = metronomeOn
        let end = arrangementBeats
        let loop = LoopRegionLogic.playbackLoop(
            loopOn: loopOn,
            region: loopRegion,
            arrangementEnd: end
        )
        let from = LoopRegionLogic.playbackStart(playhead: playheadBeat, loop: loop)
        transport.play(project: project, mediaDir: workingMediaDir, from: from, loop: loop)
        isPlaying = true
    }

    /// Set or clear the loop region (beats). No undo. Invalid (too short / inverted) clears.
    public func setLoopRegion(_ range: ClosedRange<Double>?) {
        if let range {
            loopRegion = LoopRegionLogic.normalized(start: range.lowerBound, end: range.upperBound)
        } else {
            loopRegion = nil
        }
    }

    /// Set the loop region from two beat positions (order-independent). No undo.
    public func setLoopRegion(start: Double, end: Double) {
        loopRegion = LoopRegionLogic.normalized(start: start, end: end)
    }

    /// Clear the loop region so looping falls back to the whole arrangement. No undo.
    public func clearLoopRegion() {
        loopRegion = nil
    }

    /// One-action set: loop region matches the single selected arrangement clip.
    /// No undo. Refuses empty or multi-selection with a clear status message.
    public func setLoopRegionFromSelectedClip() {
        guard !selectedClipIDs.isEmpty else {
            statusMessage = "Select a clip to set the loop region."
            return
        }
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else {
            statusMessage = "Select one clip to set the loop region."
            return
        }
        guard let loc = project.clipLocation(id: id) else {
            statusMessage = "That clip isn’t in this project."
            return
        }
        let clip = project.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard let range = LoopRegionLogic.fromClip(
            startBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats
        ) else {
            statusMessage = "That clip is too short to loop."
            return
        }
        loopRegion = range
        // Confirm the set in the header so a successful click is never a silent no-op (Z4).
        let lo = LoopRegionLogic.formatLoopBeat(range.lowerBound)
        let hi = LoopRegionLogic.formatLoopBeat(range.upperBound)
        statusMessage = "Loop region set to beats \(lo)-\(hi)."
    }

    /// Pause: stop audio but hold the current playhead so the next play resumes from there.
    /// Distinct from rewind (which returns to beat 0). Does not record undo.
    public func pausePlayback() {
        // Close still-held MIDI capture notes at the last playhead beat (M3). The take
        // stays pending until recording stops, so a second play pass can add more notes.
        endOpenMIDICaptureNotesAtPlayhead()
        let wasPlaying = isPlaying
        transport.stop()
        // Transport.stop captures the live beat into stoppedAtBeat before clearing state.
        if wasPlaying {
            playheadBeat = max(0, transport.stoppedAtBeat)
        }
        isPlaying = false
    }

    /// Stop playback while holding the playhead (same as pause). Kept for existing callers.
    public func stopPlayback() {
        pausePlayback()
    }

    /// Return the playhead to arrangement beat 0. Stops playback if running. No undo.
    public func rewindToStart() {
        if isPlaying {
            endOpenMIDICaptureNotesAtPlayhead()
            transport.stop()
            isPlaying = false
        }
        playheadBeat = 0
    }

    /// Move the playhead (clamped to >= 0). Playback follows it rather than stopping. No undo.
    ///
    /// Seeking mid-playback used to stop the transport, so repositioning while listening
    /// always cost a second click to start again. Recording is the exception: a take is a
    /// continuous performance, so a seek ends it rather than silently splicing.
    public func scrubPlayhead(to beat: Double) {
        let clamped = max(0, beat)
        let wasPlaying = isPlaying
        let wasRecording = isRecording
        if isPlaying {
            endOpenMIDICaptureNotesAtPlayhead()
            transport.stop()
            isPlaying = false
        }
        playheadBeat = clamped
        if wasPlaying, !wasRecording {
            startPlayback()
        }
    }

    public var arrangementBeats: Double {
        project.tracks.flatMap { $0.clips }.map { $0.startBeat + $0.lengthBeats }.max() ?? 8
    }

    func setMetronome(_ on: Bool) { metronomeOn = on; transport.metronomeEnabled = on }
    public func setTempo(_ bpm: Double) {
        history.record(project, name: "Set Tempo")
        project.tempoBPM = max(20, min(300, bpm))
        recovery.autosave(project)
    }

    // MARK: Track management (M4)

    public func addInstrumentTrack() {
        history.record(project, name: "Add Track")
        let n = project.tracks.filter { $0.kind == .instrument }.count + 1
        let t = Track(kind: .instrument, name: "Instrument \(n)",
                      colorIndex: project.nextTrackColorIndex, instrument: .grandPiano)
        project.tracks.append(t)
        engine.addInstrumentTrack(id: t.id, instrument: t.instrument)
        engine.applyMix(t)
        activeTrackID = t.id
        bindPianoRoll(toTrack: t.id)
        recovery.autosave(project)
    }

    public func addAudioTrack() {
        history.record(project, name: "Add Track")
        let n = project.tracks.filter { $0.kind == .audio }.count + 1
        let t = Track(kind: .audio, name: "Audio \(n)", colorIndex: project.nextTrackColorIndex)
        project.tracks.append(t)
        engine.addAudioTrack(id: t.id)
        engine.applyMix(t)
        recovery.autosave(project)
    }

    /// Change a track's identity colour (one undo entry). Index is wrapped into the fixed palette.
    public func setTrackColorIndex(_ index: Int, _ id: UUID) {
        guard project.trackIndex(id: id) != nil else {
            statusMessage = "That track isn’t in this project."
            return
        }
        let normalized = TrackPalette.normalized(index)
        if project.track(id: id)?.colorIndex == normalized { return }
        history.record(project, name: "Track Colour")
        mutate(id) { $0.colorIndex = normalized }
        recovery.autosave(project)
    }

    /// Rename a track (one undo entry). Empty / whitespace-only names are refused.
    public func renameTrack(_ id: UUID, to name: String) {
        guard project.trackIndex(id: id) != nil else {
            statusMessage = "That track isn’t in this project."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "A track needs a name."
            return
        }
        if project.track(id: id)?.name == trimmed { return }
        history.record(project, name: "Rename Track")
        mutate(id) { $0.name = trimmed }
        recovery.autosave(project)
    }

    public func deleteTrack(_ id: UUID) {
        // Refuse emptying the project: the UI always shows a trash control, so this is a
        // real user ask that must not fail silently.
        guard project.tracks.count > 1 else {
            statusMessage = "A project needs at least one track."
            return
        }
        // Should be impossible: the track list only offers delete for live rows.
        guard project.trackIndex(id: id) != nil else {
            statusMessage = "That track isn’t in this project."
            return
        }
        history.record(project, name: "Delete Track")
        engine.removeTrack(id: id)
        project.tracks.removeAll { $0.id == id }
        trackEffects.removeValue(forKey: id)
        armedTrackIDs.remove(id)
        if activeTrackID == id {
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? project.tracks.first!.id
        }
        if rollTrackID == id {
            let fallback = project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? project.tracks.first!.id
            bindPianoRoll(toTrack: fallback)
        }
        recovery.autosave(project)
    }

    /// Select a track as the working track (track list / lane gutter). Updates roll binding;
    /// instrument tracks also become the keyboard/MIDI audition target.
    public func selectTrack(_ id: UUID) {
        // Roll follows any track row (instrument draws notes; audio shows a plain empty state).
        // Keyboard / MIDI audition (`activeTrackID`) stays instrument-only.
        guard project.track(id: id) != nil else { return }
        bindPianoRoll(toTrack: id)
    }

    // MARK: Mix with solo logic (M4)

    // Continuous slider drags must NOT record undo: each drag fires ~100 calls and would
    // flush the 100-entry stack, destroying the AI-patch undo point.
    // Clamp at the setter so the stored value cannot leave its documented range (volume 0...1,
    // pan -1...1). The engine mixer and the AI patch validator already clamp; these two were
    // the one path that did not, so an out-of-range call was inaudible but still persisted an
    // invalid value into the saved project.
    public func setVolume(_ v: Double, _ id: UUID) {
        mutate(id) { $0.volume = max(0, min(1, v)) }
        applyEffectiveMix()
    }
    public func setPan(_ p: Double, _ id: UUID) {
        mutate(id) { $0.pan = max(-1, min(1, p)) }
        applyEffectiveMix()
    }
    func toggleMute(_ id: UUID) { mutate(id) { $0.mute.toggle() }; applyEffectiveMix() }
    func toggleSolo(_ id: UUID) { mutate(id) { $0.solo.toggle() }; applyEffectiveMix() }

    private func mutate(_ id: UUID, _ f: (inout Track) -> Void) {
        // Should be impossible: sliders only bind to tracks still in the list. Silent so
        // continuous volume/pan gestures never spam status during a race with delete.
        if let i = project.trackIndex(id: id) { f(&project.tracks[i]) }
    }

    /// Apply volume/pan to the engine, honoring solo (any solo mutes the non-soloed).
    func applyEffectiveMix() {
        let anySolo = project.anySolo
        for t in project.tracks {
            let effMute = t.mute || (anySolo && !t.solo)
            engine.setTrackVolume(t.volume, trackID: t.id, muted: effMute)
            engine.setTrackPan(t.pan, trackID: t.id)
        }
    }

    // MARK: Effects (M4)

    /// Manufacturer tag written into `Track.inserts` for Verse built-in effects. Hosted
    /// third-party Audio Units are never stored under this manufacturer (session-only).
    public static let builtInEffectManufacturer = "verse.builtin"

    public func setEffect(_ kind: VerseAudioEngine.BuiltInEffect, _ id: UUID) {
        engine.setEffect(kind, trackID: id)
        trackEffects[id] = kind
        // Persist into the existing schema field so the choice survives save/open and
        // reconfigure (undo/redo/patch). Do not bump Schema.current.
        if let i = project.trackIndex(id: id) {
            project.tracks[i].inserts = Self.insertsReplacingBuiltIn(kind, in: project.tracks[i].inserts)
        }
    }
    public func effect(for id: UUID) -> VerseAudioEngine.BuiltInEffect { trackEffects[id] ?? .none }
    /// Built-in effect currently wired in the engine graph for `id` (may differ from the
    /// picker only if a hosted AU is inserted; hosted AUs report as `.none`).
    public func engineEffect(for id: UUID) -> VerseAudioEngine.BuiltInEffect {
        engine.currentEffect(trackID: id)
    }
    func trackLevel(_ id: UUID) -> Float { trackLevels[id] ?? 0 }

    /// Read a Verse built-in effect marker from `Track.inserts`, or `.none`.
    public static func builtInEffect(fromInserts inserts: [AudioUnitRef]) -> VerseAudioEngine.BuiltInEffect {
        for ref in inserts where ref.manufacturer == builtInEffectManufacturer {
            if let kind = VerseAudioEngine.BuiltInEffect(rawValue: ref.subtype) {
                return kind
            }
        }
        return .none
    }

    /// Replace any `verse.builtin` entries in `existing` with the chosen built-in (or none).
    /// Non-builtin refs are left alone; hosted AUs are not written here.
    public static func insertsReplacingBuiltIn(_ kind: VerseAudioEngine.BuiltInEffect,
                                               in existing: [AudioUnitRef]) -> [AudioUnitRef] {
        var next = existing.filter { $0.manufacturer != builtInEffectManufacturer }
        if kind != .none {
            next.append(AudioUnitRef(type: "aufx",
                                     subtype: kind.rawValue,
                                     manufacturer: builtInEffectManufacturer,
                                     name: kind.label))
        }
        return next
    }
}
