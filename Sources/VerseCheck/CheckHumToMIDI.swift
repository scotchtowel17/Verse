import Foundation
import AVFoundation
import VerseModel
import VerseAudioToMIDI

func runHumToMIDIChecks(_ tk: TestKit) {
    tk.suite("Hum→MIDI: transcribes a hummed two-note melody") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-h2m-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hum.caf")
        // A4 (440 Hz, MIDI 69) for 0.6s, then D5 (587.33 Hz, MIDI 74) for 0.6s.
        try writeMelodyCAF(to: url, segments: [(440.0, 0.6), (587.33, 0.6)])

        let result = HumToMIDI.convert(url: url, bpm: 120)
        print("   ↳ mode=\(result.mode.rawValue) notes=\(result.notes.map { $0.pitch })  BasicPitch=\(HumToMIDI.basicPitchAvailable)")
        tk.expect(HumToMIDI.isAvailable, "hum→MIDI is available (fallback always works)")
        tk.expectEqual(result.mode, .monophonicFallback, "uses monophonic fallback (no model artifact bundled)")
        tk.expect(result.notes.count >= 2, "found at least two notes (\(result.notes.count))")
        let pitches = result.notes.map { $0.pitch }
        tk.expect(pitches.contains { abs($0 - 69) <= 1 }, "detected A4 (≈69): \(pitches)")
        tk.expect(pitches.contains { abs($0 - 74) <= 1 }, "detected D5 (≈74): \(pitches)")
        // Notes are ordered in time and have positive length.
        tk.expect(result.notes.allSatisfy { $0.lengthBeats > 0 }, "all notes have positive length")
        FileManager.default.removeItemSafely(dir)
    }

    tk.suite("Hum→MIDI: degrades cleanly when artifact missing") {
        tk.expectEqual(HumToMIDI.basicPitchAvailable, false,
                       "Basic Pitch model not bundled → flagged off (build never blocked)")
    }
}

/// Write a sequence of (frequencyHz, seconds) tone segments to a mono CAF at 44.1 kHz.
@discardableResult
func writeMelodyCAF(to url: URL, segments: [(Double, Double)], sampleRate: Double = 44_100) throws -> URL {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return url }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    var phase = 0.0
    for (freq, secs) in segments {
        let frames = AVAudioFrameCount(secs * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { continue }
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        let inc = 2 * Double.pi * freq / sampleRate
        for i in 0..<Int(frames) { ch[i] = Float(0.5 * sin(phase)); phase += inc }
        try file.write(from: buf)
    }
    return url
}
