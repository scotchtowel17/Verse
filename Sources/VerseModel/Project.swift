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
