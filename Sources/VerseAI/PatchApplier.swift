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

        func uuid(_ ref: TrackRef, opIndex: Int) throws -> UUID {
            switch ref {
            case .existing(let u): return u
            case .temp(let t):
                guard let u = tempTrack[t] else {
                    throw PatchError(opIndex: opIndex, "Unresolved temporary track “\(t)”.")
                }
                return u
            }
        }

        func index(_ ref: TrackRef, opIndex: Int) throws -> Int {
            let u = try uuid(ref, opIndex: opIndex)
            guard let i = project.trackIndex(id: u) else {
                throw PatchError(opIndex: opIndex, "Track no longer exists in project.")
            }
            return i
        }

        for (opIndex, op) in ops.enumerated() {
            switch op {
            case .setTempo(let b):
                project.tempoBPM = b
            case .setKey(let t, let m):
                project.key = KeySignature(tonic: t, mode: m)
            case .setTimeSignature(let n, let d):
                project.timeSignature = TimeSignature(num: n, den: d)
            case .createTrack(let tempId, let kind, let name, let inst):
                let instrument = (kind == .instrument) ? (inst ?? .grandPiano) : inst
                let t = Track(kind: kind, name: name,
                              colorIndex: project.nextTrackColorIndex,
                              instrument: instrument)
                project.tracks.append(t)
                tempTrack[tempId] = t.id
            case .renameTrack(let ref, let name):
                let i = try index(ref, opIndex: opIndex)
                project.tracks[i].name = name
            case .setInstrument(let ref, let inst):
                let i = try index(ref, opIndex: opIndex)
                project.tracks[i].instrument = inst
            case .setTrackMix(let ref, let v, let p, let mu, let so):
                let i = try index(ref, opIndex: opIndex)
                if let v { project.tracks[i].volume = v }
                if let p { project.tracks[i].pan = p }
                if let mu { project.tracks[i].mute = mu }
                if let so { project.tracks[i].solo = so }
            case .addMidiClip(let ref, let tempClipId, let start, let len):
                let i = try index(ref, opIndex: opIndex)
                let c = Clip(kind: .midi, name: "Clip", startBeat: start, lengthBeats: len, midiNotes: [])
                project.tracks[i].clips.append(c)
                tempClip[tempClipId] = (project.tracks[i].id, c.id)
            case .addNotes(_, let clipRef, let notes):
                let (trackUUID, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                guard let ti = project.trackIndex(id: trackUUID),
                      let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipUUID }) else {
                    throw PatchError(opIndex: opIndex, "Clip no longer exists in project.")
                }
                var existing = project.tracks[ti].clips[ci].midiNotes ?? []
                existing.append(contentsOf: notes)
                project.tracks[ti].clips[ci].midiNotes = existing
            case .deleteClip(_, let clipRef):
                let (trackUUID, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                guard let ti = project.trackIndex(id: trackUUID) else {
                    throw PatchError(opIndex: opIndex, "Track no longer exists in project.")
                }
                project.tracks[ti].clips.removeAll { $0.id == clipUUID }
            case .quantizeNotes(_, let clipRef, let gridBeats):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    try project.quantizeNotes(in: clipUUID, to: gridBeats)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .transposeNotes(_, let clipRef, let semitones):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    try project.transposeNotes(in: clipUUID, by: semitones)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .moveClip(_, let clipRef, let startBeat):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    try project.moveClip(id: clipUUID, toStartBeat: startBeat)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .resizeClip(_, let clipRef, let lengthBeats):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    // Validator already rejected below-minimum lengths; Project still floors.
                    try project.resizeClip(id: clipUUID, toLengthBeats: lengthBeats)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .duplicateClip(_, let clipRef):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    try project.duplicateClip(id: clipUUID)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .splitClip(_, let clipRef, let atBeat):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                do {
                    try project.splitClip(id: clipUUID, atArrangementBeat: atBeat)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .moveClipToTrack(_, let clipRef, let toTrack, let startBeat):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                let destIndex = try index(toTrack, opIndex: opIndex)
                do {
                    try project.moveClip(id: clipUUID, toTrackIndex: destIndex, startBeat: startBeat)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .deleteNote(_, let clipRef, let noteRef):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                let noteUUID = try resolveNoteUUID(noteRef, opIndex: opIndex)
                do {
                    try project.deleteNote(id: noteUUID, inClip: clipUUID)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .moveNote(_, let clipRef, let noteRef, let pitch, let startBeat):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                let noteUUID = try resolveNoteUUID(noteRef, opIndex: opIndex)
                do {
                    try project.moveNote(id: noteUUID, inClip: clipUUID,
                                         toPitch: pitch, toStartBeat: startBeat)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            case .setNoteVelocity(_, let clipRef, let noteRef, let velocity):
                let (_, clipUUID) = try resolveClipLocation(
                    clipRef, tempClip: tempClip, opIndex: opIndex)
                let noteUUID = try resolveNoteUUID(noteRef, opIndex: opIndex)
                do {
                    try project.setNoteVelocity(id: noteUUID, inClip: clipUUID, velocity: velocity)
                } catch let err as MutationError {
                    throw PatchError(opIndex: opIndex, err.description)
                }
            }
        }
        project.modifiedAt = Date()
    }

    /// Clip ownership vs. the op's track field is enforced in `PatchValidator` before apply.
    private static func resolveClipLocation(
        _ clipRef: ClipRef,
        tempClip: [String: (track: UUID, clip: UUID)],
        opIndex: Int
    ) throws -> (track: UUID, clip: UUID) {
        switch clipRef {
        case .temp(let cid):
            guard let loc = tempClip[cid] else {
                throw PatchError(opIndex: opIndex, "Unresolved temporary clip “\(cid)”.")
            }
            return loc
        case .existing(let track, let clip):
            return (track, clip)
        }
    }

    /// Note UUID is resolved at validation; apply only unwraps the already-checked ref.
    private static func resolveNoteUUID(_ noteRef: NoteRef, opIndex: Int) throws -> UUID {
        switch noteRef {
        case .existing(_, _, let note):
            return note
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
