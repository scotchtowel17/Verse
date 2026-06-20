import Foundation
import AVFoundation
import Accelerate
import VerseModel

/// Hum/voice → MIDI (Build Contract §6). Two paths, chosen at runtime:
///   • Basic Pitch CoreML (polyphonic) when the bundled `.mlpackage` is present — see BasicPitch.swift.
///   • A deterministic monophonic autocorrelation pitch tracker otherwise — humming a melody is
///     monophonic, so this gives a genuinely useful result with zero dependencies and never
///     blocks the build. (The spec's bare "feature-flag off" is the floor; this is the ceiling.)
/// Constrained to short clips, where Basic Pitch's documented temporal drift is negligible.
public enum HumToMIDI {

    public enum Mode: String, Sendable { case basicPitch, monophonicFallback, unavailable }

    public struct Result {
        public let notes: [Note]
        public let mode: Mode
        public let message: String
    }

    /// Convert a recorded clip to MIDI notes (timed in beats at `bpm`).
    public static func convert(url: URL, bpm: Double) -> Result {
        guard let samples = loadMono22050(url: url), samples.count > 4096 else {
            return Result(notes: [], mode: .unavailable, message: "Couldn’t read that take for hum-to-MIDI.")
        }
        if BasicPitchModel.isAvailable, let notes = BasicPitchModel.shared?.transcribe(samples: samples, bpm: bpm) {
            return Result(notes: notes, mode: .basicPitch,
                          message: "Transcribed \(notes.count) note(s) with Basic Pitch.")
        }
        let notes = MonophonicPitchTracker.detect(samples: samples, sampleRate: 22050, bpm: bpm)
        return Result(notes: notes, mode: .monophonicFallback,
                      message: "Transcribed \(notes.count) note(s) from your melody.")
    }

    /// True if *any* path can run (the monophonic fallback always can). Basic Pitch availability
    /// is reported separately so the UI can show which engine was used.
    public static var isAvailable: Bool { true }
    public static var basicPitchAvailable: Bool { BasicPitchModel.isAvailable }

    // MARK: - Resample to 22050 Hz mono Float32 (the model + tracker input format)

    static func loadMono22050(url: URL) -> [Float]? {
        guard let inFile = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = inFile.processingFormat
        guard inFile.length > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(inFile.length))
        else { return nil }
        do { try inFile.read(into: inBuf) } catch { return nil }

        let ratio = 22050.0 / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return nil }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard convError == nil, let ch = outBuf.floatChannelData, outBuf.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}

/// Deterministic monophonic pitch tracker: per-frame autocorrelation with an energy gate and a
/// clarity threshold, median-smoothed, then segmented into note events. Pure Swift + vDSP.
enum MonophonicPitchTracker {
    static func detect(samples: [Float], sampleRate: Double, bpm: Double) -> [Note] {
        let frame = 2048, hop = 512
        let minF0 = 65.0, maxF0 = 1000.0
        let minLag = Int(sampleRate / maxF0), maxLag = Int(sampleRate / minF0)
        guard samples.count >= frame, maxLag < frame else { return [] }

        var framePitches: [Int] = []     // MIDI note per frame, -1 = unvoiced
        var frameEnergies: [Float] = []
        // One unsafe buffer over the whole signal; per-frame work uses pointer offsets only —
        // no allocation inside the frame or lag loops (important for this DSP hot path).
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i + frame <= samples.count {
                let framePtr = base + i
                var rms: Float = 0
                vDSP_rmsqv(framePtr, 1, &rms, vDSP_Length(frame))
                frameEnergies.append(rms)
                if rms < 0.01 { framePitches.append(-1); i += hop; continue }   // silence/unvoiced

                var zeroLag: Float = 0
                vDSP_dotpr(framePtr, 1, framePtr, 1, &zeroLag, vDSP_Length(frame))
                if zeroLag <= 0 { framePitches.append(-1); i += hop; continue }

                // Autocorrelation over the lag range; pick the strongest periodic lag.
                var bestLag = 0
                var bestCorr: Float = 0
                for lag in minLag...maxLag {
                    var corr: Float = 0
                    vDSP_dotpr(framePtr, 1, framePtr + lag, 1, &corr, vDSP_Length(frame - lag))
                    let norm = corr / zeroLag
                    if norm > bestCorr { bestCorr = norm; bestLag = lag }
                }
                if bestCorr < 0.5 || bestLag == 0 {
                    framePitches.append(-1)
                } else {
                    let f0 = sampleRate / Double(bestLag)
                    let midi = Int((69.0 + 12.0 * log2(f0 / 440.0)).rounded())
                    framePitches.append((0...127).contains(midi) ? midi : -1)
                }
                i += hop
            }
        }

        // Median-smooth pitches to remove octave/jitter glitches.
        let smoothed = medianSmooth(framePitches, window: 5)

        // Segment runs of equal pitch into notes.
        let secPerFrame = Double(hop) / sampleRate
        let beatsPerSec = bpm / 60.0
        var notes: [Note] = []
        var runStart = 0
        var runPitch = smoothed.first ?? -1
        func flush(end: Int) {
            guard runPitch >= 0 else { return }
            let durSec = Double(end - runStart) * secPerFrame
            guard durSec >= 0.08 else { return }   // drop sub-80ms blips
            let startSec = Double(runStart) * secPerFrame
            let eRange = max(0, runStart)..<min(frameEnergies.count, max(runStart + 1, end))
            let energy = frameEnergies[eRange].max() ?? 0.2
            let vel = Int(min(127, max(40, energy * 600)))
            notes.append(Note(startBeat: startSec * beatsPerSec,
                              lengthBeats: max(0.1, durSec * beatsPerSec),
                              pitch: runPitch, velocity: vel))
        }
        for (idx, p) in smoothed.enumerated() {
            if p != runPitch { flush(end: idx); runStart = idx; runPitch = p }
        }
        flush(end: smoothed.count)
        return notes
    }

    private static func medianSmooth(_ xs: [Int], window: Int) -> [Int] {
        guard window > 1, xs.count >= window else { return xs }
        let half = window / 2
        return xs.indices.map { i in
            let lo = max(0, i - half), hi = min(xs.count - 1, i + half)
            let voiced = xs[lo...hi].filter { $0 >= 0 }
            if voiced.isEmpty { return -1 }
            return voiced.sorted()[voiced.count / 2]
        }
    }
}
