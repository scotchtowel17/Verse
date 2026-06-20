import Foundation
import AVFoundation
import VerseModel
import VerseEngine
import VerseAnalysis
import VersePlugins

/// Run an async closure to completion from synchronous harness code.
func runBlocking(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task.detached { await body(); sem.signal() }
    sem.wait()
}

func runAnalysisChecks(_ tk: TestKit) {
    tk.suite("Analysis: manual fallback measures a take deterministically") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-an-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take.caf")
        try writeSineCAF(to: url, seconds: 1.0)

        let r = Analysis.fallback(url: url)
        tk.expectEqual(r.source, .manualFallback, "fallback source when Music Understanding absent")
        tk.expect(abs(r.durationSec - 1.0) < 0.05, "measured duration ≈ 1.0s (got \(r.durationSec))")
        tk.expect(r.loudnessDB > -30 && r.loudnessDB < 0, "loudness in a sane dBFS range (\(r.loudnessDB))")
        tk.expect(r.tempoPending, "tempo pending (use tap-tempo)")
        tk.expect(r.keyPending, "key pending (use key picker)")
        FileManager.default.removeItemSafely(dir)
    }

    tk.suite("Analysis: capability flag reflects this SDK") {
        // On this build the framework is absent, so it must report unavailable (and not crash).
        tk.expectEqual(Analysis.isMusicUnderstandingAvailable, false,
                       "Music Understanding correctly reported unavailable on this SDK")
    }

    tk.suite("Analysis: tap-tempo averages taps to BPM") {
        var tt = TapTempo()
        // Taps every 0.5s → 120 BPM.
        _ = tt.tap(at: 0.0)
        _ = tt.tap(at: 0.5)
        _ = tt.tap(at: 1.0)
        let bpm = tt.tap(at: 1.5)
        tk.expect(bpm != nil, "produces a BPM after several taps")
        if let bpm { tk.expect(abs(bpm - 120) < 1, "0.5s taps → ~120 BPM (got \(bpm))") }
    }
}

func runPluginChecks(_ tk: TestKit) {
    tk.suite("AU hosting: discovers installed effects") {
        let effects = AudioUnitDiscovery.effects()
        tk.expect(effects.count >= 1, "found \(effects.count) installed Audio Unit effect(s)")
        // macOS always ships Apple effect AUs; print a couple for visibility.
        if let first = effects.first { print("   ↳ e.g. \(first.manufacturer) — \(first.name)") }
    }

    tk.suite("AU hosting: instantiate + insert an installed effect renders audio") {
        let effects = AudioUnitDiscovery.effects()
        guard let pick = effects.first(where: { $0.manufacturer == "Apple" }) ?? effects.first else {
            tk.expect(false, "no AU effects available to host"); return
        }
        let trackID = UUID()
        var project = Project(title: "host")
        project.tracks = [Track(id: trackID, kind: .instrument, name: "Keys", instrument: .grandPiano)]
        let engine = VerseAudioEngine(); engine.configure(with: project)

        runBlocking {
            do { try await engine.insertHostedEffect(pick.componentDescription, trackID: trackID) }
            catch { print("   ↳ host insert error: \(error)") }
        }
        tk.expect(engine.hasInsert(trackID: trackID), "hosted AU inserted on the track (\(pick.name))")

        let s = VerseAudioEngine.stats(try engine.renderOffline(seconds: 0.5) { e in
            e.noteOn(60, velocity: 100, trackID: trackID)
        })
        tk.expect(s.isAudible, "audio still flows through the hosted AU (peak=\(s.peak))")
    }
}
