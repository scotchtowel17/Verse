import Foundation
import VerseModel
import VerseCommands

/// Applies validated, fully-resolved ops to a project (Build Contract §E.4). Because validation
/// already guaranteed every reference and value, application can't fail partway — but it still
/// runs on a working copy via `PatchCommand` so the whole patch is one undo group.
public enum PatchApplier {

    public static func apply(_ ops: [TypedOp], to project: inout Project) {
        var tempTrack: [String: UUID] = [:]
        var tempClip: [String: (track: UUID, clip: UUID)] = [:]

        func uuid(_ ref: TrackRef) -> UUID? {
            switch ref {
            case .existing(let u): return u
            case .temp(let t): return tempTrack[t]
            }
        }
        func index(_ ref: TrackRef) -> Int? {
            guard let u = uuid(ref) else { return nil }
            return project.trackIndex(id: u)
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
                if let i = index(ref) { project.tracks[i].name = name }
            case .setInstrument(let ref, let inst):
                if let i = index(ref) { project.tracks[i].instrument = inst }
            case .setTrackMix(let ref, let v, let p, let mu, let so):
                if let i = index(ref) {
                    if let v { project.tracks[i].volume = v }
                    if let p { project.tracks[i].pan = p }
                    if let mu { project.tracks[i].mute = mu }
                    if let so { project.tracks[i].solo = so }
                }
            case .addMidiClip(let ref, let tempClipId, let start, let len):
                if let i = index(ref) {
                    let c = Clip(kind: .midi, name: "Clip", startBeat: start, lengthBeats: len, midiNotes: [])
                    project.tracks[i].clips.append(c)
                    tempClip[tempClipId] = (project.tracks[i].id, c.id)
                }
            case .addNotes(_, let clipRef, let notes):
                if case .temp(let cid) = clipRef, let loc = tempClip[cid],
                   let ti = project.trackIndex(id: loc.track),
                   let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == loc.clip }) {
                    var existing = project.tracks[ti].clips[ci].midiNotes ?? []
                    existing.append(contentsOf: notes)
                    project.tracks[ti].clips[ci].midiNotes = existing
                }
            case .deleteClip(_, let clipRef):
                if case .temp(let cid) = clipRef, let loc = tempClip[cid],
                   let ti = project.trackIndex(id: loc.track) {
                    project.tracks[ti].clips.removeAll { $0.id == loc.clip }
                }
            }
        }
        project.modifiedAt = Date()
    }
}

/// A whole patch as one undoable command (Build Contract §E.4 "apply as one undo group").
public struct PatchCommand: ProjectCommand {
    public let name: String
    public let ops: [TypedOp]
    public init(name: String, ops: [TypedOp]) { self.name = name; self.ops = ops }
    public func apply(to project: inout Project) throws { PatchApplier.apply(ops, to: &project) }
}
