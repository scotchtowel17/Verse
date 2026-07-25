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
