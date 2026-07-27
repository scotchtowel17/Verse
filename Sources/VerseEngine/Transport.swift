import Foundation
import AVFoundation
import VerseModel

/// One MIDI note on/off pair after `lengthBeats` clipping and negative-onset filtering.
public struct PlannedMIDINote: Equatable, Sendable {
    public let pitch: Int
    public let velocity: Int
    /// Seconds after musical t=0 (playhead start, before the scheduling lead).
    public let onSeconds: Double
    public let offSeconds: Double
}

/// One audio file segment after `lengthBeats` clipping.
public struct PlannedAudioSegment: Equatable, Sendable {
    /// Seconds after musical t=0 when the segment should start.
    public let whenSeconds: Double
    public let startingFrame: AVAudioFramePosition
    public let frameCount: AVAudioFrameCount
}

/// Drives playback of a whole arrangement (Build Contract §3 transport, §4.2).
///
/// AVAudioSequencer has no end-of-playback callback and can't re-route a live sequence, so
/// Verse schedules playback itself: audio clips are scheduled sample-accurately on each audio
/// track's player; MIDI clip notes are scheduled on a serial queue against a shared anchor;
/// end-of-arrangement is computed and fired by a timer. An optional metronome clicks the beat.
///
/// `Clip.lengthBeats` is a hard boundary: MIDI notes do not sound past the clip end, and audio
/// is scheduled only for the portion of the file that falls inside the clip (`scheduleSegment`).
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
    /// Beat captured at the most recent `stop()` (manual or auto). Used by AppStore pause
    /// / auto-stop so the playhead can hold position after `currentBeat` becomes nil.
    public private(set) var stoppedAtBeat: Double = 0

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

    // MARK: - Planning (pure; used by play and by VerseCheck)

    /// Plan MIDI note on/off events for one clip, honouring `lengthBeats` as a hard end.
    ///
    /// - A note starting at or after `clipLengthBeats` is dropped.
    /// - A note that crosses the clip end is truncated so note-off fires at the clip end.
    /// - A note whose onset is before the playhead (`onSeconds < 0`) is dropped (existing rule).
    ///
    /// Loop regions are not applied here. The plan may contain events past a loop end; that is
    /// expected. The loop boundary is enforced by `play` calling `stop()` (cancel every pending
    /// MIDI work item and `allNotesOff`) then rescheduling from `loop.lowerBound` when the wrap
    /// timer fires. Do not "fix" this by clipping the plan to the loop.
    public static func planMIDINotes(
        notes: [Note],
        clipStartBeat: Double,
        clipLengthBeats: Double,
        playFromBeat: Double,
        secondsPerBeat: Double
    ) -> [PlannedMIDINote] {
        guard clipLengthBeats > 0, secondsPerBeat > 0 else { return [] }
        var planned: [PlannedMIDINote] = []
        for note in notes {
            guard note.startBeat < clipLengthBeats else { continue }
            let truncatedLen = min(note.lengthBeats, clipLengthBeats - note.startBeat)
            guard truncatedLen > 0 else { continue }
            let onSec = (clipStartBeat + note.startBeat - playFromBeat) * secondsPerBeat
            guard onSec >= 0 else { continue }
            let offSec = onSec + truncatedLen * secondsPerBeat
            planned.append(PlannedMIDINote(
                pitch: note.pitch,
                velocity: note.velocity,
                onSeconds: onSec,
                offSeconds: offSec
            ))
        }
        return planned
    }

    /// Plan the audio segment for one clip, honouring `lengthBeats` as a hard end and
    /// `mediaStartSeconds` as the offset into the media file.
    ///
    /// Uses `scheduleSegment` semantics: only the frames that fall inside the clip are played.
    /// If the file is shorter than the clip (from the media offset), playback ends early (no
    /// loop). Clips entirely before the playhead produce `nil`.
    public static func planAudioSegment(
        clipStartBeat: Double,
        clipLengthBeats: Double,
        playFromBeat: Double,
        secondsPerBeat: Double,
        fileLengthFrames: AVAudioFramePosition,
        sampleRate: Double,
        mediaStartSeconds: Double = 0
    ) -> PlannedAudioSegment? {
        guard clipLengthBeats > 0, secondsPerBeat > 0, sampleRate > 0, fileLengthFrames > 0 else {
            return nil
        }
        guard mediaStartSeconds >= 0 else { return nil }
        let relativeStart = clipStartBeat - playFromBeat
        let relativeEnd = relativeStart + clipLengthBeats
        // Entirely before the playhead: nothing to schedule.
        guard relativeEnd > 0 else { return nil }

        let audibleStartBeats = max(0, relativeStart)
        let skipBeats = max(0, -relativeStart)
        let remainingBeats = relativeEnd - audibleStartBeats
        guard remainingBeats > 0 else { return nil }

        let whenSeconds = audibleStartBeats * secondsPerBeat
        let skipSeconds = skipBeats * secondsPerBeat
        let remainingSeconds = remainingBeats * secondsPerBeat

        // File offset = clip media start + any mid-clip playhead skip into the clip.
        let fileOffsetSeconds = mediaStartSeconds + skipSeconds
        let startFrame = AVAudioFramePosition((fileOffsetSeconds * sampleRate).rounded(.down))
        guard startFrame < fileLengthFrames else { return nil }
        let wantedFrames = AVAudioFrameCount(max(0, (remainingSeconds * sampleRate).rounded(.down)))
        let available = AVAudioFrameCount(fileLengthFrames - startFrame)
        let frameCount = min(wantedFrames, available)
        guard frameCount > 0 else { return nil }

        return PlannedAudioSegment(
            whenSeconds: whenSeconds,
            startingFrame: startFrame,
            frameCount: frameCount
        )
    }

    // MARK: - Playback

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
            // Audio clips → sample-accurate scheduled segments on the track's player.
            if let player = engine.playerNode(for: track.id) {
                player.stop()
                for clip in track.clips where clip.kind == .audio {
                    guard let name = clip.mediaFile else { continue }
                    let url = mediaDir.appendingPathComponent(name)
                    guard let file = try? AVAudioFile(forReading: url) else { continue }
                    let rate = file.processingFormat.sampleRate
                    guard let plan = Self.planAudioSegment(
                        clipStartBeat: clip.startBeat,
                        clipLengthBeats: clip.lengthBeats,
                        playFromBeat: startBeat,
                        secondsPerBeat: spb,
                        fileLengthFrames: file.length,
                        sampleRate: rate,
                        mediaStartSeconds: clip.mediaStartSeconds
                    ) else { continue }
                    let when = AVAudioTime(
                        hostTime: anchorHost + AVAudioTime.hostTime(forSeconds: plan.whenSeconds)
                    )
                    player.scheduleSegment(
                        file,
                        startingFrame: plan.startingFrame,
                        frameCount: plan.frameCount,
                        at: when
                    )
                    let dur = rate > 0 ? Double(plan.frameCount) / rate : 0
                    endSeconds = max(endSeconds, plan.whenSeconds + dur)
                }
                player.play()
            }
            // MIDI clips → scheduled note on/off, clipped at lengthBeats.
            for clip in track.clips where clip.kind == .midi {
                let notes = Self.planMIDINotes(
                    notes: clip.midiNotes ?? [],
                    clipStartBeat: clip.startBeat,
                    clipLengthBeats: clip.lengthBeats,
                    playFromBeat: startBeat,
                    secondsPerBeat: spb
                )
                let tid = track.id
                for note in notes {
                    // Schedule on MAIN so all engine/trackNodes access stays single-threaded
                    // (no race with main-thread setEffect/removeTrack/addTrack). Note events are
                    // cheap startNote/stopNote calls.
                    let on = DispatchWorkItem {
                        MainActor.assumeIsolated {
                            self.engine.noteOn(note.pitch, velocity: note.velocity, trackID: tid)
                        }
                    }
                    let off = DispatchWorkItem {
                        MainActor.assumeIsolated {
                            self.engine.noteOff(note.pitch, trackID: tid)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: midiAnchor + note.onSeconds, execute: on)
                    DispatchQueue.main.asyncAfter(deadline: midiAnchor + note.offSeconds, execute: off)
                    midiWork.append(on); midiWork.append(off)
                    endSeconds = max(endSeconds, note.offSeconds)
                }
            }
        }

        state = .playing
        if metronomeEnabled { metronome.start(bpm: bpm, lead: lead) }

        if let loop {
            // Loop boundary is stop + reschedule, not plan clipping. planMIDINotes clips to the
            // clip only; events past loop.upperBound may already be scheduled. At wrap this
            // timer calls play(from: loop.lowerBound), which begins with stop() (cancel MIDI work
            // and allNotesOff), so those post-loop events never sound. A plan that contains
            // events past the loop end is therefore expected and must not be "fixed" by
            // clipping the plan to the loop.
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
        // Capture playhead before clearing wall-clock state so pause / auto-stop can hold it.
        if let beat = currentBeat {
            stoppedAtBeat = max(0, beat)
        }
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
