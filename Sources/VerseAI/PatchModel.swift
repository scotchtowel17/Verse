import Foundation
import VerseModel

/// Allowed operations (Build Contract §E.3). Each is fully validated and reference-resolved
/// before any of them is applied.

public enum TrackRef: Equatable {
    case existing(UUID)     // an existing track resolved from its handle (T1, T2, …)
    case temp(String)       // a tempId minted earlier in the same patch
}

public enum ClipRef: Equatable {
    case temp(String)                          // a tempClipId minted earlier in the same patch
    case existing(track: UUID, clip: UUID)     // resolved from a positional handle (T2C1, …)
}

public enum TypedOp {
    case setTempo(Double)
    case setKey(Tonic, Mode)
    case setTimeSignature(num: Int, den: Int)
    case createTrack(tempId: String, kind: TrackKind, name: String, instrument: Instrument?)
    case renameTrack(TrackRef, name: String)
    case setInstrument(TrackRef, Instrument)
    case setTrackMix(TrackRef, volume: Double?, pan: Double?, mute: Bool?, solo: Bool?)
    case addMidiClip(track: TrackRef, tempClipId: String, startBeat: Double, lengthBeats: Double)
    case addNotes(track: TrackRef, clip: ClipRef, notes: [Note])
    case deleteClip(track: TrackRef, clip: ClipRef)
    /// Snap note starts to grid. `gridBeats` is 1 (1/4), 0.5 (1/8), or 0.25 (1/16).
    case quantizeNotes(track: TrackRef, clip: ClipRef, gridBeats: Double)
    /// Shift all note pitches by `semitones`. Out-of-range results are rejected, never clamped.
    case transposeNotes(track: TrackRef, clip: ClipRef, semitones: Int)
    /// Move a clip’s arrangement start. Works for MIDI and audio clips.
    case moveClip(track: TrackRef, clip: ClipRef, startBeat: Double)
}

public struct PatchError: Error, Equatable, CustomStringConvertible {
    public let opIndex: Int?     // 0-based op index, or nil for a whole-patch problem
    public let message: String
    public init(opIndex: Int?, _ message: String) { self.opIndex = opIndex; self.message = message }
    public var description: String {
        if let i = opIndex { return "Operation \(i + 1): \(message)" }
        return message
    }
}

/// Wraps the collected problems so it can be a `Result` failure type.
public struct PatchErrors: Error {
    public let errors: [PatchError]
    public init(_ errors: [PatchError]) { self.errors = errors }
}

public let versePatchOps: Set<String> = [
    "setTempo", "setKey", "setTimeSignature", "createTrack", "renameTrack",
    "setInstrument", "setTrackMix", "addMidiClip", "addNotes", "deleteClip",
    "quantizeNotes", "transposeNotes", "moveClip"
]

// MARK: - JSON coercion helpers (tolerant of NSNumber/Int/Double)

enum JSONCoerce {
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }
    static func string(_ v: Any?) -> String? { v as? String }
    static func instrument(_ v: Any?) -> Instrument? {
        guard let d = v as? [String: Any] else { return nil }
        return Instrument(
            sf2: string(d["sf2"]) ?? "GeneralUserGS",
            program: int(d["program"]) ?? 0,
            bankMSB: int(d["bankMSB"]) ?? 121,
            bankLSB: int(d["bankLSB"]) ?? 0)
    }
}
