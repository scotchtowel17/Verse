import Foundation
import AVFoundation
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
        tk.expect(SoundBank.presets.count >= 55, "curated list is browse-worthy (≥55 after I1)")
        tk.expect(SoundBank.presets.count <= 90, "curated list stays scannable with category grouping")
        let required = ["Keys", "Organ", "Guitar", "Bass", "Strings", "Brass", "Woodwind",
                        "Synth Lead", "Pad", "Ethnic", "Percussion", "Sound Effects", "Drums"]
        for cat in required {
            tk.expect(SoundBank.presets.contains { $0.category == cat },
                      "category \(cat) is offered")
        }
        // Seed instrument matches Grand Piano by program+bank, not by track name.
        let grand = SoundBank.preset(matching: .grandPiano)
        tk.expectEqual(grand?.name, "Grand Piano", "grandPiano instrument maps to Grand Piano preset")
        tk.expect(SoundBank.presetCategories.count >= 12, "categories ordered for grouped picker")
        let drums = SoundBank.presets.filter { $0.category == "Drums" }
        tk.expect(drums.count >= 8, "multiple drum kits exposed (not just one)")
        tk.expect(drums.allSatisfy { $0.bankMSB == 120 }, "drum kits use percussion bank 120")
    }

    // MARK: - Step I1: drum kits must actually load from the SF2

    tk.suite("Engine I1: every curated drum kit loads from GeneralUser GS") {
        let kits = SoundBank.presets.filter { $0.category == "Drums" }
        tk.expect(!kits.isEmpty, "at least one drum kit in curated list")
        guard let url = SoundBank.generalUserGSURL else {
            // SF2 is optional for CI without artifacts: still require the list, but skip load.
            print("   ↳ SF2 not bundled; skipping load verification for \(kits.count) kits")
            return
        }
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try engine.start()
        defer { engine.stop() }
        var loaded: [String] = []
        for kit in kits {
            do {
                try sampler.loadSoundBankInstrument(
                    at: url,
                    program: UInt8(clamping: kit.program),
                    bankMSB: UInt8(clamping: kit.bankMSB),
                    bankLSB: UInt8(clamping: kit.bankLSB))
                loaded.append(kit.name)
                tk.expect(true, "\(kit.name) (program \(kit.program)) loads")
            } catch {
                tk.expect(false, "\(kit.name) (program \(kit.program)) loads: \(error)")
            }
        }
        print("   ↳ loaded drum kits: \(loaded.joined(separator: ", "))")
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

    // MARK: - Step G5: Engine graph lifecycle

    tk.suite("Engine G5: add and remove tracks repeatedly without throws") {
        let engine = VerseAudioEngine()
        engine.configure(with: Project.newUntitled())
        var live: [UUID] = [engine.allTrackIDs[0]]

        for i in 0..<12 {
            let id = UUID()
            if i % 2 == 0 {
                tk.expect(engine.addInstrumentTrack(id: id, instrument: .grandPiano),
                          "add instrument #\(i) succeeds")
            } else {
                tk.expect(engine.addAudioTrack(id: id), "add audio #\(i) succeeds")
            }
            live.append(id)
            tk.expect(engine.trackExists(id), "track present after add #\(i)")

            if live.count > 3 {
                let doomed = live.removeFirst()
                engine.removeTrack(id: doomed)
                tk.expect(!engine.trackExists(doomed), "removed track gone after cycle #\(i)")
            }
        }
        tk.expectEqual(engine.allTrackIDs.count, live.count, "node map size matches live tracks")
        for id in live {
            tk.expect(engine.trackExists(id), "surviving track still in graph")
        }
        // Tear down everything; must not throw or leave orphaned entries.
        for id in live { engine.removeTrack(id: id) }
        tk.expectEqual(engine.allTrackIDs.count, 0, "graph empty after removing all")
    }

    tk.suite("Engine G5: reconfigure many tracks leaves expected node set") {
        var big = Project(title: "many")
        big.tracks = (0..<8).map { i in
            if i % 3 == 0 {
                return Track(kind: .audio, name: "A\(i)")
            }
            return Track(kind: .instrument, name: "I\(i)", instrument: .grandPiano)
        }
        let engine = VerseAudioEngine()
        engine.configure(with: Project.newUntitled())
        tk.expectEqual(engine.allTrackIDs.count, 1, "seed configure has one track")

        engine.reconfigure(with: big)
        let expected = Set(big.tracks.map(\.id))
        let actual = Set(engine.allTrackIDs)
        tk.expectEqual(actual.count, 8, "exactly eight track node sets after reconfigure")
        tk.expectEqual(actual, expected, "node ids match project track ids exactly")
        for t in big.tracks {
            tk.expect(engine.trackExists(t.id), "track “\(t.name)” present")
            if t.kind == .instrument {
                tk.expect(engine.samplerExists(for: t.id), "instrument track has sampler")
                tk.expect(engine.playerNode(for: t.id) == nil, "instrument track has no player")
            } else {
                tk.expect(engine.playerNode(for: t.id) != nil, "audio track has player")
                tk.expect(!engine.samplerExists(for: t.id), "audio track has no sampler")
            }
        }

        // Second reconfigure to a smaller project must drop the rest.
        let small = Project.newUntitled()
        engine.reconfigure(with: small)
        tk.expectEqual(Set(engine.allTrackIDs), Set([small.tracks[0].id]),
                       "reconfigure to single track leaves only that id")
    }

    tk.suite("Engine G5: removeTrack on unknown id is a safe no-op") {
        let project = Project.newUntitled()
        let known = project.tracks[0].id
        let engine = VerseAudioEngine()
        engine.configure(with: project)
        let before = Set(engine.allTrackIDs)
        engine.removeTrack(id: UUID())
        tk.expectEqual(Set(engine.allTrackIDs), before, "unknown remove leaves graph unchanged")
        tk.expect(engine.trackExists(known), "known track still present after unknown remove")
        // Double-remove of a real id: second call is also a no-op.
        engine.removeTrack(id: known)
        engine.removeTrack(id: known)
        tk.expect(!engine.trackExists(known), "track gone after first remove")
        tk.expectEqual(engine.allTrackIDs.count, 0, "second remove of same id is safe")
    }

    tk.suite("Engine G5: effects insert and remove; audio still flows") {
        let trackID = UUID()
        var project = Project(title: "fx-g5")
        project.tracks = [Track(id: trackID, kind: .instrument, name: "Keys", instrument: .grandPiano)]
        let engine = VerseAudioEngine()
        engine.configure(with: project)

        engine.setEffect(.reverb, trackID: trackID, amount: 50)
        tk.expectEqual(engine.currentEffect(trackID: trackID), .reverb, "reverb inserted")
        let withFX = VerseAudioEngine.stats(try engine.renderOffline(seconds: 0.5) { e in
            e.noteOn(60, velocity: 110, trackID: trackID)
        })
        tk.expect(withFX.isAudible, "audio flows through reverb insert (peak=\(withFX.peak))")

        // Swap to delay without tearing the graph down.
        engine.setEffect(.delay, trackID: trackID, amount: 40)
        tk.expectEqual(engine.currentEffect(trackID: trackID), .delay, "delay replaced reverb")

        // Remove effect (.none) and confirm path still sounds.
        engine.setEffect(.none, trackID: trackID)
        tk.expectEqual(engine.currentEffect(trackID: trackID), .none, "effect removed")
        let dry = VerseAudioEngine.stats(try engine.renderOffline(seconds: 0.5) { e in
            e.noteOn(64, velocity: 110, trackID: trackID)
        })
        tk.expect(dry.isAudible, "audio still flows after effect removed (peak=\(dry.peak))")
    }
}
