import Foundation
import VerseModel
import VerseEngine

func runEngineChecks(_ tk: TestKit) {
    tk.suite("Engine: graph builds for a project") {
        let project = Project.newUntitled()
        let engine = VerseAudioEngine()
        engine.configure(with: project)
        let trackID = project.tracks[0].id
        tk.expect(engine.samplerExists(for: trackID), "sampler node created for seed track")
    }

    tk.suite("Engine: notes are audible (offline render)") {
        let project = Project.newUntitled()
        let trackID = project.tracks[0].id
        let engine = VerseAudioEngine()
        engine.configure(with: project)
        let samples = try engine.renderOffline(seconds: 1.0) { e in
            e.noteOn(60, velocity: 110, trackID: trackID)   // middle C
            e.noteOn(64, velocity: 110, trackID: trackID)
            e.noteOn(67, velocity: 110, trackID: trackID)
        }
        let s = VerseAudioEngine.stats(samples)
        print("   ↳ rendered \(s.sampleCount) samples, peak=\(s.peak), rms=\(s.rms), SF2 bundled=\(SoundBank.isAvailable)")
        tk.expect(s.sampleCount > 40_000, "rendered ~1s of audio")
        tk.expect(s.isAudible, "peak above noise floor (sound was produced)")
    }

    tk.suite("Engine: render is deterministic") {
        func renderOnce() throws -> [Float] {
            let project = Project.newUntitled()
            let trackID = project.tracks[0].id
            let engine = VerseAudioEngine()
            engine.configure(with: project)
            return try engine.renderOffline(seconds: 0.5) { e in
                e.noteOn(60, velocity: 100, trackID: trackID)
            }
        }
        let a = try renderOnce()
        let b = try renderOnce()
        tk.expectEqual(a.count, b.count, "stable render length across runs")
        tk.expect(a == b, "identical samples across runs (deterministic)")
    }

    tk.suite("Engine: curated presets available") {
        tk.expect(SoundBank.presets.count >= 5, "at least 5 curated presets exposed")
        tk.expect(SoundBank.presets.contains { $0.category == "Bass" }, "a bass preset is offered")
    }

    // MARK: - Step G4: Crash-shape hardening

    tk.suite("Engine G4: audition across two formats does not throw") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-audition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url44 = dir.appendingPathComponent("a-44k.caf")
        let url48 = dir.appendingPathComponent("b-48k.caf")
        try writeSineCAF(to: url44, seconds: 0.05, sampleRate: 44_100)
        try writeSineCAF(to: url48, seconds: 0.05, sampleRate: 48_000)

        let engine = VerseAudioEngine()
        engine.configure(with: Project.newUntitled())
        try engine.start()
        // Same format first, then a different sample rate: must reconnect, not crash.
        try engine.playFile(url: url44)
        try engine.playFile(url: url48)
        try engine.playFile(url: url44)
        engine.stopAudition()
        engine.stop()
        tk.expect(true, "playFile across 44.1k and 48k did not throw")
    }

    tk.suite("Engine G4: removeTrack after installMeterTaps leaves no tap for that track") {
        var project = Project.newUntitled()
        let trackID = project.tracks[0].id
        let second = Track(kind: .instrument, name: "Second", instrument: .grandPiano)
        project.tracks.append(second)
        let engine = VerseAudioEngine()
        engine.configure(with: project)
        try engine.start()
        // installMeterTaps ran on start. Removing a track must strip its mixer tap so a
        // later reconfigure/install does not crash.
        engine.removeTrack(id: second.id)
        tk.expect(engine.meter(for: second.id) == nil, "meter map entry cleared for removed track")
        tk.expect(engine.trackExists(second.id) == false, "track nodes removed")
        tk.expect(engine.trackExists(trackID), "other track still present")
        // Re-installing taps for remaining tracks must not throw (no leftover tap claim).
        engine.installMeterTaps()
        tk.expect(engine.meter(for: trackID) != nil, "remaining track still metered")
        // Full reconfigure after taps is the crash path the review named.
        engine.reconfigure(with: Project.newUntitled())
        tk.expect(true, "reconfigure after removeTrack+taps did not throw")
        engine.stop()
    }

    tk.suite("Engine G4: duplicate track ids re-keyed then all present in graph") {
        let shared = UUID()
        var project = Project(title: "dup")
        project.tracks = [
            Track(id: shared, kind: .instrument, name: "A", instrument: .grandPiano),
            Track(id: shared, kind: .instrument, name: "B", instrument: .grandPiano),
            Track(id: shared, kind: .audio, name: "C")
        ]
        // Without re-keying, configure only creates one node for `shared`.
        let broken = VerseAudioEngine()
        broken.configure(with: project)
        tk.expectEqual(broken.allTrackIDs.count, 1, "unfixed duplicates yield a single silent graph slot")

        let rekeyed = project.ensureUniqueTrackIDs()
        tk.expectEqual(rekeyed, 2, "two later tracks re-keyed")
        tk.expectEqual(Set(project.tracks.map(\.id)).count, 3, "all three ids unique after fix")

        let fixed = VerseAudioEngine()
        fixed.configure(with: project)
        for t in project.tracks {
            tk.expect(fixed.trackExists(t.id), "track “\(t.name)” has engine nodes after re-key")
        }
        tk.expectEqual(fixed.allTrackIDs.count, 3, "graph has a node set per track")
    }
}
