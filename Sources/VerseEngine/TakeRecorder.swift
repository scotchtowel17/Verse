import Foundation
import AVFoundation

/// Streams a recorded take to disk *during* capture (journaled recording, Build Contract §11).
///
/// The file is pre-opened on `start`; the tap block calls `append(_:)`, which does nothing
/// but write the buffer to the already-open file and update the meter — the one file-I/O the
/// realtime thread is permitted (appending to a pre-opened file). A crash mid-take therefore
/// leaves a valid, growing audio file on disk that crash recovery can reclaim.
public final class TakeRecorder: @unchecked Sendable {
    public private(set) var isRecording = false
    public private(set) var url: URL?
    public private(set) var frameCount: AVAudioFramePosition = 0
    public let level = LevelMeter()

    private var file: AVAudioFile?
    /// Captured at `start` so duration survives `stop()` closing the file.
    private var sampleRate: Double = 0

    public init() {}

    /// Pre-open the destination file for writing in the capture format (Float32).
    public func start(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        file = f
        self.url = url
        sampleRate = f.fileFormat.sampleRate
        frameCount = 0
        level.reset()
        isRecording = true
    }

    /// Realtime-safe append (called from the input-node tap block).
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file else { return }
        do {
            try file.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
            level.update(from: buffer)
        } catch {
            // No logging on the realtime thread; the next stop() surfaces a short file.
        }
    }

    /// Stop and close the file; returns the recorded URL (nil if nothing captured).
    @discardableResult
    public func stop() -> URL? {
        isRecording = false
        let out = (frameCount > 0) ? url : nil
        file = nil   // closes/flushes the AVAudioFile
        return out
    }

    /// Duration of the captured take. Valid both during capture and after `stop()`, which
    /// closes the file: the sample rate is captured at `start` rather than read back from the
    /// (by then nil) `AVAudioFile`.
    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}
