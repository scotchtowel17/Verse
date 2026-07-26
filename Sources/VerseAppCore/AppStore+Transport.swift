import Foundation
import VerseModel
import VerseEngine

// MARK: - Transport, tracks, mix, effects

extension AppStore {
    // MARK: Transport (M4 / S1)

    // Transport actions never record undo: moving the playhead is not an edit.

    public func togglePlay() {
        // Copilot preview sheet does not disable menu/keyboard shortcuts on its own.
        guard !copilotPreviewBlocksTransport else {
            statusMessage = "Finish or cancel the Claude preview before playing."
            return
        }
        isPlaying ? pausePlayback() : startPlayback()
    }

    /// Start or resume playback from the held playhead position (`playheadBeat`).
    public func startPlayback() {
        guard !copilotPreviewBlocksTransport else {
            statusMessage = "Finish or cancel the Claude preview before playing."
            return
        }
        transport.metronomeEnabled = metronomeOn
        let end = arrangementBeats
        let loop: ClosedRange<Double>? = loopOn ? 0...max(4, end) : nil
        let from = max(0, playheadBeat)
        transport.play(project: project, mediaDir: workingMediaDir, from: from, loop: loop)
        isPlaying = true
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

    /// Move the playhead to `beat` (clamped to ≥ 0). Stops playback if running so the
    /// next play starts from the scrubbed position. No undo.
    public func scrubPlayhead(to beat: Double) {
        let clamped = max(0, beat)
        if isPlaying {
            endOpenMIDICaptureNotesAtPlayhead()
            transport.stop()
            isPlaying = false
        }
        playheadBeat = clamped
    }

    var arrangementBeats: Double {
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
        let t = Track(kind: .instrument, name: "Instrument \(n)", instrument: .grandPiano)
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
        let t = Track(kind: .audio, name: "Audio \(n)")
        project.tracks.append(t)
        engine.addAudioTrack(id: t.id)
        engine.applyMix(t)
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

    func selectTrack(_ id: UUID) {
        // Roll follows any track row (instrument draws notes; audio shows a plain empty state).
        // Keyboard / MIDI audition (`activeTrackID`) stays instrument-only.
        guard project.track(id: id) != nil else { return }
        bindPianoRoll(toTrack: id)
    }

    // MARK: Mix with solo logic (M4)

    // Continuous slider drags must NOT record undo: each drag fires ~100 calls and would
    // flush the 100-entry stack, destroying the AI-patch undo point.
    public func setVolume(_ v: Double, _ id: UUID) { mutate(id) { $0.volume = v }; applyEffectiveMix() }
    public func setPan(_ p: Double, _ id: UUID) { mutate(id) { $0.pan = p }; applyEffectiveMix() }
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
