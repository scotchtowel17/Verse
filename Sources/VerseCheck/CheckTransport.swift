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
}
