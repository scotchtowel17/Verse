import Foundation
import AVFoundation
import VerseModel

/// Drives playback of a whole arrangement (Build Contract §3 transport, §4.2).
///
/// AVAudioSequencer has no end-of-playback callback and can't re-route a live sequence, so
/// Verse schedules playback itself: audio clips are scheduled sample-accurately on each audio
/// track's player; MIDI clip notes are scheduled on a serial queue against a shared anchor;
/// end-of-arrangement is computed and fired by a timer. An optional metronome clicks the beat.
@MainActor
public final class Transport {
    public enum State: Sendable { case stopped, playing }
    public private(set) var state: State = .stopped

    private let engine: VerseAudioEngine
    private var midiWork: [DispatchWorkItem] = []
    private var autoStop: DispatchWorkItem?
    private var loopTimer: Timer?
    private let metronome: Metronome

    /// Wall-clock start of the current play call (before the scheduling lead).
    private var playWallStart: Date?
    private var playStartBeat: Double = 0
    private var playBPM: Double = 120
    private var playLead: Double = 0.12

    public var onStop: (() -> Void)?
    public var metronomeEnabled = false

    public init(engine: VerseAudioEngine) {
        self.engine = engine
        self.metronome = Metronome(engine: engine)
    }

    /// Arrangement beat under the playhead while playing; `nil` when stopped.
    ///
    /// Cheap: derived from wall clock, start beat, BPM, and the same lead used for scheduling.
    /// Musical t=0 is `playWallStart + lead` (when the first scheduled events fire).
    public var currentBeat: Double? {
        guard state == .playing, let start = playWallStart else { return nil }
        let elapsed = Date().timeIntervalSince(start) - playLead
        if elapsed < 0 { return playStartBeat }
        return playStartBeat + elapsed * (playBPM / 60.0)
    }

    /// Begin playback from `startBeat`. `mediaDir` resolves audio clip filenames.
    public func play(project: Project, mediaDir: URL, from startBeat: Double = 0,
                     loop: ClosedRange<Double>? = nil) {
        stop()
        let bpm = project.tempoBPM ?? 120
        let spb = 60.0 / bpm
        let lead = 0.12   // small scheduling lead so all sources start together
        let wallStart = Date()
        playWallStart = wallStart
        playStartBeat = startBeat
        playBPM = bpm
        playLead = lead
        let anchorHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        let midiAnchor = DispatchTime.now() + lead
        var endSeconds = 0.0

        for track in project.tracks {
            // Audio clips → sample-accurate scheduled files on the track's player.
            if let player = engine.playerNode(for: track.id) {
                player.stop()
                for clip in track.clips where clip.kind == .audio {
                    guard let name = clip.mediaFile else { continue }
                    let url = mediaDir.appendingPathComponent(name)
                    guard let file = try? AVAudioFile(forReading: url) else { continue }
                    let clipStart = max(0, (clip.startBeat - startBeat)) * spb
                    let when = AVAudioTime(hostTime: anchorHost + AVAudioTime.hostTime(forSeconds: clipStart))
                    player.scheduleFile(file, at: when)
                    let dur = file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0
                    endSeconds = max(endSeconds, clipStart + dur)
                }
                player.play()
            }
            // MIDI clips → scheduled note on/off.
            for clip in track.clips where clip.kind == .midi {
                for note in clip.midiNotes ?? [] {
                    let onSec = (clip.startBeat + note.startBeat - startBeat) * spb
                    guard onSec >= 0 else { continue }
                    let offSec = onSec + note.lengthBeats * spb
                    let tid = track.id
                    // Schedule on MAIN so all engine/trackNodes access stays single-threaded
                    // (no race with main-thread setEffect/removeTrack/addTrack). Note events are
                    // cheap startNote/stopNote calls.
                    let on = DispatchWorkItem {
                        MainActor.assumeIsolated { self.engine.noteOn(note.pitch, velocity: note.velocity, trackID: tid) }
                    }
                    let off = DispatchWorkItem {
                        MainActor.assumeIsolated { self.engine.noteOff(note.pitch, trackID: tid) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: midiAnchor + onSec, execute: on)
                    DispatchQueue.main.asyncAfter(deadline: midiAnchor + offSec, execute: off)
                    midiWork.append(on); midiWork.append(off)
                    endSeconds = max(endSeconds, offSec)
                }
            }
        }

        state = .playing
        if metronomeEnabled { metronome.start(bpm: bpm, lead: lead) }

        if let loop {
            let loopLen = max(0.1, (loop.upperBound - loop.lowerBound) * spb)
            loopTimer = Timer.scheduledTimer(withTimeInterval: lead + loopLen, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.play(project: project, mediaDir: mediaDir,
                                                       from: loop.lowerBound, loop: loop) }
            }
        } else {
            let total = lead + endSeconds + 0.8   // tail for reverb/decay
            let stopItem = DispatchWorkItem { [weak self] in self?.finish() }
            autoStop = stopItem
            DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: stopItem)
        }
    }

    public func stop() {
        midiWork.forEach { $0.cancel() }
        midiWork.removeAll()
        autoStop?.cancel(); autoStop = nil
        loopTimer?.invalidate(); loopTimer = nil
        metronome.stop()
        engine.allNotesOff()
        for id in engine.allTrackIDs { engine.playerNode(for: id)?.stop() }
        playWallStart = nil
        state = .stopped
    }

    private func finish() {
        stop()
        onStop?()
    }
}
