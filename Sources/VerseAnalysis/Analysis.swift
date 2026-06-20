import Foundation
import AVFoundation
import Accelerate
import VerseModel

/// Tempo/key/structure analysis of a recorded take (Build Contract §5).
///
/// Apple's **Music Understanding** framework is the on-device analysis path, but it is gated by
/// OS/hardware (Apple-Intelligence-capable Apple Silicon) and is absent from some SDKs. So it is
/// compiled behind `#if canImport(MusicUnderstanding)` + `#available`, and the always-present
/// path is the deterministic manual fallback: tap-tempo + key picker, plus a trivial on-device
/// loudness/duration read so "analyze" always returns *something*. An unavailable framework
/// degrades gracefully and never blocks the build.

public enum AnalysisSource: String, Sendable, Codable {
    case musicUnderstanding
    case manualFallback
}

public struct Section: Codable, Sendable, Hashable {
    public let name: String
    public let startSec: Double
    public let endSec: Double
}

public struct AnalysisResult: Codable, Sendable {
    public var tempoBPM: Double?      // nil when MU unavailable or too little audio (use tap-tempo)
    public var key: KeySignature?     // nil when MU unavailable (use key picker)
    public var structure: [Section]?
    public var loudnessDB: Float
    public var durationSec: Double
    public var source: AnalysisSource

    public var tempoPending: Bool { tempoBPM == nil }
    public var keyPending: Bool { key == nil }
}

public enum Analysis {

    /// True only if the framework is present AND available at runtime on this machine.
    public static var isMusicUnderstandingAvailable: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 26.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Analyze a take. Uses Music Understanding when available; otherwise the deterministic
    /// fallback (duration + loudness measured on-device; tempo/key left for manual entry).
    public static func analyze(url: URL) async -> AnalysisResult {
        #if canImport(MusicUnderstanding)
        if #available(macOS 26.0, *) {
            if let mu = await MusicUnderstandingAnalyzer.analyze(url: url) { return mu }
        }
        #endif
        return fallback(url: url)
    }

    /// Deterministic, dependency-free measurement used as the fallback and in tests.
    public static func fallback(url: URL) -> AnalysisResult {
        let (loud, dur) = measure(url: url)
        return AnalysisResult(tempoBPM: nil, key: nil, structure: nil,
                              loudnessDB: loud, durationSec: dur, source: .manualFallback)
    }

    static func measure(url: URL) -> (loudnessDB: Float, durationSec: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return (-120, 0) }
        let sr = file.fileFormat.sampleRate
        let dur = sr > 0 ? Double(file.length) / sr : 0
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(min(file.length, 44_100 * 60))) else {
            return (-120, dur)
        }
        do { try file.read(into: buf) } catch { return (-120, dur) }
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return (-120, dur) }
        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(buf.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return (db, dur)
    }
}

/// Manual tap-tempo (Build Contract §5 fallback). Averages the most recent taps into a BPM.
public struct TapTempo {
    private var taps: [TimeInterval] = []
    private let window: Int
    public init(window: Int = 6) { self.window = window }

    /// Register a tap at the given timestamp; returns the current BPM estimate (nil after one tap).
    public mutating func tap(at t: TimeInterval) -> Double? {
        taps.append(t)
        if taps.count > window { taps.removeFirst(taps.count - window) }
        guard taps.count >= 2 else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map { $0 - $1 }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0 else { return nil }
        return min(300, max(20, 60.0 / avg))
    }

    public mutating func reset() { taps.removeAll() }
    public var tapCount: Int { taps.count }
}
