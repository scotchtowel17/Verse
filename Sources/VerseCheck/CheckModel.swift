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

    // MARK: - Step V6: schema v2 mediaStartSeconds + v1→v2 migration
    // (Chain now continues to current schema; mediaStartSeconds assertions unchanged.)

    tk.suite("Model V6: v1 fixture opens as current with mediaStartSeconds 0; re-saves as current") {
        // Hand-built v1 JSON: no mediaStartSeconds on the audio clip.
        let v1JSON = """
        {
          "schemaVersion": 1,
          "id": "00000000-0000-4000-8000-0000000000A1",
          "title": "Legacy Song",
          "tempoBPM": 120,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [
            {
              "id": "00000000-0000-4000-8000-0000000000B1",
              "kind": "audio",
              "name": "Audio",
              "volume": 0.8,
              "pan": 0,
              "mute": false,
              "solo": false,
              "inserts": [],
              "clips": [
                {
                  "id": "00000000-0000-4000-8000-0000000000C1",
                  "kind": "audio",
                  "name": "take",
                  "startBeat": 0,
                  "lengthBeats": 4,
                  "mediaFile": "take.caf"
                }
              ]
            }
          ],
          "masterVolume": 0.85,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z"
        }
        """
        let data = Data(v1JSON.utf8)
        let opened = try Project.fromJSON(data)
        tk.expectEqual(opened.schemaVersion, Schema.current, "v1 opens as schema \(Schema.current)")
        tk.expectEqual(opened.schemaVersion, 3, "current schema is 3")
        tk.expectEqual(opened.tracks.count, 1, "track preserved")
        tk.expectEqual(opened.tracks[0].clips.count, 1, "clip preserved")
        tk.expectEqual(opened.tracks[0].clips[0].mediaStartSeconds, 0,
                       "migrated clip defaults mediaStartSeconds to 0")
        tk.expectEqual(opened.tracks[0].clips[0].mediaFile, "take.caf", "media path preserved")
        tk.expectEqual(opened.title, "Legacy Song", "title preserved")
        tk.expectEqual(opened.tracks[0].colorIndex, 0, "v1 track gets colorIndex 0 via v2→v3")

        // Re-save is current schema and includes the field.
        let resaved = try opened.jsonData()
        let resavedObj = try JSONSerialization.jsonObject(with: resaved) as? [String: Any]
        tk.expectEqual(resavedObj?["schemaVersion"] as? Int, Schema.current,
                       "re-save writes schemaVersion \(Schema.current)")
        let clips = (resavedObj?["tracks"] as? [[String: Any]])?.first?["clips"] as? [[String: Any]]
        let mediaStart = clips?.first?["mediaStartSeconds"] as? Double
        tk.expectEqual(mediaStart, 0, "re-save includes mediaStartSeconds: 0")

        let roundTrip = try Project.fromJSON(resaved)
        tk.expectEqual(roundTrip.schemaVersion, Schema.current, "re-opens as current schema")
        tk.expectEqual(roundTrip.tracks[0].clips[0].mediaStartSeconds, 0,
                       "round-trip keeps mediaStartSeconds")
    }

    // MARK: - Step X1: schema v3 track colour identity + v2→v3 migration

    tk.suite("Model X1: palette has 8 slots; new tracks round-robin; seed is 0") {
        tk.expectEqual(TrackPalette.count, 8, "fixed 8-colour palette")
        tk.expectEqual(TrackPalette.normalized(0), 0, "0 stays 0")
        tk.expectEqual(TrackPalette.normalized(8), 0, "8 wraps to 0")
        tk.expectEqual(TrackPalette.normalized(-1), 7, "negative wraps")
        tk.expectEqual(TrackPalette.normalized(15), 7, "15 wraps to 7")

        let seed = Project.newUntitled()
        tk.expectEqual(seed.schemaVersion, 3, "new project is schema 3")
        tk.expectEqual(seed.tracks[0].colorIndex, 0, "seed piano is colour 0")
        tk.expectEqual(seed.nextTrackColorIndex, 1, "next after one track is 1")

        var p = Project(title: "colours")
        for i in 0..<10 {
            p.tracks.append(Track(kind: .instrument, name: "T\(i)",
                                  colorIndex: p.nextTrackColorIndex,
                                  instrument: .grandPiano))
        }
        for i in 0..<10 {
            tk.expectEqual(p.tracks[i].colorIndex, i % 8,
                           "track \(i) colour is \(i % 8)")
        }

        // Out-of-range init is normalized.
        let wide = Track(kind: .audio, name: "X", colorIndex: 99)
        tk.expectEqual(wide.colorIndex, 99 % 8, "init normalizes colorIndex")
    }

    tk.suite("Model X1: v2 fixture opens as v3 with colorIndex by position; re-saves as v3") {
        // Hand-built v2 JSON: has mediaStartSeconds, no colorIndex.
        let v2JSON = """
        {
          "schemaVersion": 2,
          "id": "00000000-0000-4000-8000-0000000000D1",
          "title": "Coloured",
          "tempoBPM": 100,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [
            {
              "id": "00000000-0000-4000-8000-0000000000E1",
              "kind": "instrument",
              "name": "Keys",
              "volume": 0.8,
              "pan": 0,
              "mute": false,
              "solo": false,
              "inserts": [],
              "clips": []
            },
            {
              "id": "00000000-0000-4000-8000-0000000000E2",
              "kind": "audio",
              "name": "Rec",
              "volume": 0.8,
              "pan": 0,
              "mute": false,
              "solo": false,
              "inserts": [],
              "clips": [
                {
                  "id": "00000000-0000-4000-8000-0000000000F1",
                  "kind": "audio",
                  "name": "take",
                  "startBeat": 0,
                  "lengthBeats": 4,
                  "mediaFile": "take.caf",
                  "mediaStartSeconds": 0.5
                }
              ]
            },
            {
              "id": "00000000-0000-4000-8000-0000000000E3",
              "kind": "instrument",
              "name": "Bass",
              "volume": 0.7,
              "pan": 0,
              "mute": false,
              "solo": false,
              "inserts": [],
              "clips": []
            }
          ],
          "masterVolume": 0.85,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z"
        }
        """
        let data = Data(v2JSON.utf8)
        let opened = try Project.fromJSON(data)
        tk.expectEqual(opened.schemaVersion, 3, "v2 opens as schema 3")
        tk.expectEqual(opened.tracks.count, 3, "three tracks preserved")
        tk.expectEqual(opened.tracks[0].colorIndex, 0, "position 0 → colour 0")
        tk.expectEqual(opened.tracks[1].colorIndex, 1, "position 1 → colour 1")
        tk.expectEqual(opened.tracks[2].colorIndex, 2, "position 2 → colour 2")
        tk.expectEqual(opened.tracks[1].clips[0].mediaStartSeconds, 0.5,
                       "v2 mediaStartSeconds preserved through v3")
        tk.expectEqual(opened.title, "Coloured", "title preserved")

        let resaved = try opened.jsonData()
        let resavedObj = try JSONSerialization.jsonObject(with: resaved) as? [String: Any]
        tk.expectEqual(resavedObj?["schemaVersion"] as? Int, 3, "re-save writes schemaVersion 3")
        let tracks = resavedObj?["tracks"] as? [[String: Any]]
        tk.expectEqual(tracks?[0]["colorIndex"] as? Int, 0, "re-save includes colorIndex 0")
        tk.expectEqual(tracks?[1]["colorIndex"] as? Int, 1, "re-save includes colorIndex 1")
        tk.expectEqual(tracks?[2]["colorIndex"] as? Int, 2, "re-save includes colorIndex 2")

        let roundTrip = try Project.fromJSON(resaved)
        tk.expectEqual(roundTrip.schemaVersion, 3, "v3 re-opens as v3")
        tk.expectEqual(roundTrip.tracks.map(\.colorIndex), [0, 1, 2],
                       "round-trip keeps colour indices")
    }

    tk.suite("Model X1: colorIndex round-trips in JSON") {
        var p = Project(title: "rt")
        p.tracks = [
            Track(kind: .instrument, name: "A", colorIndex: 3, instrument: .grandPiano),
            Track(kind: .audio, name: "B", colorIndex: 7),
        ]
        let back = try Project.fromJSON(try p.jsonData())
        tk.expectEqual(back.schemaVersion, Schema.current, "saved as current")
        tk.expectEqual(back.tracks[0].colorIndex, 3, "index 3 round-trips")
        tk.expectEqual(back.tracks[1].colorIndex, 7, "index 7 round-trips")
    }

    tk.suite("Model V6: new clips default mediaStartSeconds to 0; non-zero round-trips") {
        let zero = Clip(kind: .audio, name: "z", startBeat: 0, lengthBeats: 2, mediaFile: "a.caf")
        tk.expectEqual(zero.mediaStartSeconds, 0, "init default is 0")
        let offset = Clip(kind: .audio, name: "o", startBeat: 0, lengthBeats: 2,
                          mediaFile: "a.caf", mediaStartSeconds: 1.25)
        tk.expectEqual(offset.mediaStartSeconds, 1.25, "non-zero stored")

        var p = Project(title: "offset", tempoBPM: 120)
        p.tracks = [Track(kind: .audio, name: "A", clips: [offset])]
        let back = try Project.fromJSON(try p.jsonData())
        tk.expectEqual(back.schemaVersion, Schema.current, "saved as current schema")
        tk.expectEqual(back.tracks[0].clips[0].mediaStartSeconds, 1.25,
                       "non-zero mediaStartSeconds round-trips")
    }

    tk.suite("Model V6: splitAudioClip tiles offsets and lengths; refuses MIDI and edges") {
        var p = Project(title: "audio-split", tempoBPM: 120)
        // 120 BPM → 0.5 s/beat. Clip at arrangement 2…10 (length 8), media starts at 1.0 s.
        // Split at arrangement beat 6 → local 4 beats → 2.0 s of media advance.
        let orig = Clip(kind: .audio, name: "take", startBeat: 2, lengthBeats: 8,
                        mediaFile: "take.caf", mediaStartSeconds: 1.0)
        let origID = orig.id
        p.tracks = [Track(kind: .audio, name: "Audio", clips: [orig])]

        let pair = try p.splitAudioClip(id: orig.id, atBeat: 6)
        tk.expectEqual(p.tracks[0].clips.count, 2, "original replaced by two halves")
        let left = p.tracks[0].clips[0]
        let right = p.tracks[0].clips[1]
        tk.expectEqual(left.id, pair.left.id, "return matches left")
        tk.expectEqual(right.id, pair.right.id, "return matches right")
        tk.expect(left.id != origID, "left has fresh UUID")
        tk.expect(right.id != origID, "right has fresh UUID")
        tk.expect(left.id != right.id, "halves have distinct UUIDs")

        tk.expectEqual(left.startBeat, 2, "left starts where original did")
        tk.expectEqual(left.lengthBeats, 4, "left runs to playhead")
        tk.expectEqual(right.startBeat, 6, "right starts at playhead")
        tk.expectEqual(right.lengthBeats, 4, "right runs to original end")
        tk.expectEqual(left.startBeat + left.lengthBeats, right.startBeat, "no gap")
        tk.expectEqual(right.startBeat + right.lengthBeats, 10, "right end matches original end")
        tk.expectEqual(left.lengthBeats + right.lengthBeats, 8, "lengths tile original")

        tk.expectEqual(left.mediaStartSeconds, 1.0, "left keeps original media offset")
        tk.expectEqual(right.mediaStartSeconds, 1.0 + 4 * 0.5,
                       "right advances by left duration in seconds (4 beats × 0.5 s)")
        tk.expectEqual(left.mediaFile, "take.caf", "left shares media file")
        tk.expectEqual(right.mediaFile, "take.caf", "right shares media file")

        // Edges and wrong kind.
        var midiProject = Project.newUntitled()
        let midi = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        midiProject.tracks[0].clips = [midi]
        tk.expectThrows("refuse MIDI via splitAudioClip") {
            try midiProject.splitAudioClip(id: midi.id, atBeat: 2)
        }

        // Rebuild a single audio clip for edge refusals.
        var edge = Project(title: "edge", tempoBPM: 120)
        let a = Clip(kind: .audio, name: "t", startBeat: 0, lengthBeats: 4,
                     mediaFile: "t.caf", mediaStartSeconds: 0.5)
        edge.tracks = [Track(kind: .audio, name: "A", clips: [a])]
        tk.expectThrows("refuse split at exact start") {
            try edge.splitAudioClip(id: a.id, atBeat: 0)
        }
        tk.expectThrows("refuse split at exact end") {
            try edge.splitAudioClip(id: a.id, atBeat: 4)
        }
        tk.expectThrows("refuse unknown clip") {
            try edge.splitAudioClip(id: UUID(), atBeat: 2)
        }
        tk.expectEqual(edge.tracks[0].clips.count, 1, "failed splits leave clip intact")
        tk.expectEqual(edge.tracks[0].clips[0].mediaStartSeconds, 0.5,
                       "failed splits leave mediaStartSeconds")
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

    tk.suite("Model: deepCopyClip regenerates clip and note UUIDs") {
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 0.5, pitch: 64, velocity: 80)
        let original = Clip(kind: .midi, name: "src", startBeat: 4, lengthBeats: 8,
                            midiNotes: [n1, n2])
        let copy = Project.deepCopyClip(original)
        tk.expect(copy.id != original.id, "deep copy has a new clip UUID")
        tk.expectEqual(copy.startBeat, 4, "deepCopy leaves startBeat for the caller")
        tk.expectEqual(copy.lengthBeats, 8, "length preserved")
        tk.expectEqual(copy.name, "src", "name preserved")
        tk.expectEqual(copy.midiNotes?.count, 2, "notes deep-copied")
        let origIDs = Set([n1.id, n2.id])
        let copyIDs = Set((copy.midiNotes ?? []).map(\.id))
        tk.expect(origIDs.isDisjoint(with: copyIDs), "every note UUID regenerated")
        tk.expectEqual(copy.midiNotes?[0].pitch, 60, "note payload preserved")

        let audio = Clip(kind: .audio, name: "take", startBeat: 0, lengthBeats: 2,
                         mediaFile: "take-1.wav")
        let audioCopy = Project.deepCopyClip(audio)
        tk.expect(audioCopy.id != audio.id, "audio deep copy has new clip UUID")
        tk.expectEqual(audioCopy.mediaFile, "take-1.wav", "media path shared (not re-copied)")
        tk.expect(audioCopy.midiNotes == nil, "audio copy has no notes")
    }

    tk.suite("Model: removeClip and moveClip track + kind rules") {
        var p = Project.newUntitled()
        p.tracks.append(Track(kind: .audio, name: "Audio"))
        p.tracks.append(Track(kind: .instrument, name: "Lead", instrument: .grandPiano))
        let midi = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        let audio = Clip(kind: .audio, name: "take", startBeat: 0, lengthBeats: 2,
                         mediaFile: "t.wav")
        p.tracks[0].clips = [midi]
        p.tracks[1].clips = [audio]

        tk.expect(Project.trackAccepts(clipKind: .midi, trackKind: .instrument),
                  "MIDI accepts instrument")
        tk.expect(!Project.trackAccepts(clipKind: .midi, trackKind: .audio),
                  "MIDI rejects audio track")
        tk.expect(Project.trackAccepts(clipKind: .audio, trackKind: .audio),
                  "audio accepts audio")
        tk.expect(!Project.trackAccepts(clipKind: .audio, trackKind: .instrument),
                  "audio rejects instrument")

        // Move MIDI to another instrument track.
        try p.moveClip(id: midi.id, toTrackIndex: 2, startBeat: 8)
        tk.expectEqual(p.tracks[0].clips.count, 0, "MIDI left source track")
        tk.expectEqual(p.tracks[2].clips.count, 1, "MIDI on dest instrument track")
        tk.expectEqual(p.tracks[2].clips[0].startBeat, 8, "startBeat updated on cross-track move")
        tk.expectEqual(p.tracks[2].clips[0].id, midi.id, "clip id stable on move")

        tk.expectThrows("MIDI cannot land on audio track") {
            try p.moveClip(id: midi.id, toTrackIndex: 1, startBeat: 0)
        }
        tk.expectEqual(p.tracks[2].clips.count, 1, "failed move leaves clip on instrument")
        tk.expectEqual(p.tracks[1].clips.count, 1, "audio track still only has audio clip")

        tk.expectThrows("audio cannot land on instrument track") {
            try p.moveClip(id: audio.id, toTrackIndex: 0)
        }

        // Same-track start only.
        try p.moveClip(id: midi.id, toTrackIndex: 2, startBeat: 1)
        tk.expectEqual(p.tracks[2].clips[0].startBeat, 1, "same-track start update")

        try p.removeClip(id: midi.id)
        tk.expectEqual(p.tracks[2].clips.count, 0, "removeClip drops the clip")
        tk.expectThrows("remove unknown clip") {
            try p.removeClip(id: UUID())
        }

        let msg = MutationError.incompatibleClipTrack(clipKind: .midi, trackKind: .audio)
            .description
        tk.expect(msg.contains("MIDI"), "incompatible message names MIDI")
        tk.expect(msg.contains("instrument") || msg.contains("audio"),
                  "incompatible message names track kinds")
    }

    tk.suite("Model U2: splitClip divides notes; preserves total duration") {
        var p = Project.newUntitled()
        // Clip spans arrangement 4…12 (length 8). Split at arrangement beat 8 → local 4.
        // before: 0…2, crossing: 3…6 (crosses 4), after: 5…6.5
        let before = Note(startBeat: 0, lengthBeats: 2, pitch: 60, velocity: 100)
        let crossing = Note(startBeat: 3, lengthBeats: 3, pitch: 64, velocity: 90)
        let after = Note(startBeat: 5, lengthBeats: 1.5, pitch: 67, velocity: 80)
        let origTotal = before.lengthBeats + crossing.lengthBeats + after.lengthBeats
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 4, lengthBeats: 8,
                        midiNotes: [before, crossing, after])
        p.tracks[0].clips = [clip]
        let origClipID = clip.id
        let origNoteIDs = Set([before.id, crossing.id, after.id])

        let pair = try p.splitClip(id: clip.id, atArrangementBeat: 8)

        tk.expectEqual(p.tracks[0].clips.count, 2, "original replaced by two halves")
        let left = p.tracks[0].clips[0]
        let right = p.tracks[0].clips[1]
        tk.expectEqual(left.id, pair.left.id, "return matches left placement")
        tk.expectEqual(right.id, pair.right.id, "return matches right placement")
        tk.expect(left.id != origClipID, "left half has a fresh clip UUID")
        tk.expect(right.id != origClipID, "right half has a fresh clip UUID")
        tk.expect(left.id != right.id, "halves have distinct UUIDs")
        tk.expectEqual(left.startBeat, 4, "left starts where original did")
        tk.expectEqual(left.lengthBeats, 4, "left runs to playhead")
        tk.expectEqual(right.startBeat, 8, "right starts at playhead")
        tk.expectEqual(right.lengthBeats, 4, "right runs to original end")
        tk.expectEqual(left.startBeat + left.lengthBeats, right.startBeat,
                       "no gap between halves")
        tk.expectEqual(right.startBeat + right.lengthBeats, 12,
                       "right end matches original end")

        // Note partition: left has before + left half of crossing; right has right half + after.
        tk.expectEqual(left.midiNotes?.count, 2, "left: before + left of crossing")
        tk.expectEqual(right.midiNotes?.count, 2, "right: right of crossing + after")
        let leftNotes = left.midiNotes!
        let rightNotes = right.midiNotes!
        tk.expectEqual(leftNotes[0].pitch, 60, "before stays left")
        tk.expectEqual(leftNotes[0].startBeat, 0, "before start unchanged")
        tk.expectEqual(leftNotes[0].lengthBeats, 2, "before length unchanged")
        tk.expectEqual(leftNotes[1].pitch, 64, "crossing left half")
        tk.expectEqual(leftNotes[1].startBeat, 3, "crossing left keeps original start")
        tk.expectEqual(leftNotes[1].lengthBeats, 1, "crossing left ends at boundary (3→4)")
        tk.expectEqual(rightNotes[0].pitch, 64, "crossing right half")
        tk.expectEqual(rightNotes[0].startBeat, 0, "crossing right starts at 0 in new clip")
        tk.expectEqual(rightNotes[0].lengthBeats, 2, "crossing right is remainder (4→6)")
        tk.expectEqual(leftNotes[1].lengthBeats + rightNotes[0].lengthBeats, 3,
                       "crossing halves sum to original length")
        tk.expectEqual(rightNotes[1].pitch, 67, "after note on right")
        tk.expectEqual(rightNotes[1].startBeat, 1, "after rebased: 5 − 4 = 1")
        tk.expectEqual(rightNotes[1].lengthBeats, 1.5, "after length unchanged")

        let newTotal = (leftNotes + rightNotes).map(\.lengthBeats).reduce(0, +)
        tk.expectEqual(newTotal, origTotal, "total note duration preserved across split")
        let newNoteIDs = Set((leftNotes + rightNotes).map(\.id))
        tk.expectEqual(newNoteIDs.count, 4, "four notes after split (crossing became two)")
        tk.expect(origNoteIDs.isDisjoint(with: newNoteIDs), "every note UUID regenerated")
        tk.expectEqual(leftNotes.count + rightNotes.count, 4, "note count: 3 original → 4")
    }

    tk.suite("Model U2: splitClip refuses audio, edges, and missing clip") {
        var p = Project.newUntitled()
        p.tracks.append(Track(kind: .audio, name: "Audio"))
        let midi = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        let audio = Clip(kind: .audio, name: "take", startBeat: 0, lengthBeats: 4,
                         mediaFile: "t.wav")
        p.tracks[0].clips = [midi]
        p.tracks[1].clips = [audio]

        tk.expectThrows("reject audio split") {
            try p.splitClip(id: audio.id, atArrangementBeat: 2)
        }
        tk.expectEqual(p.tracks[1].clips.count, 1, "refused audio split leaves clip")
        tk.expectEqual(p.tracks[1].clips[0].id, audio.id, "audio id stable after refuse")

        tk.expectThrows("reject split at exact start") {
            try p.splitClip(id: midi.id, atArrangementBeat: 2)
        }
        tk.expectThrows("reject split at exact end") {
            try p.splitClip(id: midi.id, atArrangementBeat: 6)
        }
        tk.expectThrows("reject split before clip") {
            try p.splitClip(id: midi.id, atArrangementBeat: 1)
        }
        tk.expectThrows("reject split after clip") {
            try p.splitClip(id: midi.id, atArrangementBeat: 7)
        }
        tk.expectEqual(p.tracks[0].clips.count, 1, "failed splits leave MIDI clip intact")
        tk.expectEqual(p.tracks[0].clips[0].lengthBeats, 4, "failed splits leave length")

        tk.expectThrows("reject unknown clip on split") {
            try p.splitClip(id: UUID(), atArrangementBeat: 1)
        }

        let audioMsg = MutationError.cannotSplitAudioClip.description
        tk.expect(audioMsg.contains("Audio") || audioMsg.contains("audio"),
                  "audio refusal message names audio")
        tk.expect(audioMsg.contains("MIDI") || audioMsg.contains("can’t") || audioMsg.contains("can't"),
                  "audio refusal is plain language")
        let boundsMsg = MutationError.splitOutOfBounds.description
        tk.expect(boundsMsg.contains("playhead") || boundsMsg.contains("start") || boundsMsg.contains("end"),
                  "bounds refusal explains why")
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
