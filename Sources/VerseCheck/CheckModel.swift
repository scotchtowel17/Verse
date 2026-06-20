import Foundation
import VerseModel

func runModelChecks(_ tk: TestKit) {
    tk.suite("Model: new untitled project") {
        let p = Project.newUntitled()
        tk.expectEqual(p.schemaVersion, Schema.current, "schemaVersion is current")
        tk.expectEqual(p.tracks.count, 1, "one seed track")
        tk.expectEqual(p.tracks.first?.kind, .instrument, "seed track is instrument")
        tk.expectEqual(p.tracks.first?.instrument, .grandPiano, "seed instrument is grand piano")
    }

    tk.suite("Model: JSON round-trip") {
        var p = Project.newUntitled()
        p.title = "My Song"
        p.tempoBPM = 128
        p.key = KeySignature(tonic: .Gs, mode: .minor)
        p.tracks[0].clips = [Clip(kind: .midi, name: "v1", startBeat: 0, lengthBeats: 4,
                                  midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])]
        let data = try p.jsonData()
        let back = try Project.fromJSON(data)
        tk.expectEqual(back.title, "My Song", "title round-trips")
        tk.expectEqual(back.tempoBPM, 128, "tempo round-trips")
        tk.expectEqual(back.key?.tonic, .Gs, "key tonic round-trips")
        tk.expectEqual(back.key?.mode, .minor, "key mode round-trips")
        tk.expectEqual(back.tracks.first?.clips.first?.midiNotes?.first?.pitch, 60, "note pitch round-trips")
        tk.expectEqual(back.id, p.id, "project id stable")
    }

    tk.suite("Model: migration pass-through") {
        let p = Project.newUntitled()
        let data = try p.jsonData()
        let migrated = try Migration.migrateRawIfNeeded(data)
        tk.expectNoThrow("current-schema data decodes after migrate") {
            _ = try Project.fromJSON(migrated)
        }
    }

    tk.suite("Model: tonic enum") {
        tk.expectEqual(Tonic.Cs.rawValue, "C#", "sharp-style raw value")
        tk.expectEqual(Tonic.allCases.count, 12, "twelve tonics")
    }
}
