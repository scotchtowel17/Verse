import Foundation
import VerseModel
import VerseEngine

// MARK: - Transport, tracks, mix, effects

extension AppStore {
    // MARK: Transport (M4)

    func togglePlay() {
        // Copilot preview sheet does not disable menu/keyboard shortcuts on its own.
        guard !copilotPreviewBlocksTransport else { return }
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        guard !copilotPreviewBlocksTransport else { return }
        transport.metronomeEnabled = metronomeOn
        let end = arrangementBeats
        let loop: ClosedRange<Double>? = loopOn ? 0...max(4, end) : nil
        transport.play(project: project, mediaDir: workingMediaDir, from: 0, loop: loop)
        isPlaying = true
    }

    func stopPlayback() { transport.stop(); isPlaying = false }

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
        guard project.tracks.count > 1 else { return }
        history.record(project, name: "Delete Track")
        engine.removeTrack(id: id)
        project.tracks.removeAll { $0.id == id }
        if activeTrackID == id {
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? project.tracks.first!.id
        }
        recovery.autosave(project)
    }

    func selectTrack(_ id: UUID) {
        if project.track(id: id)?.kind == .instrument { activeTrackID = id }
    }

    // MARK: Mix with solo logic (M4)

    // Continuous slider drags must NOT record undo: each drag fires ~100 calls and would
    // flush the 100-entry stack, destroying the AI-patch undo point.
    public func setVolume(_ v: Double, _ id: UUID) { mutate(id) { $0.volume = v }; applyEffectiveMix() }
    public func setPan(_ p: Double, _ id: UUID) { mutate(id) { $0.pan = p }; applyEffectiveMix() }
    func toggleMute(_ id: UUID) { mutate(id) { $0.mute.toggle() }; applyEffectiveMix() }
    func toggleSolo(_ id: UUID) { mutate(id) { $0.solo.toggle() }; applyEffectiveMix() }

    private func mutate(_ id: UUID, _ f: (inout Track) -> Void) {
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

    func setEffect(_ kind: VerseAudioEngine.BuiltInEffect, _ id: UUID) {
        engine.setEffect(kind, trackID: id)
        trackEffects[id] = kind
    }
    func effect(for id: UUID) -> VerseAudioEngine.BuiltInEffect { trackEffects[id] ?? .none }
    func trackLevel(_ id: UUID) -> Float { trackLevels[id] ?? 0 }
}
