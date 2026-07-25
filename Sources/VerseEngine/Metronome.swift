import Foundation
import AVFoundation

/// A simple metronome: a dedicated percussion sampler clicking each beat (accent on beat 1).
/// Timer-driven — adequate for a guide click; not sample-accurate.
@MainActor
final class Metronome {
    private let engine: VerseAudioEngine
    private let sampler = AVAudioUnitSampler()
    private var timer: Timer?
    private var attached = false
    private var beat = 0

    init(engine: VerseAudioEngine) { self.engine = engine }

    private func ensureAttached() {
        guard !attached else { return }
        engine.avEngine.attach(sampler)
        engine.avEngine.connect(sampler, to: engine.avEngine.mainMixerNode, format: nil)
        if let url = SoundBank.anyAvailableURL {
            try? sampler.loadSoundBankInstrument(at: url, program: 0, bankMSB: 120, bankLSB: 0) // drum kit
        }
        attached = true
    }

    func start(bpm: Double, lead: Double) {
        ensureAttached()
        beat = 0
        let interval = 60.0 / max(20, bpm)
        DispatchQueue.main.asyncAfter(deadline: .now() + lead) { [weak self] in self?.click() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func click() {
        let accent = (beat % 4 == 0)
        let note: UInt8 = accent ? 76 : 77   // GM hi/low woodblock
        sampler.startNote(note, withVelocity: accent ? 112 : 84, onChannel: 9) // ch 10 = drums
        beat += 1
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }
}
