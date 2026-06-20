import Foundation
import CoreML
import VerseModel

/// Basic Pitch (Spotify, Apache-2.0) CoreML transcription path (Build Contract §6).
///
/// The model is an optional bundled artifact fetched by scripts/fetch-artifacts.sh --with-model.
/// When absent, `isAvailable` is false and HumToMIDI uses the monophonic fallback — so a missing
/// or format-drifted artifact degrades gracefully and never blocks the build. Constants below are
/// the documented contract; the CoreML output names are remapped exactly (Identity_1→note,
/// Identity_2→onset, Identity→contour). Constrained to short clips (drift negligible).
enum BasicPitchConstants {
    static let sampleRate = 22050.0
    static let audioWindow = 43844          // samples per inference window (~1.99 s)
    static let overlap = 7680               // DEFAULT_OVERLAPPING_FRAMES(30) * FFT_HOP(256)
    static let hop = 43844 - 7680           // 36164
    static let annotFrames = 172            // frames per window
    static let fftHop = 256
    static let fps = 22050.0 / 256.0        // ≈ 86.13
    static let midiOffset = 21              // bin 0 = A0
    static let pitchBins = 88
    static let onsetThreshold: Float = 0.5
    static let frameThreshold: Float = 0.3
    static let minNoteFrames = 11           // ≈ 127.7 ms
    static let inputFeatureName = "input_2"
    static let noteOutput = "Identity_1"
    static let onsetOutput = "Identity_2"
    static let contourOutput = "Identity"
}

final class BasicPitchModel {
    private let model: MLModel
    private init(model: MLModel) { self.model = model }

    /// Locate the bundled model artifact (compiled or package).
    static var modelURL: URL? {
        for name in ["BasicPitch", "BasicPitch_nmp", "nmp"] {
            if let u = Bundle.module.url(forResource: name, withExtension: "mlmodelc") { return u }
            if let u = Bundle.module.url(forResource: name, withExtension: "mlpackage") { return u }
        }
        return nil
    }

    static var isAvailable: Bool { modelURL != nil }

    static let shared: BasicPitchModel? = {
        guard let url = modelURL else { return nil }
        do {
            let compiled: URL = (url.pathExtension == "mlmodelc") ? url : try MLModel.compileModel(at: url)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            return BasicPitchModel(model: try MLModel(contentsOf: compiled, configuration: cfg))
        } catch {
            print("[BasicPitch] model load failed: \(error). Falling back to monophonic.")
            return nil
        }
    }()

    /// Run sliding-window inference and post-process to notes (timed in beats at `bpm`).
    func transcribe(samples: [Float], bpm: Double) -> [Note]? {
        let C = BasicPitchConstants.self
        var events: [(start: Double, end: Double, pitch: Int, vel: Int)] = []
        var windowIndex = 0
        var pos = 0
        while pos < samples.count {
            guard let input = try? MLMultiArray(shape: [1, NSNumber(value: C.audioWindow), 1], dataType: .float32) else { break }
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: C.audioWindow)
            for k in 0..<C.audioWindow {
                let idx = pos + k
                ptr[k] = idx < samples.count ? samples[idx] : 0
            }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: [C.inputFeatureName: MLFeatureValue(multiArray: input)]),
                  let out = try? model.prediction(from: provider),
                  let note = out.featureValue(for: C.noteOutput)?.multiArrayValue,
                  let onset = out.featureValue(for: C.onsetOutput)?.multiArrayValue
            else { break }

            let windowStartSec = Double(windowIndex) * Double(C.hop) / C.sampleRate
            events.append(contentsOf: Self.createNotes(note: note, onset: onset, windowStartSec: windowStartSec))

            windowIndex += 1
            pos += C.hop
            if samples.count <= C.audioWindow { break }   // single short window
        }

        let beatsPerSec = bpm / 60.0
        return events.map {
            Note(startBeat: $0.start * beatsPerSec,
                 lengthBeats: max(0.1, ($0.end - $0.start) * beatsPerSec),
                 pitch: $0.pitch, velocity: $0.vel)
        }
    }

    /// Greedy onset-triggered, frame-sustained note creation with the documented thresholds.
    private static func createNotes(note: MLMultiArray, onset: MLMultiArray,
                                    windowStartSec: Double) -> [(start: Double, end: Double, pitch: Int, vel: Int)] {
        let C = BasicPitchConstants.self
        let frames = C.annotFrames, bins = C.pitchBins
        func n(_ f: Int, _ p: Int) -> Float { note[[0, f, p] as [NSNumber]].floatValue }
        func o(_ f: Int, _ p: Int) -> Float { onset[[0, f, p] as [NSNumber]].floatValue }

        var result: [(Double, Double, Int, Int)] = []
        for p in 0..<bins {
            var f = 0
            while f < frames {
                if o(f, p) >= C.onsetThreshold && n(f, p) >= C.frameThreshold {
                    var end = f
                    while end < frames && n(end, p) >= C.frameThreshold { end += 1 }
                    if end - f >= C.minNoteFrames {
                        let startSec = windowStartSec + Double(f) / C.fps
                        let endSec = windowStartSec + Double(end) / C.fps
                        let vel = Int(min(127, max(40, n(f, p) * 127)))
                        result.append((startSec, endSec, p + C.midiOffset, vel))
                    }
                    f = end
                } else {
                    f += 1
                }
            }
        }
        return result
    }
}
