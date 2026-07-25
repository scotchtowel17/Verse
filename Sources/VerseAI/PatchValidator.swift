import Foundation
import VerseModel

/// Validates a parsed patch against a project (Build Contract §E.4), collecting *all* problems
/// (it never stops at the first) and resolving every track/clip reference to an existing handle
/// or a temp id minted earlier in the same patch. On success it returns fully-typed ops ready
/// for transactional application; on any error it returns the full list of problems and nothing
/// is applied.
public enum PatchValidator {

    public struct Success {
        public let ops: [TypedOp]
        public let clamps: [String]     // human-readable notes about values that were clamped
        public let summary: String?
    }

    public static func validate(_ parsed: PatchParser.ParsedPatch,
                                project: Project) -> Result<Success, PatchErrors> {
        var errors: [PatchError] = []
        var clamps: [String] = []
        var typed: [TypedOp] = []

        // Whole-patch header checks.
        if let schema = parsed.schema, schema != "verse-patch" {
            errors.append(PatchError(opIndex: nil, "Unexpected schema “\(schema)” (expected “verse-patch”)."))
        } else if parsed.schema == nil {
            errors.append(PatchError(opIndex: nil, "Missing “schema”: \"verse-patch\"."))
        }
        if let v = parsed.version, v != 1 {
            errors.append(PatchError(opIndex: nil, "Unsupported patch version \(v) (this app supports version 1)."))
        }
        // Project fingerprint: handles are positional; refuse a patch that was built against a
        // different track/clip layout (or that left the code out entirely).
        let liveFingerprint = project.structuralFingerprint
        if let fp = parsed.fingerprint {
            let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                errors.append(PatchError(opIndex: nil,
                    "Claude left out the project code. Ask it to include the fingerprint field exactly."))
            } else if trimmed != liveFingerprint {
                errors.append(PatchError(opIndex: nil,
                    "Your project changed since you copied this request. Copy a fresh one."))
            }
        } else {
            errors.append(PatchError(opIndex: nil,
                "Claude left out the project code. Ask it to include the fingerprint field exactly."))
        }

        // Existing track handles: positional T1…Tn.
        var trackHandles: [String: UUID] = [:]
        for (i, t) in project.tracks.enumerated() { trackHandles["T\(i + 1)"] = t.id }

        // Existing clip handles: positional T1C1, T2C3, …
        // Map handle → (trackUUID, clipUUID)
        var clipHandles: [String: (track: UUID, clip: UUID)] = [:]
        for (ti, t) in project.tracks.enumerated() {
            for (ci, c) in t.clips.enumerated() {
                clipHandles["T\(ti + 1)C\(ci + 1)"] = (t.id, c.id)
            }
        }

        var tempTracks: Set<String> = []
        var tempClips: Set<String> = []
        // Simulated note pitches per clip handle/temp id so transpose can reject out-of-range
        // results even when earlier ops in this patch added notes.
        var clipNotePitches: [String: [Int]] = [:]
        for (handle, loc) in clipHandles {
            if let ti = project.trackIndex(id: loc.track),
               let clip = project.tracks[ti].clips.first(where: { $0.id == loc.clip }),
               let notes = clip.midiNotes {
                clipNotePitches[handle] = notes.map(\.pitch)
            }
        }

        func resolveTrack(_ ref: Any?, op i: Int) -> TrackRef? {
            guard let s = JSONCoerce.string(ref), !s.isEmpty else {
                errors.append(PatchError(opIndex: i, "Missing track reference.")); return nil
            }
            if tempTracks.contains(s) { return .temp(s) }
            if let uuid = trackHandles[s] { return .existing(uuid) }
            errors.append(PatchError(opIndex: i, "Unknown track “\(s)”.")); return nil
        }

        func resolveClip(_ ref: Any?, track: TrackRef, trackHandle: String, op i: Int) -> ClipRef? {
            guard let s = JSONCoerce.string(ref), !s.isEmpty else {
                errors.append(PatchError(opIndex: i, "Missing clip reference.")); return nil
            }
            if tempClips.contains(s) { return .temp(s) }
            if let loc = clipHandles[s] {
                // Clip handles encode their track (T3C2 → T3). Reject when the op names a different track.
                switch track {
                case .existing(let trackUUID):
                    if loc.track != trackUUID {
                        errors.append(PatchError(opIndex: i, "Clip “\(s)” isn't on track “\(trackHandle)”."))
                        return nil
                    }
                case .temp:
                    errors.append(PatchError(opIndex: i, "Clip “\(s)” isn't on track “\(trackHandle)”."))
                    return nil
                }
                return .existing(track: loc.track, clip: loc.clip)
            }
            errors.append(PatchError(opIndex: i, "Unknown clip “\(s)”.")); return nil
        }

        /// MIDI-only ops reject audio clips. Temp clips are always MIDI (only `addMidiClip` mints them).
        func requireMidiClip(_ clip: ClipRef, handle: String, opName: String, op i: Int) -> Bool {
            switch clip {
            case .temp:
                return true
            case .existing(_, let clipID):
                guard let found = project.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }) else {
                    errors.append(PatchError(opIndex: i, "Unknown clip “\(handle)”."))
                    return false
                }
                if found.kind == .audio {
                    errors.append(PatchError(opIndex: i,
                        "\(opName) only works on MIDI clips (clip “\(handle)” is audio)."))
                    return false
                }
                return true
            }
        }

        /// Accept `gridBeats` as 1 / 0.5 / 0.25, or `grid` / `gridBeats` as "1/4", "1/8", "1/16".
        func parseQuantizeGrid(_ op: [String: Any], op i: Int) -> Double? {
            if let g = JSONCoerce.double(op["gridBeats"]), [1.0, 0.5, 0.25].contains(g) {
                return g
            }
            let raw = JSONCoerce.string(op["grid"]) ?? JSONCoerce.string(op["gridBeats"])
            if let s = raw {
                switch s.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "1/4", "1": return 1.0
                case "1/8", "0.5": return 0.5
                case "1/16", "0.25": return 0.25
                default: break
                }
            }
            errors.append(PatchError(opIndex: i,
                "quantizeNotes needs “gridBeats” of 1, 0.5, or 0.25 (1/4, 1/8, or 1/16 beat)."))
            return nil
        }

        for (i, op) in parsed.ops.enumerated() {
            guard let name = JSONCoerce.string(op["op"]) else {
                errors.append(PatchError(opIndex: i, "Operation is missing its “op” name.")); continue
            }
            guard versePatchOps.contains(name) else {
                errors.append(PatchError(opIndex: i, "Unknown operation “\(name)”.")); continue
            }

            switch name {
            case "setTempo":
                guard let bpm = JSONCoerce.double(op["bpm"]) else {
                    errors.append(PatchError(opIndex: i, "setTempo needs a numeric “bpm”.")); continue
                }
                guard (20...300).contains(bpm) else {
                    errors.append(PatchError(opIndex: i, "Tempo \(bpm) out of range (20–300).")); continue
                }
                typed.append(.setTempo(bpm))

            case "setKey":
                guard let tonicStr = JSONCoerce.string(op["tonic"]), let tonic = Tonic(rawValue: tonicStr) else {
                    errors.append(PatchError(opIndex: i, "setKey needs a valid “tonic” (C, C#, … B).")); continue
                }
                guard let modeStr = JSONCoerce.string(op["mode"]), let mode = Mode(rawValue: modeStr) else {
                    errors.append(PatchError(opIndex: i, "setKey needs “mode”: major or minor.")); continue
                }
                typed.append(.setKey(tonic, mode))

            case "setTimeSignature":
                guard let num = JSONCoerce.int(op["num"]), (1...16).contains(num) else {
                    errors.append(PatchError(opIndex: i, "Time signature “num” must be 1–16.")); continue
                }
                guard let den = JSONCoerce.int(op["den"]), [1, 2, 4, 8, 16].contains(den) else {
                    errors.append(PatchError(opIndex: i, "Time signature “den” must be 1, 2, 4, 8 or 16.")); continue
                }
                typed.append(.setTimeSignature(num: num, den: den))

            case "createTrack":
                guard let tempId = JSONCoerce.string(op["tempId"]), !tempId.isEmpty else {
                    errors.append(PatchError(opIndex: i, "createTrack needs a “tempId”.")); continue
                }
                if tempTracks.contains(tempId) {
                    errors.append(PatchError(opIndex: i, "Duplicate tempId “\(tempId)”.")); continue
                }
                guard let kindStr = JSONCoerce.string(op["kind"]), let kind = TrackKind(rawValue: kindStr) else {
                    errors.append(PatchError(opIndex: i, "createTrack “kind” must be instrument or audio.")); continue
                }
                let name = JSONCoerce.string(op["name"]) ?? "Track"
                tempTracks.insert(tempId)
                typed.append(.createTrack(tempId: tempId, kind: kind, name: name,
                                          instrument: JSONCoerce.instrument(op["instrument"])))

            case "renameTrack":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                guard let newName = JSONCoerce.string(op["name"]) else {
                    errors.append(PatchError(opIndex: i, "renameTrack needs a “name”.")); continue
                }
                typed.append(.renameTrack(ref, name: newName))

            case "setInstrument":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                guard let program = JSONCoerce.int(op["program"]), (0...127).contains(program) else {
                    errors.append(PatchError(opIndex: i, "setInstrument “program” must be 0–127.")); continue
                }
                let inst = Instrument(sf2: JSONCoerce.string(op["sf2"]) ?? "MuseScoreGeneral",
                                      program: program,
                                      bankMSB: JSONCoerce.int(op["bankMSB"]) ?? 121,
                                      bankLSB: JSONCoerce.int(op["bankLSB"]) ?? 0)
                typed.append(.setInstrument(ref, inst))

            case "setTrackMix":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                var vol = JSONCoerce.double(op["volume"])
                var pan = JSONCoerce.double(op["pan"])
                if let v = vol, !(0...1).contains(v) {
                    vol = max(0, min(1, v)); clamps.append("Clamped volume \(v) → \(vol!).")
                }
                if let p = pan, !(-1...1).contains(p) {
                    pan = max(-1, min(1, p)); clamps.append("Clamped pan \(p) → \(pan!).")
                }
                typed.append(.setTrackMix(ref, volume: vol, pan: pan,
                                          mute: JSONCoerce.bool(op["mute"]), solo: JSONCoerce.bool(op["solo"])))

            case "addMidiClip":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                guard let tempClipId = JSONCoerce.string(op["tempClipId"]), !tempClipId.isEmpty else {
                    errors.append(PatchError(opIndex: i, "addMidiClip needs a “tempClipId”.")); continue
                }
                if tempClips.contains(tempClipId) {
                    errors.append(PatchError(opIndex: i, "Duplicate tempClipId “\(tempClipId)”.")); continue
                }
                let start = JSONCoerce.double(op["startBeat"]) ?? 0
                guard start >= 0 else {
                    errors.append(PatchError(opIndex: i, "addMidiClip “startBeat” must be ≥ 0.")); continue
                }
                guard let len = JSONCoerce.double(op["lengthBeats"]), len > 0 else {
                    errors.append(PatchError(opIndex: i, "addMidiClip “lengthBeats” must be > 0.")); continue
                }
                tempClips.insert(tempClipId)
                clipNotePitches[tempClipId] = []
                typed.append(.addMidiClip(track: ref, tempClipId: tempClipId, startBeat: start, lengthBeats: len))

            case "addNotes":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                let trackHandle = JSONCoerce.string(op["track"]) ?? ""
                let clipHandle = JSONCoerce.string(op["clip"]) ?? ""
                guard let clip = resolveClip(op["clip"], track: ref, trackHandle: trackHandle, op: i) else { continue }
                guard let notesArr = op["notes"] as? [[String: Any]] else {
                    errors.append(PatchError(opIndex: i, "addNotes needs a “notes” list.")); continue
                }
                var notes: [Note] = []
                var noteOK = true
                for (n, nd) in notesArr.enumerated() {
                    let start = JSONCoerce.double(nd["startBeat"]) ?? 0
                    let len = JSONCoerce.double(nd["lengthBeats"]) ?? 0
                    let pitch = JSONCoerce.int(nd["pitch"]) ?? -1
                    let vel = JSONCoerce.int(nd["velocity"]) ?? 0
                    if start < 0 { errors.append(PatchError(opIndex: i, "Note \(n + 1): startBeat must be ≥ 0.")); noteOK = false }
                    if len <= 0 { errors.append(PatchError(opIndex: i, "Note \(n + 1): lengthBeats must be > 0.")); noteOK = false }
                    if !(0...127).contains(pitch) { errors.append(PatchError(opIndex: i, "Note \(n + 1): pitch must be 0–127.")); noteOK = false }
                    if !(1...127).contains(vel) { errors.append(PatchError(opIndex: i, "Note \(n + 1): velocity must be 1–127.")); noteOK = false }
                    if noteOK {
                        notes.append(Note(startBeat: start, lengthBeats: len, pitch: pitch, velocity: vel,
                                          pitchBend: (nd["pitchBend"] as? [Any])?.compactMap { JSONCoerce.double($0) }))
                    }
                }
                if noteOK {
                    typed.append(.addNotes(track: ref, clip: clip, notes: notes))
                    var pitches = clipNotePitches[clipHandle] ?? []
                    pitches.append(contentsOf: notes.map(\.pitch))
                    clipNotePitches[clipHandle] = pitches
                }

            case "deleteClip":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                let trackHandle = JSONCoerce.string(op["track"]) ?? ""
                let clipHandle = JSONCoerce.string(op["clip"]) ?? ""
                guard let clip = resolveClip(op["clip"], track: ref, trackHandle: trackHandle, op: i) else { continue }
                // Invalidate so later ops on this handle fail validation (not apply).
                clipNotePitches.removeValue(forKey: clipHandle)
                clipHandles.removeValue(forKey: clipHandle)
                tempClips.remove(clipHandle)
                typed.append(.deleteClip(track: ref, clip: clip))

            case "quantizeNotes":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                let trackHandle = JSONCoerce.string(op["track"]) ?? ""
                let clipHandle = JSONCoerce.string(op["clip"]) ?? ""
                guard let clip = resolveClip(op["clip"], track: ref, trackHandle: trackHandle, op: i) else { continue }
                guard requireMidiClip(clip, handle: clipHandle, opName: "quantizeNotes", op: i) else { continue }
                guard let grid = parseQuantizeGrid(op, op: i) else { continue }
                typed.append(.quantizeNotes(track: ref, clip: clip, gridBeats: grid))

            case "transposeNotes":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                let trackHandle = JSONCoerce.string(op["track"]) ?? ""
                let clipHandle = JSONCoerce.string(op["clip"]) ?? ""
                guard let clip = resolveClip(op["clip"], track: ref, trackHandle: trackHandle, op: i) else { continue }
                guard requireMidiClip(clip, handle: clipHandle, opName: "transposeNotes", op: i) else { continue }
                guard let semitones = JSONCoerce.int(op["semitones"]) else {
                    errors.append(PatchError(opIndex: i, "transposeNotes needs an integer “semitones”.")); continue
                }
                let pitches = clipNotePitches[clipHandle] ?? []
                var pitchOK = true
                for p in pitches {
                    let next = p + semitones
                    if !(0...127).contains(next) {
                        errors.append(PatchError(opIndex: i,
                            "transposeNotes would push pitch \(p) by \(semitones) outside MIDI 0–127."))
                        pitchOK = false
                        break
                    }
                }
                if pitchOK {
                    clipNotePitches[clipHandle] = pitches.map { $0 + semitones }
                    typed.append(.transposeNotes(track: ref, clip: clip, semitones: semitones))
                }

            case "moveClip":
                guard let ref = resolveTrack(op["track"], op: i) else { continue }
                let trackHandle = JSONCoerce.string(op["track"]) ?? ""
                guard let clip = resolveClip(op["clip"], track: ref, trackHandle: trackHandle, op: i) else { continue }
                guard let start = JSONCoerce.double(op["startBeat"]) else {
                    errors.append(PatchError(opIndex: i, "moveClip needs a numeric “startBeat”.")); continue
                }
                guard start >= 0 else {
                    errors.append(PatchError(opIndex: i, "moveClip “startBeat” must be ≥ 0.")); continue
                }
                typed.append(.moveClip(track: ref, clip: clip, startBeat: start))

            default:
                errors.append(PatchError(opIndex: i, "Unhandled operation “\(name)”."))
            }
        }

        if !errors.isEmpty { return .failure(PatchErrors(errors)) }
        return .success(Success(ops: typed, clamps: clamps, summary: parsed.summary))
    }
}
