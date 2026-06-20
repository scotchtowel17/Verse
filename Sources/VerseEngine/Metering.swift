import Foundation
import AVFoundation
import Accelerate

/// A lightweight level meter. `update(from:)` runs on the realtime render thread inside a
/// tap block — it only computes peak/RMS with vDSP and stores plain `Float`s (no allocation,
/// no locking, no logging). The UI reads `peak`/`rms` on a timer; momentary cross-thread
/// tearing of a `Float` is harmless for a meter (Build Contract §4, §11).
public final class LevelMeter: @unchecked Sendable {
    public private(set) var peak: Float = 0
    public private(set) var rms: Float = 0

    public init() {}

    /// Realtime-safe: called from the tap block.
    public func update(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }
        var p: Float = 0, r: Float = 0
        vDSP_maxmgv(ch[0], 1, &p, n)   // peak magnitude
        vDSP_rmsqv(ch[0], 1, &r, n)    // root-mean-square
        // Peak holds with fast attack; UI applies decay via `decay()`.
        peak = Swift.max(peak, p)
        rms = r
    }

    /// Called on the UI timer to make the meter fall back smoothly.
    public func decay(_ factor: Float = 0.82) {
        peak *= factor
        rms *= factor
    }

    public func reset() { peak = 0; rms = 0 }

    /// 0…1 display value mapped from dBFS so quiet signals are visible.
    public var displayLevel: Float {
        let db = 20 * log10(Swift.max(peak, 1e-6))
        let floorDB: Float = -60
        return Swift.max(0, Swift.min(1, (db - floorDB) / -floorDB))
    }
}
