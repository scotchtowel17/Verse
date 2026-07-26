import Foundation
import VerseModel
import VerseAI
import VerseCommands

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

    // ── D mandatory preview: renderer is TypedOp-only; never Claude's summary.
    tk.suite("preview renderer — never emits parsed.summary") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Piano"
        let poison = "POISON_SUMMARY_MUST_NEVER_APPEAR_IN_APPROVAL"
        let reply = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":99}]",
            summary: poison)
        switch Copilot.preview(reply: reply, project: project) {
        case .failure(let outcome):
            tk.expect(false, "preview should succeed (got \(outcome.status))")
        case .success(let prep):
            tk.expect(!prep.description.contains(poison),
                      "approval text must not contain Claude’s summary")
            for line in prep.lines {
                tk.expect(!line.contains(poison), "no rendered line may contain Claude’s summary")
            }
            tk.expectEqual(prep.claudeSummary, poison,
                           "Claude summary is kept separately for a “Claude says:” label")
            tk.expect(prep.description.contains("99"), "renderer mentions the tempo value")
            tk.expect(prep.description.contains("BPM"), "renderer mentions BPM")
            // Preview must not mutate the project.
            tk.expectEqual(project.tempoBPM, 120, "preview leaves project unchanged")
        }
    }

    tk.suite("preview renderer — names the right tracks") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Piano"
        project.tracks.append(Track(kind: .instrument, name: "Bass", instrument: .grandPiano))
        project.tracks.append(Track(kind: .audio, name: "Recordings"))
        project.tracks[2].clips = [
            Clip(kind: .audio, name: "Take 1", startBeat: 0, lengthBeats: 4,
                 mediaFile: "take-abc.wav")
        ]
        // Rename T2 (Bass), mix on T1 (Piano), delete audio clip on T3 (Recordings),
        // and add many notes on a new MIDI clip on Bass.
        let opsJSON = "[" +
            "{\"op\":\"renameTrack\",\"track\":\"T2\",\"name\":\"Low End\"}," +
            "{\"op\":\"setTrackMix\",\"track\":\"T1\",\"volume\":0.5}," +
            "{\"op\":\"deleteClip\",\"track\":\"T3\",\"clip\":\"T3C1\"}," +
            "{\"op\":\"addMidiClip\",\"track\":\"T2\",\"tempClipId\":\"c1\",\"startBeat\":0,\"lengthBeats\":8}," +
            "{\"op\":\"addNotes\",\"track\":\"T2\",\"clip\":\"c1\",\"notes\":[" +
            (0..<64).map { i in
                "{\"startBeat\":\(Double(i) * 0.25),\"lengthBeats\":0.25,\"pitch\":36,\"velocity\":100}"
            }.joined(separator: ",") +
            "]}]"
        let reply = patchWithFingerprint(project, opsJSON: opsJSON,
                                         summary: "Totally wrong story about lead guitar")
        switch Copilot.preview(reply: reply, project: project) {
        case .failure(let outcome):
            tk.expect(false, "preview should succeed (got \(outcome.userMessage))")
        case .success(let prep):
            let text = prep.description
            tk.expect(!text.contains("Totally wrong story about lead guitar"),
                      "Claude summary is never approval text")
            tk.expect(text.contains("Bass"), "names the Bass track for rename")
            tk.expect(text.contains("Low End"), "names the new track name")
            tk.expect(text.contains("Piano"), "names the Piano track for mix")
            tk.expect(text.contains("Recordings"), "names the Recordings track for delete")
            tk.expect(text.contains("take-abc.wav"), "deleteClip on audio names the take")
            tk.expect(text.contains("Take 1"), "deleteClip names the clip")
            tk.expect(text.contains("64 notes") || text.contains("add 64 note"),
                      "groups large note additions into a count")
            tk.expect(!text.contains("pitch"), "does not dump individual note pitches")
            // Still not applied.
            tk.expectEqual(project.tracks[1].name, "Bass", "preview does not rename")
            tk.expectEqual(project.tracks[2].clips.count, 1, "preview does not delete")
        }
    }

    tk.suite("preview renderer — includes clamp notices") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Piano"
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTrackMix\",\"track\":\"T1\",\"volume\":2.0,\"pan\":-9}]")
        switch Copilot.preview(reply: reply, project: project) {
        case .failure:
            tk.expect(false, "preview should succeed with clamps")
        case .success(let prep):
            tk.expect(prep.lines.contains { $0.localizedCaseInsensitiveContains("clamp") },
                      "clamp notices appear in rendered lines")
            tk.expect(prep.description.contains("Piano"), "still names the track")
        }
    }

    tk.suite("commit — re-checks fingerprint after structural change") {
        var project = Project.newUntitled()
        let reply = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":150}]")
        guard case .success(let prep) = Copilot.preview(reply: reply, project: project) else {
            tk.expect(false, "preview should succeed before commit test")
            return
        }
        // Structural change while the sheet would be open: add a clip.
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Intruder", startBeat: 0, lengthBeats: 2, midiNotes: [])
        ]
        let outcome = Copilot.commit(prep, to: &project)
        tk.expectEqual(outcome.status, .rejected, "commit rejects after structural drift")
        tk.expectEqual(project.tempoBPM, 120, "tempo not applied on stale fingerprint")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("Your project changed since you copied this request. Copy a fresh one."),
                  "commit uses the mismatch message")
    }

    tk.suite("commit — applies after clean preview") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Lead"
        let reply = patchWithFingerprint(project,
            opsJSON: "[{\"op\":\"setTempo\",\"bpm\":142},{\"op\":\"renameTrack\",\"track\":\"T1\",\"name\":\"Synth\"}]",
            summary: "SHOULD_NOT_BE_APPROVAL_TEXT")
        guard case .success(let prep) = Copilot.preview(reply: reply, project: project) else {
            tk.expect(false, "preview should succeed")
            return
        }
        tk.expect(!prep.description.contains("SHOULD_NOT_BE_APPROVAL_TEXT"),
                  "approval text ignores summary before commit")
        tk.expect(prep.description.contains("Lead"), "renderer named the track before rename")
        let outcome = Copilot.commit(prep, to: &project)
        tk.expectEqual(outcome.status, .applied, "commit applies when fingerprint still matches")
        tk.expectEqual(project.tempoBPM, 142, "tempo applied")
        tk.expectEqual(project.tracks[0].name, "Synth", "rename applied")
    }

    // ── E AI expansion: quantizeNotes, transposeNotes, moveClip.
    tk.suite("verse-patch — quantizeNotes snaps note starts") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Piano"
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0.3, lengthBeats: 0.5, pitch: 60, velocity: 100),
                Note(startBeat: 1.1, lengthBeats: 0.25, pitch: 62, velocity: 100),
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"gridBeats\":0.25}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "quantizeNotes applies")
        let notes = project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(notes[0].startBeat, 0.25, "0.3 snaps to 0.25")
        tk.expectEqual(notes[1].startBeat, 1.0, "1.1 snaps to 1.0")
        tk.expectEqual(notes[0].lengthBeats, 0.5, "lengths untouched")
    }

    tk.suite("verse-patch — quantizeNotes rejects audio clips") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 4, mediaFile: "take.wav")
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"gridBeats\":0.25}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "audio quantize rejected")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.localizedCaseInsensitiveContains("midi"), "error says MIDI-only")
        tk.expect(joined.localizedCaseInsensitiveContains("audio"), "error mentions audio")
    }

    tk.suite("verse-patch — quantizeNotes rejects bad grid") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0.3, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"gridBeats\":0.333}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unsupported grid rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].startBeat, 0.3, "notes unchanged")
    }

    tk.suite("verse-patch — quantizeNotes accepts grid string 1/16") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0.3, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"grid\":\"1/16\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "string grid 1/16 applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].startBeat, 0.25, "snapped on 1/16")
    }

    tk.suite("verse-patch — quantizeNotes accepts 1/32 and triplet strings (Z2)") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0.1, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let reply32 = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"grid\":\"1/32\"}]")
        let out32 = Copilot.apply(reply: reply32, to: &project)
        tk.expectEqual(out32.status, .applied, "string grid 1/32 applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].startBeat, 0.125, "snapped on 1/32")

        project.tracks[0].clips[0].midiNotes = [
            Note(startBeat: 0.4, lengthBeats: 1, pitch: 60, velocity: 100)
        ]
        let replyT = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"grid\":\"1/4T\"}]")
        let outT = Copilot.apply(reply: replyT, to: &project)
        tk.expectEqual(outT.status, .applied, "string grid 1/4T applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].startBeat, SnapGrid.quarterTriplet,
                       "snapped on 1/4T")
    }

    tk.suite("verse-patch — transposeNotes shifts pitches") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
                Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90),
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"transposeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"semitones\":-2}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "transposeNotes applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].pitch, 58, "60 → 58")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[1].pitch, 62, "64 → 62")
    }

    tk.suite("verse-patch — transposeNotes rejects out-of-range pitches") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 120, velocity: 100),
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"transposeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"semitones\":12}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "out-of-range transpose rejected (not clamped)")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].pitch, 120, "pitch unchanged")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("0–127") || joined.contains("0-127") || joined.contains("MIDI"),
                  "error mentions MIDI range")
    }

    tk.suite("verse-patch — transposeNotes rejects audio clips") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 4, mediaFile: "take.wav")
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"transposeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"semitones\":3}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "audio transpose rejected")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.localizedCaseInsensitiveContains("midi"), "error says MIDI-only")
    }

    tk.suite("verse-patch — moveClip updates startBeat") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"startBeat\":8}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "moveClip applies")
        tk.expectEqual(project.tracks[0].clips[0].startBeat, 8, "startBeat is 8")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "notes preserved")
    }

    tk.suite("verse-patch — moveClip works on audio clips") {
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .audio, name: "Recordings"))
        project.tracks[1].clips = [
            Clip(kind: .audio, name: "Take 1", startBeat: 0, lengthBeats: 4, mediaFile: "take.wav")
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClip\",\"track\":\"T2\",\"clip\":\"T2C1\",\"startBeat\":16}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "moveClip on audio applies")
        tk.expectEqual(project.tracks[1].clips[0].startBeat, 16, "audio clip startBeat is 16")
    }

    tk.suite("verse-patch — moveClip rejects negative startBeat") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 4, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"startBeat\":-1}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "negative startBeat rejected")
        tk.expectEqual(project.tracks[0].clips[0].startBeat, 4, "startBeat unchanged")
    }

    tk.suite("preview renderer — describes expansion ops") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Keys"
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0.3, lengthBeats: 1, pitch: 60, velocity: 100),
            ])
        ]
        let opsJSON = "[" +
            "{\"op\":\"quantizeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"gridBeats\":0.25}," +
            "{\"op\":\"transposeNotes\",\"track\":\"T1\",\"clip\":\"T1C1\",\"semitones\":5}," +
            "{\"op\":\"moveClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"startBeat\":8}" +
            "]"
        let reply = patchWithFingerprint(project, opsJSON: opsJSON, summary: "POISON_SUMMARY_EXPANSION")
        switch Copilot.preview(reply: reply, project: project) {
        case .failure(let outcome):
            tk.expect(false, "preview should succeed (got \(outcome.userMessage))")
        case .success(let prep):
            let text = prep.description
            tk.expect(!text.contains("POISON_SUMMARY_EXPANSION"), "summary never in approval text")
            tk.expect(text.localizedCaseInsensitiveContains("quantize"), "mentions quantize")
            tk.expect(text.localizedCaseInsensitiveContains("1/16"), "names the 1/16 grid")
            tk.expect(text.localizedCaseInsensitiveContains("transpose"), "mentions transpose")
            tk.expect(text.contains("5"), "names the semitone amount")
            tk.expect(text.localizedCaseInsensitiveContains("move"), "mentions move")
            tk.expect(text.contains("8"), "names the destination beat")
            tk.expect(text.contains("Keys"), "names the track")
            tk.expect(text.contains("Hook"), "names the clip")
            // Preview must not mutate.
            tk.expectEqual(project.tracks[0].clips[0].startBeat, 0, "preview leaves startBeat")
            tk.expectEqual(project.tracks[0].clips[0].midiNotes?[0].pitch, 60, "preview leaves pitch")
        }
    }

    tk.suite("request builder — capabilityOps lists expansion ops") {
        let project = Project.newUntitled()
        let req = Copilot.buildRequest(project: project, userPrompt: "Tighten the groove")
        tk.expect(req.contains("quantizeNotes"), "lists quantizeNotes")
        tk.expect(req.contains("transposeNotes"), "lists transposeNotes")
        tk.expect(req.contains("moveClip"), "lists moveClip")
        tk.expect(req.contains("resizeClip"), "lists resizeClip")
        tk.expect(req.contains("duplicateClip"), "lists duplicateClip")
        tk.expect(req.contains("splitClip"), "lists splitClip")
        tk.expect(req.contains("moveClipToTrack"), "lists moveClipToTrack")
        tk.expect(req.contains("deleteNote"), "lists deleteNote")
        tk.expect(req.contains("moveNote"), "lists moveNote")
        tk.expect(req.contains("setNoteVelocity"), "lists setNoteVelocity")
        tk.expect(!req.contains("setClipGain"), "does not list setClipGain")
        tk.expect(!req.contains("addHarmony"), "does not list addHarmony")
    }

    // ── V3 AI capability parity: resizeClip, duplicateClip, splitClip,
    //    moveClipToTrack, deleteNote, moveNote. Five tests each:
    //    happy path, bad reference, out-of-range, undo restores exactly,
    //    multi-op with one invalid applies nothing.

    // —— resizeClip ——
    tk.suite("V3 resizeClip — happy path") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"lengthBeats\":8}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "resizeClip applies")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 8, "length is 8")
    }

    tk.suite("V3 resizeClip — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C9\",\"lengthBeats\":8}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown clip rejected")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 4, "length unchanged")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("T1C9"), "error names the bad clip handle")
    }

    tk.suite("V3 resizeClip — out-of-range (below minimum, reject not clamp)") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"lengthBeats\":0.01}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "below-minimum length rejected")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 4, "length unchanged (not clamped)")
    }

    tk.suite("V3 resizeClip — undo restores exactly") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"lengthBeats\":8}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "resize applies before undo")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 8, "mutated")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 4, "undo restores length")
    }

    tk.suite("V3 resizeClip — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":140}," +
            "{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"lengthBeats\":0.01}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "setTempo did not apply")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 4, "resize did not apply")
    }

    // —— duplicateClip ——
    tk.suite("V3 duplicateClip — happy path") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let originalClipID = project.tracks[0].clips[0].id
        let originalNoteID = n1.id
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T1C1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "duplicateClip applies")
        tk.expectEqual(project.tracks[0].clips.count, 2, "two clips after duplicate")
        tk.expectEqual(project.tracks[0].clips[1].startBeat, 4, "copy starts after original")
        tk.expect(project.tracks[0].clips[1].id != originalClipID, "copy has fresh clip UUID")
        tk.expect(project.tracks[0].clips[1].midiNotes?.first?.id != originalNoteID,
                  "copy has fresh note UUID")
        tk.expectEqual(project.tracks[0].clips[1].midiNotes?.first?.pitch, 60, "pitch preserved")
    }

    tk.suite("V3 duplicateClip — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T9C1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "bad clip handle rejected")
        tk.expectEqual(project.tracks[0].clips.count, 1, "no copy created")
    }

    tk.suite("V3 duplicateClip — out-of-range (mismatched track ownership)") {
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .instrument, name: "Second", instrument: .grandPiano))
        project.tracks[1].clips = [
            Clip(kind: .midi, name: "On T2", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T2C1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "ownership mismatch rejected")
        tk.expectEqual(project.tracks[1].clips.count, 1, "no extra clip on T2")
        tk.expectEqual(project.tracks[0].clips.count, 0, "no clip landed on T1")
    }

    tk.suite("V3 duplicateClip — undo restores exactly") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T1C1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "duplicate applies")
        tk.expectEqual(project.tracks[0].clips.count, 2, "two clips before undo")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips.count, 1, "undo removes the copy")
    }

    tk.suite("V3 duplicateClip — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T1C1\"}," +
            "{\"op\":\"setTempo\",\"bpm\":999}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips.count, 1, "no duplicate applied")
    }

    // —— splitClip ——
    tk.suite("V3 splitClip — happy path") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
                Note(startBeat: 5, lengthBeats: 1, pitch: 64, velocity: 90),
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"splitClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"atBeat\":4}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "splitClip applies")
        tk.expectEqual(project.tracks[0].clips.count, 2, "two halves")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 4, "left length 4")
        tk.expectEqual(project.tracks[0].clips[1].startBeat, 4, "right starts at 4")
        tk.expectEqual(project.tracks[0].clips[1].lengthBeats, 4, "right length 4")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "left has first note")
        tk.expectEqual(project.tracks[0].clips[1].midiNotes?.count, 1, "right has second note")
    }

    tk.suite("V3 splitClip — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"splitClip\",\"track\":\"T1\",\"clip\":\"T1C3\",\"atBeat\":4}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown clip rejected")
        tk.expectEqual(project.tracks[0].clips.count, 1, "still one clip")
    }

    tk.suite("V3 splitClip — out-of-range (edge / audio)") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8, midiNotes: [])
        ]
        let edgeReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"splitClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"atBeat\":0}]")
        let edgeOutcome = Copilot.apply(reply: edgeReply, to: &project)
        tk.expectEqual(edgeOutcome.status, .rejected, "split at start rejected")
        let edgeMsg = edgeOutcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(edgeMsg.localizedCaseInsensitiveContains("playhead") ||
                  edgeMsg.localizedCaseInsensitiveContains("empty half"),
                  "uses UI split-out-of-bounds wording")
        tk.expectEqual(project.tracks[0].clips.count, 1, "MIDI clip intact after edge refuse")

        project.tracks.append(Track(kind: .audio, name: "Rec"))
        project.tracks[1].clips = [
            Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 8, mediaFile: "t.wav")
        ]
        let audioReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"splitClip\",\"track\":\"T2\",\"clip\":\"T2C1\",\"atBeat\":4}]")
        let audioOutcome = Copilot.apply(reply: audioReply, to: &project)
        tk.expectEqual(audioOutcome.status, .rejected, "audio split rejected")
        let audioMsg = audioOutcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(audioMsg.localizedCaseInsensitiveContains("audio"), "mentions audio")
        tk.expectEqual(project.tracks[1].clips.count, 1, "audio clip intact")
    }

    tk.suite("V3 splitClip — undo restores exactly") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let originalID = project.tracks[0].clips[0].id
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"splitClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"atBeat\":4}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "split applies")
        tk.expectEqual(project.tracks[0].clips.count, 2, "two after split")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips.count, 1, "undo restores one clip")
        tk.expectEqual(project.tracks[0].clips[0].id, originalID, "original clip UUID restored")
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 8, "original length restored")
    }

    tk.suite("V3 splitClip — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"splitClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"atBeat\":0}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips.count, 1, "no split applied")
    }

    // —— moveClipToTrack ——
    tk.suite("V3 moveClipToTrack — happy path") {
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .instrument, name: "Keys", instrument: .grandPiano))
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let clipID = project.tracks[0].clips[0].id
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\"," +
            "\"toTrack\":\"T2\",\"startBeat\":8}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "moveClipToTrack applies")
        tk.expectEqual(project.tracks[0].clips.count, 0, "left source track")
        tk.expectEqual(project.tracks[1].clips.count, 1, "on dest track")
        tk.expectEqual(project.tracks[1].clips[0].id, clipID, "same clip UUID")
        tk.expectEqual(project.tracks[1].clips[0].startBeat, 8, "new startBeat")
    }

    tk.suite("V3 moveClipToTrack — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\",\"toTrack\":\"T9\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown dest track rejected")
        tk.expectEqual(project.tracks[0].clips.count, 1, "clip still on T1")
    }

    tk.suite("V3 moveClipToTrack — out-of-range (kind mismatch + negative start)") {
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .audio, name: "Rec"))
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let kindReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\",\"toTrack\":\"T2\"}]")
        let kindOutcome = Copilot.apply(reply: kindReply, to: &project)
        tk.expectEqual(kindOutcome.status, .rejected, "MIDI onto audio rejected")
        let kindMsg = kindOutcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(kindMsg.localizedCaseInsensitiveContains("instrument") ||
                  kindMsg.localizedCaseInsensitiveContains("MIDI"),
                  "uses UI kind-mismatch wording")
        tk.expectEqual(project.tracks[0].clips.count, 1, "still on instrument track")

        let negReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\"," +
            "\"toTrack\":\"T1\",\"startBeat\":-2}]")
        let negOutcome = Copilot.apply(reply: negReply, to: &project)
        tk.expectEqual(negOutcome.status, .rejected, "negative start rejected")
        tk.expectEqual(project.tracks[0].clips[0].startBeat, 0, "startBeat unchanged")
    }

    tk.suite("V3 moveClipToTrack — undo restores exactly") {
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .instrument, name: "Keys", instrument: .grandPiano))
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 2, lengthBeats: 4, midiNotes: [])
        ]
        let clipID = project.tracks[0].clips[0].id
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\"," +
            "\"toTrack\":\"T2\",\"startBeat\":10}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "move applies")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips.count, 1, "back on T1")
        tk.expectEqual(project.tracks[1].clips.count, 0, "gone from T2")
        tk.expectEqual(project.tracks[0].clips[0].id, clipID, "same clip")
        tk.expectEqual(project.tracks[0].clips[0].startBeat, 2, "original start")
    }

    tk.suite("V3 moveClipToTrack — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks.append(Track(kind: .audio, name: "Rec"))
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 4, midiNotes: [])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"moveClipToTrack\",\"track\":\"T1\",\"clip\":\"T1C1\",\"toTrack\":\"T2\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips.count, 1, "clip still on T1")
        tk.expectEqual(project.tracks[1].clips.count, 0, "nothing on audio track")
    }

    // —— deleteNote ——
    tk.suite("V3 deleteNote — happy path") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1, n2])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "deleteNote applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "one note left")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n2.id, "N2 remains")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 64, "pitch 64 remains")
    }

    tk.suite("V3 deleteNote — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N9\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "stale note handle rejected at validation")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "note still present")
        let joined = outcome.errors.map { $0.description }.joined(separator: " | ")
        tk.expect(joined.contains("T1C1N9"), "error names the bad note handle")
    }

    tk.suite("V3 deleteNote — out-of-range (note on wrong clip / audio)") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "A", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ]),
            Clip(kind: .midi, name: "B", startBeat: 4, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 62, velocity: 100)
            ])
        ]
        // Note T1C1N1 claimed against clip T1C2.
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C2\",\"note\":\"T1C1N1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "mismatched note/clip rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "N1 still in C1")
        tk.expectEqual(project.tracks[0].clips[1].midiNotes?.count, 1, "C2 untouched")
    }

    tk.suite("V3 deleteNote — undo restores exactly") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "delete applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 0, "deleted")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "undo restores note")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n1.id, "same note UUID")
    }

    tk.suite("V3 deleteNote — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N9\"}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 1, "note still there")
    }

    // —— moveNote ——
    tk.suite("V3 moveNote — happy path") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":72,\"startBeat\":2}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "moveNote applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n1.id, "same note UUID")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 72, "pitch 72")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.startBeat, 2, "start 2")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.lengthBeats, 1, "length untouched")
    }

    tk.suite("V3 moveNote — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N3\"," +
            "\"pitch\":64,\"startBeat\":1}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown note rejected at validation")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 60, "pitch unchanged")
    }

    tk.suite("V3 moveNote — out-of-range (pitch / negative start)") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let pitchReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":200,\"startBeat\":1}]")
        let pitchOutcome = Copilot.apply(reply: pitchReply, to: &project)
        tk.expectEqual(pitchOutcome.status, .rejected, "pitch 200 rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 60, "pitch unchanged")

        let negReply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":64,\"startBeat\":-1}]")
        let negOutcome = Copilot.apply(reply: negReply, to: &project)
        tk.expectEqual(negOutcome.status, .rejected, "negative start rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.startBeat, 0, "start unchanged")
    }

    tk.suite("V3 moveNote — undo restores exactly") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":72,\"startBeat\":3}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "move applies")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 60, "undo pitch")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.startBeat, 0, "undo start")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n1.id, "same UUID")
    }

    tk.suite("V3 moveNote — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":200,\"startBeat\":1}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 60, "note unchanged")
    }

    // —— setNoteVelocity (Z1) ——
    tk.suite("Z1 setNoteVelocity — happy path") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":42}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "setNoteVelocity applies")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n1.id, "same note UUID")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 42, "velocity 42")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.pitch, 60, "pitch untouched")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.startBeat, 0, "start untouched")
    }

    tk.suite("Z1 setNoteVelocity — bad reference") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N3\"," +
            "\"velocity\":64}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "unknown note rejected at validation")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 100, "velocity unchanged")
    }

    tk.suite("Z1 setNoteVelocity — out-of-range rejected") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let zero = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":0}]")
        tk.expectEqual(Copilot.apply(reply: zero, to: &project).status, .rejected, "velocity 0 rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 100, "unchanged after 0")

        let high = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":128}]")
        tk.expectEqual(Copilot.apply(reply: high, to: &project).status, .rejected, "velocity 128 rejected")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 100, "unchanged after 128")
    }

    tk.suite("Z1 setNoteVelocity — undo restores exactly") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [n1])
        ]
        let stack = UndoStack<Project>()
        stack.record(project, name: "Apply Claude patch")
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":55}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .applied, "set applies")
        if let restored = stack.undo(current: project) { project = restored }
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 100, "undo velocity")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.id, n1.id, "same UUID")
    }

    tk.suite("Z1 setNoteVelocity — multi-op with invalid applies nothing") {
        var project = Project.newUntitled()
        project.tempoBPM = 100
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let reply = patchWithFingerprint(project, opsJSON:
            "[{\"op\":\"setTempo\",\"bpm\":150}," +
            "{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":200}]")
        let outcome = Copilot.apply(reply: reply, to: &project)
        tk.expectEqual(outcome.status, .rejected, "whole patch rejected")
        tk.expectEqual(project.tempoBPM, 100, "tempo unchanged")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes?.first?.velocity, 100, "note unchanged")
    }

    tk.suite("V3 preview renderer — describes parity ops") {
        var project = Project.newUntitled()
        project.tracks[0].name = "Piano"
        project.tracks.append(Track(kind: .instrument, name: "Keys", instrument: .grandPiano))
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Hook", startBeat: 0, lengthBeats: 8, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
                Note(startBeat: 2, lengthBeats: 1, pitch: 64, velocity: 90),
            ])
        ]
        // Preview only: resize + duplicate + moveNote (no split so handles stay valid in one patch
        // of independent descriptions; renderer is per-op from TypedOp).
        let opsJSON = "[" +
            "{\"op\":\"resizeClip\",\"track\":\"T1\",\"clip\":\"T1C1\",\"lengthBeats\":6}," +
            "{\"op\":\"duplicateClip\",\"track\":\"T1\",\"clip\":\"T1C1\"}," +
            "{\"op\":\"moveNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"pitch\":72,\"startBeat\":1}," +
            "{\"op\":\"setNoteVelocity\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N1\"," +
            "\"velocity\":88}," +
            "{\"op\":\"deleteNote\",\"track\":\"T1\",\"clip\":\"T1C1\",\"note\":\"T1C1N2\"}" +
            "]"
        let reply = patchWithFingerprint(project, opsJSON: opsJSON, summary: "POISON_V3_SUMMARY")
        switch Copilot.preview(reply: reply, project: project) {
        case .failure(let outcome):
            tk.expect(false, "preview should succeed (got \(outcome.userMessage))")
        case .success(let prep):
            let text = prep.description
            tk.expect(!text.contains("POISON_V3_SUMMARY"), "summary never in approval text")
            tk.expect(text.localizedCaseInsensitiveContains("resize"), "mentions resize")
            tk.expect(text.contains("6"), "names new length")
            tk.expect(text.localizedCaseInsensitiveContains("duplicate"), "mentions duplicate")
            tk.expect(text.localizedCaseInsensitiveContains("move"), "mentions move note")
            tk.expect(text.contains("72"), "names pitch")
            tk.expect(text.localizedCaseInsensitiveContains("velocity"), "mentions velocity")
            tk.expect(text.contains("88"), "names velocity value")
            tk.expect(text.localizedCaseInsensitiveContains("delete"), "mentions delete note")
            tk.expect(text.contains("Hook"), "names the clip")
            tk.expectEqual(project.tracks[0].clips[0].lengthBeats, 8, "preview leaves length")
            tk.expectEqual(project.tracks[0].clips[0].midiNotes?.count, 2, "preview leaves notes")
        }
    }

    tk.suite("V3 request builder — exposes note handles") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 4, midiNotes: [
                Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
            ])
        ]
        let req = Copilot.buildRequest(project: project, userPrompt: "Delete the first note")
        tk.expect(req.contains("T1C1N1"), "request exposes note handle T1C1N1")
        tk.expect(req.contains("note ids"), "instructions mention note ids")
    }
}
