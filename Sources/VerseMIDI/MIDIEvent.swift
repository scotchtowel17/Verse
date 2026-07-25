import Foundation

/// A decoded channel-voice MIDI event. Pure value type; no CoreMIDI dependency.
public enum MIDIEvent: Equatable, Sendable {
    /// Note on with non-zero velocity.
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    /// Note off, including note-on messages with velocity 0 (standard MIDI convention).
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
}
