import Foundation
import AVFoundation
import VerseModel

/// The audio engine — the single source of truth for sound (Build Contract §4, §11).
///
/// Wraps an `AVAudioEngine` node graph. Each track owns an `AVAudioMixerNode` (per-track
/// volume/pan) summing into `mainMixerNode → outputNode`:
///   • instrument tracks: `AVAudioUnitSampler → [effect] → trackMixer`
///   • audio tracks:      `AVAudioPlayerNode  → [effect] → trackMixer`
/// No custom realtime DSP and no Swift↔C++ interop. Control methods run on the main thread;
/// the realtime render thread is owned by Apple's nodes (we never write a render callback).
public final class VerseAudioEngine {

    public let avEngine = AVAudioEngine()
    public internal(set) var isRunning = false

    struct TrackNodes {
        var sampler: AVAudioUnitSampler?     // instrument tracks
        var player: AVAudioPlayerNode?       // audio tracks
        var effect: AVAudioUnit?             // optional inserted effect (built-in or hosted)
        let mixer: AVAudioMixerNode
        var source: AVAudioNode { sampler ?? player ?? mixer }
    }
    var trackNodes: [UUID: TrackNodes] = [:]

    // Recording / metering / monitoring / audition state (used by the +Recording extension).
    let recorder = TakeRecorder()
    public let masterMeter = LevelMeter()
    var meters: [UUID: LevelMeter] = [:]
    var masterMeterInstalled = false
    var monitorMixer: AVAudioMixerNode?
    var auditionPlayer: AVAudioPlayerNode?
    /// Format used when the audition player was last connected. Reconnect when a new file
    /// has a different `processingFormat` (sample-rate / channel change), or `scheduleFile`
    /// raises an uncatchable AVAudioEngine exception.
    var auditionFormat: AVAudioFormat?
    /// Set when a background `inputNode` bind timed out while still inside CoreAudio.
    /// That stuck thread holds the engine lock, so further `avEngine` calls (including
    /// `stop`) would deadlock. Skip locking engine ops and let the process drop the instance.
    var inputNodeBindAbandoned = false

    public init() {}

    // MARK: - Lifecycle

    /// Build the graph for a project (instrument + audio tracks) without starting playback.
    public func configure(with project: Project) {
        for track in project.tracks {
            switch track.kind {
            case .instrument: addInstrumentTrack(id: track.id, instrument: track.instrument)
            case .audio:      addAudioTrack(id: track.id)
            }
            applyMix(track)
        }
        setMasterVolume(project.masterVolume)
    }

    public func start() throws {
        guard !isRunning else { return }
        // A prior timed-out input bind may still hold the engine lock; do not re-enter.
        guard !inputNodeBindAbandoned else {
            throw RecordingError.inputBindTimedOut
        }
        avEngine.prepare()
        try avEngine.start()
        isRunning = true
        installMeterTaps()   // node formats are valid once running
    }

    public func stop() {
        guard isRunning else { return }
        // If an input-node bind was abandoned mid-flight, a stuck CoreAudio thread still
        // holds the AVAudioEngine lock. Calling stop would hang the main actor forever.
        if !inputNodeBindAbandoned {
            avEngine.stop()
        }
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
        avEngine.connect(sampler, to: mixer, format: nil)
        avEngine.connect(mixer, to: avEngine.mainMixerNode, format: nil)
        trackNodes[id] = TrackNodes(sampler: sampler, player: nil, effect: nil, mixer: mixer)
        loadInstrument(id: id, instrument: instrument ?? .grandPiano)
        if isRunning { installMeterTaps() }
        return true
    }

    @discardableResult
    public func addAudioTrack(id: UUID) -> Bool {
        guard trackNodes[id] == nil else { return false }
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        avEngine.attach(player)
        avEngine.attach(mixer)
        avEngine.connect(player, to: mixer, format: nil)
        avEngine.connect(mixer, to: avEngine.mainMixerNode, format: nil)
        trackNodes[id] = TrackNodes(sampler: nil, player: player, effect: nil, mixer: mixer)
        if isRunning { installMeterTaps() }
        return true
    }

    public func playerNode(for trackID: UUID) -> AVAudioPlayerNode? { trackNodes[trackID]?.player }
    public var allTrackIDs: [UUID] { Array(trackNodes.keys) }

    /// Tear down all track nodes (e.g. before loading a different project).
    public func reset() {
        allNotesOff()
        for id in Array(trackNodes.keys) { removeTrack(id: id) }
        meters.removeAll()
        // Master mixer is not detached, but the tap must still come off before a later
        // installMeterTaps re-install (and so reconfigure never leaves a stale tap claim).
        if masterMeterInstalled {
            avEngine.mainMixerNode.removeTap(onBus: 0)
            masterMeterInstalled = false
        }
    }

    /// Rebuild the graph for a different project, preserving the running engine.
    public func reconfigure(with project: Project) {
        reset()
        configure(with: project)
        if isRunning { installMeterTaps() }
    }

    public func removeTrack(id: UUID) {
        guard let nodes = trackNodes[id] else { return }
        nodes.player?.stop()
        // removeTap before detach. Leaving a tap on a detached node crashes on reconfigure.
        if meters[id] != nil {
            nodes.mixer.removeTap(onBus: 0)
            meters[id] = nil
        }
        if let s = nodes.sampler { avEngine.disconnectNodeOutput(s); avEngine.detach(s) }
        if let p = nodes.player { avEngine.disconnectNodeOutput(p); avEngine.detach(p) }
        if let e = nodes.effect { avEngine.disconnectNodeOutput(e); avEngine.detach(e) }
        avEngine.disconnectNodeOutput(nodes.mixer)
        avEngine.detach(nodes.mixer)
        trackNodes[id] = nil
    }

    /// Load a sound-bank instrument from the resolved SF2 (named bank if present, else the
    /// other bundled bank). Falls back silently to the sampler's built-in default voice if
    /// no SF2 is available or a preset triplet doesn't exist — so the "hear sound" path
    /// never blocks (Build Contract §9).
    public func loadInstrument(id: UUID, instrument: Instrument) {
        guard let sampler = trackNodes[id]?.sampler else { return }
        guard let url = SoundBank.resolveURL(for: instrument) else {
            return // default voice
        }
        do {
            try sampler.loadSoundBankInstrument(
                at: url,
                program: UInt8(clamping: instrument.program),
                bankMSB: UInt8(clamping: instrument.bankMSB),
                bankLSB: UInt8(clamping: instrument.bankLSB))
        } catch {
            print("[VerseEngine] SF2 load failed for program \(instrument.program): \(error). Using default voice.")
        }
    }

    // MARK: - Notes

    public func noteOn(_ pitch: Int, velocity: Int = 90, trackID: UUID) {
        trackNodes[trackID]?.sampler?.startNote(UInt8(clamping: pitch),
                                                withVelocity: UInt8(clamping: max(1, velocity)),
                                                onChannel: 0)
    }

    public func noteOff(_ pitch: Int, trackID: UUID) {
        trackNodes[trackID]?.sampler?.stopNote(UInt8(clamping: pitch), onChannel: 0)
    }

    public func allNotesOff() {
        for (_, nodes) in trackNodes {
            guard let sampler = nodes.sampler else { continue }
            for pitch in 0...127 { sampler.stopNote(UInt8(pitch), onChannel: 0) }
        }
    }

    // MARK: - Mix

    public func applyMix(_ track: Track) {
        guard let nodes = trackNodes[track.id] else { return }
        // Solo is applied as effective mute in AppStore.applyEffectiveMix, not here.
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

    public func samplerExists(for trackID: UUID) -> Bool { trackNodes[trackID]?.sampler != nil }
    public func trackExists(_ trackID: UUID) -> Bool { trackNodes[trackID] != nil }
}
