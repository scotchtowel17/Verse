import Foundation
import AVFoundation
import VerseModel

/// The audio engine — the single source of truth for sound (Build Contract §4, §11).
///
/// Wraps an `AVAudioEngine` node graph: each instrument track is an `AVAudioUnitSampler`
/// feeding a per-track `AVAudioMixerNode`, all summing into `mainMixerNode → outputNode`.
/// No custom realtime DSP and no Swift↔C++ interop. Control methods run on the main thread;
/// the realtime render thread is owned by Apple's nodes (we never write a render callback).
public final class VerseAudioEngine {

    public let avEngine = AVAudioEngine()
    public internal(set) var isRunning = false

    struct TrackNodes {
        let sampler: AVAudioUnitSampler
        let mixer: AVAudioMixerNode
    }
    private(set) var trackNodes: [UUID: TrackNodes] = [:]

    public init() {}

    // MARK: - Lifecycle

    /// Build the graph for a project (instrument tracks) without starting playback.
    public func configure(with project: Project) {
        for track in project.tracks where track.kind == .instrument {
            addInstrumentTrack(id: track.id, instrument: track.instrument)
            applyMix(track)
        }
        setMasterVolume(project.masterVolume)
    }

    public func start() throws {
        guard !isRunning else { return }
        avEngine.prepare()
        try avEngine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        avEngine.stop()
        isRunning = false
    }

    // MARK: - Tracks

    @discardableResult
    public func addInstrumentTrack(id: UUID, instrument: Instrument?) -> Bool {
        guard trackNodes[id] == nil else { return false }
        let sampler = AVAudioUnitSampler()
        let mixer = AVAudioMixerNode()
        avEngine.attach(sampler)
        avEngine.attach(mixer)
        // Connect with nil format so the engine adopts the source node's native format,
        // then route the per-track submix into the main mixer (Build Contract §4.3).
        avEngine.connect(sampler, to: mixer, format: nil)
        avEngine.connect(mixer, to: avEngine.mainMixerNode, format: nil)
        trackNodes[id] = TrackNodes(sampler: sampler, mixer: mixer)
        loadInstrument(id: id, instrument: instrument ?? .grandPiano)
        return true
    }

    public func removeTrack(id: UUID) {
        guard let nodes = trackNodes[id] else { return }
        avEngine.disconnectNodeOutput(nodes.sampler)
        avEngine.disconnectNodeOutput(nodes.mixer)
        avEngine.detach(nodes.sampler)
        avEngine.detach(nodes.mixer)
        trackNodes[id] = nil
    }

    /// Load a sound-bank instrument (GeneralUser GS SF2). Falls back silently to the sampler's
    /// built-in default voice if the SF2 isn't bundled or a preset triplet doesn't exist —
    /// so the "hear sound" path never blocks (Build Contract §9).
    public func loadInstrument(id: UUID, instrument: Instrument) {
        guard let nodes = trackNodes[id] else { return }
        guard instrument.sf2 == SoundBank.generalUserGS, let url = SoundBank.generalUserGSURL else {
            return // default voice
        }
        do {
            try nodes.sampler.loadSoundBankInstrument(
                at: url,
                program: UInt8(clamping: instrument.program),
                bankMSB: UInt8(clamping: instrument.bankMSB),
                bankLSB: UInt8(clamping: instrument.bankLSB))
        } catch {
            // Not realtime: console log only. Common cause is -10851 (preset triplet absent).
            print("[VerseEngine] SF2 load failed for program \(instrument.program): \(error). Using default voice.")
        }
    }

    // MARK: - Notes

    public func noteOn(_ pitch: Int, velocity: Int = 90, trackID: UUID) {
        trackNodes[trackID]?.sampler.startNote(UInt8(clamping: pitch),
                                               withVelocity: UInt8(clamping: max(1, velocity)),
                                               onChannel: 0)
    }

    public func noteOff(_ pitch: Int, trackID: UUID) {
        trackNodes[trackID]?.sampler.stopNote(UInt8(clamping: pitch), onChannel: 0)
    }

    public func allNotesOff() {
        for (_, nodes) in trackNodes {
            for pitch in 0...127 { nodes.sampler.stopNote(UInt8(pitch), onChannel: 0) }
        }
    }

    // MARK: - Mix

    public func applyMix(_ track: Track) {
        guard let nodes = trackNodes[track.id] else { return }
        nodes.mixer.outputVolume = Float(track.mute ? 0 : track.volume)
        nodes.mixer.pan = Float(max(-1, min(1, track.pan)))
    }

    public func setTrackVolume(_ volume: Double, trackID: UUID, muted: Bool = false) {
        trackNodes[trackID]?.mixer.outputVolume = Float(muted ? 0 : max(0, min(1, volume)))
    }

    public func setTrackPan(_ pan: Double, trackID: UUID) {
        trackNodes[trackID]?.mixer.pan = Float(max(-1, min(1, pan)))
    }

    public func setMasterVolume(_ volume: Double) {
        avEngine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
    }

    public func samplerExists(for trackID: UUID) -> Bool { trackNodes[trackID] != nil }
}
