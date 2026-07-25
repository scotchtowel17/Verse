import Foundation
import AVFoundation
import VerseEngine
import VerseModel

func runRecordingChecks(_ tk: TestKit) {
    // MARK: - Step H1: startRecording must never hang

    tk.suite("Recording H1: startRecording returns without hanging") {
        // Real bug: `avEngine.inputNode` can block forever inside CoreAudio
        // (`setDeviceID:` / BindToDeviceInternal). Record runs on the main actor, so a hang
        // freezes the whole app and freezes VerseCheck.
        //
        // Assert the PROPERTY, not the environment: startRecording must return (throw or
        // succeed) within a bound. Machines with a working mic may succeed; bare CLI /
        // no-device / denied-permission paths throw. Do NOT require a specific error code
        // (that failed CI on a machine that could open the mic).
        let engine = VerseAudioEngine()
        engine.configure(with: Project.newUntitled())
        try engine.start()
        defer { engine.stop() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-h1-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        // Bound well above the production inputBindTimeout so a legitimate slow bind still
        // passes; a hang never finishes and would fail this suite (or the process timeout).
        let bound = VerseAudioEngine.inputBindTimeout + 5.0
        let started = Date()
        var returned = false
        do {
            try engine.startRecording(to: url)
            returned = true
            _ = engine.stopRecording()
        } catch {
            returned = true
            // Any error is fine. Hang is the only failure mode this suite forbids.
        }
        let elapsed = Date().timeIntervalSince(started)
        tk.expect(returned, "startRecording returned (threw or succeeded)")
        tk.expect(elapsed < bound,
                  "returned within \(bound)s (got \(String(format: "%.2f", elapsed))s); hang never finishes")
    }

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

    // MARK: - Step G5: TakeRecorder edge cases

    tk.suite("Recording G5: stop twice is safe") {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            tk.expect(false, "could not make format"); return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-rec-g5-dbl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dbl.caf")

        let recorder = TakeRecorder()
        try recorder.start(url: url, format: fmt)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024) else {
            tk.expect(false, "buffer"); return
        }
        buf.frameLength = 1024
        let ch = buf.floatChannelData![0]
        for i in 0..<1024 { ch[i] = 0.2 }
        recorder.append(buf)

        let first = recorder.stop()
        tk.expect(first != nil, "first stop returns a URL")
        tk.expect(!recorder.isRecording, "not recording after first stop")
        // Second stop must not throw or clear the captured frame count incorrectly.
        let second = recorder.stop()
        tk.expect(!recorder.isRecording, "still not recording after second stop")
        tk.expect(recorder.frameCount > 0, "frame count retained after second stop")
        // Safe either way: nil or same URL; must not crash or invent a new path.
        if let second {
            tk.expectEqual(second, first!, "second stop returns the same take URL")
        } else {
            tk.expect(true, "second stop returned nil (also safe)")
        }
    }

    tk.suite("Recording G5: durationSeconds correct before and after stop") {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            tk.expect(false, "could not make format"); return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-rec-g5-dur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dur.caf")

        let recorder = TakeRecorder()
        try recorder.start(url: url, format: fmt)
        let framesPerBlock: AVAudioFrameCount = 4410  // 0.1s at 44.1k
        let blocks = 3
        for _ in 0..<blocks {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: framesPerBlock) else {
                continue
            }
            buf.frameLength = framesPerBlock
            let ch = buf.floatChannelData![0]
            for i in 0..<Int(framesPerBlock) { ch[i] = 0.15 }
            recorder.append(buf)
        }
        let expectedFrames = AVAudioFramePosition(framesPerBlock) * AVAudioFramePosition(blocks)
        let expectedDuration = Double(expectedFrames) / 44_100.0

        let before = recorder.durationSeconds
        tk.expect(abs(before - expectedDuration) < 0.001,
                  "durationSeconds before stop ≈ \(expectedDuration)s (got \(before))")
        tk.expectEqual(recorder.frameCount, expectedFrames, "frame count before stop")

        let result = recorder.stop()
        tk.expect(result != nil, "stop returns URL for non-empty take")
        // Intended contract (G5): duration remains correct after stop. Today this returns 0
        // because stop() nils the AVAudioFile and durationSeconds only reads sampleRate from
        // that handle. See project_plan.md “Bug G5-1”. Do not weaken this assertion.
        let after = recorder.durationSeconds
        tk.expect(abs(after - expectedDuration) < 0.001,
                  "durationSeconds after stop ≈ \(expectedDuration)s (got \(after))")
        tk.expectEqual(recorder.frameCount, expectedFrames, "frame count still correct after stop")
    }

    tk.suite("Recording G5: zero-frame take reports no URL") {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            tk.expect(false, "could not make format"); return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verse-rec-g5-zero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.caf")

        let recorder = TakeRecorder()
        try recorder.start(url: url, format: fmt)
        tk.expect(recorder.isRecording, "recording after start")
        tk.expectEqual(recorder.frameCount, 0, "no frames before any append")
        let result = recorder.stop()
        tk.expect(result == nil, "zero-frame take returns no URL")
        tk.expect(!recorder.isRecording, "not recording after stop")
        tk.expectEqual(recorder.frameCount, 0, "frame count still zero")
    }
}
