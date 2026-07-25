import Foundation
import VerseModel
import VerseAI
import VerseMIDI

// MARK: - Seeded deterministic PRNG (Step H2)

/// SplitMix64-style generator. Same seed always yields the same sequence.
/// Never use `Date()`, `SystemRandomNumberGenerator`, or unseeded `UUID()` for fuzz inputs.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // Zero seed is legal but collapses SplitMix; remap so seed 0 still runs.
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: nextUInt64())
    }

    mutating func nextBool() -> Bool {
        nextUInt64() & 1 == 1
    }

    /// Inclusive range. Precondition: range is non-empty.
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = UInt64(upper - lower + 1)
        return lower + Int(nextUInt64() % span)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let u = Double(nextUInt64() >> 11) * (1.0 / Double(1 << 53))
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func nextBytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in nextByte() }
    }

    /// Deterministic UUID from the stream (not Foundation `UUID()`).
    mutating func nextUUID() -> UUID {
        var bytes = nextBytes(count: 16)
        // RFC 4122 version-4 + variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[nextInt(in: 0...(items.count - 1))]
    }
}

// MARK: - Entry

func runFuzzChecks(_ tk: TestKit) {
    runPatchParserFuzz(tk)
    runPatchValidatorPropertyTests(tk)
    runMIDIParserFuzz(tk)
}

// MARK: - Parser invoke helper

private enum ParserOutcome {
    case parsed(PatchParser.ParsedPatch)
    case parseError(PatchParser.ParseError)
    case unexpected(Error)
}

private func invokeParser(_ input: String) -> ParserOutcome {
    do {
        return .parsed(try PatchParser.parse(input))
    } catch let e as PatchParser.ParseError {
        return .parseError(e)
    } catch {
        return .unexpected(error)
    }
}

/// Build a `ParsedPatch` via the public parser (no public memberwise init on the struct).
private func makeParsed(schema: String? = "verse-patch",
                        version: Int? = 1,
                        fingerprint: String? = nil,
                        summary: String? = nil,
                        ops: [[String: Any]]) -> PatchParser.ParsedPatch? {
    var patch: [String: Any] = ["ops": ops]
    if let schema { patch["schema"] = schema }
    if let version { patch["version"] = version }
    if let fingerprint { patch["fingerprint"] = fingerprint }
    if let summary { patch["summary"] = summary }
    let top: [String: Any] = ["versePatch": patch]
    guard let data = try? JSONSerialization.data(withJSONObject: top),
          let str = String(data: data, encoding: .utf8),
          let parsed = try? PatchParser.parse(str) else {
        return nil
    }
    return parsed
}

// MARK: - 1. PatchParser fuzz

private func runPatchParserFuzz(_ tk: TestKit) {
    tk.suite("H2 PatchParser fuzz — fixed adversarial corpus") {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("whitespace", "   \n\t  "),
            ("truncated object",
             #"{"versePatch":{"schema":"verse-patch","version":1,"ops":[{"op":"setTempo""#),
            ("unbalanced braces", #"{{{"versePatch": {"ops": []}}"#),
            ("unbalanced brackets", #"{"versePatch":{"ops":[[{"op":"setTempo"}]}"#),
            ("deeply nested", deepNestedJSON(depth: 80)),
            ("enormous string", enormousStringCase(charCount: 50_000)),
            ("NUL in middle", "hello\u{0000}{\"versePatch\":{\"ops\":[]}}"),
            ("emoji", "🎵 patch please 🎶 {\"versePatch\":{\"ops\":[]}} 🎸"),
            ("RTL", "\u{200F}العربية\u{200E} {\"versePatch\":{\"schema\":\"verse-patch\",\"ops\":[]}}"),
            ("HTML", #"<div class="x">{"versePatch":{"ops":[]}}</div>"#),
            ("multiple fenced blocks", """
                ```json
                {"noise": true}
                ```
                and then
                ```json
                {"versePatch":{"schema":"verse-patch","version":1,"ops":[]}}
                ```
                """),
            ("fence with no closing fence", "```json\n{\"versePatch\":{\"ops\":[]}}\n"),
            ("comment inside string",
             #"{"versePatch":{"summary":"a // not a comment","ops":[]}}"#),
            ("trailing commas everywhere",
             #"{"versePatch":{"schema":"verse-patch","version":1,"ops":[{"op":"setTempo","bpm":120,},],},}"#),
            ("only prose", "Sorry, I cannot help with that request."),
            ("array top level", #"[1,2,3]"#),
            ("versePatch not object", #"{"versePatch":"nope"}"#),
            ("ops not array", #"{"versePatch":{"ops":{}}}"#),
            ("ops null", #"{"versePatch":{"ops":null}}"#),
            ("smart quotes only", "\u{201C}versePatch\u{201D}: {}"),
            ("BOM only", "\u{FEFF}"),
            ("nested braces in string",
             #"{"versePatch":{"summary":"use { and } freely","ops":[]}}"#),
            ("escaped quotes", #"{"versePatch":{"summary":"say \"hi\"","ops":[]}}"#),
            ("line comments", "{\n// header\n\"versePatch\":{\"ops\":[] // end\n}\n}"),
            // Lossily-decoded invalid UTF-8 becomes U+FFFD; still must not crash.
            ("replacement chars", String(decoding: [0xFF, 0xFE, 0x80, 0x61], as: UTF8.self)
                + #"{"versePatch":{"ops":[]}}"#),
        ]

        var ok = 0
        for (label, input) in cases {
            switch invokeParser(input) {
            case .parsed, .parseError:
                ok += 1
            case .unexpected(let err):
                tk.expect(false, "corpus \(label)", "unexpected non-ParseError: \(err)")
            }
        }
        tk.expectEqual(ok, cases.count,
                       "all \(cases.count) corpus cases returned ParsedPatch or ParseError")
    }

    tk.suite("H2 PatchParser fuzz — seeded random inputs (seed 0xA11CE001)") {
        var rng = SeededRNG(seed: 0xA11CE001)
        let trialCount = 200
        var ok = 0
        for trial in 0..<trialCount {
            let input = randomParserInput(rng: &rng)
            switch invokeParser(input) {
            case .parsed, .parseError:
                ok += 1
            case .unexpected(let err):
                tk.expect(false, "random trial \(trial)",
                          "unexpected non-ParseError (seed 0xA11CE001 trial \(trial)): \(err)")
            }
        }
        tk.expectEqual(ok, trialCount,
                       "\(trialCount)/\(trialCount) random trials returned ParsedPatch or ParseError")
    }

    // Sanity: a well-formed patch still parses (proves the harness is not all-reject).
    tk.suite("H2 PatchParser fuzz — well-formed control case") {
        let good = #"{"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"deadbeef","ops":[{"op":"setTempo","bpm":120}]}}"#
        switch invokeParser(good) {
        case .parsed(let p):
            tk.expectEqual(p.ops.count, 1, "control case yields one op")
            tk.expectEqual(p.schema, "verse-patch", "control schema")
        case .parseError(let e):
            tk.expect(false, "control case parses", "got \(e)")
        case .unexpected(let err):
            tk.expect(false, "control case parses", "unexpected \(err)")
        }
    }
}

private func deepNestedJSON(depth: Int) -> String {
    var s = ""
    for _ in 0..<depth { s += "{\"a\":" }
    s += "1"
    for _ in 0..<depth { s += "}" }
    return "{\"outer\":" + s + ",\"versePatch\":{\"ops\":[]}}"
}

private func enormousStringCase(charCount: Int) -> String {
    let filler = String(repeating: "x", count: charCount)
    return "{\"versePatch\":{\"summary\":\"\(filler)\",\"ops\":[]}}"
}

private func randomParserInput(rng: inout SeededRNG) -> String {
    switch rng.nextInt(in: 0...9) {
    case 0:
        let len = rng.nextInt(in: 0...400)
        var s = ""
        for _ in 0..<len {
            let code = rng.nextInt(in: 1...0x10FF)
            if let u = UnicodeScalar(code), u.value != 0xFFFE, u.value != 0xFFFF {
                s.unicodeScalars.append(u)
            } else {
                s.append("?")
            }
        }
        return s
    case 1:
        let full = #"{"versePatch":{"schema":"verse-patch","version":1,"ops":[{"op":"setTempo","bpm":100}]}}"#
        let cut = rng.nextInt(in: 0...full.count)
        return String(full.prefix(cut))
    case 2:
        let body = rng.nextBool()
            ? #"{"versePatch":{"ops":[]}}"#
            : #"{"noise":true}"#
        let open = rng.nextBool() ? "```json\n" : "```\n"
        let close = rng.nextBool() ? "\n```" : ""
        return "prose \(rng.nextInt(in: 0...999))\n" + open + body + close
    case 3:
        return """
            // leading
            {"versePatch":{"schema":"verse-patch","ops":[
              {"op":"setTempo","bpm":\(rng.nextInt(in: 0...400)),},
            ],},}
            """
    case 4:
        return """
            {"a":1} then {"versePatch":{"ops":[{"op":"nope"}]}} and {"b":2}
            """
    case 5:
        let len = rng.nextInt(in: 0...300)
        return String((0..<len).map { _ in
            Character(UnicodeScalar(rng.nextInt(in: 32...126))!)
        })
    case 6:
        return deepNestedJSON(depth: rng.nextInt(in: 1...40))
    case 7:
        var s = #"{"versePatch":{"ops":[]}}"#
        if rng.nextBool() {
            let idx = s.index(s.startIndex, offsetBy: rng.nextInt(in: 0...(s.count - 1)))
            s.insert("\u{0000}", at: idx)
        }
        return s
    case 8:
        return "\u{FEFF}Sure: \u{201C}versePatch\u{201D} " +
            #"{"versePatch":{"schema":"verse-patch","ops":[]}}"#
    default:
        let bpm = rng.nextInt(in: -50...400)
        return #"{"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"aabbccdd","ops":[{"op":"setTempo","bpm":\#(bpm)}]}}"#
    }
}

// MARK: - 2. PatchValidator property tests

private func runPatchValidatorPropertyTests(_ tk: TestKit) {
    tk.suite("H2 PatchValidator property — collects all errors (no early return)") {
        var project = Project.newUntitled()
        project.tempoBPM = 95
        // Missing fingerprint, bad schema, unknown op, bad track, bad tempo: several independent errors.
        // Omitting fingerprint from JSON so parse leaves it nil.
        let json = """
            {"versePatch":{"schema":"wrong-schema","version":99,"ops":[
              {"op":"setTempo","bpm":999},
              {"op":"frobnicate","track":"T1"},
              {"op":"renameTrack","track":"T99","name":"X"},
              {"op":"setKey","tonic":"H","mode":"lydian"}
            ]}}
            """
        guard case .parsed(let parsed) = invokeParser(json) else {
            tk.expect(false, "multi-error fixture parses", "parser did not return ParsedPatch")
            return
        }
        let before = projectSnapshot(project)
        switch PatchValidator.validate(parsed, project: project) {
        case .success:
            tk.expect(false, "multi-error patch is rejected", "validator accepted a broken patch")
        case .failure(let errs):
            tk.expect(errs.errors.count >= 4,
                      "collects multiple errors (got \(errs.errors.count))")
            let joined = errs.errors.map(\.description).joined(separator: " | ")
            tk.expect(joined.contains("schema") || joined.contains("verse-patch"),
                      "reports schema problem")
            tk.expect(joined.contains("version") || joined.contains("99"),
                      "reports version problem")
            tk.expect(joined.contains("fingerprint") || joined.contains("project code"),
                      "reports missing fingerprint")
            tk.expect(joined.contains("frobnicate") || joined.contains("Unknown"),
                      "reports unknown op")
            tk.expect(joined.contains("T99") || joined.contains("Unknown track"),
                      "reports bad track")
        }
        tk.expect(projectSnapshot(project) == before,
                  "rejected validation leaves project bytes unchanged")
    }

    tk.suite("H2 PatchValidator property — random projects and ops (seed 0xBADA110C)") {
        var rng = SeededRNG(seed: 0xBADA_110C)
        let trials = 150
        var accepted = 0
        var rejected = 0
        var applyOK = 0
        var multiErrorSamples = 0

        for trial in 0..<trials {
            var project = randomProject(rng: &rng)
            let before = projectSnapshot(project)
            // omitDeleteClip: sequences with deleteClip + later use of the same handle
            // trip known defect H2-VAL-1 (documented below). Random apply checks stay
            // free of that hole so this suite asserts properties that should hold today.
            let ops = randomOpDicts(project: project, rng: &rng, count: rng.nextInt(in: 0...8),
                                    omitDeleteClip: true)
            var opsWithFaults = ops
            if rng.nextBool() {
                opsWithFaults.append(["op": "notARealOp"])
                opsWithFaults.append(["op": "renameTrack", "track": "T999", "name": "Z"])
            }
            let useGoodFP = rng.nextInt(in: 0...9) != 0
            guard let parsed = makeParsed(
                fingerprint: useGoodFP ? project.structuralFingerprint : "00000000",
                summary: rng.nextBool() ? "s" : nil,
                ops: opsWithFaults
            ) else {
                tk.expect(false, "random trial \(trial) builds ParsedPatch")
                continue
            }

            switch PatchValidator.validate(parsed, project: project) {
            case .failure(let errs):
                rejected += 1
                tk.expect(!errs.errors.isEmpty, "failure has ≥1 error (trial \(trial))")
                if opsWithFaults.count >= 2 && !useGoodFP && errs.errors.count >= 2 {
                    multiErrorSamples += 1
                }
                tk.expect(projectSnapshot(project) == before,
                          "reject leaves project unchanged (trial \(trial))")
                // Snapshot equality already covers all fields including tempo.

            case .success(let ok):
                accepted += 1
                tk.expectEqual(ok.ops.count, opsWithFaults.count,
                               "typed op count matches input when all valid (trial \(trial))")
                do {
                    try PatchApplier.apply(ok.ops, to: &project)
                    applyOK += 1
                } catch {
                    tk.expect(false, "accepted ops apply without throw (trial \(trial))",
                              "apply threw: \(error)")
                }
                tk.expectNoThrow("accepted project still encodes (trial \(trial))") {
                    _ = try project.jsonData()
                }
            }
        }

        tk.expect(accepted + rejected == trials, "every trial accepted or rejected")
        tk.expect(accepted > 0, "at least one random patch accepted (\(accepted))")
        tk.expect(rejected > 0, "at least one random patch rejected (\(rejected))")
        tk.expectEqual(applyOK, accepted, "every accepted patch applied cleanly")
        tk.expect(true, "multi-error samples observed: \(multiErrorSamples)")
    }

    tk.suite("H2 PatchValidator property — two bad ops both reported") {
        let project = Project.newUntitled()
        guard let parsed = makeParsed(
            fingerprint: project.structuralFingerprint,
            ops: [
                ["op": "setTempo", "bpm": 5],
                ["op": "setTimeSignature", "num": 99, "den": 3],
            ]
        ) else {
            tk.expect(false, "two-bad-ops fixture builds ParsedPatch")
            return
        }
        let before = projectSnapshot(project)
        switch PatchValidator.validate(parsed, project: project) {
        case .success:
            tk.expect(false, "two-bad-ops rejected")
        case .failure(let errs):
            tk.expect(errs.errors.count >= 2, "both ops contribute errors (got \(errs.errors.count))")
            let joined = errs.errors.map(\.description).joined(separator: " | ")
            tk.expect(joined.contains("Tempo") || joined.contains("bpm") || joined.contains("5"),
                      "mentions tempo problem")
            tk.expect(joined.contains("Time signature") || joined.contains("num") || joined.contains("den"),
                      "mentions time-signature problem")
        }
        tk.expect(projectSnapshot(project) == before, "no mutation on multi-op reject")
    }

    // Documents known defect H2-VAL-1 (see project_plan.md). Do not “fix” this by
    // changing the production validator in this step. When the defect is fixed, this
    // suite should be rewritten to assert rejection (or successful apply) instead.
    tk.suite("H2 known defect VAL-1 — deleteClip then use same handle validates, apply throws") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Doomed", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        guard let parsed = makeParsed(
            fingerprint: project.structuralFingerprint,
            ops: [
                ["op": "deleteClip", "track": "T1", "clip": "T1C1"],
                ["op": "moveClip", "track": "T1", "clip": "T1C1", "startBeat": 8],
            ]
        ) else {
            tk.expect(false, "VAL-1 fixture builds ParsedPatch")
            return
        }
        switch PatchValidator.validate(parsed, project: project) {
        case .failure(let errs):
            // If this starts failing (validator now rejects), the defect is fixed: update plan.
            tk.expect(false, "VAL-1 still validates (defect open)",
                      "validator rejected (may be fixed): \(errs.errors.map(\.description))")
        case .success(let ok):
            tk.expectEqual(ok.ops.count, 2, "VAL-1: both ops typed despite use-after-delete")
            var threw = false
            do {
                try PatchApplier.apply(ok.ops, to: &project)
            } catch {
                threw = true
            }
            tk.expect(threw, "VAL-1: apply throws after validate accepted use-after-delete")
        }
    }
}

// MARK: - Project snapshot (byte identity for “mutates nothing”)

private func projectSnapshot(_ project: Project) -> Data {
    do {
        return try project.jsonData()
    } catch {
        return Data()
    }
}

private func decodeSnapshot(_ data: Data) -> Project {
    (try? Project.fromJSON(data)) ?? Project.newUntitled()
}

private func randomProject(rng: inout SeededRNG) -> Project {
    let trackCount = rng.nextInt(in: 1...4)
    var tracks: [Track] = []
    for t in 0..<trackCount {
        let kind: TrackKind = rng.nextBool() ? .instrument : .audio
        var track = Track(
            id: rng.nextUUID(),
            kind: kind,
            name: "T\(t)",
            volume: rng.nextDouble(in: 0...1),
            pan: rng.nextDouble(in: -1...1),
            mute: rng.nextBool(),
            solo: false,
            instrument: kind == .instrument ? .grandPiano : nil,
            clips: []
        )
        let clipCount = rng.nextInt(in: 0...3)
        for c in 0..<clipCount {
            if kind == .instrument {
                let noteCount = rng.nextInt(in: 0...4)
                var notes: [Note] = []
                for _ in 0..<noteCount {
                    notes.append(Note(
                        id: rng.nextUUID(),
                        startBeat: rng.nextDouble(in: 0...8),
                        lengthBeats: rng.nextDouble(in: 0.25...2),
                        pitch: rng.nextInt(in: 0...127),
                        velocity: rng.nextInt(in: 1...127)
                    ))
                }
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .midi,
                    name: "C\(c)",
                    startBeat: rng.nextDouble(in: 0...16),
                    lengthBeats: rng.nextDouble(in: 1...8),
                    midiNotes: notes
                ))
            } else {
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .audio,
                    name: "A\(c)",
                    startBeat: rng.nextDouble(in: 0...16),
                    lengthBeats: rng.nextDouble(in: 1...8),
                    mediaFile: "take-\(c).wav"
                ))
            }
        }
        tracks.append(track)
    }
    return Project(
        id: rng.nextUUID(),
        title: "Fuzz",
        tempoBPM: Double(rng.nextInt(in: 40...200)),
        key: rng.nextBool()
            ? KeySignature(tonic: rng.pick(Array(Tonic.allCases)), mode: rng.pick(Array(Mode.allCases)))
            : nil,
        timeSignature: TimeSignature(num: rng.pick([2, 3, 4, 6]), den: rng.pick([4, 8])),
        tracks: tracks,
        masterVolume: 0.85,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0)
    )
}

private func randomOpDicts(project: Project, rng: inout SeededRNG, count: Int,
                           omitDeleteClip: Bool = false) -> [[String: Any]] {
    var ops: [[String: Any]] = []
    var tempTracks: [String] = []
    var tempClips: [(tempId: String, track: String)] = []
    let trackHandles = (0..<project.tracks.count).map { "T\($0 + 1)" }

    for i in 0..<count {
        var choice = rng.nextInt(in: 0...12)
        // case 9 is deleteClip; remap when omitted (H2-VAL-1 isolation).
        if omitDeleteClip && choice == 9 { choice = 0 }
        switch choice {
        case 0:
            ops.append(["op": "setTempo", "bpm": rng.nextDouble(in: 20...300)])
        case 1:
            let tonic = rng.pick(Array(Tonic.allCases)).rawValue
            let mode = rng.pick(Array(Mode.allCases)).rawValue
            ops.append(["op": "setKey", "tonic": tonic, "mode": mode])
        case 2:
            ops.append([
                "op": "setTimeSignature",
                "num": rng.nextInt(in: 1...16),
                "den": rng.pick([1, 2, 4, 8, 16]),
            ])
        case 3:
            let temp = "tmp\(i)"
            tempTracks.append(temp)
            ops.append([
                "op": "createTrack",
                "tempId": temp,
                "kind": rng.nextBool() ? "instrument" : "audio",
                "name": "New\(i)",
            ])
        case 4:
            let ref = pickTrackRef(trackHandles: trackHandles, tempTracks: tempTracks, rng: &rng)
            ops.append(["op": "renameTrack", "track": ref, "name": "Renamed\(i)"])
        case 5:
            let ref = pickTrackRef(trackHandles: trackHandles, tempTracks: tempTracks, rng: &rng)
            ops.append(["op": "setInstrument", "track": ref, "program": rng.nextInt(in: 0...127)])
        case 6:
            let ref = pickTrackRef(trackHandles: trackHandles, tempTracks: tempTracks, rng: &rng)
            ops.append([
                "op": "setTrackMix",
                "track": ref,
                "volume": rng.nextDouble(in: -0.5...1.5),
                "pan": rng.nextDouble(in: -2...2),
            ])
        case 7:
            let ref = pickTrackRef(trackHandles: trackHandles, tempTracks: tempTracks, rng: &rng)
            let tc = "c\(i)"
            tempClips.append((tc, ref))
            ops.append([
                "op": "addMidiClip",
                "track": ref,
                "tempClipId": tc,
                "startBeat": rng.nextDouble(in: 0...16),
                "lengthBeats": rng.nextDouble(in: 0.5...8),
            ])
        case 8:
            if let clip = pickClipRef(project: project, tempClips: tempClips, rng: &rng) {
                ops.append([
                    "op": "addNotes",
                    "track": clip.track,
                    "clip": clip.clip,
                    "notes": [[
                        "startBeat": rng.nextDouble(in: 0...4),
                        "lengthBeats": rng.nextDouble(in: 0.25...2),
                        "pitch": rng.nextInt(in: 0...127),
                        "velocity": rng.nextInt(in: 1...127),
                    ]],
                ])
            } else {
                ops.append(["op": "setTempo", "bpm": 120])
            }
        case 9:
            if let clip = pickClipRef(project: project, tempClips: tempClips, rng: &rng) {
                ops.append(["op": "deleteClip", "track": clip.track, "clip": clip.clip])
            } else {
                ops.append(["op": "setTempo", "bpm": 100])
            }
        case 10:
            if let clip = pickClipRef(project: project, tempClips: tempClips, rng: &rng) {
                ops.append([
                    "op": "quantizeNotes",
                    "track": clip.track,
                    "clip": clip.clip,
                    "gridBeats": rng.pick([1.0, 0.5, 0.25]),
                ])
            } else {
                ops.append(["op": "setTempo", "bpm": 110])
            }
        case 11:
            if let clip = pickClipRef(project: project, tempClips: tempClips, rng: &rng) {
                ops.append([
                    "op": "transposeNotes",
                    "track": clip.track,
                    "clip": clip.clip,
                    "semitones": rng.nextInt(in: -12...12),
                ])
            } else {
                ops.append(["op": "setTempo", "bpm": 115])
            }
        default:
            if let clip = pickClipRef(project: project, tempClips: tempClips, rng: &rng) {
                ops.append([
                    "op": "moveClip",
                    "track": clip.track,
                    "clip": clip.clip,
                    "startBeat": rng.nextDouble(in: 0...32),
                ])
            } else {
                ops.append(["op": "setTempo", "bpm": 118])
            }
        }
    }
    return ops
}

private func pickTrackRef(trackHandles: [String], tempTracks: [String], rng: inout SeededRNG) -> String {
    let all = trackHandles + tempTracks
    guard !all.isEmpty else { return "T1" }
    return rng.pick(all)
}

private func pickClipRef(project: Project, tempClips: [(tempId: String, track: String)],
                         rng: inout SeededRNG) -> (track: String, clip: String)? {
    var options: [(String, String)] = []
    for (ti, t) in project.tracks.enumerated() {
        for (ci, _) in t.clips.enumerated() {
            options.append(("T\(ti + 1)", "T\(ti + 1)C\(ci + 1)"))
        }
    }
    for tc in tempClips {
        options.append((tc.track, tc.tempId))
    }
    guard !options.isEmpty else { return nil }
    let pick = rng.pick(options)
    return (pick.0, pick.1)
}

// MARK: - 3. MIDI parser fuzz

private func runMIDIParserFuzz(_ tk: TestKit) {
    // Streams whose data bytes are legal MIDI (0…127). Range property must hold.
    // Streams that deliberately feed high-bit “data” are covered by known defect H2-MIDI-1.
    tk.suite("H2 MIDI parser fuzz — fixed adversarial streams (no crash + legal data in range)") {
        // Data-plane bytes here are 0…127 or pure status/SysEx/real-time at message
        // boundaries. Hostile high-bit data and real-time *inside* data slots are H2-MIDI-1.
        let legalStreams: [(String, [UInt8])] = [
            ("empty", []),
            ("single status", [0x90]),
            ("truncated note on", [0x90, 60]),
            ("truncated note off", [0x80, 64]),
            ("running status", [0x90, 60, 100, 64, 90, 67, 80]),
            ("note-on vel 0", [0x90, 60, 0]),
            ("SysEx short", [0xF0, 0x43, 0x12, 0xF7]),
            ("SysEx unclosed", [0xF0, 0x01, 0x02, 0x03]),
            // Real-time only between complete messages (after both data bytes).
            ("real-time between messages", [0x90, 60, 100, 0xF8, 0x90, 64, 90]),
            ("all data bytes", [60, 100, 64, 90]),
            ("song position", [0xF2, 0x00, 0x01, 0x90, 60, 100]),
            ("time code / song select", [0xF1, 0x00, 0xF3, 0x01, 0x90, 60, 80]),
            ("CC stream", [0xB0, 1, 64, 7, 100, 10, 0]),
            ("only real-time", [0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF]),
            ("program change then note", [0xC0, 5, 0x90, 72, 100]),
            ("channel pressure then note", [0xD0, 40, 0x90, 60, 90]),
            ("multi-channel", [0x90, 60, 100, 0x91, 64, 90, 0x80, 60, 0]),
        ]

        // Hostile cases: must not crash (range property is H2-MIDI-1).
        let hostileNoCrash: [(String, [UInt8])] = [
            ("high data bytes as payload", [0x90, 0xFF, 0xFF]),
            ("status as data byte", [0x90, 0x80, 0x40]),
            ("real-time mid-data", [0x90, 0xF8, 60, 0xFE, 100]),
            ("real-time mid-running", [0x90, 60, 100, 0xF8, 64, 90]),
        ]

        var rangeOK = 0
        for (label, bytes) in legalStreams {
            let events = MIDIParser.parse(bytes)
            let bad = outOfRangeNoteEvents(events)
            if bad.isEmpty {
                rangeOK += 1
            } else {
                tk.expect(false, "fixed \(label) pitches/velocities in 0…127",
                          "out-of-range: \(bad)")
            }
        }
        tk.expectEqual(rangeOK, legalStreams.count,
                       "all \(legalStreams.count) legal fixed streams keep pitch/velocity in 0…127")

        for (label, bytes) in hostileNoCrash {
            _ = MIDIParser.parse(bytes)
            tk.expect(true, "hostile \(label) did not crash")
        }
    }

    // Hard property for hostile input: never crash. Range violations under hostile
    // high-bit bytes are known defect H2-MIDI-1 (documented, not fixed in this step).
    tk.suite("H2 MIDI parser fuzz — seeded random streams never crash (seed 0xD1D1F002)") {
        var rng = SeededRNG(seed: 0xD1D1_F002)
        let trialCount = 500
        var parsed = 0
        var rangeViolations = 0
        for _ in 0..<trialCount {
            let bytes = randomMIDIBytes(rng: &rng)
            let events = MIDIParser.parse(bytes)
            parsed += 1
            if !outOfRangeNoteEvents(events).isEmpty { rangeViolations += 1 }
        }
        tk.expectEqual(parsed, trialCount, "\(trialCount) random streams parsed without crash")
        // Observational: violations expected until H2-MIDI-1 is fixed.
        tk.expect(true, "H2-MIDI-1 range violations in random set: \(rangeViolations)/\(trialCount)")
    }

    tk.suite("H2 MIDI parser fuzz — structured + noise never crash (seed 0xC0FFEE01)") {
        var rng = SeededRNG(seed: 0xC0FF_EE01)
        let trialCount = 200
        var parsed = 0
        var rangeViolations = 0
        for _ in 0..<trialCount {
            var bytes: [UInt8] = []
            let messages = rng.nextInt(in: 1...12)
            for _ in 0..<messages {
                if rng.nextInt(in: 0...4) == 0 {
                    bytes.append(UInt8(0xF8 + rng.nextInt(in: 0...7)))
                }
                switch rng.nextInt(in: 0...6) {
                case 0:
                    bytes += [UInt8(0x90 | rng.nextInt(in: 0...15)),
                              UInt8(rng.nextInt(in: 0...127)),
                              UInt8(rng.nextInt(in: 0...127))]
                case 1:
                    bytes += [UInt8(0x80 | rng.nextInt(in: 0...15)),
                              UInt8(rng.nextInt(in: 0...127)),
                              UInt8(rng.nextInt(in: 0...127))]
                case 2:
                    bytes += [UInt8(0xB0 | rng.nextInt(in: 0...15)),
                              UInt8(rng.nextInt(in: 0...127)),
                              UInt8(rng.nextInt(in: 0...127))]
                case 3:
                    bytes.append(0xF0)
                    let n = rng.nextInt(in: 0...8)
                    bytes += rng.nextBytes(count: n).map { $0 & 0x7F }
                    if rng.nextBool() { bytes.append(0xF7) }
                case 4:
                    bytes += [UInt8(0x90 | rng.nextInt(in: 0...15)),
                              UInt8(rng.nextInt(in: 0...127))]
                case 5:
                    bytes += [0x90, 60, 100,
                              UInt8(rng.nextInt(in: 0...127)),
                              UInt8(rng.nextInt(in: 1...127))]
                default:
                    bytes += rng.nextBytes(count: rng.nextInt(in: 1...6))
                }
            }
            let events = MIDIParser.parse(bytes)
            parsed += 1
            if !outOfRangeNoteEvents(events).isEmpty { rangeViolations += 1 }
        }
        tk.expectEqual(parsed, trialCount, "\(trialCount) structured streams parsed without crash")
        tk.expect(true, "H2-MIDI-1 range violations in structured set: \(rangeViolations)/\(trialCount)")
    }

    // Minimal repro for known defect H2-MIDI-1. When fixed, rewrite to assert in-range
    // (or no event) and close the write-up in project_plan.md.
    tk.suite("H2 known defect MIDI-1 — high-bit / real-time mid-data become out-of-range fields") {
        let high = outOfRangeNoteEvents(MIDIParser.parse([0x90, 0xFF, 0xFF]))
        tk.expect(!high.isEmpty,
                  "MIDI-1 high data bytes still out of range (defect open)",
                  "parser kept values in 0…127; update project_plan H2-MIDI-1 if fixed")

        let statusAsData = outOfRangeNoteEvents(MIDIParser.parse([0x90, 0x80, 0x40]))
        tk.expect(!statusAsData.isEmpty,
                  "MIDI-1 status-as-data still out of range (defect open)",
                  "parser kept values in 0…127; update project_plan H2-MIDI-1 if fixed")

        // Real-time is skipped only at message boundaries today, not inside data slots.
        let rtMid = outOfRangeNoteEvents(MIDIParser.parse([0x90, 0xF8, 60, 0xFE, 100]))
        tk.expect(!rtMid.isEmpty,
                  "MIDI-1 real-time mid-data still out of range (defect open)",
                  "parser kept values in 0…127; update project_plan H2-MIDI-1 if fixed")
    }
}

private func randomMIDIBytes(rng: inout SeededRNG) -> [UInt8] {
    let len = rng.nextInt(in: 0...64)
    return rng.nextBytes(count: len)
}

private func outOfRangeNoteEvents(_ events: [MIDIEvent]) -> [String] {
    var bad: [String] = []
    for (i, e) in events.enumerated() {
        switch e {
        case .noteOn(_, let note, let vel):
            // UInt8 is always ≤255; property requires MIDI 0…127.
            if note > 127 || vel > 127 {
                bad.append("[\(i)] noteOn note=\(note) vel=\(vel)")
            }
        case .noteOff(_, let note, let vel):
            if note > 127 || vel > 127 {
                bad.append("[\(i)] noteOff note=\(note) vel=\(vel)")
            }
        case .controlChange(_, let cc, let val):
            if cc > 127 || val > 127 {
                bad.append("[\(i)] cc controller=\(cc) value=\(val)")
            }
        }
    }
    return bad
}
