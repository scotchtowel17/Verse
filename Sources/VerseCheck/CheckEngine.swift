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
}
