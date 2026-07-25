import Foundation
import AVFoundation
import VerseModel

/// Recording, metering, monitoring, and audition playback (Build Contract §4, §11).
/// The microphone is only pulled when the user records or enables monitoring, so launching
/// Verse does not trigger a mic-permission prompt before it's needed.
public extension VerseAudioEngine {

    enum RecordingError: Error, LocalizedError {
        case noInputAvailable
        case notRunning
        public var errorDescription: String? {
            switch self {
            case .noInputAvailable: return "No audio input is available. Connect a microphone or interface."
            case .notRunning: return "The audio engine isn’t running."
            }
        }
    }

    // MARK: - Input-node safety

    /// Whether touching `AVAudioEngine.inputNode` is expected to complete.
    ///
    /// Bare CLI executables (including VerseCheck) have no `NSMicrophoneUsageDescription`.
    /// On those processes, reading `inputNode` enables the hardware input device and then
    /// blocks forever inside CoreAudio (`EnableInputDevice` → `CreateIOProcID` →
    /// `_TellServerAboutStreamUsage`) instead of throwing. The real Verse.app bundle carries
    /// the usage string and audio-input entitlement, so the OS can prompt and finish the bind.
    ///
    /// Callers that only need MIDI arm (instrument tracks) already soft-fail on
    /// `noInputAvailable`; this gate turns an infinite hang into that clean error.
    static var canSafelyOpenInputNode: Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            return false
        case .granted:
            return true
        case .undetermined:
            // Only attempt the HAL path when this process declared mic use to the OS.
            return Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        @unknown default:
            return false
        }
    }

    // MARK: - Recording (input-node tap → pre-opened file)

    func startRecording(to url: URL) throws {
        guard isRunning else { throw RecordingError.notRunning }
        // Must preflight: `inputNode` itself can hang indefinitely (see canSafelyOpenInputNode).
        guard Self.canSafelyOpenInputNode else { throw RecordingError.noInputAvailable }
        let input = avEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { throw RecordingError.noInputAvailable }

        try recorder.start(url: url, format: fmt)
        // 4096 is advisory; the system may pick another size (commonly ~4800 on macOS).
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [recorder = self.recorder] buffer, _ in
            recorder.append(buffer)   // realtime-safe: file append + meter only
        }
    }

    @discardableResult
    func stopRecording() -> (url: URL?, frames: AVAudioFramePosition, seconds: Double) {
        // Only remove a tap when one was installed. Calling inputNode after a failed/skipped
        // arm would re-enter the same hang-prone HAL path.
        if recorder.isRecording {
            avEngine.inputNode.removeTap(onBus: 0)
        }
        let frames = recorder.frameCount
        let secs = recorder.durationSeconds
        let url = recorder.stop()
        return (url, frames, secs)
    }

    var isRecording: Bool { recorder.isRecording }
    var recordingMeter: LevelMeter { recorder.level }

    // MARK: - Input monitoring (off by default to avoid feedback)

    func setMonitoring(_ on: Bool) {
        // Same hang risk as startRecording: never touch inputNode without the preflight.
        guard on else {
            monitorMixer?.outputVolume = 0.0
            return
        }
        guard Self.canSafelyOpenInputNode else { return }
        let input = avEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0 else { return }
        if monitorMixer == nil {
            let m = AVAudioMixerNode()
            avEngine.attach(m)
            avEngine.connect(input, to: m, format: fmt)
            avEngine.connect(m, to: avEngine.mainMixerNode, format: nil)
            monitorMixer = m
        }
        monitorMixer?.outputVolume = 1.0
    }

    // MARK: - Metering

    /// Install meter taps on the main mixer and each track mixer (call once the engine is
    /// running so node formats are valid).
    func installMeterTaps() {
        let main = avEngine.mainMixerNode
        let mfmt = main.outputFormat(forBus: 0)
        if mfmt.channelCount > 0, !masterMeterInstalled {
            main.installTap(onBus: 0, bufferSize: 2048, format: mfmt) { [masterMeter] buffer, _ in
                masterMeter.update(from: buffer)
            }
            masterMeterInstalled = true
        }
        for (id, nodes) in trackNodes where meters[id] == nil {
            let fmt = nodes.mixer.outputFormat(forBus: 0)
            guard fmt.channelCount > 0 else { continue }
            let meter = LevelMeter()
            meters[id] = meter
            nodes.mixer.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buffer, _ in
                meter.update(from: buffer)
            }
        }
    }

    func meter(for trackID: UUID) -> LevelMeter? { meters[trackID] }

    /// UI timer hook: let all meters fall back smoothly.
    func decayMeters() {
        masterMeter.decay()
        recorder.level.decay()
        for (_, m) in meters { m.decay() }
    }

    // MARK: - Audition playback (play a recorded take)

    func playFile(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if let player = auditionPlayer {
            // Mismatched format on a reused connection raises an uncatchable engine exception.
            if let connected = auditionFormat, !connected.isEqual(format) {
                player.stop()
                avEngine.disconnectNodeOutput(player)
                avEngine.connect(player, to: avEngine.mainMixerNode, format: format)
                auditionFormat = format
            }
        } else {
            let p = AVAudioPlayerNode()
            avEngine.attach(p)
            avEngine.connect(p, to: avEngine.mainMixerNode, format: format)
            auditionPlayer = p
            auditionFormat = format
        }
        guard let player = auditionPlayer else { return }
        player.stop()
        player.scheduleFile(file, at: nil)
        if !avEngine.isRunning { try avEngine.start() }
        player.play()
    }

    func stopAudition() { auditionPlayer?.stop() }
}
