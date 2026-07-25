import Foundation
import VerseModel
import VerseAI

func runPatchChecks(_ tk: TestKit) {

    // ── Fixture 1 (Build Contract §E.6): prose + smart quotes + trailing comma → applies.
    let fixture1 = """
    Sure! Here's your patch:
    ```json
    { \u{201C}versePatch\u{201D}: { \u{201C}schema\u{201D}: \u{201C}verse-patch\u{201D}, \u{201C}version\u{201D}: 1,
      \u{201C}summary\u{201D}: \u{201C}Set tempo and add one note\u{201D},
      \u{201C}ops\u{201D}: [ {\u{201C}op\u{201D}:\u{201C}setTempo\u{201D},\u{201C}bpm\u{201D}:128}, {\u{201C}op\u{201D}:\u{201C}addMidiClip\u{201D},\u{201C}track\u{201D}:\u{201C}T1\u{201D},\u{201C}tempClipId\u{201D}:\u{201C}c1\u{201D},\u{201C}startBeat\u{201D}:0,\u{201C}lengthBeats\u{201D}:4},
               {\u{201C}op\u{201D}:\u{201C}addNotes\u{201D},\u{201C}track\u{201D}:\u{201C}T1\u{201D},\u{201C}clip\u{201D}:\u{201C}c1\u{201D},\u{201C}notes\u{201D}:[{\u{201C}startBeat\u{201D}:0,\u{201C}lengthBeats\u{201D}:1,\u{201C}pitch\u{201D}:60,\u{201C}velocity\u{201D}:100}]}, ] } }
    ```
    Let me know if you want changes!
    """

    tk.suite("verse-patch Fixture 1 — happy path (smart quotes/prose/trailing comma)") {
        var project = Project.newUntitled()   // one instrument track → handle T1
        let before = project.tempoBPM
        let outcome = Copilot.apply(reply: fixture1, to: &project)
        tk.expectEqual(outcome.status, .applied, "fixture 1 applies")
        tk.expectEqual(outcome.opCount, 3, "all 3 ops applied as one group")
        tk.expectEqual(project.tempoBPM, 128, "tempo became 128 (was \(before ?? -1))")
        let clip = project.tracks[0].clips.first
        tk.expect(clip?.kind == .midi, "midi clip c1 created on T1")
        tk.expectEqual(clip?.midiNotes?.count, 1, "one note in the clip")
        tk.expectEqual(clip?.midiNotes?.first?.pitch, 60, "the note is middle C (60)")
    }

    // ── Fixture 2 (Build Contract §E.6): invalid op + bad refs → rejected wholesale.
    let fixture2 = """
    { "versePatch": { "schema": "verse-patch", "version": 1,
      "ops": [ { "op": "setTempo", "bpm": 120 },
               { "op": "frobnicate", "track": "T1" },
               { "op": "addNotes", "track": "T99", "clip": "nope", "notes": [] } ] } }
    """

    tk.suite("verse-patch Fixture 2 — invalid op + bad ref (reject everything)") {
        var project = Project.newUntitled()
        project.tempoBPM = 95   // distinctive value to prove the valid setTempo(120) did NOT apply
        let outcome = Copilot.apply(reply: fixture2, to: &project)
        tk.expectEqual(outcome.status, .rejected, "fixture 2 rejected wholesale")
        tk.expectEqual(project.tempoBPM, 95, "nothing applied — tempo unchanged (not 120)")
        tk.expect(project.tracks[0].clips.isEmpty, "no clips created")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("frobnicate"), "reports the unknown op")
        tk.expect(joined.contains("T99"), "reports the unresolved track reference")
        tk.expect(outcome.errors.count >= 2, "lists both problems (\(outcome.errors.count))")
    }

    // ── Additional cases the spec calls for (§H).
    tk.suite("verse-patch — missing fence still parses (balanced object)") {
        var project = Project.newUntitled()
        let reply = "Here you go: { \"versePatch\": { \"schema\":\"verse-patch\",\"version\":1," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":140}] } } — enjoy!"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "fence-less patch located and applied")
        tk.expectEqual(project.tempoBPM, 140, "tempo applied")
    }

    tk.suite("verse-patch — UTF-8 BOM tolerated") {
        var project = Project.newUntitled()
        let reply = "\u{FEFF}```json\n{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[{\"op\":\"setKey\",\"tonic\":\"G\",\"mode\":\"minor\"}]}}\n```"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "BOM-prefixed reply applies")
        tk.expectEqual(project.key?.tonic, .G, "key tonic G")
        tk.expectEqual(project.key?.mode, .minor, "key mode minor")
    }

    tk.suite("verse-patch — duplicate tempId rejected") {
        var project = Project.newUntitled()
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"createTrack\",\"tempId\":\"x\",\"kind\":\"instrument\",\"name\":\"A\"}," +
            "{\"op\":\"createTrack\",\"tempId\":\"x\",\"kind\":\"instrument\",\"name\":\"B\"}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "duplicate tempId rejected")
        tk.expect(outcome.errors.contains { $0.description.contains("Duplicate") }, "reports the duplicate")
    }

    tk.suite("verse-patch — out-of-range tempo rejected") {
        var project = Project.newUntitled(); project.tempoBPM = 100
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[{\"op\":\"setTempo\",\"bpm\":999}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "999 BPM rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
    }

    tk.suite("verse-patch — no JSON at all is a clean parse error") {
        var project = Project.newUntitled()
        let outcome = Copilot.apply(reply: "Sorry, I can't do that right now.", to: &project)
        tk.expectEqual(outcome.status, .parseError, "no JSON → parse error (not a crash)")
    }

    tk.suite("verse-patch — request builder emits a fenced json block") {
        let project = Project.newUntitled()
        let req = Copilot.buildRequest(project: project, userPrompt: "Add a bass line")
        tk.expect(req.contains("```json"), "request includes a fenced json block")
        tk.expect(req.contains("verseRequest"), "request carries the verseRequest object")
        tk.expect(req.contains("\"T1\""), "tracks carry positional handles")
    }

    tk.suite("verse-patch — clamps volume/pan and reports it") {
        var project = Project.newUntitled()
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"setTrackMix\",\"track\":\"T1\",\"volume\":2.0,\"pan\":-9}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "mix op applies with clamping")
        tk.expectEqual(project.tracks[0].volume, 1.0, "volume clamped to 1.0")
        tk.expectEqual(project.tracks[0].pan, -1.0, "pan clamped to -1.0")
        tk.expect(!outcome.clamps.isEmpty, "clamps were reported")
    }

    // ── A3 corrections: existing-clip ops, ownership check, unresolvable refs.
    tk.suite("verse-patch — addNotes to an existing clip adds notes") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Existing", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"addNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"notes\":[" +
            "{\"startBeat\":1,\"lengthBeats\":1,\"pitch\":64,\"velocity\":90}]}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "addNotes on existing clip applies")
        tk.expectEqual(project.tracks[0].clips.count, 1, "still one clip")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 2, "original note plus one new note")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.last?.pitch, 64, "new note pitch is 64")
    }

    tk.suite("verse-patch — deleteClip on an existing clip removes it") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Keep", startBeat: 0, lengthBeats: 2, midiNotes: []),
            Clip(kind: .midi, name: "Drop", startBeat: 2, lengthBeats: 2, midiNotes: [])
        ]
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"deleteClip\",\"track\":\"T1\",\"clip\":\"T1C2\"}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "deleteClip on existing clip applies")
        tk.expectEqual(project.tracks[0].clips.count, 1, "one clip remains")
        tk.expectEqual(project.tracks[0].clips[0].name, "Keep", "the kept clip is the first one")
    }

    tk.suite("verse-patch — clip handle naming the wrong track is rejected") {
        var project = Project.newUntitled()
        // T1 has no clips; T2 has clip T2C1. Op claims track T1 with clip T2C1.
        project.tracks.append(Track(kind: .instrument, name: "Second", instrument: .grandPiano))
        project.tracks[1].clips = [
            Clip(kind: .midi, name: "On T2", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"deleteClip\",\"track\":\"T1\",\"clip\":\"T2C1\"}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "mismatched track/clip rejected")
        tk.expectEqual(project.tracks[1].clips.count, 1, "clip on T2 was not deleted")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("T2C1"), "error names the clip handle")
        tk.expect(joined.contains("T1"), "error names the track handle")
        tk.expect(joined.contains("isn't on track"), "error is the ownership mismatch message")
    }

    tk.suite("verse-patch — unresolvable reference is a rejection, not silent success") {
        var project = Project.newUntitled()
        project.tempoBPM = 88
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1,\"ops\":[" +
            "{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"addNotes\",\"track\":\"T1\",\"clip\":\"T1C9\",\"notes\":[" +
            "{\"startBeat\":0,\"lengthBeats\":1,\"pitch\":60,\"velocity\":100}]}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown clip handle rejects the whole patch")
        tk.expectEqual(project.tempoBPM, 88, "setTempo did not apply (transactional reject)")
        tk.expect(project.tracks[0].clips.isEmpty, "no clips created as a side effect")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("T1C9"), "reports the unresolvable clip")
    }
}
