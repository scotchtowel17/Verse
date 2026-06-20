import Foundation
import AVFoundation
import VerseEngine

func runRecordingChecks(_ tk: TestKit) {
    tk.suite("Recording: journaled take written to disk") {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            tk.expect(false, "could not make format"); return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take1.caf")

        let recorder = TakeRecorder()
        try recorder.start(url: url, format: fmt)

        // Synthesize ~0.5s of a sine and feed it through the same append() the tap uses.
        let frames: AVAudioFrameCount = 4410
        let blocks = 5
        for b in 0..<blocks {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { continue }
            buf.frameLength = frames
            let ch = buf.floatChannelData![0]
            for i in 0..<Int(frames) {
                let t = Double(b * Int(frames) + i) / 44_100.0
                ch[i] = Float(0.4 * sin(2 * Double.pi * 440 * t))
            }
            recorder.append(buf)
        }
        let result = recorder.stop()

        tk.expect(result != nil, "stop() returns a take URL")
        tk.expectEqual(recorder.frameCount, AVAudioFramePosition(frames) * AVAudioFramePosition(blocks),
                       "all frames accounted for")
        tk.expect(recorder.level.peak > 0.1, "meter responded to the signal")

        // Read the file back and confirm it is non-empty with the expected length.
        if FileManager.default.fileExists(atPath: url.path) {
            let readBack = try AVAudioFile(forReading: url)
            tk.expectEqual(readBack.length, AVAudioFramePosition(frames) * AVAudioFramePosition(blocks),
                           "on-disk file length matches what was captured")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            tk.expect(size > 1000, "take file is non-empty (\(size) bytes)")
        } else {
            tk.expect(false, "take file exists on disk")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    tk.suite("Metering: dBFS display mapping") {
        let m = LevelMeter()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024) else {
            tk.expect(false, "format/buffer"); return
        }
        buf.frameLength = 1024
        let ch = buf.floatChannelData![0]
        for i in 0..<1024 { ch[i] = 0.5 } // -6 dBFS-ish constant
        m.update(from: buf)
        tk.expect(m.peak > 0.49 && m.peak <= 0.51, "peak captured")
        tk.expect(m.displayLevel > 0.5, "loud signal maps high on the meter")
        m.reset()
        tk.expectEqual(m.peak, 0, "reset clears peak")
    }
}
