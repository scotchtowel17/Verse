import Foundation
import AVFoundation

/// Hosting installed Audio Units as per-track inserts (Build Contract §8). AUv3 require async
/// instantiation; `AVAudioEngine` handles them in-process. The hosted unit replaces any existing
/// insert on the track: `source → hostedAU → trackMixer`.
public extension VerseAudioEngine {

    enum HostingError: Error, LocalizedError {
        case noTrack, instantiationFailed
        public var errorDescription: String? {
            switch self {
            case .noTrack: return "That track can’t host an effect."
            case .instantiationFailed: return "The Audio Unit couldn’t be loaded."
            }
        }
    }

    /// Instantiate an installed Audio Unit and insert it on a track. Async because AUv3 must be
    /// instantiated asynchronously.
    func insertHostedEffect(_ desc: AudioComponentDescription, trackID: UUID) async throws {
        guard let nodes = trackNodes[trackID], let src = nodes.sampler ?? nodes.player else {
            throw HostingError.noTrack
        }
        let unit: AVAudioUnit = try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
                if let unit { cont.resume(returning: unit) }
                else { cont.resume(throwing: error ?? HostingError.instantiationFailed) }
            }
        }

        // Tear down any existing insert, then wire source → hosted unit → mixer.
        var n = nodes
        if let old = n.effect {
            avEngine.disconnectNodeOutput(src)
            avEngine.disconnectNodeOutput(old)
            avEngine.detach(old)
            n.effect = nil
            avEngine.connect(src, to: n.mixer, format: nil)
        }
        avEngine.attach(unit)
        avEngine.disconnectNodeOutput(src)
        avEngine.connect(src, to: unit, format: nil)
        avEngine.connect(unit, to: n.mixer, format: nil)
        n.effect = unit
        trackNodes[trackID] = n
    }

    /// Whether a track currently hosts an inserted unit.
    func hasInsert(trackID: UUID) -> Bool { trackNodes[trackID]?.effect != nil }
}
