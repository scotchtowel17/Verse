import Foundation

/// The authoritative, serialized project model (Build Contract §10).
///
/// At runtime the audio engine is the single source of truth; this model mirrors it and
/// is what gets persisted to `project.json` inside the `.verse` file package. The model
/// imports no UI and no audio frameworks so it can be unit-tested in isolation.

// MARK: - Schema versioning

public enum Schema {
    /// Bump on any breaking change to the persisted shape; `Migration` chains forward.
    public static let current: Int = 1
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
    public var sf2: String          // logical sound-bank name, e.g. "GeneralUserGS"
    public var program: Int         // GM program 0–127
    public var bankMSB: Int
    public var bankLSB: Int
    public init(sf2: String = "GeneralUserGS", program: Int = 0, bankMSB: Int = 121, bankLSB: Int = 0) {
        self.sf2 = sf2; self.program = program; self.bankMSB = bankMSB; self.bankLSB = bankLSB
    }
    public static let grandPiano = Instrument(sf2: "GeneralUserGS", program: 0, bankMSB: 121, bankLSB: 0)
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
    public var midiNotes: [Note]?
    public init(id: UUID = UUID(), kind: ClipKind, name: String = "",
                startBeat: Double = 0, lengthBeats: Double = 0,
                mediaFile: String? = nil, midiNotes: [Note]? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.startBeat = startBeat; self.lengthBeats = lengthBeats
        self.mediaFile = mediaFile; self.midiNotes = midiNotes
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
    public var instrument: Instrument?
    public var inserts: [AudioUnitRef]
    public var clips: [Clip]
    public init(id: UUID = UUID(), kind: TrackKind, name: String,
                volume: Double = 0.8, pan: Double = 0,
                mute: Bool = false, solo: Bool = false,
                instrument: Instrument? = nil, inserts: [AudioUnitRef] = [], clips: [Clip] = []) {
        self.id = id; self.kind = kind; self.name = name
        self.volume = volume; self.pan = pan; self.mute = mute; self.solo = solo
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
                tracks: [Track(kind: .instrument, name: "Piano", instrument: .grandPiano)])
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

// MARK: - Mutation helpers (schema stays v1)

/// Readable failures from pure project/track mutations. Callers must not treat a throw as success.
public enum MutationError: Error, Equatable, CustomStringConvertible {
    case clipNotFound
    case negativeStartBeat
    case invalidQuantizeGrid(Double)
    case pitchOutOfRange(pitch: Int, semitones: Int)

    public var description: String {
        switch self {
        case .clipNotFound:
            return "That clip isn’t in this project."
        case .negativeStartBeat:
            return "A clip can’t start before beat 0."
        case .invalidQuantizeGrid(let g):
            return "Quantize grid must be 1/4, 1/8, or 1/16 beat (got \(g))."
        case .pitchOutOfRange(let pitch, let semitones):
            return "Transposing pitch \(pitch) by \(semitones) semitones would leave the MIDI range 0–127."
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

    /// Duplicate a clip. The copy gets a fresh clip UUID and every contained `Note` gets a
    /// fresh UUID. The copy is placed at `startBeat + lengthBeats` of the original.
    @discardableResult
    mutating func duplicateClip(id: UUID) throws -> Clip {
        guard let loc = clipLocation(id: id) else { throw MutationError.clipNotFound }
        let original = tracks[loc.trackIndex].clips[loc.clipIndex]
        var copy = original
        copy.id = UUID()
        copy.startBeat = original.startBeat + original.lengthBeats
        if let notes = original.midiNotes {
            copy.midiNotes = notes.map { note in
                var n = note
                n.id = UUID()
                return n
            }
        }
        tracks[loc.trackIndex].clips.append(copy)
        return copy
    }

    /// Quantize note **starts** in a clip to the nearest grid point.
    ///
    /// - Supported grids (in beats): `1` (1/4), `0.5` (1/8), `0.25` (1/16).
    /// - Only start times move; lengths are untouched.
    /// - Starts are never moved past the clip end (`lengthBeats`); they clamp to that bound.
    /// - Starts are never moved before beat 0 within the clip.
    mutating func quantizeNotes(in clipID: UUID, to gridBeats: Double) throws {
        let allowed: Set<Double> = [1.0, 0.5, 0.25]
        guard allowed.contains(gridBeats) else { throw MutationError.invalidQuantizeGrid(gridBeats) }
        guard let loc = clipLocation(id: clipID) else { throw MutationError.clipNotFound }
        let clipEnd = tracks[loc.trackIndex].clips[loc.clipIndex].lengthBeats
        guard var notes = tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes, !notes.isEmpty else {
            return
        }
        for i in notes.indices {
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
