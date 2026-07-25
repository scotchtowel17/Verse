import Foundation
import AVFoundation
import CoreAudio
import VerseModel

/// Recording, metering, monitoring, and audition playback (Build Contract §4, §11).
/// The microphone is only pulled when the user records or enables monitoring, so launching
/// Verse does not trigger a mic-permission prompt before it's needed.
public extension VerseAudioEngine {

    enum RecordingError: Error, LocalizedError {
        case noInputAvailable
        case microphonePermissionDenied
        case inputBindTimedOut
        case notRunning
        public var errorDescription: String? {
            switch self {
            case .noInputAvailable:
                return "No audio input is available. Connect a microphone or interface."
            case .microphonePermissionDenied:
                return "Verse doesn’t have permission to use the microphone."
            case .inputBindTimedOut:
                return "Couldn’t open the microphone in time. Check that no other app is using it, then try again."
            case .notRunning:
                return "The audio engine isn’t running."
            }
        }
    }

    // MARK: - Input-node safety (Step H1)

    /// How long we wait for CoreAudio to finish binding the default input device.
    /// Reading `AVAudioEngine.inputNode` can block forever inside
    /// `AUHALOutputUnit setDeviceID:` when the device cannot be claimed. A finite wait keeps
    /// Record from freezing the whole app (main actor) or the test harness.
    static let inputBindTimeout: TimeInterval = 3.0

    /// Non-blocking preflight before any call that touches `avEngine.inputNode`.
    ///
    /// These checks never enter the HAL bind path that hangs.
    /// 1. Default input device via CoreAudio property query.
    /// 2. Microphone authorization (denied / restricted fail fast with a distinct error).
    /// 3. This process must declare mic use (`NSMicrophoneUsageDescription`). Bare CLI
    ///    binaries (VerseCheck, `swift run Verse`) lack it; even when TCC shows authorized,
    ///    reading `inputNode` still enables hardware input and then blocks forever inside
    ///    CoreAudio. Verse.app carries the usage string via `scripts/make-app.sh`.
    static func preflightInputAvailability() throws {
        guard hasDefaultInputDevice() else {
            throw RecordingError.noInputAvailable
        }
        // Always required. Do not treat “authorized” alone as safe: CLI processes can report
        // authorized TCC while the bind path still hangs without a usage description.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw RecordingError.noInputAvailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw RecordingError.microphonePermissionDenied
        case .authorized, .notDetermined:
            // notDetermined: the real app will prompt on first open. denied already thrown.
            return
        @unknown default:
            throw RecordingError.noInputAvailable
        }
    }

    /// `true` when CoreAudio reports a default input device (not `kAudioObjectUnknown`).
    static func hasDefaultInputDevice() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    /// Open `inputNode` only after preflight, with a bounded wait so a wedged HAL cannot
    /// hang the caller forever. The property access runs off the calling thread; if it has
    /// not returned by `inputBindTimeout`, the caller gets `inputBindTimedOut`. The stuck
    /// background attempt may still hold the engine lock, so the engine is marked abandoned
    /// and later `stop` / restart skip locking `avEngine` calls.
    func openInputNodeBounded() throws -> AVAudioInputNode {
        if inputNodeBindAbandoned {
            throw RecordingError.inputBindTimedOut
        }
        try Self.preflightInputAvailability()

        final class Box: @unchecked Sendable {
            var node: AVAudioInputNode?
            let lock = NSLock()
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let engine = avEngine
        DispatchQueue.global(qos: .userInitiated).async {
            // May block indefinitely inside CoreAudio on a wedged device path.
            let node = engine.inputNode
            box.lock.lock()
            box.node = node
            box.lock.unlock()
            sem.signal()
        }
        let wait = sem.wait(timeout: .now() + Self.inputBindTimeout)
        if wait == .timedOut {
            inputNodeBindAbandoned = true
            throw RecordingError.inputBindTimedOut
        }
        box.lock.lock()
        let node = box.node
        box.lock.unlock()
        guard let node else {
            throw RecordingError.noInputAvailable
        }
        return node
    }

    // MARK: - Recording (input-node tap → pre-opened file)

    func startRecording(to url: URL) throws {
        guard isRunning else { throw RecordingError.notRunning }
        // Never touch inputNode until preflight passes; bind itself is time-bounded (H1).
        let input = try openInputNodeBounded()
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
        // arm would re-enter the hang-prone HAL path.
        if recorder.isRecording, !inputNodeBindAbandoned {
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
        // Same hang risk as startRecording: never touch inputNode without a safe open.
        guard on else {
            monitorMixer?.outputVolume = 0.0
            return
        }
        let input: AVAudioInputNode
        do {
            input = try openInputNodeBounded()
        } catch {
            return
        }
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
