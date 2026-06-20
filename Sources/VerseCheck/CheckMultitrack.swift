import Foundation
import AVFoundation
import VerseModel
import VerseEngine

func runMultitrackChecks(_ tk: TestKit) {
    tk.suite("Multitrack: 3 instrument tracks mix together") {
        // One track, one note.
        var single = Project(title: "single", tracks: [Track(kind: .instrument, name: "A", instrument: .grandPiano)])
        let e1 = VerseAudioEngine(); e1.configure(with: single)
        let s1 = VerseAudioEngine.stats(try e1.renderOffline(seconds: 0.5) { e in
            e.noteOn(60, velocity: 100, trackID: single.tracks[0].id)
        })

        // Three tracks, each playing the same note → summed energy is greater.
        var three = Project(title: "three")
        three.tracks = (0..<3).map { Track(kind: .instrument, name: "T\($0)", instrument: .grandPiano) }
        let e3 = VerseAudioEngine(); e3.configure(with: three)
        let s3 = VerseAudioEngine.stats(try e3.renderOffline(seconds: 0.5) { e in
            for t in three.tracks { e.noteOn(60, velocity: 100, trackID: t.id) }
        })

        tk.expect(s1.isAudible && s3.isAudible, "both renders audible")
        tk.expect(s3.rms > s1.rms * 1.4, "3-track mix is louder than 1 track (mixing works): \(s1.rms) → \(s3.rms)")
    }

    tk.suite("Multitrack: audio-track clip plays back") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.caf")
        try writeSineCAF(to: url, seconds: 0.4)

        let audioTrackID = UUID()
        var project = Project(title: "audio")
        project.tracks = [Track(id: audioTrackID, kind: .audio, name: "Recordings")]
        let engine = VerseAudioEngine(); engine.configure(with: project)

        let samples = try engine.renderOffline(seconds: 0.4) { e in
            try? e.scheduleClip(url: url, on: audioTrackID)
        }
        let s = VerseAudioEngine.stats(samples)
        tk.expect(s.isAudible, "audio clip rendered through its track player (peak=\(s.peak))")
        FileManager.default.removeItemSafely(dir)
    }

    tk.suite("Multitrack: built-in effect insert doesn't break audio") {
        let trackID = UUID()
        var project = Project(title: "fx")
        project.tracks = [Track(id: trackID, kind: .instrument, name: "Keys", instrument: .grandPiano)]
        let engine = VerseAudioEngine(); engine.configure(with: project)
        engine.setEffect(.reverb, trackID: trackID, amount: 40)
        let s = VerseAudioEngine.stats(try engine.renderOffline(seconds: 0.6) { e in
            e.noteOn(64, velocity: 100, trackID: trackID)
        })
        tk.expect(s.isAudible, "reverb-inserted track still produces sound")
        tk.expectEqual(engine.currentEffect(trackID: trackID), .reverb, "effect recorded on track")
    }
}

extension FileManager {
    func removeItemSafely(_ url: URL) { try? removeItem(at: url) }
}
