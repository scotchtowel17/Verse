import SwiftUI
import Observation
import VerseModel
import VerseEngine

/// Top-level observable application state. Owns the project model and the audio engine, and
/// is the single object the UI talks to. Runs on the main actor; the engine's realtime work
/// happens on Apple's render thread, never here.
@MainActor
@Observable
final class AppStore {
    var project: Project
    var activeTrackID: UUID
    /// MIDI pitches currently held (for on-screen key highlight).
    var heldNotes: Set<Int> = []
    var engineError: String?
    var baseOctaveC: Int = 60          // computer-keyboard 'a' = this pitch (C4 by default)

    @ObservationIgnored let engine = VerseAudioEngine()
    @ObservationIgnored private var started = false

    init() {
        let p = Project.newUntitled()
        self.project = p
        self.activeTrackID = p.tracks.first?.id ?? UUID()
    }

    var activeTrack: Track? { project.track(id: activeTrackID) }
    var sf2Bundled: Bool { SoundBank.isAvailable }
    var presets: [SoundBank.Preset] { SoundBank.presets }

    /// Build the graph and start audio. Idempotent; safe to call from `.onAppear`.
    func startEngineIfNeeded() {
        guard !started else { return }
        engine.configure(with: project)
        do { try engine.start(); started = true }
        catch { engineError = "Couldn’t start audio: \(error.localizedDescription)" }
    }

    func newProject() {
        engine.allNotesOff()
        let p = Project.newUntitled()
        project = p
        activeTrackID = p.tracks.first?.id ?? UUID()
        // Rebuild engine graph for the new project.
        for t in p.tracks where t.kind == .instrument {
            if !engine.samplerExists(for: t.id) { engine.addInstrumentTrack(id: t.id, instrument: t.instrument) }
            engine.applyMix(t)
        }
    }

    // MARK: - Playing notes

    func noteOn(_ pitch: Int) {
        guard heldNotes.insert(pitch).inserted else { return }
        engine.noteOn(pitch, velocity: 96, trackID: activeTrackID)
    }

    func noteOff(_ pitch: Int) {
        guard heldNotes.remove(pitch) != nil else { return }
        engine.noteOff(pitch, trackID: activeTrackID)
    }

    func panic() {
        engine.allNotesOff()
        heldNotes.removeAll()
    }

    // MARK: - Instrument selection

    func selectPreset(_ preset: SoundBank.Preset) {
        guard let idx = project.trackIndex(id: activeTrackID) else { return }
        let inst = Instrument(sf2: SoundBank.generalUserGS,
                              program: preset.program, bankMSB: preset.bankMSB, bankLSB: preset.bankLSB)
        project.tracks[idx].instrument = inst
        project.tracks[idx].name = preset.name
        engine.loadInstrument(id: activeTrackID, instrument: inst)
    }

    var currentPresetName: String { activeTrack?.name ?? "Instrument" }
}
