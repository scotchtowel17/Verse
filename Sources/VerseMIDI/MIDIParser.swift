import Foundation

/// Pure MIDI byte decoder. Unit-testable without a live CoreMIDI port.
///
/// Handles running status and the common note-on-with-velocity-0 = note-off rule.
/// SysEx and other system messages are skipped (not expanded into events).
public enum MIDIParser {

    /// Decode a contiguous stream of MIDI bytes into channel-voice events.
    public static func parse(_ bytes: [UInt8]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var i = 0
        var runningStatus: UInt8 = 0

        while i < bytes.count {
            let b = bytes[i]

            // Real-time system messages (single byte) can appear anywhere; skip.
            if b >= 0xF8 {
                i += 1
                continue
            }

            let status: UInt8
            if b & 0x80 != 0 {
                status = b
                i += 1
                // System common / SysEx: skip body we do not decode.
                if status >= 0xF0 {
                    runningStatus = 0
                    if status == 0xF0 {
                        // SysEx until 0xF7 or end.
                        while i < bytes.count, bytes[i] != 0xF7 { i += 1 }
                        if i < bytes.count { i += 1 }
                    } else if status == 0xF1 || status == 0xF3 {
                        if i < bytes.count { i += 1 }
                    } else if status == 0xF2 {
                        i = min(i + 2, bytes.count)
                    }
                    continue
                }
                runningStatus = status
            } else if runningStatus != 0 {
                status = runningStatus
            } else {
                // Orphan data byte with no status: skip.
                i += 1
                continue
            }

            let type = status & 0xF0
            let channel = status & 0x0F
            let dataLen: Int
            switch type {
            case 0xC0, 0xD0: dataLen = 1
            default: dataLen = 2
            }
            guard i + dataLen <= bytes.count else { break }

            let d1 = bytes[i]
            let d2 = dataLen == 2 ? bytes[i + 1] : 0
            i += dataLen

            switch type {
            case 0x80:
                events.append(.noteOff(channel: channel, note: d1, velocity: d2))
            case 0x90:
                // Velocity 0 is note-off on nearly every controller, including Akai MPK mini.
                if d2 == 0 {
                    events.append(.noteOff(channel: channel, note: d1, velocity: 0))
                } else {
                    events.append(.noteOn(channel: channel, note: d1, velocity: d2))
                }
            case 0xB0:
                events.append(.controlChange(channel: channel, controller: d1, value: d2))
            default:
                break
            }
        }
        return events
    }
}
