import Foundation
import VerseModel
import VerseAI

/// Build a minimal versePatch reply with a live project fingerprint and the given ops JSON array body.
private func patchWithFingerprint(_ project: Project, opsJSON: String,
                                  summary: String? = nil) -> String {
    let fp = project.structuralFingerprint
    var fields = "\"schema\":\"verse-patch\",\"version\":1,\"fingerprint\":\"\(fp)\""
    if let summary {
        fields += ",\"summary\":\"\(summary)\""
    }
    fields += ",\"ops\":\(opsJSON)"
    return "{\"versePatch\":{\(fields)}}"
}

func runPatchChecks(_ tk: TestKit) {

    // ── Fixture 1 (Build Contract §E.6): prose + smart quotes + trailing comma → applies.
    tk.suite("verse-patch Fixture 1 — happy path (smart quotes/prose/trailing comma)") {
        var project = Project.newUntitled()   // one instrument track → handle T1
        let fp = project.structuralFingerprint
        let fixture1 = """
        Sure! Here's your patch:
        ```json
        { \u{201C}versePatch\u{201D}: { \u{201C}schema\u{201D}: \u{201C}verse-patch\u{201D}, \u{201C}version\u{201D}: 1,
          \u{201C}fingerprint\u{201D}: \u{201C}\(fp)\u{201D},
          \u{201C}summary\u{201D}: \u{201C}Set tempo and add one note\u{201D},
          \u{201C}ops\u{201D}: [ {\u{201C}op\u{201D}:\u{201C}setTempo\u{201D},\u{201C}bpm\u{201D}:128}, {\u{201C}op\u{201D}:\u{201C}addMidiClip\u{201D},\u{201C}track\u{201D}:\u{201C}T1\u{201D},\u{201C}tempClipId\u{201D}:\u{201C}c1\u{201D},\u{201C}startBeat\u{201D}:0,\u{201C}lengthBeats\u{201D}:4},
                   {\u{201C}op\u{201D}:\u{201C}addNotes\u{201D},\u{201C}track\u{201D}:\u{201C}T1\u{201D},\u{201C}clip\u{201D}:\u{201C}c1\u{201D},\u{201C}notes\u{201D}:[{\u{201C}startBeat\u{201D}:0,\u{201C}lengthBeats\u{201D}:1,\u{201C}pitch\u{201D}:60,\u{201C}velocity\u{201D}:100}]}, ] } }
        ```
        Let me know if you want changes!
        """
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
    // No fingerprint on purpose: missing fingerprint is also an error; other problems still report.
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
        let reply = "Here you go: " + patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":140}]") + " — enjoy!"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "fence-less patch located and applied")
        tk.expectEqual(project.tempoBPM, 140, "tempo applied")
    }

    tk.suite("verse-patch — UTF-8 BOM tolerated") {
        var project = Project.newUntitled()
        let body = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setKey\",\"tonic\":\"G\",\"mode\":\"minor\"}]")
        let reply = "\u{FEFF}```json\n\(body)\n```"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "BOM-prefixed reply applies")
        tk.expectEqual(project.key?.tonic, .G, "key tonic G")
        tk.expectEqual(project.key?.mode, .minor, "key mode minor")
    }

    tk.suite("verse-patch — duplicate tempId rejected") {
        var project = Project.newUntitled()
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"createTrack\",\"tempId\":\"x\",\"kind\":\"instrument\",\"name\":\"A\"}," +
            "{\"op\":\"createTrack\",\"tempId\":\"x\",\"kind\":\"instrument\",\"name\":\"B\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "duplicate tempId rejected")
        tk.expect(outcome.errors.contains { $0.description.contains("Duplicate") }, "reports the duplicate")
    }

    tk.suite("verse-patch — out-of-range tempo rejected") {
        var project = Project.newUntitled(); project.tempoBPM = 100
        let reply = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":999}]")
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
        tk.expect(req.contains("\"fingerprint\""), "request carries a fingerprint field")
        tk.expect(req.contains(project.structuralFingerprint), "fingerprint matches the live project")
        tk.expect(req.contains("Copy the fingerprint"), "preamble tells Claude to copy the fingerprint")
    }

    tk.suite("verse-patch — clamps volume/pan and reports it") {
        var project = Project.newUntitled()
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTrackMix\",\"track\":\"T1\",\"volume\":2.0,\"pan\":-9}]")
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
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"addNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"notes\":[" +
            "{\"startBeat\":1,\"lengthBeats\":1,\"pitch\":64,\"velocity\":90}]}]")
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
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteClip\",\"track\":\"T1\",\"clip\":\"T1C2\"}]")
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
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteClip\",\"track\":\"T1\",\"clip\":\"T2C1\"}]")
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
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"addNotes\",\"track\":\"T1\",\"clip\":\"T1C9\",\"notes\":[" +
            "{\"startBeat\":0,\"lengthBeats\":1,\"pitch\":60,\"velocity\":100}]}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown clip handle rejects the whole patch")
        tk.expectEqual(project.tempoBPM, 88, "setTempo did not apply (transactional reject)")
        tk.expect(project.tracks[0].clips.isEmpty, "no clips created as a side effect")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("T1C9"), "reports the unresolvable clip")
    }

    // ── A1 project fingerprint.
    tk.suite("fingerprint — matching fingerprint passes") {
        var project = Project.newUntitled()
        let reply = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":111}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "matching fingerprint applies")
        tk.expectEqual(project.tempoBPM, 111, "tempo applied under matching fingerprint")
    }

    tk.suite("fingerprint — mismatched rejects with mismatch message") {
        var project = Project.newUntitled()
        project.tempoBPM = 90
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"fingerprint\":\"deadbeef\"," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":150}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "mismatched fingerprint rejected")
        tk.expectEqual(project.tempoBPM, 90, "nothing applied on mismatch")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("Your project changed since you copied this request. Copy a fresh one."),
                  "mismatch message is exact")
    }

    tk.suite("fingerprint — absent rejects with missing message") {
        var project = Project.newUntitled()
        project.tempoBPM = 90
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":150}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "absent fingerprint rejected")
        tk.expectEqual(project.tempoBPM, 90, "nothing applied when fingerprint missing")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains(
            "Claude left out the project code. Ask it to include the fingerprint field exactly."),
                  "missing message is exact")
    }

    tk.suite("fingerprint — tempo or title alone does not change fingerprint") {
        var project = Project.newUntitled()
        let before = project.structuralFingerprint
        tk.expectEqual(before.count, 8, "fingerprint is 8 hex characters")
        tk.expect(before.allSatisfy { $0.isHexDigit }, "fingerprint is hex")

        project.tempoBPM = 200
        project.title = "Completely Different Title"
        project.modifiedAt = Date(timeIntervalSince1970: 1)
        project.key = KeySignature(tonic: .Fs, mode: .minor)
        tk.expectEqual(project.structuralFingerprint, before,
                       "tempo/title/key/modifiedAt do not invalidate fingerprint")

        // A patch minted against the original fingerprint still applies after those edits.
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"fingerprint\":\"\(before)\"," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":133}]}}"
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "patch still applies after non-structural edits")
        tk.expectEqual(project.tempoBPM, 133, "tempo op applied")
    }

    tk.suite("fingerprint — adding or deleting a clip invalidates fingerprint") {
        var project = Project.newUntitled()
        let base = project.structuralFingerprint

        project.tracks[0].clips = [
            Clip(kind: .midi, name: "New", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let afterAdd = project.structuralFingerprint
        tk.expect(afterAdd != base, "adding a clip changes the fingerprint")

        let staleReply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"fingerprint\":\"\(base)\"," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":150}]}}"
        var projectAfterAdd = project
        let staleOutcome = Copilot.apply(reply: staleReply, to: &projectAfterAdd)
        tk.expectEqual(staleOutcome.status, .rejected, "stale fingerprint after add is rejected")
        let joinedAdd = staleOutcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joinedAdd.contains("Your project changed since you copied this request. Copy a fresh one."),
                  "add-clip mismatch uses the mismatch message")

        project.tracks[0].clips = []
        let afterDelete = project.structuralFingerprint
        tk.expectEqual(afterDelete, base, "deleting the only clip restores the original fingerprint")
        tk.expect(afterDelete != afterAdd, "delete differs from the with-clip fingerprint")

        // Fresh fingerprint after delete must apply; old with-clip fingerprint must not.
        let withClipFP = afterAdd
        let deadReply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"fingerprint\":\"\(withClipFP)\"," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":160}]}}"
        var projectEmpty = project
        projectEmpty.tempoBPM = 70
        let deadOutcome = Copilot.apply(reply: deadReply, to: &projectEmpty)
        tk.expectEqual(deadOutcome.status, .rejected, "fingerprint from deleted-clip layout is rejected")
        tk.expectEqual(projectEmpty.tempoBPM, 70, "nothing applied with deleted-clip fingerprint")
    }
}
