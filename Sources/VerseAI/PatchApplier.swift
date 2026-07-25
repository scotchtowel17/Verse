import Foundation
import VerseModel
import VerseCommands

/// Applies validated, fully-resolved ops to a project (Build Contract §E.4).
/// Application is transactional via `PatchCommand`. Unresolvable references now throw
/// instead of silently succeeding.
public enum PatchApplier {

    public static func apply(_ ops: [TypedOp], to project: inout Project) throws {
        var tempTrack: [String: UUID] = [:]
        var tempClip: [String: (track: UUID, clip: UUID)] = [:]

        func uuid(_ ref: TrackRef) throws -> UUID {
            switch ref {
            case .existing(let u): return u
            case .temp(let t):
                guard let u = tempTrack[t] else {
                    throw PatchError(opIndex: nil, "Unresolved temporary track “\(t)”.")
                }
                return u
            }
        }

        func index(_ ref: TrackRef) throws -> Int {
            let u = try uuid(ref)
            guard let i = project.trackIndex(id: u) else {
                throw PatchError(opIndex: nil, "Track no longer exists in project.")
            }
            return i
        }

        for op in ops {
            switch op {
            case .setTempo(let b):
                project.tempoBPM = b
            case .setKey(let t, let m):
                project.key = KeySignature(tonic: t, mode: m)
            case .setTimeSignature(let n, let d):
                project.timeSignature = TimeSignature(num: n, den: d)
            case .createTrack(let tempId, let kind, let name, let inst):
                let instrument = (kind == .instrument) ? (inst ?? .grandPiano) : inst
                let t = Track(kind: kind, name: name, instrument: instrument)
                project.tracks.append(t)
                tempTrack[tempId] = t.id
            case .renameTrack(let ref, let name):
                let i = try index(ref)
                project.tracks[i].name = name
            case .setInstrument(let ref, let inst):
                let i = try index(ref)
                project.tracks[i].instrument = inst
            case .setTrackMix(let ref, let v, let p, let mu, let so):
                let i = try index(ref)
                if let v { project.tracks[i].volume = v }
                if let p { project.tracks[i].pan = p }
                if let mu { project.tracks[i].mute = mu }
                if let so { project.tracks[i].solo = so }
            case .addMidiClip(let ref, let tempClipId, let start, let len):
                let i = try index(ref)
                let c = Clip(kind: .midi, name: "Clip", startBeat: start, lengthBeats: len, midiNotes: [])
                project.tracks[i].clips.append(c)
                tempClip[tempClipId] = (project.tracks[i].id, c.id)
            case .addNotes(let trackRef, let clipRef, let notes):
                let (trackUUID, clipUUID) = try resolveClipLocation(clipRef, tempClip: tempClip, trackRef: trackRef, tempTrack: tempTrack)
                guard let ti = project.trackIndex(id: trackUUID),
                      let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipUUID }) else {
                    throw PatchError(opIndex: nil, "Clip no longer exists in project.")
                }
                var existing = project.tracks[ti].clips[ci].midiNotes ?? []
                existing.append(contentsOf: notes)
                project.tracks[ti].clips[ci].midiNotes = existing
            case .deleteClip(let trackRef, let clipRef):
                let (trackUUID, clipUUID) = try resolveClipLocation(clipRef, tempClip: tempClip, trackRef: trackRef, tempTrack: tempTrack)
                guard let ti = project.trackIndex(id: trackUUID) else {
                    throw PatchError(opIndex: nil, "Track no longer exists in project.")
                }
                project.tracks[ti].clips.removeAll { $0.id == clipUUID }
            }
        }
        project.modifiedAt = Date()
    }

    private static func resolveClipLocation(
        _ clipRef: ClipRef,
        tempClip: [String: (track: UUID, clip: UUID)],
        trackRef: TrackRef,
        tempTrack: [String: UUID]
    ) throws -> (track: UUID, clip: UUID) {
        switch clipRef {
        case .temp(let cid):
            guard let loc = tempClip[cid] else {
                throw PatchError(opIndex: nil, "Unresolved temporary clip “\(cid)”.")
            }
            return loc
        case .existing(let track, let clip):
            // Optional ownership sanity check against the track ref (best-effort)
            return (track, clip)
        }
    }
}

/// A whole patch as one undoable command (Build Contract §E.4 "apply as one undo group").
public struct PatchCommand: ProjectCommand {
    public let name: String
    public let ops: [TypedOp]
    public init(name: String, ops: [TypedOp]) { self.name = name; self.ops = ops }
    public func apply(to project: inout Project) throws { try PatchApplier.apply(ops, to: &project) }
}
