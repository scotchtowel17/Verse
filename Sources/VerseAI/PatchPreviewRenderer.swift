import Foundation
import VerseModel

/// Plain-English description of a validated patch, built **exclusively** from `TypedOp`
/// values plus the live project (for track/clip names and audio take filenames).
///
/// Never reads `parsed.summary` or any other free-form Claude prose. That prose may be
/// shown separately under a “Claude says:” label, but it is never the approval text.
public enum PatchPreviewRenderer {

    /// One human-readable line per logical change, then any clamp notices.
    public static func render(ops: [TypedOp], clamps: [String], project: Project) -> [String] {
        var tempTrackNames: [String: String] = [:]
        var lines: [String] = []

        for op in ops {
            switch op {
            case .setTempo(let bpm):
                lines.append("Set tempo to \(formatNumber(bpm)) BPM")

            case .setKey(let tonic, let mode):
                lines.append("Set key to \(tonic.rawValue) \(mode.rawValue)")

            case .setTimeSignature(let num, let den):
                lines.append("Set time signature to \(num)/\(den)")

            case .createTrack(let tempId, let kind, let name, _):
                tempTrackNames[tempId] = name
                let kindWord = kind == .instrument ? "instrument" : "audio"
                lines.append("Create \(kindWord) track \(quote(name))")

            case .renameTrack(let ref, let name):
                let from = trackLabel(ref, project: project, temps: tempTrackNames)
                lines.append("Rename \(from) to \(quote(name))")
                if case .temp(let t) = ref { tempTrackNames[t] = name }

            case .setInstrument(let ref, let inst):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                lines.append("Set instrument on \(track) to program \(inst.program)")

            case .setTrackMix(let ref, let volume, let pan, let mute, let solo):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                var parts: [String] = []
                if let volume { parts.append("volume \(formatNumber(volume))") }
                if let pan { parts.append("pan \(formatNumber(pan))") }
                if let mute { parts.append(mute ? "mute on" : "mute off") }
                if let solo { parts.append(solo ? "solo on" : "solo off") }
                if parts.isEmpty {
                    lines.append("Set mix on \(track) (no changes)")
                } else {
                    lines.append("Set mix on \(track): \(parts.joined(separator: ", "))")
                }

            case .addMidiClip(let ref, _, let start, let length):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                lines.append(
                    "Add MIDI clip on \(track) (\(formatNumber(length)) beats from beat \(formatNumber(start)))")

            case .addNotes(let ref, _, let notes):
                // Group note lists into a single count line; never dump individual pitches.
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let n = notes.count
                lines.append("\(track): add \(n) note\(n == 1 ? "" : "s")")

            case .deleteClip(let ref, let clipRef):
                lines.append(deleteClipLine(track: ref, clip: clipRef,
                                            project: project, temps: tempTrackNames))

            case .quantizeNotes(let ref, let clipRef, let gridBeats):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Quantize notes in \(clip) on \(track) to \(gridLabel(gridBeats))")

            case .transposeNotes(let ref, let clipRef, let semitones):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                let direction: String
                if semitones > 0 {
                    direction = "up \(semitones) semitone\(semitones == 1 ? "" : "s")"
                } else if semitones < 0 {
                    let n = abs(semitones)
                    direction = "down \(n) semitone\(n == 1 ? "" : "s")"
                } else {
                    direction = "by 0 semitones"
                }
                lines.append("Transpose notes in \(clip) on \(track) \(direction)")

            case .moveClip(let ref, let clipRef, let startBeat):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Move \(clip) on \(track) to beat \(formatNumber(startBeat))")

            case .resizeClip(let ref, let clipRef, let lengthBeats):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Resize \(clip) on \(track) to \(formatNumber(lengthBeats)) beats")

            case .duplicateClip(let ref, let clipRef):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Duplicate \(clip) on \(track)")

            case .splitClip(let ref, let clipRef, let atBeat):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Split \(clip) on \(track) at beat \(formatNumber(atBeat))")

            case .moveClipToTrack(let ref, let clipRef, let toTrack, let startBeat):
                let from = trackLabel(ref, project: project, temps: tempTrackNames)
                let to = trackLabel(toTrack, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                if let startBeat {
                    lines.append("Move \(clip) from \(from) to \(to) at beat \(formatNumber(startBeat))")
                } else {
                    lines.append("Move \(clip) from \(from) to \(to)")
                }

            case .deleteNote(let ref, let clipRef, _):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append("Delete a note in \(clip) on \(track)")

            case .moveNote(let ref, let clipRef, _, let pitch, let startBeat):
                let track = trackLabel(ref, project: project, temps: tempTrackNames)
                let clip = clipLabel(clipRef, project: project)
                lines.append(
                    "Move a note in \(clip) on \(track) to pitch \(pitch) at beat \(formatNumber(startBeat))")
            }
        }

        for notice in clamps {
            lines.append(notice)
        }
        return lines
    }

    /// Joined multi-line description used as the approval text.
    public static func description(ops: [TypedOp], clamps: [String], project: Project) -> String {
        render(ops: ops, clamps: clamps, project: project).joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func deleteClipLine(track: TrackRef, clip: ClipRef,
                                       project: Project, temps: [String: String]) -> String {
        let trackPart = trackLabel(track, project: project, temps: temps)
        switch clip {
        case .temp(let id):
            return "Delete clip \(quote(id)) on \(trackPart)"
        case .existing(_, let clipID):
            guard let resolved = findClip(clipID, in: project) else {
                return "Delete clip on \(trackPart)"
            }
            let clipName = resolved.name.isEmpty ? "unnamed clip" : resolved.name
            if resolved.kind == .audio {
                if let take = resolved.mediaFile, !take.isEmpty {
                    return "Delete audio clip \(quote(clipName)) on \(trackPart) (removes take \(quote(take)))"
                }
                return "Delete audio clip \(quote(clipName)) on \(trackPart)"
            }
            return "Delete MIDI clip \(quote(clipName)) on \(trackPart)"
        }
    }

    private static func findClip(_ id: UUID, in project: Project) -> Clip? {
        for t in project.tracks {
            if let c = t.clips.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    private static func clipLabel(_ ref: ClipRef, project: Project) -> String {
        switch ref {
        case .temp(let id):
            return "clip \(quote(id))"
        case .existing(_, let clipID):
            guard let clip = findClip(clipID, in: project) else {
                return "clip"
            }
            let name = clip.name.isEmpty ? "unnamed clip" : clip.name
            return "clip \(quote(name))"
        }
    }

    private static func gridLabel(_ gridBeats: Double) -> String {
        switch gridBeats {
        case 1.0: return "1/4 note"
        case 0.5: return "1/8 note"
        case 0.25: return "1/16 note"
        default: return "\(formatNumber(gridBeats))-beat grid"
        }
    }

    /// Positional handle plus display name: `Track 1 “Piano”`.
    private static func trackLabel(_ ref: TrackRef, project: Project,
                                   temps: [String: String]) -> String {
        switch ref {
        case .existing(let uuid):
            if let (index, track) = project.tracks.enumerated().first(where: { $0.element.id == uuid }) {
                return "Track \(index + 1) \(quote(track.name))"
            }
            return "Track (unknown)"
        case .temp(let tempId):
            if let name = temps[tempId] {
                return "new track \(quote(name))"
            }
            return "new track \(quote(tempId))"
        }
    }

    private static func quote(_ s: String) -> String { "“\(s)”" }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        // Trim trailing zeros without locale surprises.
        var s = String(format: "%.4f", value)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        return s
    }
}
