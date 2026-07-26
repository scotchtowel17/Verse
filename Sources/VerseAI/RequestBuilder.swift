import Foundation
import VerseModel

/// Builds the `verseRequest` JSON the user pastes into Claude (Build Contract §E.1). It carries
/// the project context (tracks get positional handles T1…Tn, clips get T2C1… style handles) plus
/// the user's ask and the allowed-op capability list. No network, no API key.
public enum RequestBuilder {

    public static let capabilityOps = [
        "createTrack", "setInstrument", "addMidiClip", "addNotes", "setTempo", "setKey",
        "setTimeSignature", "setTrackMix", "deleteClip", "renameTrack",
        "quantizeNotes", "transposeNotes", "moveClip",
        "resizeClip", "duplicateClip", "splitClip", "moveClipToTrack",
        "deleteNote", "moveNote"
    ]

    public static func buildJSON(project: Project, userPrompt: String, appVersion: String = "0.1.0") -> String {
        var tracks: [[String: Any]] = []
        for (ti, t) in project.tracks.enumerated() {
            var clips: [[String: Any]] = []
            for (ci, c) in t.clips.enumerated() {
                let clipId = "T\(ti + 1)C\(ci + 1)"
                var notes: [[String: Any]] = []
                if let midiNotes = c.midiNotes {
                    for (ni, n) in midiNotes.enumerated() {
                        notes.append([
                            "id": "\(clipId)N\(ni + 1)",
                            "pitch": n.pitch,
                            "startBeat": n.startBeat,
                            "lengthBeats": n.lengthBeats,
                            "velocity": n.velocity
                        ])
                    }
                }
                var clipDict: [String: Any] = [
                    "id": clipId,
                    "kind": c.kind.rawValue,
                    "name": c.name,
                    "startBeat": c.startBeat,
                    "lengthBeats": c.lengthBeats,
                    "noteCount": c.midiNotes?.count ?? 0
                ]
                if !notes.isEmpty { clipDict["notes"] = notes }
                clips.append(clipDict)
            }

            var dict: [String: Any] = [
                "id": "T\(ti + 1)",
                "kind": t.kind.rawValue,
                "name": t.name,
                "clips": clips
            ]
            if let inst = t.instrument {
                dict["instrument"] = ["sf2": inst.sf2, "program": inst.program,
                                      "bankMSB": inst.bankMSB, "bankLSB": inst.bankLSB]
            }
            tracks.append(dict)
        }

        var projectDict: [String: Any] = [
            "title": project.title,
            "timeSignature": ["num": project.timeSignature.num, "den": project.timeSignature.den],
            "tracks": tracks
        ]
        if let bpm = project.tempoBPM { projectDict["tempoBPM"] = bpm }
        if let key = project.key { projectDict["key"] = ["tonic": key.tonic.rawValue, "mode": key.mode.rawValue] }

        let request: [String: Any] = [
            "verseRequest": [
                "schema": "verse-patch-request",
                "version": 1,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": appVersion,
                "userPrompt": userPrompt,
                "fingerprint": project.structuralFingerprint,
                "project": projectDict,
                "capabilities": ["ops": capabilityOps]
            ]
        ]

        let data = (try? JSONSerialization.data(withJSONObject: request,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return instructions(userPrompt: userPrompt) + "\n\n```json\n" + json + "\n```\n"
    }

    /// Plain-language framing so the user can paste the whole thing into Claude.
    private static func instructions(userPrompt: String) -> String {
        """
        I'm using an app called Verse. Please reply with ONLY a fenced ```json block containing a \
        "versePatch" object (schema "verse-patch", version 1) whose "ops" implement my request. \
        Allowed ops: \(capabilityOps.joined(separator: ", ")). Use the track ids (T1, T2, …), \
        clip ids (T1C1, T2C3, …), and note ids (T1C1N1, T2C3N2, …) below. Mint your own \
        tempId / tempClipId for new tracks/clips. Copy the fingerprint value from the \
        verseRequest into your versePatch verbatim as "fingerprint": "<value>". My request: \
        "\(userPrompt)".
        """
    }
}
