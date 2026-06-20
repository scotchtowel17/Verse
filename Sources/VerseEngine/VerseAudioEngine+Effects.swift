import Foundation
import AVFoundation

/// Built-in Apple effect inserts per track (Build Contract §3 "built-in effects via Apple AU
/// effect nodes"). Inserted between a track's source (sampler/player) and its mixer. Hosting
/// *third-party* installed Audio Units is M6 (VersePlugins); these are the bundled Apple ones.
public extension VerseAudioEngine {

    enum BuiltInEffect: String, CaseIterable, Sendable, Identifiable {
        case none, reverb, delay, distortion, eq
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "None"
            case .reverb: return "Reverb"
            case .delay: return "Echo"
            case .distortion: return "Crunch"
            case .eq: return "EQ"
            }
        }
    }

    /// Insert (or replace/remove with `.none`) a built-in effect on a track.
    func setEffect(_ kind: BuiltInEffect, trackID: UUID, amount: Float = 35) {
        guard var nodes = trackNodes[trackID] else { return }
        guard let src: AVAudioNode = nodes.sampler ?? nodes.player else { return }

        // Tear down any existing effect, restoring source → mixer.
        if let old = nodes.effect {
            avEngine.disconnectNodeOutput(src)
            avEngine.disconnectNodeOutput(old)
            avEngine.detach(old)
            nodes.effect = nil
            avEngine.connect(src, to: nodes.mixer, format: nil)
        }

        if kind == .none {
            trackNodes[trackID] = nodes
            return
        }

        let unit = Self.makeEffect(kind, amount: amount)
        avEngine.attach(unit)
        avEngine.disconnectNodeOutput(src)
        avEngine.connect(src, to: unit, format: nil)
        avEngine.connect(unit, to: nodes.mixer, format: nil)
        nodes.effect = unit
        trackNodes[trackID] = nodes
    }

    /// Adjust the wet/dry mix of an inserted reverb/delay/distortion (0…100).
    func setEffectAmount(_ amount: Float, trackID: UUID) {
        let a = max(0, min(100, amount))
        switch trackNodes[trackID]?.effect {
        case let r as AVAudioUnitReverb: r.wetDryMix = a
        case let d as AVAudioUnitDelay: d.wetDryMix = a
        case let d as AVAudioUnitDistortion: d.wetDryMix = a
        default: break
        }
    }

    func currentEffect(trackID: UUID) -> BuiltInEffect {
        switch trackNodes[trackID]?.effect {
        case is AVAudioUnitReverb: return .reverb
        case is AVAudioUnitDelay: return .delay
        case is AVAudioUnitDistortion: return .distortion
        case is AVAudioUnitEQ: return .eq
        default: return .none
        }
    }

    private static func makeEffect(_ kind: BuiltInEffect, amount: Float) -> AVAudioUnit {
        switch kind {
        case .reverb:
            let r = AVAudioUnitReverb(); r.loadFactoryPreset(.mediumHall); r.wetDryMix = amount; return r
        case .delay:
            let d = AVAudioUnitDelay(); d.delayTime = 0.28; d.feedback = 30; d.wetDryMix = amount; return d
        case .distortion:
            let d = AVAudioUnitDistortion(); d.loadFactoryPreset(.multiEcho1); d.wetDryMix = amount; return d
        case .eq:
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            eq.bands[0].filterType = .parametric
            eq.bands[0].frequency = 2000; eq.bands[0].gain = 4; eq.bands[0].bandwidth = 1
            eq.bands[0].bypass = false
            return eq
        case .none:
            return AVAudioUnitEQ(numberOfBands: 0)
        }
    }

    // MARK: - Offline-friendly clip playback (used by transport and the determinism harness)

    /// Schedule an audio file on a track's player and start it. Works in both realtime and
    /// offline manual-rendering modes (when scheduled at `nil`).
    func scheduleClip(url: URL, on trackID: UUID, at when: AVAudioTime? = nil) throws {
        guard let player = trackNodes[trackID]?.player else { return }
        let file = try AVAudioFile(forReading: url)
        player.scheduleFile(file, at: when)
        player.play()
    }
}
