import Foundation
import VerseModel

/// Builds the `verseRequest` JSON the user pastes into Claude (Build Contract §E.1). It carries
/// the project context (tracks get positional handles T1…Tn that the response references) plus
/// the user's ask and the allowed-op capability list. No network, no API key.
public enum RequestBuilder {

    public static let capabilityOps = [
        "createTrack", "setInstrument", "addMidiClip", "addNotes", "setTempo", "setKey",
        "setTimeSignature", "setTrackMix", "deleteClip", "renameTrack"
    ]

    public static func buildJSON(project: Project, userPrompt: String, appVersion: String = "0.1.0") -> String {
        var tracks: [[String: Any]] = []
        for (i, t) in project.tracks.enumerated() {
            var dict: [String: Any] = [
                "id": "T\(i + 1)",
                "kind": t.kind.rawValue,
                "name": t.name,
                "clips": t.clips.count
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
        Allowed ops: \(capabilityOps.joined(separator: ", ")). Use the track ids below (T1, T2, …) \
        and mint your own tempId / tempClipId for new tracks/clips. My request: "\(userPrompt)".
        """
    }
}
