import Foundation
import AVFoundation

/// Offline (manual) rendering support — used to *prove* audibility and render determinism
/// without audio hardware (Build Contract §H). The same graph renders to a buffer that the
/// verification harness inspects (RMS, length, stable hash).
public extension VerseAudioEngine {

    struct RenderStats {
        public let sampleCount: Int
        public let peak: Float
        public let rms: Float
        public let isAudible: Bool          // peak above a clear noise floor
    }

    /// Render `seconds` of audio offline while `play` drives note events, returning the
    /// mono mixdown samples. Engine must NOT be already running in realtime mode.
    func renderOffline(seconds: Double,
                       sampleRate: Double = 44_100,
                       play: (VerseAudioEngine) -> Void) throws -> [Float] {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return []
        }
        let maxFrames: AVAudioFrameCount = 4096
        try avEngine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        avEngine.prepare()
        try avEngine.start()
        isRunning = true

        // Trigger note events now; the sampler will sound across the rendered window.
        play(self)

        guard let buf = AVAudioPCMBuffer(pcmFormat: avEngine.manualRenderingFormat,
                                         frameCapacity: maxFrames) else { return [] }
        var samples: [Float] = []
        let total = AVAudioFramePosition(seconds * sampleRate)
        while avEngine.manualRenderingSampleTime < total {
            let remaining = total - avEngine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), remaining))
            let status = try avEngine.renderOffline(frames, to: buf)
            if status == .success, let ch = buf.floatChannelData {
                for i in 0..<Int(buf.frameLength) { samples.append(ch[0][i]) }
            } else if status == .insufficientDataFromInputNode {
                break
            }
        }

        avEngine.stop()
        avEngine.disableManualRenderingMode()
        isRunning = false
        return samples
    }

    static func stats(_ samples: [Float]) -> RenderStats {
        var peak: Float = 0
        var sumSq: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a }; sumSq += s * s }
        let rms = samples.isEmpty ? 0 : (sumSq / Float(samples.count)).squareRoot()
        return RenderStats(sampleCount: samples.count, peak: peak, rms: rms, isAudible: peak > 1e-3)
    }
}
