import Foundation
import AVFoundation
import VerseModel
import VerseEngine

func runTransportChecks(_ tk: TestKit) {
    // Transport is @MainActor. Same harness pattern as AppStore checks.
    if Thread.isMainThread {
        MainActor.assumeIsolated { runTransportChecksOnMain(tk) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { runTransportChecksOnMain(tk) }
        }
    }
}

/// Pump the main run loop so DispatchWorkItem / Timer work can fire.
private func pumpMain(for seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func runTransportChecksOnMain(_ tk: TestKit) {

    // MARK: - Step G5: Transport

    tk.suite("Transport G5: audio + MIDI arrangement end drives auto-stop") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-g5-end-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 0.1s audio at beat 0. MIDI note ends at beat 4 → at 120 BPM that is 2.0s of audio time.
        // Arrangement end must follow the longer MIDI tail, not the short audio file alone.
        let takeName = "short.caf"
        try writeSineCAF(to: dir.appendingPathComponent(takeName), seconds: 0.1)

        let audioID = UUID()
        let midiID = UUID()
        var project = Project(title: "mix-end", tempoBPM: 120)
        project.tracks = [
            Track(id: audioID, kind: .audio, name: "Audio", clips: [
                Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 1, mediaFile: takeName)
            ]),
            Track(id: midiID, kind: .instrument, name: "Keys", instrument: .grandPiano, clips: [
                Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 4, pitch: 60, velocity: 90)])
            ])
        ]

        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        let transport = Transport(engine: engine)

        // lead (0.12) + endSeconds (4 beats * 0.5s = 2.0) + tail (0.8) ≈ 2.92s
        let expectedTotal = 0.12 + 2.0 + 0.8
        var didAutoStop = false
        // Record WHEN auto-stop fired. Measuring total pump time instead would just measure
        // how long the test waited (and how loaded the machine is), not what the code did.
        var stopElapsed: Double?
        let t0 = Date()
        transport.onStop = { didAutoStop = true; stopElapsed = Date().timeIntervalSince(t0) }

        transport.play(project: project, mediaDir: dir)
        tk.expectEqual(transport.state, .playing, "transport is playing after play()")

        // Wait past the expected end with margin; do not wait long enough that a pure-audio
        // end (0.12+0.1+0.8 ≈ 1.02s) could be confused if we only checked "eventually stopped".
        pumpMain(for: expectedTotal + 0.6)

        tk.expect(didAutoStop, "onStop fired from arrangement auto-stop")
        tk.expectEqual(transport.state, .stopped, "state is stopped after arrangement end")
        // The load-bearing assertion: auto-stop must NOT fire at the audio-only end
        // (0.12 + 0.1 + 0.8 ≈ 1.02s). It has to wait for the longer MIDI tail (≈ 2.92s).
        // Only a lower bound is asserted. An upper bound here would measure machine load
        // rather than behavior, and is what made this suite flaky on CI.
        if let stopElapsed {
            tk.expect(stopElapsed >= expectedTotal - 0.35,
                      "auto-stop waited for MIDI end, not the short audio clip "
                      + "(fired at \(String(format: "%.2f", stopElapsed))s, floor \(String(format: "%.2f", expectedTotal - 0.35))s)")
        }
        engine.stop()
    }

    tk.suite("Transport G5: stop() cancels pending work so no note fires after") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-g5-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Note scheduled ~0.5s after play (beat 1 at 120 BPM). Stop immediately; cancel must
        // prevent the note work item and the arrangement auto-stop callback from running.
        let midiID = UUID()
        var project = Project(title: "cancel", tempoBPM: 120)
        project.tracks = [
            Track(id: midiID, kind: .instrument, name: "Keys", instrument: .grandPiano, clips: [
                Clip(kind: .midi, name: "Late", startBeat: 0, lengthBeats: 8,
                     midiNotes: [Note(startBeat: 1, lengthBeats: 1, pitch: 72, velocity: 100)])
            ])
        ]

        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        let transport = Transport(engine: engine)

        var autoStopFired = false
        transport.onStop = { autoStopFired = true }

        transport.play(project: project, mediaDir: dir)
        tk.expectEqual(transport.state, .playing, "playing before manual stop")
        transport.stop()
        tk.expectEqual(transport.state, .stopped, "stopped after manual stop")

        // Past when the note (beat 1 → 0.5s + 0.12 lead) and a short arrangement would fire.
        pumpMain(for: 1.2)
        tk.expectEqual(transport.state, .stopped, "still stopped after waiting past note time")
        tk.expect(!autoStopFired,
                  "manual stop cancelled auto-stop; onStop must not fire afterwards")

        // A second stop is also safe.
        transport.stop()
        tk.expectEqual(transport.state, .stopped, "second stop is a no-op, still stopped")
        engine.stop()
    }

    tk.suite("Transport G5: negative clip startBeat does not schedule a negative onset") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-g5-neg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let takeName = "neg.caf"
        try writeSineCAF(to: dir.appendingPathComponent(takeName), seconds: 0.15)

        let audioID = UUID()
        let midiID = UUID()
        // Model mutation rejects negative starts; construct clips directly to probe transport.
        var project = Project(title: "neg-onset", tempoBPM: 120)
        project.tracks = [
            Track(id: audioID, kind: .audio, name: "Audio", clips: [
                Clip(kind: .audio, name: "Early", startBeat: -4, lengthBeats: 2, mediaFile: takeName)
            ]),
            Track(id: midiID, kind: .instrument, name: "Keys", instrument: .grandPiano, clips: [
                Clip(kind: .midi, name: "Early MIDI", startBeat: -2, lengthBeats: 1,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 0.5, pitch: 60, velocity: 80)])
            ])
        ]

        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        let transport = Transport(engine: engine)

        // Must not throw or hang. Audio path clamps onset with max(0, ...); MIDI path skips
        // notes whose onSec is negative.
        transport.play(project: project, mediaDir: dir)
        tk.expectEqual(transport.state, .playing, "play accepts project with negative startBeats")
        pumpMain(for: 0.25)
        transport.stop()
        tk.expectEqual(transport.state, .stopped, "clean stop after negative-onset project")
        engine.stop()
        tk.expect(true, "no crash and no negative onset scheduled")
    }

    // MARK: - Phase P4: playhead position

    tk.suite("Transport: currentBeat is nil when stopped and advances while playing") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-playhead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let midiID = UUID()
        var project = Project(title: "playhead", tempoBPM: 120)
        project.tracks = [
            Track(id: midiID, kind: .instrument, name: "Keys", instrument: .grandPiano, clips: [
                Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 4, pitch: 60, velocity: 90)])
            ])
        ]

        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        let transport = Transport(engine: engine)

        tk.expect(transport.currentBeat == nil, "currentBeat is nil before play")
        transport.play(project: project, mediaDir: dir, from: 0)
        tk.expectEqual(transport.state, .playing, "playing")
        // During the 0.12s lead the beat should still report the start beat (not negative).
        if let early = transport.currentBeat {
            tk.expect(early >= 0, "beat is never negative during lead (got \(early))")
        } else {
            tk.expect(false, "currentBeat is non-nil while playing")
        }
        // Wait past the lead so musical time has advanced; only a lower bound matters.
        pumpMain(for: 0.4)
        if let later = transport.currentBeat {
            // 0.4s wall − 0.12 lead = 0.28s → at 120 BPM ≈ 0.56 beats; allow slack for scheduling.
            tk.expect(later >= 0.2, "beat advances after the lead (got \(later))")
        } else {
            tk.expect(false, "currentBeat stays non-nil while still playing")
        }
        transport.stop()
        tk.expect(transport.currentBeat == nil, "currentBeat is nil after stop")
        tk.expect(transport.stoppedAtBeat >= 0.2,
                  "stoppedAtBeat captures last playhead for pause/resume (got \(transport.stoppedAtBeat))")
        engine.stop()
    }

    tk.suite("Transport S1: play(from:) starts currentBeat at the given beat") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-from-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let midiID = UUID()
        var project = Project(title: "from-beat", tempoBPM: 120)
        project.tracks = [
            Track(id: midiID, kind: .instrument, name: "Keys", instrument: .grandPiano, clips: [
                Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 16,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 8, pitch: 60, velocity: 90)])
            ])
        ]
        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        let transport = Transport(engine: engine)

        transport.play(project: project, mediaDir: dir, from: 3.0)
        tk.expectEqual(transport.state, .playing, "playing from beat 3")
        if let early = transport.currentBeat {
            tk.expect(early >= 2.95 && early < 3.5,
                      "currentBeat starts near from: 3 (got \(early))")
        } else {
            tk.expect(false, "currentBeat non-nil while playing from 3")
        }
        transport.stop()
        tk.expect(transport.stoppedAtBeat >= 2.95,
                  "stoppedAtBeat near resume point (got \(transport.stoppedAtBeat))")
        engine.stop()
    }

    // MARK: - Step R1: lengthBeats is a hard transport boundary

    tk.suite("Transport R1: MIDI plan truncates note at clip end; drops notes past end") {
        // 120 BPM → 0.5 s/beat. Clip is 2 beats long.
        let spb = 0.5
        let notes = [
            // Fully inside: 0…1 → on 0, off 0.5
            Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
            // Crosses the boundary: starts at 1.5, length 2 → should end at clip end (2.0)
            // on = 1.5 * 0.5 = 0.75, off = 2.0 * 0.5 = 1.0 (truncated, not 1.75)
            Note(startBeat: 1.5, lengthBeats: 2, pitch: 64, velocity: 90),
            // Starts exactly at clip end: must not sound
            Note(startBeat: 2.0, lengthBeats: 1, pitch: 67, velocity: 80),
            // Starts after clip end: must not sound
            Note(startBeat: 3.0, lengthBeats: 1, pitch: 72, velocity: 70),
        ]
        let planned = Transport.planMIDINotes(
            notes: notes,
            clipStartBeat: 0,
            clipLengthBeats: 2,
            playFromBeat: 0,
            secondsPerBeat: spb
        )
        tk.expectEqual(planned.count, 2, "only in-clip notes are planned (got \(planned.count))")
        if planned.count >= 1 {
            tk.expectEqual(planned[0].pitch, 60, "first planned note is pitch 60")
            tk.expectEqual(planned[0].onSeconds, 0, "full note on at 0")
            tk.expectEqual(planned[0].offSeconds, 0.5, "full note off at length")
        }
        if planned.count >= 2 {
            tk.expectEqual(planned[1].pitch, 64, "crossing note is pitch 64")
            tk.expectEqual(planned[1].onSeconds, 0.75, "crossing note on at 1.5 beats")
            tk.expectEqual(planned[1].offSeconds, 1.0, "crossing note off at clip end (not past it)")
            tk.expect(planned[1].offSeconds < 0.75 + 2 * spb,
                      "truncated off is earlier than the unclipped note end")
        }
        tk.expect(!planned.contains { $0.pitch == 67 }, "note at clip end never scheduled")
        tk.expect(!planned.contains { $0.pitch == 72 }, "note past clip end never scheduled")
    }

    tk.suite("Transport R1: MIDI plan keeps negative-onset skip") {
        let spb = 0.5
        // Clip starts at beat -2; note at relative 0 has onSec = -1 and must be dropped.
        let planned = Transport.planMIDINotes(
            notes: [Note(startBeat: 0, lengthBeats: 0.5, pitch: 60, velocity: 80)],
            clipStartBeat: -2,
            clipLengthBeats: 1,
            playFromBeat: 0,
            secondsPerBeat: spb
        )
        tk.expectEqual(planned.count, 0, "negative onset note is not scheduled")

        // Same clip geometry, but play from beat -2 so the note lands at t=0.
        let fromClipStart = Transport.planMIDINotes(
            notes: [Note(startBeat: 0, lengthBeats: 0.5, pitch: 60, velocity: 80)],
            clipStartBeat: -2,
            clipLengthBeats: 1,
            playFromBeat: -2,
            secondsPerBeat: spb
        )
        tk.expectEqual(fromClipStart.count, 1, "note is scheduled when playhead is at clip start")
        if let n = fromClipStart.first {
            tk.expectEqual(n.onSeconds, 0, "on at musical t=0")
            tk.expectEqual(n.offSeconds, 0.25, "off at half a beat")
        }
    }

    tk.suite("Transport R1: audio plan frame count comes from lengthBeats, not file length") {
        let spb = 0.5            // 120 BPM
        let sampleRate = 44_100.0
        // 1.0 s file = 44100 frames; clip is only 1 beat = 0.5 s = 22050 frames.
        let fileFrames: AVAudioFramePosition = 44_100
        let plan = Transport.planAudioSegment(
            clipStartBeat: 0,
            clipLengthBeats: 1,
            playFromBeat: 0,
            secondsPerBeat: spb,
            fileLengthFrames: fileFrames,
            sampleRate: sampleRate
        )
        tk.expect(plan != nil, "segment planned for in-range clip")
        if let plan {
            tk.expectEqual(plan.whenSeconds, 0, "starts at playhead")
            tk.expectEqual(plan.startingFrame, 0, "starts at file head")
            tk.expectEqual(plan.frameCount, 22_050,
                           "frame count is lengthBeats * spb * rate, not the whole file")
            tk.expect(AVAudioFramePosition(plan.frameCount) < fileFrames,
                      "scheduled frames are fewer than the full file")
        }

        // Clip longer than the file: play the whole file, do not invent frames or loop.
        let longClip = Transport.planAudioSegment(
            clipStartBeat: 0,
            clipLengthBeats: 8,
            playFromBeat: 0,
            secondsPerBeat: spb,
            fileLengthFrames: fileFrames,
            sampleRate: sampleRate
        )
        tk.expect(longClip != nil, "long clip still plans")
        if let longClip {
            tk.expectEqual(longClip.frameCount, AVAudioFrameCount(fileFrames),
                           "file shorter than clip ends early (no loop)")
        }

        // Clip entirely before the playhead: nothing.
        let past = Transport.planAudioSegment(
            clipStartBeat: -4,
            clipLengthBeats: 2,
            playFromBeat: 0,
            secondsPerBeat: spb,
            fileLengthFrames: fileFrames,
            sampleRate: sampleRate
        )
        tk.expect(past == nil, "clip entirely before playhead is not scheduled")
    }

    tk.suite("Transport R1: offline render of audio clip is silent after lengthBeats") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-tr-r1-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRate = 44_100.0
        let fileSeconds = 1.0
        let takeName = "long.caf"
        let url = dir.appendingPathComponent(takeName)
        try writeSineCAF(to: url, seconds: fileSeconds, sampleRate: sampleRate)

        // Clip length 1 beat at 120 BPM = 0.5 s. Whole file is 1.0 s.
        let spb = 0.5
        let file = try AVAudioFile(forReading: url)
        let plan = Transport.planAudioSegment(
            clipStartBeat: 0,
            clipLengthBeats: 1,
            playFromBeat: 0,
            secondsPerBeat: spb,
            fileLengthFrames: file.length,
            sampleRate: file.processingFormat.sampleRate
        )
        tk.expect(plan != nil, "plan exists for offline segment")
        guard let plan else { return }

        let audioID = UUID()
        var project = Project(title: "r1-audio", tempoBPM: 120)
        project.tracks = [
            Track(id: audioID, kind: .audio, name: "Audio", clips: [
                Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 1, mediaFile: takeName)
            ])
        ]
        let engine = VerseAudioEngine()
        engine.configure(with: project)

        // Render a full second: first half must be audible (the scheduled segment), second half
        // must be near silent because scheduleSegment ended at lengthBeats (not scheduleFile).
        let samples = try engine.renderOffline(seconds: 1.0, sampleRate: sampleRate) { e in
            guard let player = e.playerNode(for: audioID) else { return }
            player.stop()
            player.scheduleSegment(
                file,
                startingFrame: plan.startingFrame,
                frameCount: plan.frameCount,
                at: nil
            )
            player.play()
        }

        let half = samples.count / 2
        tk.expect(half > 1000, "rendered enough samples to split (got \(samples.count))")
        guard half > 0 else { return }

        let first = VerseAudioEngine.stats(Array(samples[0..<half]))
        let second = VerseAudioEngine.stats(Array(samples[half..<samples.count]))
        tk.expect(first.isAudible, "first half (inside lengthBeats) is audible (peak=\(first.peak))")
        // Hard boundary: after the segment ends the player outputs silence. Allow a tiny
        // numerical floor, far below the sine amplitude (0.3).
        tk.expect(second.peak < 1e-3,
                  "second half (past lengthBeats) is silent (peak=\(second.peak)); "
                  + "scheduleFile would still be playing the rest of the file here")
        tk.expect(first.rms > second.rms * 10,
                  "in-clip energy dwarfs post-clip energy (\(first.rms) vs \(second.rms))")
    }

    tk.suite("Transport R1: play() uses plan (audio end follows lengthBeats, not file length)") {
        // Pure plan already locks frame counts; this checks Transport.play wires the same math
        // for arrangement endSeconds: a long file under a short clip must not extend auto-stop
        // past the clip. We assert via planned duration, not wall-clock.
        let spb = 0.5
        let sampleRate = 44_100.0
        // 2.0 s file, clip only 1 beat (0.5 s).
        let plan = Transport.planAudioSegment(
            clipStartBeat: 0,
            clipLengthBeats: 1,
            playFromBeat: 0,
            secondsPerBeat: spb,
            fileLengthFrames: AVAudioFramePosition(2.0 * sampleRate),
            sampleRate: sampleRate
        )
        tk.expect(plan != nil, "short clip over long file plans")
        if let plan {
            let scheduledSec = Double(plan.frameCount) / sampleRate
            tk.expect(abs(scheduledSec - 0.5) < 0.001,
                      "scheduled duration is 0.5s from lengthBeats (got \(scheduledSec))")
            tk.expect(scheduledSec < 2.0, "scheduled duration is not the full 2s file")
        }

        // MIDI: a 16-beat note inside an 2-beat clip contributes only 2 beats to the end.
        let midi = Transport.planMIDINotes(
            notes: [Note(startBeat: 0, lengthBeats: 16, pitch: 60, velocity: 100)],
            clipStartBeat: 0,
            clipLengthBeats: 2,
            playFromBeat: 0,
            secondsPerBeat: spb
        )
        tk.expectEqual(midi.count, 1, "truncated note is still planned")
        if let n = midi.first {
            tk.expectEqual(n.offSeconds, 1.0, "arrangement end from MIDI is clip end (2 beats)")
            tk.expect(n.offSeconds < 16 * spb, "not the unclipped 16-beat note end")
        }
    }
}
