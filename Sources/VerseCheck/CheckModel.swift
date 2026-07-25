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

    tk.suite("Model H4: future schemaVersion is a readable open failure") {
        let future = Schema.current + 1
        let json = """
        {
          "schemaVersion": \(future),
          "id": "00000000-0000-4000-8000-0000000000CC",
          "title": "Too New",
          "tempoBPM": 120,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [],
          "masterVolume": 0.8,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z",
          "futureOnlyField": true
        }
        """
        let data = Data(json.utf8)
        tk.expectThrows("fromJSON rejects schema newer than current") {
            _ = try Project.fromJSON(data)
        }
        do {
            _ = try Project.fromJSON(data)
            tk.expect(false, "must throw", "opened")
        } catch let err as Migration.MigrationError {
            let msg = err.errorDescription ?? err.description
            tk.expect(msg.localizedCaseInsensitiveContains("newer"),
                      "message says newer version")
            tk.expect(msg.contains("\(future)"), "message includes schema \(future)")
        } catch {
            tk.expect(false, "MigrationError.unsupportedFutureVersion", "got \(error)")
        }

        // Current schema still opens; no regression.
        let current = Project.newUntitled()
        let currentData = try current.jsonData()
        let back = try Project.fromJSON(currentData)
        tk.expectEqual(back.schemaVersion, Schema.current, "current schema unaffected")
        tk.expectEqual(back.tracks.count, current.tracks.count, "current tracks preserved")
    }

    tk.suite("Model: tonic enum") {
        tk.expectEqual(Tonic.Cs.rawValue, "C#", "sharp-style raw value")
        tk.expectEqual(Tonic.allCases.count, 12, "twelve tonics")
    }

    tk.suite("Model G4: ensureUniqueTrackIDs") {
        let shared = UUID()
        var p = Project(title: "dups")
        p.tracks = [
            Track(id: shared, kind: .instrument, name: "Keep", instrument: .grandPiano),
            Track(id: shared, kind: .instrument, name: "Dup", instrument: .grandPiano),
            Track(kind: .audio, name: "Unique")
        ]
        let alreadyUnique = p.ensureUniqueTrackIDs()
        tk.expectEqual(alreadyUnique, 1, "one duplicate re-keyed")
        tk.expectEqual(p.tracks[0].id, shared, "first occurrence keeps its id")
        tk.expect(p.tracks[1].id != shared, "duplicate got a new id")
        tk.expectEqual(Set(p.tracks.map(\.id)).count, 3, "all ids unique")
        tk.expectEqual(p.ensureUniqueTrackIDs(), 0, "second call is a no-op")
    }

    tk.suite("Model: moveClip") {
        var p = Project.newUntitled()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        p.tracks[0].clips = [clip]
        try p.moveClip(id: clip.id, toStartBeat: 8)
        tk.expectEqual(p.tracks[0].clips[0].startBeat, 8, "startBeat updates")

        tk.expectThrows("reject negative startBeat") {
            try p.moveClip(id: clip.id, toStartBeat: -0.5)
        }
        tk.expectEqual(p.tracks[0].clips[0].startBeat, 8, "negative move leaves startBeat unchanged")

        tk.expectThrows("reject unknown clip") {
            try p.moveClip(id: UUID(), toStartBeat: 0)
        }
    }

    tk.suite("Model: resizeClip") {
        var p = Project.newUntitled()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        p.tracks[0].clips = [clip]
        try p.resizeClip(id: clip.id, toLengthBeats: 2.5)
        tk.expectEqual(p.tracks[0].clips[0].lengthBeats, 2.5, "length updates")
        tk.expectEqual(p.tracks[0].clips[0].startBeat, 2, "start untouched on resize")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 60, "notes untouched on resize")

        try p.resizeClip(id: clip.id, toLengthBeats: 0.01)
        tk.expectEqual(p.tracks[0].clips[0].lengthBeats, Project.minimumClipLengthBeats,
                       "sub-minimum resize floored to 1/32")

        tk.expectThrows("reject zero length on resize") {
            try p.resizeClip(id: clip.id, toLengthBeats: 0)
        }
        tk.expectThrows("reject negative length on resize") {
            try p.resizeClip(id: clip.id, toLengthBeats: -0.5)
        }
        tk.expectEqual(p.tracks[0].clips[0].lengthBeats, Project.minimumClipLengthBeats,
                       "failed resize leaves length")

        tk.expectThrows("reject unknown clip on resize") {
            try p.resizeClip(id: UUID(), toLengthBeats: 1)
        }
    }

    tk.suite("Model: duplicateClip") {
        var p = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 4,
                        midiNotes: [n1, n2])
        p.tracks[0].clips = [clip]
        let copy = try p.duplicateClip(id: clip.id)

        tk.expectEqual(p.tracks[0].clips.count, 2, "two clips after duplicate")
        tk.expect(copy.id != clip.id, "copy has a new clip UUID")
        tk.expectEqual(copy.startBeat, 6, "copy placed at startBeat + lengthBeats")
        tk.expectEqual(copy.lengthBeats, 4, "length preserved")
        tk.expectEqual(copy.midiNotes?.count, 2, "notes copied")
        let originalNoteIDs = Set([n1.id, n2.id])
        let copyNoteIDs = Set((copy.midiNotes ?? []).map(\.id))
        tk.expect(originalNoteIDs.isDisjoint(with: copyNoteIDs), "every note UUID regenerated")
        tk.expectEqual(copy.midiNotes?[0].pitch, 60, "note data preserved")
        tk.expectEqual(copy.midiNotes?[1].startBeat, 1, "note starts preserved")

        // Original clip and its note ids unchanged.
        tk.expectEqual(p.tracks[0].clips[0].id, clip.id, "original clip id stable")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].id, n1.id, "original note ids stable")

        tk.expectThrows("reject unknown clip on duplicate") {
            try p.duplicateClip(id: UUID())
        }
    }

    tk.suite("Model: quantizeNotes") {
        var p = Project.newUntitled()
        // Off-grid starts: 0.3 → 0.25 (1/16), 1.1 → 1.0, near end that would snap past length.
        let notes = [
            Note(startBeat: 0.3, lengthBeats: 0.5, pitch: 60, velocity: 100),
            Note(startBeat: 1.1, lengthBeats: 0.25, pitch: 62, velocity: 100),
            Note(startBeat: 3.9, lengthBeats: 0.5, pitch: 64, velocity: 100),
        ]
        let lengths = notes.map(\.lengthBeats)
        let clip = Clip(kind: .midi, name: "q", startBeat: 0, lengthBeats: 4, midiNotes: notes)
        p.tracks[0].clips = [clip]

        try p.quantizeNotes(in: clip.id, to: 0.25) // 1/16
        let after = p.tracks[0].clips[0].midiNotes!
        tk.expectEqual(after[0].startBeat, 0.25, "0.3 snaps to nearest 1/16")
        tk.expectEqual(after[1].startBeat, 1.0, "1.1 snaps to 1.0")
        tk.expectEqual(after[2].startBeat, 4.0, "start never past clip end (clamped)")
        tk.expectEqual(after[0].lengthBeats, lengths[0], "length untouched (note 0)")
        tk.expectEqual(after[1].lengthBeats, lengths[1], "length untouched (note 1)")
        tk.expectEqual(after[2].lengthBeats, lengths[2], "length untouched (note 2)")

        // 1/8 grid
        p.tracks[0].clips[0].midiNotes = [
            Note(startBeat: 0.4, lengthBeats: 1, pitch: 60, velocity: 100),
        ]
        try p.quantizeNotes(in: clip.id, to: 0.5)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes![0].startBeat, 0.5, "0.4 snaps to 0.5 on 1/8")

        // 1/4 grid
        p.tracks[0].clips[0].midiNotes = [
            Note(startBeat: 1.4, lengthBeats: 1, pitch: 60, velocity: 100),
        ]
        try p.quantizeNotes(in: clip.id, to: 1.0)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes![0].startBeat, 1.0, "1.4 snaps to 1.0 on 1/4")

        tk.expectThrows("reject unsupported grid") {
            try p.quantizeNotes(in: clip.id, to: 1.0 / 3.0)
        }
        tk.expectThrows("reject unknown clip on quantize") {
            try p.quantizeNotes(in: UUID(), to: 0.25)
        }

        // Empty / missing notes: succeeds without mutating structure.
        let emptyClip = Clip(kind: .midi, name: "empty", startBeat: 0, lengthBeats: 4, midiNotes: [])
        p.tracks[0].clips.append(emptyClip)
        try p.quantizeNotes(in: emptyClip.id, to: 0.25)
        tk.expectEqual(p.tracks[0].clips[1].midiNotes?.count, 0, "empty note list stays empty")
    }

    tk.suite("Model: transposeNotes") {
        var p = Project.newUntitled()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [
                            Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
                            Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90),
                        ])
        p.tracks[0].clips = [clip]
        try p.transposeNotes(in: clip.id, by: 2)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 62, "C becomes D")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[1].pitch, 66, "E becomes F#")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].startBeat, 0, "starts untouched")

        // Reject rather than clamp when a pitch would leave 0–127.
        p.tracks[0].clips[0].midiNotes = [
            Note(startBeat: 0, lengthBeats: 1, pitch: 126, velocity: 100),
        ]
        tk.expectThrows("reject pitch above 127") {
            try p.transposeNotes(in: clip.id, by: 2)
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 126, "failed transpose leaves pitches unchanged")

        p.tracks[0].clips[0].midiNotes = [
            Note(startBeat: 0, lengthBeats: 1, pitch: 1, velocity: 100),
        ]
        tk.expectThrows("reject pitch below 0") {
            try p.transposeNotes(in: clip.id, by: -2)
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 1, "failed down-transpose leaves pitches unchanged")

        tk.expectThrows("reject unknown clip on transpose") {
            try p.transposeNotes(in: UUID(), by: 1)
        }

        let empty = Clip(kind: .midi, name: "empty", startBeat: 0, lengthBeats: 4, midiNotes: [])
        p.tracks[0].clips.append(empty)
        try p.transposeNotes(in: empty.id, by: 12)
        tk.expectEqual(p.tracks[0].clips[1].midiNotes?.count, 0, "empty note list stays empty")
    }

    // MARK: - Note-level helpers (Phase P1)

    tk.suite("Model: addNote") {
        var p = Project.newUntitled()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8, midiNotes: nil)
        p.tracks[0].clips = [clip]

        let id = try p.addNote(toClip: clip.id, pitch: 60, startBeat: 1, lengthBeats: 0.5, velocity: 100)
        let notes = p.tracks[0].clips[0].midiNotes!
        tk.expectEqual(notes.count, 1, "one note after add")
        tk.expectEqual(notes[0].id, id, "returned id matches stored note")
        tk.expectEqual(notes[0].pitch, 60, "pitch stored")
        tk.expectEqual(notes[0].startBeat, 1, "startBeat stored")
        tk.expectEqual(notes[0].lengthBeats, 0.5, "length stored")
        tk.expectEqual(notes[0].velocity, 100, "velocity stored")

        // Second note coexists; first untouched.
        let id2 = try p.addNote(toClip: clip.id, pitch: 64, startBeat: 2, lengthBeats: 1, velocity: 80)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?.count, 2, "two notes after second add")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].id, id, "first note id stable")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[1].id, id2, "second note returned")

        // Sub-minimum positive length is floored to 1/32 beat.
        let shortID = try p.addNote(toClip: clip.id, pitch: 67, startBeat: 0, lengthBeats: 0.01, velocity: 90)
        let short = p.tracks[0].clips[0].midiNotes!.first { $0.id == shortID }!
        tk.expectEqual(short.lengthBeats, Project.minimumNoteLengthBeats, "sub-minimum length floored to 1/32")

        tk.expectThrows("reject pitch below 0") {
            try p.addNote(toClip: clip.id, pitch: -1, startBeat: 0, lengthBeats: 1, velocity: 100)
        }
        tk.expectThrows("reject pitch above 127") {
            try p.addNote(toClip: clip.id, pitch: 128, startBeat: 0, lengthBeats: 1, velocity: 100)
        }
        tk.expectThrows("reject negative startBeat") {
            try p.addNote(toClip: clip.id, pitch: 60, startBeat: -0.25, lengthBeats: 1, velocity: 100)
        }
        tk.expectThrows("reject zero length") {
            try p.addNote(toClip: clip.id, pitch: 60, startBeat: 0, lengthBeats: 0, velocity: 100)
        }
        tk.expectThrows("reject negative length") {
            try p.addNote(toClip: clip.id, pitch: 60, startBeat: 0, lengthBeats: -1, velocity: 100)
        }
        tk.expectThrows("reject unknown clip on add") {
            try p.addNote(toClip: UUID(), pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100)
        }
        // Rejection paths must not mutate existing notes.
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?.count, 3, "failed adds leave note count unchanged")
    }

    tk.suite("Model: deleteNote") {
        var p = Project.newUntitled()
        let keep = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let drop = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [keep, drop])
        p.tracks[0].clips = [clip]

        try p.deleteNote(id: drop.id, inClip: clip.id)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?.count, 1, "one note remains")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].id, keep.id, "kept note untouched")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 60, "kept pitch untouched")

        tk.expectThrows("reject unknown note") {
            try p.deleteNote(id: drop.id, inClip: clip.id)
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?.count, 1, "failed delete leaves notes")

        tk.expectThrows("reject unknown clip on delete") {
            try p.deleteNote(id: keep.id, inClip: UUID())
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].id, keep.id, "unknown clip leaves notes")

        // nil midiNotes: note not found
        let bare = Clip(kind: .midi, name: "bare", startBeat: 0, lengthBeats: 4, midiNotes: nil)
        p.tracks[0].clips.append(bare)
        tk.expectThrows("reject note on nil midiNotes") {
            try p.deleteNote(id: keep.id, inClip: bare.id)
        }
    }

    tk.suite("Model: moveNote") {
        var p = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 2, lengthBeats: 0.5, pitch: 67, velocity: 80)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2])
        p.tracks[0].clips = [clip]

        try p.moveNote(id: n1.id, inClip: clip.id, toPitch: 72, toStartBeat: 3.5)
        let moved = p.tracks[0].clips[0].midiNotes!.first { $0.id == n1.id }!
        tk.expectEqual(moved.pitch, 72, "pitch updated")
        tk.expectEqual(moved.startBeat, 3.5, "startBeat updated")
        tk.expectEqual(moved.lengthBeats, 1, "length unchanged on move")
        // Sibling note untouched.
        let sibling = p.tracks[0].clips[0].midiNotes!.first { $0.id == n2.id }!
        tk.expectEqual(sibling.pitch, 67, "sibling pitch untouched")
        tk.expectEqual(sibling.startBeat, 2, "sibling start untouched")

        tk.expectThrows("reject pitch below 0 on move") {
            try p.moveNote(id: n1.id, inClip: clip.id, toPitch: -1, toStartBeat: 0)
        }
        tk.expectThrows("reject pitch above 127 on move") {
            try p.moveNote(id: n1.id, inClip: clip.id, toPitch: 128, toStartBeat: 0)
        }
        tk.expectThrows("reject negative startBeat on move") {
            try p.moveNote(id: n1.id, inClip: clip.id, toPitch: 60, toStartBeat: -1)
        }
        // Failed moves leave the note as last good values.
        let afterFail = p.tracks[0].clips[0].midiNotes!.first { $0.id == n1.id }!
        tk.expectEqual(afterFail.pitch, 72, "failed move leaves pitch")
        tk.expectEqual(afterFail.startBeat, 3.5, "failed move leaves start")

        tk.expectThrows("reject unknown note on move") {
            try p.moveNote(id: UUID(), inClip: clip.id, toPitch: 60, toStartBeat: 0)
        }
        tk.expectThrows("reject unknown clip on move") {
            try p.moveNote(id: n1.id, inClip: UUID(), toPitch: 60, toStartBeat: 0)
        }
    }

    tk.suite("Model: resizeNote") {
        var p = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 2, lengthBeats: 2, pitch: 64, velocity: 90)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2])
        p.tracks[0].clips = [clip]

        try p.resizeNote(id: n1.id, inClip: clip.id, toLengthBeats: 2.5)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].lengthBeats, 2.5, "length updated")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].pitch, 60, "pitch untouched on resize")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].startBeat, 0, "start untouched on resize")
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[1].lengthBeats, 2, "sibling length untouched")

        // Sub-minimum positive length floored to 1/32.
        try p.resizeNote(id: n1.id, inClip: clip.id, toLengthBeats: 0.01)
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].lengthBeats, Project.minimumNoteLengthBeats,
                       "sub-minimum resize floored to 1/32")

        tk.expectThrows("reject zero length on resize") {
            try p.resizeNote(id: n1.id, inClip: clip.id, toLengthBeats: 0)
        }
        tk.expectThrows("reject negative length on resize") {
            try p.resizeNote(id: n1.id, inClip: clip.id, toLengthBeats: -0.5)
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[0].lengthBeats, Project.minimumNoteLengthBeats,
                       "failed resize leaves length")

        tk.expectThrows("reject unknown note on resize") {
            try p.resizeNote(id: UUID(), inClip: clip.id, toLengthBeats: 1)
        }
        tk.expectThrows("reject unknown clip on resize") {
            try p.resizeNote(id: n1.id, inClip: UUID(), toLengthBeats: 1)
        }
        tk.expectEqual(p.tracks[0].clips[0].midiNotes?[1].lengthBeats, 2, "sibling still untouched after fails")
    }
}
