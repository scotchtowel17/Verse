import Foundation
import VerseModel

// Compiled ONLY on SDKs that ship Music Understanding (WWDC 2026). On this build's SDK the
// framework is absent, so this file contributes nothing and the manual fallback is used.
// The shape follows Apple's session 253 + developer docs (Build Contract §5): create a session
// from a precise-timing asset, request specific result types, read optional bpm/key/structure.
#if canImport(MusicUnderstanding)
import AVFoundation
import MusicUnderstanding

@available(macOS 26.0, *)
enum MusicUnderstandingAnalyzer {

    static func analyze(url: URL) async -> AnalysisResult? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let session = try MusicUnderstandingSession(asset: asset)
            let result = try await session.analyze(for: [.rhythm, .key, .structure])

            // Rhythm → tempo (optional: nil until ≥2 beats are found).
            let bpm: Double? = result.rhythm?.beatsPerMinute

            // Key → our KeySignature.
            var key: KeySignature?
            if let keyResult = result.key, let first = keyResult.values.first {
                key = Self.mapKey(first.value)
            }

            // Structure → named sections.
            var sections: [Section]?
            if let structure = result.structure {
                sections = structure.segments.map {
                    Section(name: "\($0.label)",
                            startSec: $0.range.start.seconds,
                            endSec: $0.range.end.seconds)
                }
            }

            let (loud, dur) = Analysis.measure(url: url)
            return AnalysisResult(tempoBPM: bpm, key: key, structure: sections,
                                  loudnessDB: loud, durationSec: dur, source: .musicUnderstanding)
        } catch {
            return nil
        }
    }

    private static func mapKey(_ signature: KeySignature_MU) -> KeySignature? {
        // Placeholder mapping; concrete MU types are resolved at compile time on a capable SDK.
        return nil
    }
}

// Stand-in alias so the file type-checks if the concrete MU type name differs across betas;
// replaced by the real type when compiled against the shipping SDK.
private typealias KeySignature_MU = Any
#endif
