import SwiftUI
import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import VerseModel
import VerseEngine
import VersePersistence

/// Top-level observable application state. Owns the project model, the audio engine, and the
/// crash-recovery workspace. Runs on the main actor; the engine's realtime work happens on
/// Apple's render thread, never here.
@MainActor
@Observable
final class AppStore {
    var project: Project
    var activeTrackID: UUID
    var heldNotes: Set<Int> = []
    var engineError: String?
    var baseOctaveC: Int = 60

    // Recording / metering UI state
    var isRecording = false
    var monitoring = false
    var masterLevel: Float = 0
    var inputLevel: Float = 0
    var recordError: String?
    var takes: [Take] = []

    // Persistence state
    var currentPackageURL: URL?
    var pendingRecovery: RecoveryManager.RecoveryInfo?
    var statusMessage: String?

    @ObservationIgnored let engine = VerseAudioEngine()
    @ObservationIgnored let recovery = RecoveryManager()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var autosaveTimer: Timer?

    /// Captured takes stream here; this is the persistent crash-recovery workspace.
    @ObservationIgnored var workingMediaDir: URL { recovery.mediaDir }

    struct Take: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let seconds: Double
        var label: String { String(format: "Take · %.1fs", seconds) }
    }

    init() {
        let p = Project.newUntitled()
        self.project = p
        self.activeTrackID = p.tracks.first?.id ?? UUID()
        // Detect recovery BEFORE marking a new session live.
        self.pendingRecovery = recovery.detectRecovery()
        recovery.beginSession()
    }

    var activeTrack: Track? { project.track(id: activeTrackID) }
    var sf2Bundled: Bool { SoundBank.isAvailable }
    var presets: [SoundBank.Preset] { SoundBank.presets }
    var documentName: String { currentPackageURL?.deletingPathExtension().lastPathComponent ?? project.title }

    // MARK: - Engine lifecycle

    func startEngineIfNeeded() {
        guard !started else { return }
        engine.configure(with: project)
        do { try engine.start(); started = true }
        catch { engineError = "Couldn’t start audio: \(error.localizedDescription)" }
        startTimers()
        observeTermination()
    }

    private func startTimers() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.masterLevel = self.engine.masterMeter.displayLevel
                self.inputLevel = self.isRecording ? self.engine.recordingMeter.displayLevel : 0
                self.engine.decayMeters()
            }
        }
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recovery.autosave(self?.project ?? .newUntitled()) }
        }
    }

    private func observeTermination() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recovery.endSessionCleanly(clearMedia: false) }
        }
    }

    // MARK: - Recovery

    func applyRecovery() {
        guard let info = pendingRecovery else { return }
        if let recovered = info.project { project = recovered }
        activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? activeTrackID
        engine.reconfigure(with: project)
        if let takeURL = info.inProgressTakeURL {
            addRecordingClip(filename: takeURL.lastPathComponent, seconds: durationOf(takeURL))
        }
        rebuildTakesFromModel()
        statusMessage = "Recovered your unsaved work."
        pendingRecovery = nil
    }

    func dismissRecovery() {
        recovery.discardRecovery()
        pendingRecovery = nil
    }

    // MARK: - New / Open / Save

    func newProject() {
        engine.allNotesOff()
        let p = Project.newUntitled()
        project = p
        activeTrackID = p.tracks.first?.id ?? UUID()
        currentPackageURL = nil
        takes.removeAll()
        engine.reconfigure(with: project)
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.verseType]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openPackage(url)
    }

    func openPackage(_ url: URL) {
        do {
            let loaded = try ProjectPackage.read(url)
            _ = try? ProjectPackage.extractMedia(from: url, to: workingMediaDir)
            project = loaded
            currentPackageURL = url
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? project.tracks.first?.id ?? UUID()
            engine.reconfigure(with: project)
            rebuildTakesFromModel()
            statusMessage = "Opened “\(documentName)”."
        } catch {
            statusMessage = "Couldn’t open: \(error.localizedDescription)"
        }
    }

    func save() {
        if let url = currentPackageURL { writePackage(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.verseType]
        panel.nameFieldStringValue = "\(project.title).verse"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != ProjectPackage.fileExtension {
            url.appendPathExtension(ProjectPackage.fileExtension)
        }
        currentPackageURL = url
        writePackage(to: url)
    }

    private func writePackage(to url: URL) {
        do {
            try ProjectPackage.write(project, to: url, mediaSourceDir: workingMediaDir)
            statusMessage = "Saved “\(url.deletingPathExtension().lastPathComponent)”."
        } catch {
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    static let verseType = UTType(filenameExtension: ProjectPackage.fileExtension,
                                  conformingTo: .package) ?? .package

    // MARK: - Playing notes

    func noteOn(_ pitch: Int) {
        guard heldNotes.insert(pitch).inserted else { return }
        engine.noteOn(pitch, velocity: 96, trackID: activeTrackID)
    }
    func noteOff(_ pitch: Int) {
        guard heldNotes.remove(pitch) != nil else { return }
        engine.noteOff(pitch, trackID: activeTrackID)
    }
    func panic() { engine.allNotesOff(); heldNotes.removeAll() }

    // MARK: - Instrument selection

    func selectPreset(_ preset: SoundBank.Preset) {
        guard let idx = project.trackIndex(id: activeTrackID) else { return }
        let inst = Instrument(sf2: SoundBank.generalUserGS,
                              program: preset.program, bankMSB: preset.bankMSB, bankLSB: preset.bankLSB)
        project.tracks[idx].instrument = inst
        project.tracks[idx].name = preset.name
        engine.loadInstrument(id: activeTrackID, instrument: inst)
        recovery.autosave(project)
    }
    var currentPresetName: String { activeTrack?.name ?? "Instrument" }

    // MARK: - Recording → clips

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        recordError = nil
        let url = recovery.newTakeURL()
        do {
            try engine.startRecording(to: url)
            recovery.noteRecordingStarted(takeFilename: url.lastPathComponent)
            isRecording = true
        } catch {
            recordError = error.localizedDescription
        }
    }

    func stopRecording() {
        let result = engine.stopRecording()
        recovery.noteRecordingStopped()
        isRecording = false
        if let url = result.url, result.seconds > 0 {
            takes.insert(Take(url: url, seconds: result.seconds), at: 0)
            addRecordingClip(filename: url.lastPathComponent, seconds: result.seconds)
            recovery.autosave(project)
        }
    }

    func setMonitoring(_ on: Bool) { monitoring = on; engine.setMonitoring(on) }

    func play(_ take: Take) { try? engine.playFile(url: take.url) }

    // MARK: - Recordings track helpers

    private func recordingsTrackIndex() -> Int {
        if let i = project.tracks.firstIndex(where: { $0.kind == .audio && $0.name == "Recordings" }) { return i }
        project.tracks.append(Track(kind: .audio, name: "Recordings"))
        return project.tracks.count - 1
    }

    private func addRecordingClip(filename: String, seconds: Double) {
        let i = recordingsTrackIndex()
        let beats = max(1, (project.tempoBPM ?? 120) / 60.0 * seconds)
        let clip = Clip(kind: .audio, name: "Take \(project.tracks[i].clips.count + 1)",
                        startBeat: 0, lengthBeats: beats, mediaFile: filename)
        project.tracks[i].clips.append(clip)
    }

    private func durationOf(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    private func rebuildTakesFromModel() {
        takes.removeAll()
        for track in project.tracks where track.kind == .audio {
            for clip in track.clips {
                guard let name = clip.mediaFile else { continue }
                let url = workingMediaDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    takes.append(Take(url: url, seconds: durationOf(url)))
                }
            }
        }
    }
}
