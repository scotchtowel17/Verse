import Foundation
import VerseModel
import VerseAI
import VerseMIDI
import VersePersistence
import VerseAppCore

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
    runModelRoundTripProperty(tk)
    runMigrationHostility(tk)
    runScaleChecks(tk)
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
            // deleteClip invalidates the handle during validation (H2-VAL-1 fixed in H3),
            // so use-after-delete is rejected and accepted ops must still apply cleanly.
            let ops = randomOpDicts(project: project, rng: &rng, count: rng.nextInt(in: 0...8),
                                    omitDeleteClip: false)
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

    // H2-VAL-1 closed in H3: deleteClip removes the handle so later ops are rejected
    // at validation (validation still guarantees apply cannot fail).
    tk.suite("H3 VAL-1 fix — deleteClip then use same handle is rejected at validation") {
        var project = Project.newUntitled()
        project.tracks[0].clips = [
            Clip(kind: .midi, name: "Doomed", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        let before = projectSnapshot(project)
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
        case .success:
            tk.expect(false, "VAL-1: use-after-delete must be rejected at validation")
        case .failure(let errs):
            tk.expect(!errs.errors.isEmpty, "VAL-1: at least one validation error")
            let joined = errs.errors.map(\.description).joined(separator: " | ")
            tk.expect(joined.contains("Unknown clip") || joined.contains("T1C1"),
                      "VAL-1: later op reports unknown clip (got: \(joined))")
        }
        tk.expect(projectSnapshot(project) == before,
                  "VAL-1: rejected validation leaves project unchanged")
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
    // Every emitted event must carry pitch, velocity, and controller values in 0…127
    // (H2-MIDI-1 fixed in H3). Truncated or malformed messages yield no out-of-range event.
    tk.suite("H2 MIDI parser fuzz — fixed adversarial streams (all events in 0…127)") {
        let allStreams: [(String, [UInt8])] = [
            ("empty", []),
            ("single status", [0x90]),
            ("truncated note on", [0x90, 60]),
            ("truncated note off", [0x80, 64]),
            ("running status", [0x90, 60, 100, 64, 90, 67, 80]),
            ("note-on vel 0", [0x90, 60, 0]),
            ("SysEx short", [0xF0, 0x43, 0x12, 0xF7]),
            ("SysEx unclosed", [0xF0, 0x01, 0x02, 0x03]),
            ("real-time between messages", [0x90, 60, 100, 0xF8, 0x90, 64, 90]),
            ("all data bytes", [60, 100, 64, 90]),
            ("song position", [0xF2, 0x00, 0x01, 0x90, 60, 100]),
            ("time code / song select", [0xF1, 0x00, 0xF3, 0x01, 0x90, 60, 80]),
            ("CC stream", [0xB0, 1, 64, 7, 100, 10, 0]),
            ("only real-time", [0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF]),
            ("program change then note", [0xC0, 5, 0x90, 72, 100]),
            ("channel pressure then note", [0xD0, 40, 0x90, 60, 90]),
            ("multi-channel", [0x90, 60, 100, 0x91, 64, 90, 0x80, 60, 0]),
            // Hostile: high-bit payload, status-as-data, real-time mid-data.
            ("high data bytes as payload", [0x90, 0xFF, 0xFF]),
            ("status as data byte", [0x90, 0x80, 0x40]),
            ("real-time mid-data", [0x90, 0xF8, 60, 0xFE, 100]),
            ("real-time mid-running", [0x90, 60, 100, 0xF8, 64, 90]),
        ]

        var rangeOK = 0
        for (label, bytes) in allStreams {
            let events = MIDIParser.parse(bytes)
            let bad = outOfRangeNoteEvents(events)
            if bad.isEmpty {
                rangeOK += 1
            } else {
                tk.expect(false, "fixed \(label) pitches/velocities/CC in 0…127",
                          "out-of-range: \(bad)")
            }
        }
        tk.expectEqual(rangeOK, allStreams.count,
                       "all \(allStreams.count) fixed streams keep pitch/velocity/CC in 0…127")

        // Real-time mid-data still produces the intended note (60, 100).
        let rtEvents = MIDIParser.parse([0x90, 0xF8, 60, 0xFE, 100])
        tk.expectEqual(rtEvents.count, 1, "real-time mid-data yields one note-on")
        if case .noteOn(_, 60, 100) = rtEvents.first {
            tk.expect(true, "real-time mid-data note is 60@100")
        } else {
            tk.expect(false, "real-time mid-data note is 60@100", "got \(rtEvents)")
        }
    }

    tk.suite("H2 MIDI parser fuzz — seeded random streams in range (seed 0xD1D1F002)") {
        var rng = SeededRNG(seed: 0xD1D1_F002)
        let trialCount = 500
        var rangeOK = 0
        for trial in 0..<trialCount {
            let bytes = randomMIDIBytes(rng: &rng)
            let events = MIDIParser.parse(bytes)
            let bad = outOfRangeNoteEvents(events)
            if bad.isEmpty {
                rangeOK += 1
            } else {
                tk.expect(false, "random trial \(trial) events in 0…127",
                          "out-of-range: \(bad)")
            }
        }
        tk.expectEqual(rangeOK, trialCount,
                       "\(trialCount)/\(trialCount) random streams keep pitch/velocity/CC in 0…127")
    }

    tk.suite("H2 MIDI parser fuzz — structured + noise in range (seed 0xC0FFEE01)") {
        var rng = SeededRNG(seed: 0xC0FF_EE01)
        let trialCount = 200
        var rangeOK = 0
        for trial in 0..<trialCount {
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
            let bad = outOfRangeNoteEvents(events)
            if bad.isEmpty {
                rangeOK += 1
            } else {
                tk.expect(false, "structured trial \(trial) events in 0…127",
                          "out-of-range: \(bad)")
            }
        }
        tk.expectEqual(rangeOK, trialCount,
                       "\(trialCount)/\(trialCount) structured streams keep pitch/velocity/CC in 0…127")
    }

    // H2-MIDI-1 closed in H3: high-bit / real-time mid-data never emit out-of-range fields.
    tk.suite("H3 MIDI-1 fix — high-bit / real-time mid-data stay in 0…127") {
        let high = MIDIParser.parse([0x90, 0xFF, 0xFF])
        tk.expect(outOfRangeNoteEvents(high).isEmpty,
                  "MIDI-1 high data bytes: no out-of-range fields")

        let statusAsData = MIDIParser.parse([0x90, 0x80, 0x40])
        tk.expect(outOfRangeNoteEvents(statusAsData).isEmpty,
                  "MIDI-1 status-as-data: no out-of-range fields")

        let rtMid = MIDIParser.parse([0x90, 0xF8, 60, 0xFE, 100])
        tk.expect(outOfRangeNoteEvents(rtMid).isEmpty,
                  "MIDI-1 real-time mid-data: no out-of-range fields")
        tk.expectEqual(rtMid.count, 1, "MIDI-1 real-time mid-data yields one event")
        if case .noteOn(_, 60, 100) = rtMid.first {
            tk.expect(true, "MIDI-1 real-time mid-data is noteOn 60@100")
        } else {
            tk.expect(false, "MIDI-1 real-time mid-data is noteOn 60@100", "got \(rtMid)")
        }
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

// MARK: - 4. Model round-trip property test

private func runModelRoundTripProperty(_ tk: TestKit) {
    tk.suite("H2 model round-trip — seeded random projects (seed 0xA011D7A1)") {
        // Seed chosen for reproducibility; failures should re-run with the same seed.
        var rng = SeededRNG(seed: 0xA011_D7A1)
        let trialCount = 80
        var ok = 0
        for trial in 0..<trialCount {
            let project = randomRoundTripProject(rng: &rng)
            do {
                let data = try project.jsonData()
                let back = try Project.fromJSON(data)
                let data2 = try back.jsonData()
                if data == data2 {
                    ok += 1
                } else {
                    // Field-level diagnosis for the failing trial (still deterministic).
                    let mismatches = projectFieldMismatches(project, back)
                    tk.expect(false, "trial \(trial) JSON bytes match after re-encode",
                              mismatches.isEmpty
                              ? "byte mismatch without field-level diff (len \(data.count) vs \(data2.count))"
                              : mismatches.joined(separator: "; "))
                }
            } catch {
                tk.expect(false, "trial \(trial) encode/decode", "error: \(error)")
            }
        }
        tk.expectEqual(ok, trialCount,
                       "\(trialCount)/\(trialCount) random projects encode→decode→re-encode identically")
    }

    tk.suite("H2 model round-trip — dense multi-track control case") {
        var rng = SeededRNG(seed: 0xC017_A01D)
        let project = randomRoundTripProject(rng: &rng, trackCount: 8, clipsPerTrack: 4, notesPerClip: 12)
        let noteCount = project.tracks.reduce(0) { acc, t in
            acc + t.clips.reduce(0) { $0 + ($1.midiNotes?.count ?? 0) }
        }
        tk.expect(noteCount > 0, "control case has notes (got \(noteCount))")
        do {
            let data = try project.jsonData()
            let back = try Project.fromJSON(data)
            tk.expectEqual(try back.jsonData(), data, "dense control re-encodes identically")
            tk.expectEqual(back.structuralFingerprint, project.structuralFingerprint,
                           "fingerprint stable across JSON round-trip")
            tk.expectEqual(back.tracks.count, project.tracks.count, "track count preserved")
            tk.expectEqual(
                back.tracks.flatMap { $0.clips }.count,
                project.tracks.flatMap { $0.clips }.count,
                "clip count preserved"
            )
        } catch {
            tk.expect(false, "dense control encode/decode", "error: \(error)")
        }
    }
}

/// Richer random project for round-trip identity (inserts, optional pitch bend, audio+MIDI mix).
private func randomRoundTripProject(rng: inout SeededRNG,
                                    trackCount: Int? = nil,
                                    clipsPerTrack: Int? = nil,
                                    notesPerClip: Int? = nil) -> Project {
    let tCount = trackCount ?? rng.nextInt(in: 1...6)
    var tracks: [Track] = []
    for t in 0..<tCount {
        let kind: TrackKind = rng.nextBool() ? .instrument : .audio
        var inserts: [AudioUnitRef] = []
        if rng.nextInt(in: 0...4) == 0 {
            inserts.append(AudioUnitRef(
                type: "aufx",
                subtype: "dstr",
                manufacturer: "appl",
                name: "Dist\(t)",
                stateBlob: rng.nextBool() ? Data(rng.nextBytes(count: rng.nextInt(in: 1...16))) : nil
            ))
        }
        var track = Track(
            id: rng.nextUUID(),
            kind: kind,
            name: "Track \(t)",
            volume: rng.nextDouble(in: 0...1),
            pan: rng.nextDouble(in: -1...1),
            mute: rng.nextBool(),
            solo: false,
            instrument: kind == .instrument
                ? Instrument(sf2: rng.pick(["MuseScoreGeneral", "GeneralUserGS"]),
                             program: rng.nextInt(in: 0...127),
                             bankMSB: rng.nextInt(in: 0...127),
                             bankLSB: rng.nextInt(in: 0...127))
                : nil,
            inserts: inserts,
            clips: []
        )
        let cCount = clipsPerTrack ?? rng.nextInt(in: 0...4)
        for c in 0..<cCount {
            if kind == .instrument {
                let nCount = notesPerClip ?? rng.nextInt(in: 0...8)
                var notes: [Note] = []
                for _ in 0..<nCount {
                    let bend: [Double]? = rng.nextInt(in: 0...5) == 0
                        ? (0..<rng.nextInt(in: 1...4)).map { _ in rng.nextDouble(in: -1...1) }
                        : nil
                    notes.append(Note(
                        id: rng.nextUUID(),
                        startBeat: rng.nextDouble(in: 0...16),
                        lengthBeats: rng.nextDouble(in: 0.0625...4),
                        pitch: rng.nextInt(in: 0...127),
                        velocity: rng.nextInt(in: 1...127),
                        pitchBend: bend
                    ))
                }
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .midi,
                    name: "MIDI \(t).\(c)",
                    startBeat: rng.nextDouble(in: 0...32),
                    lengthBeats: rng.nextDouble(in: 1...16),
                    midiNotes: notes
                ))
            } else {
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .audio,
                    name: "Audio \(t).\(c)",
                    startBeat: rng.nextDouble(in: 0...32),
                    lengthBeats: rng.nextDouble(in: 1...16),
                    mediaFile: "take-\(t)-\(c).wav"
                ))
            }
        }
        tracks.append(track)
    }
    return Project(
        id: rng.nextUUID(),
        title: "RoundTrip-\(rng.nextInt(in: 0...9999))",
        tempoBPM: rng.nextBool() ? Double(rng.nextInt(in: 40...240)) : nil,
        key: rng.nextBool()
            ? KeySignature(tonic: rng.pick(Array(Tonic.allCases)), mode: rng.pick(Array(Mode.allCases)))
            : nil,
        timeSignature: TimeSignature(num: rng.pick([2, 3, 4, 5, 6, 7]), den: rng.pick([2, 4, 8, 16])),
        tracks: tracks,
        masterVolume: rng.nextDouble(in: 0...1),
        createdAt: Date(timeIntervalSince1970: Double(rng.nextInt(in: 0...2_000_000_000))),
        modifiedAt: Date(timeIntervalSince1970: Double(rng.nextInt(in: 0...2_000_000_000)))
    )
}

private func projectFieldMismatches(_ a: Project, _ b: Project) -> [String] {
    var m: [String] = []
    if a.schemaVersion != b.schemaVersion { m.append("schemaVersion \(a.schemaVersion)≠\(b.schemaVersion)") }
    if a.id != b.id { m.append("id") }
    if a.title != b.title { m.append("title") }
    if a.tempoBPM != b.tempoBPM { m.append("tempoBPM \(String(describing: a.tempoBPM))≠\(String(describing: b.tempoBPM))") }
    if a.key != b.key { m.append("key") }
    if a.timeSignature != b.timeSignature { m.append("timeSignature") }
    if a.masterVolume != b.masterVolume { m.append("masterVolume") }
    if a.createdAt != b.createdAt { m.append("createdAt") }
    if a.modifiedAt != b.modifiedAt { m.append("modifiedAt") }
    if a.tracks.count != b.tracks.count {
        m.append("tracks.count \(a.tracks.count)≠\(b.tracks.count)")
        return m
    }
    for i in a.tracks.indices {
        let ta = a.tracks[i], tb = b.tracks[i]
        if ta.id != tb.id { m.append("track[\(i)].id") }
        if ta.kind != tb.kind { m.append("track[\(i)].kind") }
        if ta.name != tb.name { m.append("track[\(i)].name") }
        if ta.volume != tb.volume { m.append("track[\(i)].volume") }
        if ta.pan != tb.pan { m.append("track[\(i)].pan") }
        if ta.mute != tb.mute { m.append("track[\(i)].mute") }
        if ta.solo != tb.solo { m.append("track[\(i)].solo") }
        if ta.instrument != tb.instrument { m.append("track[\(i)].instrument") }
        if ta.inserts != tb.inserts { m.append("track[\(i)].inserts") }
        if ta.clips.count != tb.clips.count {
            m.append("track[\(i)].clips.count \(ta.clips.count)≠\(tb.clips.count)")
            continue
        }
        for j in ta.clips.indices {
            let ca = ta.clips[j], cb = tb.clips[j]
            if ca != cb { m.append("track[\(i)].clip[\(j)]") }
        }
    }
    return m
}

// MARK: - 5. Migration hostility

private func runMigrationHostility(_ tk: TestKit) {
    // Property: hostile project.json must yield a readable error (throw), never a crash,
    // and never a silent success that drops or invents structure.

    tk.suite("H2 migration hostility — malformed / truncated / wrong-type") {
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("whitespace", Data("   \n\t".utf8)),
            ("truncated object", Data(#"{"schemaVersion":1,"id":"#.utf8)),
            ("truncated array", Data(#"[{"schemaVersion":1"#.utf8)),
            ("not JSON", Data("this is not json at all".utf8)),
            ("NUL only", Data([0])),
            ("top-level array", Data(#"[]"#.utf8)),
            ("top-level string", Data(#""a project?""#.utf8)),
            ("top-level number", Data(#"42"#.utf8)),
            ("top-level null", Data(#"null"#.utf8)),
            ("empty object", Data(#"{}"#.utf8)),
            ("schemaVersion string", Data(#"{"schemaVersion":"one","id":"00000000-0000-4000-8000-000000000001","title":"x","timeSignature":{"num":4,"den":4},"tracks":[],"masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
            ("tracks wrong type", Data(#"{"schemaVersion":1,"id":"00000000-0000-4000-8000-000000000001","title":"x","timeSignature":{"num":4,"den":4},"tracks":"nope","masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
            ("id wrong type", Data(#"{"schemaVersion":1,"id":12345,"title":"x","timeSignature":{"num":4,"den":4},"tracks":[],"masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
            ("tempoBPM string", Data(#"{"schemaVersion":1,"id":"00000000-0000-4000-8000-000000000001","title":"x","tempoBPM":"fast","timeSignature":{"num":4,"den":4},"tracks":[],"masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
            ("clip kind unknown", Data(#"{"schemaVersion":1,"id":"00000000-0000-4000-8000-000000000001","title":"x","timeSignature":{"num":4,"den":4},"tracks":[{"id":"00000000-0000-4000-8000-000000000002","kind":"instrument","name":"P","volume":0.8,"pan":0,"mute":false,"solo":false,"inserts":[],"clips":[{"id":"00000000-0000-4000-8000-000000000003","kind":"banana","name":"c","startBeat":0,"lengthBeats":4}]}],"masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
            ("note pitch string", Data(#"{"schemaVersion":1,"id":"00000000-0000-4000-8000-000000000001","title":"x","timeSignature":{"num":4,"den":4},"tracks":[{"id":"00000000-0000-4000-8000-000000000002","kind":"instrument","name":"P","volume":0.8,"pan":0,"mute":false,"solo":false,"inserts":[],"clips":[{"id":"00000000-0000-4000-8000-000000000003","kind":"midi","name":"c","startBeat":0,"lengthBeats":4,"midiNotes":[{"id":"00000000-0000-4000-8000-000000000004","startBeat":0,"lengthBeats":1,"pitch":"middle-C","velocity":100}]}]}],"masterVolume":0.8,"createdAt":"1970-01-01T00:00:00Z","modifiedAt":"1970-01-01T00:00:00Z"}"#.utf8)),
        ]

        var threwReadable = 0
        for (label, data) in cases {
            do {
                _ = try Project.fromJSON(data)
                tk.expect(false, "\(label) must not decode silently",
                          "fromJSON succeeded on hostile input")
            } catch {
                let msg = readableErrorMessage(error)
                if msg.isEmpty {
                    tk.expect(false, "\(label) readable error", "empty error description: \(error)")
                } else {
                    threwReadable += 1
                }
            }
        }
        tk.expectEqual(threwReadable, cases.count,
                       "all \(cases.count) hostile inputs throw a non-empty error message")
    }

    tk.suite("H2 migration hostility — future schemaVersion") {
        // H4 / H2-MIG-1 FIXED: future schema must refuse open with a readable error.
        // Never decode-as-v1 (that would silently drop unknown fields on re-save).
        let futureJSON = """
        {
          "schemaVersion": 99,
          "id": "00000000-0000-4000-8000-0000000000AA",
          "title": "Future",
          "tempoBPM": 120,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [],
          "masterVolume": 0.85,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z",
          "futureOnlyField": { "keepMe": true }
        }
        """
        let data = Data(futureJSON.utf8)

        var migrateThrew = false
        var migrateMsg = ""
        do {
            _ = try Migration.migrateRawIfNeeded(data)
        } catch {
            migrateThrew = true
            migrateMsg = readableErrorMessage(error)
        }
        tk.expect(migrateThrew, "migrateRawIfNeeded rejects future schemaVersion")
        tk.expect(!migrateMsg.isEmpty, "migrate error is non-empty")
        tk.expect(migrateMsg.localizedCaseInsensitiveContains("newer")
                  || migrateMsg.localizedCaseInsensitiveContains("schema")
                  || migrateMsg.localizedCaseInsensitiveContains("version"),
                  "migrate error mentions newer/schema/version")

        var fromJSONSucceeded = false
        var fromJSONMsg = ""
        do {
            _ = try Project.fromJSON(data)
            fromJSONSucceeded = true
        } catch {
            fromJSONMsg = readableErrorMessage(error)
        }
        tk.expect(!fromJSONSucceeded, "fromJSON must not open a future schema (no partial load)")
        tk.expect(!fromJSONMsg.isEmpty, "future schema rejected with readable error")
        tk.expect(fromJSONMsg.localizedCaseInsensitiveContains("newer")
                  || fromJSONMsg.localizedCaseInsensitiveContains("schema")
                  || fromJSONMsg.localizedCaseInsensitiveContains("version"),
                  "fromJSON error mentions newer/schema/version")
    }

    tk.suite("H4 future schema — package read and recovery surface readable failure") {
        let futureVersion = Schema.current + 98
        let futureJSON = """
        {
          "schemaVersion": \(futureVersion),
          "id": "00000000-0000-4000-8000-0000000000BB",
          "title": "From The Future",
          "tempoBPM": 100,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [],
          "masterVolume": 0.8,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z",
          "futureOnlyField": { "keepMe": true }
        }
        """
        let data = Data(futureJSON.utf8)

        // Explicit MigrationError case.
        do {
            _ = try Migration.migrateRawIfNeeded(data)
            tk.expect(false, "migrate must throw", "succeeded")
        } catch let err as Migration.MigrationError {
            if case .unsupportedFutureVersion(let v) = err {
                tk.expectEqual(v, futureVersion, "error carries the future schema number")
            } else {
                tk.expect(false, "expected unsupportedFutureVersion", "got \(err)")
            }
            let msg = err.errorDescription ?? ""
            tk.expect(msg.localizedCaseInsensitiveContains("newer"),
                      "plain-language “newer version” message")
            tk.expect(msg.contains("\(futureVersion)"),
                      "message names schema \(futureVersion)")
        } catch {
            tk.expect(false, "expected MigrationError", "got \(error)")
        }

        // .verse package open path (ProjectPackage.read → Project.fromJSON → migrate).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-h4-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = dir.appendingPathComponent("Future.verse")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try data.write(to: pkg.appendingPathComponent("project.json"))
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("Media"), withIntermediateDirectories: true)

        var packageOpened = false
        var packageMsg = ""
        do {
            _ = try ProjectPackage.read(pkg)
            packageOpened = true
        } catch {
            packageMsg = readableErrorMessage(error)
        }
        tk.expect(!packageOpened, "package with future schema must not open")
        tk.expect(!packageMsg.isEmpty, "package open error is non-empty")
        tk.expect(packageMsg.localizedCaseInsensitiveContains("newer")
                  || packageMsg.localizedCaseInsensitiveContains("schema")
                  || packageMsg.localizedCaseInsensitiveContains("version"),
                  "package error is readable about schema/version")

        // RecoveryManager: future autosave is not silent garbage; failure is surfaced.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-h4-recov-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let rec = RecoveryManager(baseDir: base)
        rec.beginSession()
        try data.write(to: rec.workspaceDir.appendingPathComponent("autosave-project.json"),
                       options: [.atomic])
        let relaunch = RecoveryManager(baseDir: base)
        let info = relaunch.detectRecovery()
        tk.expect(info != nil, "future-schema autosave still surfaces as recovery")
        tk.expect(info?.project == nil, "project is not partially decoded")
        let failMsg = info?.projectLoadFailureMessage ?? ""
        tk.expect(!failMsg.isEmpty, "projectLoadFailureMessage is set")
        tk.expect(failMsg.localizedCaseInsensitiveContains("newer")
                  || failMsg.localizedCaseInsensitiveContains("schema")
                  || failMsg.localizedCaseInsensitiveContains("version"),
                  "recovery failure names schema/version/newer")
        // Autosave file must still be on disk (not treated as disposable garbage).
        tk.expect(FileManager.default.fileExists(
            atPath: relaunch.workspaceDir.appendingPathComponent("autosave-project.json").path),
                  "autosave file retained after failed decode")
        relaunch.endSessionCleanly()
    }

    tk.suite("H2 migration hostility — current schema still opens") {
        let p = Project.newUntitled()
        do {
            let data = try p.jsonData()
            let back = try Project.fromJSON(data)
            tk.expectEqual(back.schemaVersion, Schema.current, "current schema opens")
            tk.expectEqual(back.tracks.count, 1, "seed track preserved")
        } catch {
            tk.expect(false, "current schema opens", "error: \(error)")
        }
    }

    tk.suite("H2 migration hostility — package missing project.json") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-h2-mig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Empty package directory: no project.json.
        do {
            _ = try ProjectPackage.read(dir)
            tk.expect(false, "missing project.json must throw", "read succeeded")
        } catch let err as ProjectPackage.PackageError {
            let msg = err.errorDescription ?? err.localizedDescription
            tk.expect(!msg.isEmpty, "PackageError has readable text")
            tk.expect(msg.localizedCaseInsensitiveContains("project")
                      || msg.localizedCaseInsensitiveContains("missing"),
                      "message names the missing project data")
        } catch {
            // Any other error is still a failure mode (not a crash), but prefer PackageError.
            let msg = readableErrorMessage(error)
            tk.expect(!msg.isEmpty, "non-PackageError is still readable: \(msg)")
        }
    }
}

private func readableErrorMessage(_ error: Error) -> String {
    if let e = error as? LocalizedError {
        let parts = [e.errorDescription, e.failureReason, e.recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
    }
    let s = String(describing: error)
    return s.isEmpty ? "unknown error" : s
}

// MARK: - 6. Scale (≈50 tracks, ≈20,000 notes)

private func runScaleChecks(_ tk: TestKit) {
    tk.suite("H2 scale — 50 tracks / ~20k notes save, load, fingerprint, layout") {
        var rng = SeededRNG(seed: 0x5CA1E_7E57)
        let trackCount = 50
        let notesPerTrack = 400 // 50 × 400 = 20_000
        let totalNotesTarget = trackCount * notesPerTrack

        // Build without wall-clock bounds (AGENTS: no flaky upper bounds). Time and report.
        let buildStart = CFAbsoluteTimeGetCurrent()
        var tracks: [Track] = []
        tracks.reserveCapacity(trackCount)
        var totalNotes = 0
        var allNotesForLayout: [Note] = []
        allNotesForLayout.reserveCapacity(totalNotesTarget)

        for t in 0..<trackCount {
            var notes: [Note] = []
            notes.reserveCapacity(notesPerTrack)
            for n in 0..<notesPerTrack {
                let note = Note(
                    id: rng.nextUUID(),
                    startBeat: Double(n % 64) * 0.25,
                    lengthBeats: 0.25,
                    pitch: rng.nextInt(in: 24...96),
                    velocity: rng.nextInt(in: 40...120)
                )
                notes.append(note)
                allNotesForLayout.append(note)
            }
            totalNotes += notes.count
            let clip = Clip(
                id: rng.nextUUID(),
                kind: .midi,
                name: "Clip \(t)",
                startBeat: 0,
                lengthBeats: 64,
                midiNotes: notes
            )
            tracks.append(Track(
                id: rng.nextUUID(),
                kind: .instrument,
                name: "Track \(t)",
                instrument: .grandPiano,
                clips: [clip]
            ))
        }
        let project = Project(
            id: rng.nextUUID(),
            title: "Scale H2",
            tempoBPM: 120,
            key: KeySignature(tonic: .C, mode: .major),
            tracks: tracks,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let buildSec = CFAbsoluteTimeGetCurrent() - buildStart
        tk.expectEqual(totalNotes, totalNotesTarget,
                       "built \(totalNotesTarget) notes (got \(totalNotes))")
        tk.expectEqual(project.tracks.count, trackCount, "\(trackCount) tracks")

        // Fingerprint
        let fpStart = CFAbsoluteTimeGetCurrent()
        let fp1 = project.structuralFingerprint
        let fpSec = CFAbsoluteTimeGetCurrent() - fpStart
        tk.expectEqual(fp1.count, 8, "fingerprint is 8 hex chars")
        tk.expect(fp1.allSatisfy(\.isHexDigit), "fingerprint is hex")
        let fp2 = project.structuralFingerprint
        tk.expectEqual(fp1, fp2, "fingerprint is stable when re-read")

        // JSON encode (model-level save path used by ProjectPackage)
        let encStart = CFAbsoluteTimeGetCurrent()
        var encoded = Data()
        do {
            encoded = try project.jsonData()
        } catch {
            tk.expect(false, "encode large project", "error: \(error)")
            return
        }
        let encSec = CFAbsoluteTimeGetCurrent() - encStart
        tk.expect(encoded.count > 1000, "encoded JSON is substantial (\(encoded.count) bytes)")

        // JSON decode
        let decStart = CFAbsoluteTimeGetCurrent()
        var loaded: Project?
        do {
            loaded = try Project.fromJSON(encoded)
        } catch {
            tk.expect(false, "decode large project", "error: \(error)")
            return
        }
        let decSec = CFAbsoluteTimeGetCurrent() - decStart
        guard let loaded else { return }

        tk.expectEqual(loaded.tracks.count, trackCount, "load preserves track count")
        let loadedNotes = loaded.tracks.reduce(0) { acc, t in
            acc + t.clips.reduce(0) { $0 + ($1.midiNotes?.count ?? 0) }
        }
        tk.expectEqual(loadedNotes, totalNotesTarget, "load preserves note count")
        tk.expectEqual(loaded.structuralFingerprint, fp1,
                       "fingerprint matches after JSON load")
        tk.expectEqual(loaded.title, "Scale H2", "title preserved")

        // Package write/read (atomic .verse path)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-h2-scale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = dir.appendingPathComponent("scale.verse")

        let writeStart = CFAbsoluteTimeGetCurrent()
        do {
            _ = try ProjectPackage.write(project, to: pkg, mediaSourceDir: nil)
        } catch {
            tk.expect(false, "package write large project", "error: \(error)")
            return
        }
        let writeSec = CFAbsoluteTimeGetCurrent() - writeStart

        let readStart = CFAbsoluteTimeGetCurrent()
        var pkgLoaded: Project?
        do {
            pkgLoaded = try ProjectPackage.read(pkg)
        } catch {
            tk.expect(false, "package read large project", "error: \(error)")
            return
        }
        let readSec = CFAbsoluteTimeGetCurrent() - readStart
        guard let pkgLoaded else { return }

        tk.expectEqual(pkgLoaded.tracks.count, trackCount, "package load track count")
        let pkgNotes = pkgLoaded.tracks.reduce(0) { acc, t in
            acc + t.clips.reduce(0) { $0 + ($1.midiNotes?.count ?? 0) }
        }
        tk.expectEqual(pkgNotes, totalNotesTarget, "package load note count")
        tk.expectEqual(pkgLoaded.structuralFingerprint, fp1,
                       "fingerprint matches after package load")

        // Piano-roll layout on the full 20k-note set (bounded window, pure function).
        let layoutStart = CFAbsoluteTimeGetCurrent()
        let focus = PianoRollLayout.focusPitch(notes: allNotesForLayout)
        let range = PianoRollLayout.visiblePitchRange(
            focusPitch: focus,
            paneHeight: PianoRollLayout.defaultPitchPaneHeight,
            rowHeight: PianoRollLayout.rowHeight
        )
        let layoutSec = CFAbsoluteTimeGetCurrent() - layoutStart

        tk.expect(range.contains(focus), "layout window contains focus pitch \(focus)")
        tk.expect(range.lowerBound >= 0 && range.upperBound <= 127,
                  "layout range stays in MIDI 0…127")
        tk.expectEqual(
            range.upperBound - range.lowerBound + 1,
            PianoRollLayout.defaultViewportPitchRows,
            "default pane is exactly \(PianoRollLayout.defaultViewportPitchRows) whole rows"
        )

        // Per-track windows must stay in MIDI and include each track's focus pitch.
        var tracksCovered = 0
        for track in project.tracks {
            let notes = track.clips.first?.midiNotes ?? []
            let f = PianoRollLayout.focusPitch(notes: notes)
            let r = PianoRollLayout.visiblePitchRange(
                focusPitch: f,
                paneHeight: PianoRollLayout.defaultPitchPaneHeight,
                rowHeight: PianoRollLayout.rowHeight
            )
            if r.contains(f) && r.lowerBound >= 0 && r.upperBound <= 127 {
                tracksCovered += 1
            }
        }
        tk.expectEqual(tracksCovered, trackCount,
                       "per-track layout covers focus on all \(trackCount) tracks")

        // Snap / resize helpers must stay O(1) and correct on extreme widths.
        tk.expectEqual(PianoRollLayout.snap(1.24, to: 0.25), 1.25, "snap still correct at scale")
        tk.expectEqual(PianoRollLayout.resizeHandleWidth(noteWidth: 4), 1.2,
                       "tiny note handle stays proportional")
        tk.expectEqual(PianoRollLayout.resizeHandleWidth(noteWidth: 10_000),
                       PianoRollLayout.resizeHandleMaxWidth,
                       "huge note handle caps at max")

        // Report timings (not pass/fail: CI load varies; AGENTS forbids flaky upper bounds).
        let report = String(
            format: "H2 scale timings: build=%.3fs encode=%.3fs decode=%.3fs fingerprint=%.4fs packageWrite=%.3fs packageRead=%.3fs layout20k=%.4fs jsonBytes=%d notes=%d",
            buildSec, encSec, decSec, fpSec, writeSec, readSec, layoutSec,
            encoded.count, totalNotes
        )
        print("   ⏱ \(report)")
        tk.expect(true, report)
    }
}
