import Foundation

/// The authoritative, serialized project model (Build Contract §10).
///
/// At runtime the audio engine is the single source of truth; this model mirrors it and
/// is what gets persisted to `project.json` inside the `.verse` file package. The model
/// imports no UI and no audio frameworks so it can be unit-tested in isolation.

// MARK: - Schema versioning

public enum Schema {
    /// Bump on any breaking change to the persisted shape; `Migration` chains forward.
    public static let current: Int = 3
}

// MARK: - Track colour identity (schema v3)

/// Fixed 8-slot palette indices for track identity colour.
/// Actual display colours live in the UI layer so themes stay coherent; the model
/// only stores which slot. Semantic colours (record, play, selection, warning) are
/// never drawn from this palette.
public enum TrackPalette {
    public static let count = 8

    /// Wrap any stored index into `0..<count`.
    public static func normalized(_ index: Int) -> Int {
        let m = index % count
        return m >= 0 ? m : m + count
    }

    /// Next colour for a newly appended track (round-robin by current track count).
    public static func colorIndexForNewTrack(existingCount: Int) -> Int {
        normalized(existingCount)
    }
}

// MARK: - Musical value types

public enum Tonic: String, Codable, CaseIterable, Sendable, Hashable {
    case C, Cs = "C#", D, Ds = "D#", E, F, Fs = "F#", G, Gs = "G#", A, As = "A#", B
}

public enum Mode: String, Codable, CaseIterable, Sendable, Hashable {
    case major, minor
}

public struct KeySignature: Codable, Sendable, Hashable {
    public var tonic: Tonic
    public var mode: Mode
    public init(tonic: Tonic, mode: Mode) { self.tonic = tonic; self.mode = mode }
}

public struct TimeSignature: Codable, Sendable, Hashable {
    public var num: Int
    public var den: Int
    public init(num: Int = 4, den: Int = 4) { self.num = num; self.den = den }
    public static let common = TimeSignature(num: 4, den: 4)
}

// MARK: - Instruments & inserts

public struct Instrument: Codable, Sendable, Hashable {
    public var sf2: String          // logical sound-bank name, e.g. "MuseScoreGeneral" or "GeneralUserGS"
    public var program: Int         // GM program 0–127
    public var bankMSB: Int
    public var bankLSB: Int
    /// New instruments default to MuseScore General. Existing projects keep the bank name they stored.
    public init(sf2: String = "MuseScoreGeneral", program: Int = 0, bankMSB: Int = 121, bankLSB: Int = 0) {
        self.sf2 = sf2; self.program = program; self.bankMSB = bankMSB; self.bankLSB = bankLSB
    }
    public static let grandPiano = Instrument(sf2: "MuseScoreGeneral", program: 0, bankMSB: 121, bankLSB: 0)
}

/// A reference to a hosted Audio Unit insert (Build Contract §10). FourCC stored as strings.
public struct AudioUnitRef: Codable, Sendable, Hashable {
    public var type: String
    public var subtype: String
    public var manufacturer: String
    public var name: String
    public var stateBlob: Data?
    public init(type: String, subtype: String, manufacturer: String, name: String = "", stateBlob: Data? = nil) {
        self.type = type; self.subtype = subtype; self.manufacturer = manufacturer
        self.name = name; self.stateBlob = stateBlob
    }
}

// MARK: - Notes & clips

public struct Note: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    public var pitch: Int       // MIDI 0–127
    public var velocity: Int    // 1–127
    public var pitchBend: [Double]?
    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double,
                pitch: Int, velocity: Int, pitchBend: [Double]? = nil) {
        self.id = id; self.startBeat = startBeat; self.lengthBeats = lengthBeats
        self.pitch = pitch; self.velocity = velocity; self.pitchBend = pitchBend
    }
}

public enum ClipKind: String, Codable, Sendable { case audio, midi }

public struct Clip: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: ClipKind
    public var name: String
    public var startBeat: Double
    public var lengthBeats: Double
    /// Relative path within the bundle's `Media/` directory for audio clips.
    public var mediaFile: String?
    /// Offset in seconds into `mediaFile` where this clip begins (audio only; 0 = file start).
    /// Schema v2; v1 projects migrate to 0.
    public var mediaStartSeconds: Double
    public var midiNotes: [Note]?
    public init(id: UUID = UUID(), kind: ClipKind, name: String = "",
                startBeat: Double = 0, lengthBeats: Double = 0,
                mediaFile: String? = nil, mediaStartSeconds: Double = 0,
                midiNotes: [Note]? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.startBeat = startBeat; self.lengthBeats = lengthBeats
        self.mediaFile = mediaFile; self.mediaStartSeconds = mediaStartSeconds
        self.midiNotes = midiNotes
    }
}

// MARK: - Tracks

public enum TrackKind: String, Codable, Sendable { case instrument, audio }

public struct Track: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String
    public var volume: Double    // 0…1 (linear gain into track mixer)
    public var pan: Double       // -1…1
    public var mute: Bool
    public var solo: Bool
    /// Index into the fixed 8-colour identity palette (schema v3). Not a semantic state colour.
    public var colorIndex: Int
    public var instrument: Instrument?
    public var inserts: [AudioUnitRef]
    public var clips: [Clip]
    public init(id: UUID = UUID(), kind: TrackKind, name: String,
                volume: Double = 0.8, pan: Double = 0,
                mute: Bool = false, solo: Bool = false,
                colorIndex: Int = 0,
                instrument: Instrument? = nil, inserts: [AudioUnitRef] = [], clips: [Clip] = []) {
        self.id = id; self.kind = kind; self.name = name
        self.volume = volume; self.pan = pan; self.mute = mute; self.solo = solo
        self.colorIndex = TrackPalette.normalized(colorIndex)
        self.instrument = instrument; self.inserts = inserts; self.clips = clips
    }
}

// MARK: - Project

public struct Project: Codable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var tempoBPM: Double?
    public var key: KeySignature?
    public var timeSignature: TimeSignature
    public var tracks: [Track]
    public var masterVolume: Double
    public var createdAt: Date
    public var modifiedAt: Date

    public init(schemaVersion: Int = Schema.current,
                id: UUID = UUID(),
                title: String = "Untitled",
                tempoBPM: Double? = 120,
                key: KeySignature? = nil,
                timeSignature: TimeSignature = .common,
                tracks: [Track] = [],
                masterVolume: Double = 0.85,
                createdAt: Date = Date(),
                modifiedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.id = id; self.title = title
        self.tempoBPM = tempoBPM; self.key = key
        self.timeSignature = timeSignature; self.tracks = tracks
        self.masterVolume = masterVolume
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }

    /// A fresh untitled project seeded with one piano instrument track (the default new doc).
    public static func newUntitled() -> Project {
        Project(title: "Untitled",
                tracks: [Track(kind: .instrument, name: "Piano",
                               colorIndex: TrackPalette.colorIndexForNewTrack(existingCount: 0),
                               instrument: .grandPiano)])
    }

    /// Round-robin colour for the next track appended to this project.
    public var nextTrackColorIndex: Int {
        TrackPalette.colorIndexForNewTrack(existingCount: tracks.count)
    }

    // MARK: Convenience lookups
    public func track(id: UUID) -> Track? { tracks.first { $0.id == id } }
    public func trackIndex(id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }
    public var anySolo: Bool { tracks.contains { $0.solo } }

    /// Give every track a unique id. Corrupted or hand-edited packages can repeat UUIDs;
    /// the engine then refuses the second `add*Track` and that track is visible but silent.
    /// Keeps the first occurrence of each id; later duplicates get a fresh UUID.
    /// - Returns: how many tracks were re-keyed (0 means already unique).
    @discardableResult
    public mutating func ensureUniqueTrackIDs() -> Int {
        var seen = Set<UUID>()
        var rekeyed = 0
        for i in tracks.indices {
            if seen.contains(tracks[i].id) {
                tracks[i].id = UUID()
                rekeyed += 1
            }
            seen.insert(tracks[i].id)
        }
        return rekeyed
    }

    /// 8-hex-character digest over ordered track UUIDs and, per track, ordered clip UUIDs.
    ///
    /// Structural input only: tempo, title, key, names, mix, notes, and timestamps do not
    /// affect the value. Handles (T1, T2C1, …) are positional over this same order, so a
    /// matching fingerprint means the handles in a patch still mean what they meant when
    /// the request was copied.
    public var structuralFingerprint: String {
        // FNV-1a 32-bit over UUID strings (Foundation only; deterministic across runs).
        var hash: UInt32 = 2_166_136_261
        let prime: UInt32 = 16_777_619
        func feed(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt32(byte)
                hash = hash &* prime
            }
        }
        for track in tracks {
            feed(track.id.uuidString)
            feed(">")
            for clip in track.clips {
                feed(clip.id.uuidString)
                feed(",")
            }
            feed(";")
        }
        return String(format: "%08x", hash)
    }
}

// MARK: - Mutation helpers

/// Readable failures from pure project/track mutations. Callers must not treat a throw as success.
public enum MutationError: Error, Equatable, CustomStringConvertible {
    case clipNotFound
    case noteNotFound
    case trackNotFound
    case negativeStartBeat
    case negativeNoteStartBeat
    case invalidQuantizeGrid(Double)
    case pitchOutOfRange(pitch: Int, semitones: Int)
    /// Pitch for a single-note add/move is outside MIDI 0–127.
    case invalidPitch(Int)
    /// Velocity for a single-note set is outside MIDI 1–127.
    case invalidVelocity(Int)
    /// Note length is not positive (or otherwise unusable).
    case invalidNoteLength(Double)
    /// Clip length is not positive (or otherwise unusable).
    case invalidClipLength(Double)
    /// Clip kind does not match the destination track kind (MIDI→instrument, audio→audio).
    case incompatibleClipTrack(clipKind: ClipKind, trackKind: TrackKind)
    /// `splitClip` is MIDI-only; audio uses `splitAudioClip` (not yet in UI / AI).
    case cannotSplitAudioClip
    /// `splitAudioClip` is audio-only; MIDI uses `splitClip`.
    case cannotSplitNonAudioClip
    /// Split point is at or outside the clip’s own time range (would yield a zero-length half).
    case splitOutOfBounds

    public var description: String {
        switch self {
        case .clipNotFound:
            return "That clip isn’t in this project."
        case .noteNotFound:
            return "That note isn’t in this clip."
        case .trackNotFound:
            return "That track isn’t in this project."
        case .negativeStartBeat:
            return "A clip can’t start before beat 0."
        case .negativeNoteStartBeat:
            return "A note can’t start before beat 0."
        case .invalidQuantizeGrid(let g):
            return "Quantize grid must be 1/4, 1/8, 1/16, 1/32, or a triplet (1/4T, 1/8T, 1/16T) (got \(g))."
        case .pitchOutOfRange(let pitch, let semitones):
            return "Transposing pitch \(pitch) by \(semitones) semitones would leave the MIDI range 0–127."
        case .invalidPitch(let pitch):
            return "Pitch must be between 0 and 127 (got \(pitch))."
        case .invalidVelocity(let velocity):
            return "Velocity must be between 1 and 127 (got \(velocity))."
        case .invalidNoteLength(let length):
            return "A note’s length must be greater than 0 beats (got \(length))."
        case .invalidClipLength(let length):
            return "A clip’s length must be greater than 0 beats (got \(length))."
        case .incompatibleClipTrack(let clipKind, let trackKind):
            switch (clipKind, trackKind) {
            case (.midi, .audio):
                return "A MIDI clip can only go on an instrument track, not an audio track."
            case (.audio, .instrument):
                return "An audio clip can only go on an audio track, not an instrument track."
            default:
                return "That clip can’t go on that track."
            }
        case .cannotSplitAudioClip:
            return "Audio clips can’t be split yet. Only MIDI clips can be split."
        case .cannotSplitNonAudioClip:
            return "Only audio clips can be split this way. Use the regular split for MIDI clips."
        case .splitOutOfBounds:
            return "Move the playhead inside the clip to split it. Splitting at the start or end would leave an empty half."
        }
    }
}

public extension Project {
    /// Locate a clip by id across all tracks. Returns track index and clip index, or nil.
    func clipLocation(id: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for (ti, track) in tracks.enumerated() {
            if let ci = track.clips.firstIndex(where: { $0.id == id }) {
                return (ti, ci)
            }
        }
        return nil
    }

    /// Move a clip’s arrangement start. Rejects `startBeat < 0` because the transport drops
    /// negative-onset MIDI notes and clamps audio, so a negative start is silently partly
    /// inaudible.
    mutating func moveClip(id: UUID, toStartBeat startBeat: Double) throws {
        guard startBeat >= 0 else { throw MutationError.negativeStartBeat }
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        tracks[loc.trackIndex].clips[loc.clipIndex].startBeat = startBeat
    }

    /// Shortest allowed clip length in beats (one 1/32 note). Keeps a clip visible and
    /// resizable on the arrangement timeline.
    static let minimumClipLengthBeats: Double = 0.125

    /// Change a clip’s length. Rejects `lengthBeats <= 0`. Lengths below
    /// `minimumClipLengthBeats` are raised to that floor so the clip stays visible.
    mutating func resizeClip(id: UUID, toLengthBeats lengthBeats: Double) throws {
        guard lengthBeats > 0 else { throw MutationError.invalidClipLength(lengthBeats) }
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        tracks[loc.trackIndex].clips[loc.clipIndex].lengthBeats =
            max(lengthBeats, Self.minimumClipLengthBeats)
    }

    /// Whether a clip of `clipKind` may live on a track of `trackKind`.
    /// MIDI clips need instrument tracks; audio clips need audio tracks.
    static func trackAccepts(clipKind: ClipKind, trackKind: TrackKind) -> Bool {
        switch (clipKind, trackKind) {
        case (.midi, .instrument), (.audio, .audio): return true
        default: return false
        }
    }

    /// Deep-copy a clip value: fresh clip UUID and fresh UUID for every contained note.
    /// Placement, track membership, and `startBeat` are the caller’s job (this only
    /// regenerates identity). Shared by `duplicateClip` and arrangement paste so there is
    /// one copy path for new UUIDs.
    static func deepCopyClip(_ original: Clip) -> Clip {
        var copy = original
        copy.id = UUID()
        if let notes = original.midiNotes {
            copy.midiNotes = notes.map { note in
                var n = note
                n.id = UUID()
                return n
            }
        }
        return copy
    }

    /// Duplicate a clip. The copy gets a fresh clip UUID and every contained `Note` gets a
    /// fresh UUID (via `deepCopyClip`). The copy is placed at `startBeat + lengthBeats` of
    /// the original, on the same track.
    @discardableResult
    mutating func duplicateClip(id: UUID) throws -> Clip {
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        let original = tracks[loc.trackIndex].clips[loc.clipIndex]
        var copy = Self.deepCopyClip(original)
        copy.startBeat = original.startBeat + original.lengthBeats
        tracks[loc.trackIndex].clips.append(copy)
        return copy
    }

    /// Remove a clip by id from its track. Other clips are untouched.
    mutating func removeClip(id: UUID) throws {
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
    }

    /// Split a MIDI clip at an arrangement-absolute beat into two abutting halves on the
    /// same track. Notes entirely before the split stay in the left half; notes entirely
    /// after move to the right with `startBeat` rebased; notes that cross the split become
    /// two notes whose lengths sum to the original. Both result clips and every note get
    /// fresh UUIDs. Audio is refused; a split at or outside the clip bounds is refused
    /// (zero-length half).
    @discardableResult
    mutating func splitClip(id: UUID, atArrangementBeat playhead: Double) throws -> (left: Clip, right: Clip) {
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        let original = tracks[loc.trackIndex].clips[loc.clipIndex]
        guard original.kind == .midi else { throw MutationError.cannotSplitAudioClip }
        let local = playhead - original.startBeat
        guard local > 0, local < original.lengthBeats else {
            throw MutationError.splitOutOfBounds
        }

        let leftLen = local
        let rightLen = original.lengthBeats - local
        var leftNotes: [Note] = []
        var rightNotes: [Note] = []
        for note in original.midiNotes ?? [] {
            let noteEnd = note.startBeat + note.lengthBeats
            if noteEnd <= local {
                // Entirely before the split: keep local start, new UUID.
                leftNotes.append(Note(
                    id: UUID(),
                    startBeat: note.startBeat,
                    lengthBeats: note.lengthBeats,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    pitchBend: note.pitchBend
                ))
            } else if note.startBeat >= local {
                // Entirely after: rebase into the right clip.
                rightNotes.append(Note(
                    id: UUID(),
                    startBeat: note.startBeat - local,
                    lengthBeats: note.lengthBeats,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    pitchBend: note.pitchBend
                ))
            } else {
                // Crosses the boundary: one note ending at the split, one starting there.
                let leftPartLen = local - note.startBeat
                let rightPartLen = noteEnd - local
                leftNotes.append(Note(
                    id: UUID(),
                    startBeat: note.startBeat,
                    lengthBeats: leftPartLen,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    pitchBend: note.pitchBend
                ))
                rightNotes.append(Note(
                    id: UUID(),
                    startBeat: 0,
                    lengthBeats: rightPartLen,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    pitchBend: note.pitchBend
                ))
            }
        }

        let left = Clip(
            id: UUID(),
            kind: .midi,
            name: original.name,
            startBeat: original.startBeat,
            lengthBeats: leftLen,
            mediaFile: nil,
            mediaStartSeconds: 0,
            midiNotes: leftNotes
        )
        let right = Clip(
            id: UUID(),
            kind: .midi,
            name: original.name,
            startBeat: playhead,
            lengthBeats: rightLen,
            mediaFile: nil,
            mediaStartSeconds: 0,
            midiNotes: rightNotes
        )

        tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
        tracks[loc.trackIndex].clips.insert(left, at: loc.clipIndex)
        tracks[loc.trackIndex].clips.insert(right, at: loc.clipIndex + 1)
        return (left, right)
    }

    /// Split an audio clip at an arrangement-absolute beat into two abutting halves on the
    /// same track. The left half keeps `mediaStartSeconds`; the right half advances it by
    /// the left duration in seconds (from project tempo). Both result clips get fresh UUIDs.
    /// MIDI is refused (use `splitClip`); a split at or outside the clip bounds is refused.
    @discardableResult
    mutating func splitAudioClip(id: UUID, atBeat playhead: Double) throws -> (left: Clip, right: Clip) {
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        let original = tracks[loc.trackIndex].clips[loc.clipIndex]
        guard original.kind == .audio else { throw MutationError.cannotSplitNonAudioClip }
        let local = playhead - original.startBeat
        guard local > 0, local < original.lengthBeats else {
            throw MutationError.splitOutOfBounds
        }

        let leftLen = local
        let rightLen = original.lengthBeats - local
        let bpm = tempoBPM ?? 120
        let secondsPerBeat = 60.0 / bpm
        let advancedMediaStart = original.mediaStartSeconds + leftLen * secondsPerBeat

        let left = Clip(
            id: UUID(),
            kind: .audio,
            name: original.name,
            startBeat: original.startBeat,
            lengthBeats: leftLen,
            mediaFile: original.mediaFile,
            mediaStartSeconds: original.mediaStartSeconds,
            midiNotes: nil
        )
        let right = Clip(
            id: UUID(),
            kind: .audio,
            name: original.name,
            startBeat: playhead,
            lengthBeats: rightLen,
            mediaFile: original.mediaFile,
            mediaStartSeconds: advancedMediaStart,
            midiNotes: nil
        )

        tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
        tracks[loc.trackIndex].clips.insert(left, at: loc.clipIndex)
        tracks[loc.trackIndex].clips.insert(right, at: loc.clipIndex + 1)
        return (left, right)
    }

    /// Move a clip to another track and/or start beat. Rejects negative starts and kind
    /// mismatches (MIDI only on instrument tracks, audio only on audio tracks). Same-track
    /// moves only update `startBeat` when provided.
    mutating func moveClip(id: UUID, toTrackIndex destTrack: Int, startBeat: Double? = nil) throws {
        guard tracks.indices.contains(destTrack) else { throw MutationError.trackNotFound }
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        if let startBeat, startBeat < 0 { throw MutationError.negativeStartBeat }
        var clip = tracks[loc.trackIndex].clips[loc.clipIndex]
        let destKind = tracks[destTrack].kind
        guard Self.trackAccepts(clipKind: clip.kind, trackKind: destKind) else {
            throw MutationError.incompatibleClipTrack(clipKind: clip.kind, trackKind: destKind)
        }
        if let startBeat {
            clip.startBeat = startBeat
        }
        if loc.trackIndex == destTrack {
            tracks[loc.trackIndex].clips[loc.clipIndex] = clip
            return
        }
        tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
        tracks[destTrack].clips.append(clip)
    }

    /// Append a clip onto a track. Rejects kind mismatch. Used by paste after `deepCopyClip`.
    mutating func insertClip(_ clip: Clip, onTrackIndex trackIndex: Int) throws {
        guard tracks.indices.contains(trackIndex) else { throw MutationError.trackNotFound }
        let trackKind = tracks[trackIndex].kind
        guard Self.trackAccepts(clipKind: clip.kind, trackKind: trackKind) else {
            throw MutationError.incompatibleClipTrack(clipKind: clip.kind, trackKind: trackKind)
        }
        tracks[trackIndex].clips.append(clip)
    }

    /// Quantize note **starts** in a clip to the nearest grid point.
    ///
    /// - Supported grids: see `SnapGrid.allowedQuantizeGrids` (straight 1/4–1/32 and
    ///   triplets 1/4T, 1/8T, 1/16T).
    /// - Only start times move; lengths are untouched.
    /// - Starts are never moved past the clip end (`lengthBeats`); they clamp to that bound.
    /// - Starts are never moved before beat 0 within the clip.
    /// - When `noteIDs` is non-nil and non-empty, only those notes are quantized; otherwise
    ///   every note in the clip is quantized.
    mutating func quantizeNotes(in clipID: UUID, to gridBeats: Double, noteIDs: Set<UUID>? = nil) throws {
        guard SnapGrid.isAllowedQuantizeGrid(gridBeats) else {
            throw MutationError.invalidQuantizeGrid(gridBeats)
        }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        let clipEnd = tracks[loc.trackIndex].clips[loc.clipIndex].lengthBeats
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes, !notes.isEmpty else {
            return
        }
        let filter: Set<UUID>? = {
            guard let noteIDs, !noteIDs.isEmpty else { return nil }
            return noteIDs
        }()
        for i in notes.indices {
            if let filter, !filter.contains(notes[i].id) { continue }
            let raw = (notes[i].startBeat / gridBeats).rounded() * gridBeats
            notes[i].startBeat = min(max(0, raw), clipEnd)
        }
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }

    /// Shift every note pitch in a clip by `semitones`. **Rejects** (does not clamp) if any
    /// resulting pitch would leave the MIDI range 0–127. Empty note lists succeed as a no-op.
    mutating func transposeNotes(in clipID: UUID, by semitones: Int) throws {
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes, !notes.isEmpty else {
            return
        }
        for n in notes {
            let next = n.pitch + semitones
            if !(0...127).contains(next) {
                throw MutationError.pitchOutOfRange(pitch: n.pitch, semitones: semitones)
            }
        }
        for i in notes.indices {
            notes[i].pitch += semitones
        }
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }

    // MARK: - Note-level helpers (piano roll)

    /// Shortest allowed note length in beats: one 1/32 note (so a note can never become
    /// zero-length and invisible on the roll).
    static let minimumNoteLengthBeats: Double = 0.125

    /// Append a note to a clip. Rejects pitch outside 0–127, `startBeat < 0`, and
    /// `lengthBeats <= 0`. Lengths below `minimumNoteLengthBeats` are raised to that floor.
    /// Initializes `midiNotes` when the clip has none yet.
    @discardableResult
    mutating func addNote(toClip clipID: UUID, pitch: Int, startBeat: Double,
                          lengthBeats: Double, velocity: Int) throws -> UUID {
        guard (0...127).contains(pitch) else { throw MutationError.invalidPitch(pitch) }
        guard startBeat >= 0 else { throw MutationError.negativeNoteStartBeat }
        guard lengthBeats > 0 else { throw MutationError.invalidNoteLength(lengthBeats) }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        let length = max(lengthBeats, Self.minimumNoteLengthBeats)
        let note = Note(startBeat: startBeat, lengthBeats: length, pitch: pitch, velocity: velocity)
        var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes ?? []
        notes.append(note)
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
        return note.id
    }

    /// Remove a note by id from a clip. Leaves other notes untouched.
    mutating func deleteNote(id noteID: UUID, inClip clipID: UUID) throws {
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes else {
            throw MutationError.noteNotFound
        }
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else {
            throw MutationError.noteNotFound
        }
        notes.remove(at: idx)
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }

    /// Move a note’s pitch and start. Same pitch / start validation as `addNote`. Length is
    /// unchanged. Other notes in the clip are untouched.
    mutating func moveNote(id noteID: UUID, inClip clipID: UUID,
                           toPitch pitch: Int, toStartBeat startBeat: Double) throws {
        guard (0...127).contains(pitch) else { throw MutationError.invalidPitch(pitch) }
        guard startBeat >= 0 else { throw MutationError.negativeNoteStartBeat }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes else {
            throw MutationError.noteNotFound
        }
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else {
            throw MutationError.noteNotFound
        }
        notes[idx].pitch = pitch
        notes[idx].startBeat = startBeat
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }

    /// Change a note’s length. Rejects `lengthBeats <= 0`. Lengths below
    /// `minimumNoteLengthBeats` are raised to that floor so the note stays visible.
    mutating func resizeNote(id noteID: UUID, inClip clipID: UUID,
                             toLengthBeats lengthBeats: Double) throws {
        guard lengthBeats > 0 else { throw MutationError.invalidNoteLength(lengthBeats) }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes else {
            throw MutationError.noteNotFound
        }
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else {
            throw MutationError.noteNotFound
        }
        notes[idx].lengthBeats = max(lengthBeats, Self.minimumNoteLengthBeats)
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }

    /// Set a note’s velocity. Rejects values outside MIDI 1–127. Pitch, start, and length
    /// are unchanged. Other notes in the clip are untouched.
    mutating func setNoteVelocity(id noteID: UUID, inClip clipID: UUID, velocity: Int) throws {
        guard (1...127).contains(velocity) else { throw MutationError.invalidVelocity(velocity) }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes else {
            throw MutationError.noteNotFound
        }
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else {
            throw MutationError.noteNotFound
        }
        notes[idx].velocity = velocity
        tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes = notes
    }
}

// MARK: - Codable JSON helpers

public extension Project {
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    func jsonData() throws -> Data { try Self.makeEncoder().encode(self) }
    static func fromJSON(_ data: Data) throws -> Project {
        // Migrate forward if the persisted schema is older than current.
        let migrated = try Migration.migrateRawIfNeeded(data)
        return try makeDecoder().decode(Project.self, from: migrated)
    }
}
