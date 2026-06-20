import SwiftUI
import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import VerseModel
import VerseEngine
import VersePersistence
import VerseCommands
import VerseAI
import VerseAnalysis
import VersePlugins
import VerseAudioToMIDI

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

    // Transport / multitrack state
    var isPlaying = false
    var metronomeOn = false
    var loopOn = false
    var trackLevels: [UUID: Float] = [:]
    var trackEffects: [UUID: VerseAudioEngine.BuiltInEffect] = [:]

    // Claude copilot state
    var showCopilot = false
    var copilotPrompt = ""
    var copilotReply = ""
    var copilotMessage: String?

    // Analysis + AU hosting state (M6)
    var showTools = false
    var analysisResult: AnalysisResult?
    var analysisBusy = false
    @ObservationIgnored var tapState = TapTempo()
    @ObservationIgnored lazy var installedEffects: [DiscoveredAU] = AudioUnitDiscovery.effects()
    var musicUnderstandingAvailable: Bool { Analysis.isMusicUnderstandingAvailable }

    @ObservationIgnored let engine = VerseAudioEngine()
    @ObservationIgnored let recovery = RecoveryManager()
    @ObservationIgnored let history = UndoStack<Project>()
    @ObservationIgnored lazy var transport = Transport(engine: engine)
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
        transport.onStop = { [weak self] in MainActor.assumeIsolated { self?.isPlaying = false } }
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
                for id in self.engine.allTrackIDs { self.trackLevels[id] = self.engine.meter(for: id)?.displayLevel ?? 0 }
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

    func selectPreset(_ preset: SoundBank.Preset, for id: UUID? = nil) {
        let tid = id ?? activeTrackID
        guard let idx = project.trackIndex(id: tid) else { return }
        let inst = Instrument(sf2: SoundBank.generalUserGS,
                              program: preset.program, bankMSB: preset.bankMSB, bankLSB: preset.bankLSB)
        project.tracks[idx].instrument = inst
        project.tracks[idx].name = preset.name
        engine.loadInstrument(id: tid, instrument: inst)
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
        let t = Track(kind: .audio, name: "Recordings")
        project.tracks.append(t)
        engine.addAudioTrack(id: t.id)
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

    // MARK: - Transport (M4)

    func togglePlay() { isPlaying ? stopPlayback() : startPlayback() }

    func startPlayback() {
        transport.metronomeEnabled = metronomeOn
        let end = arrangementBeats
        let loop: ClosedRange<Double>? = loopOn ? 0...max(4, end) : nil
        transport.play(project: project, mediaDir: workingMediaDir, from: 0, loop: loop)
        isPlaying = true
    }

    func stopPlayback() { transport.stop(); isPlaying = false }

    var arrangementBeats: Double {
        project.tracks.flatMap { $0.clips }.map { $0.startBeat + $0.lengthBeats }.max() ?? 8
    }

    func setMetronome(_ on: Bool) { metronomeOn = on; transport.metronomeEnabled = on }
    func setTempo(_ bpm: Double) { project.tempoBPM = max(20, min(300, bpm)); recovery.autosave(project) }

    // MARK: - Track management (M4)

    func addInstrumentTrack() {
        let n = project.tracks.filter { $0.kind == .instrument }.count + 1
        let t = Track(kind: .instrument, name: "Instrument \(n)", instrument: .grandPiano)
        project.tracks.append(t)
        engine.addInstrumentTrack(id: t.id, instrument: t.instrument)
        engine.applyMix(t)
        activeTrackID = t.id
        recovery.autosave(project)
    }

    func addAudioTrack() {
        let n = project.tracks.filter { $0.kind == .audio }.count + 1
        let t = Track(kind: .audio, name: "Audio \(n)")
        project.tracks.append(t)
        engine.addAudioTrack(id: t.id)
        engine.applyMix(t)
        recovery.autosave(project)
    }

    func deleteTrack(_ id: UUID) {
        guard project.tracks.count > 1 else { return }
        engine.removeTrack(id: id)
        project.tracks.removeAll { $0.id == id }
        if activeTrackID == id {
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? project.tracks.first!.id
        }
        recovery.autosave(project)
    }

    func selectTrack(_ id: UUID) {
        if project.track(id: id)?.kind == .instrument { activeTrackID = id }
    }

    // MARK: - Mix with solo logic (M4)

    func setVolume(_ v: Double, _ id: UUID) { mutate(id) { $0.volume = v }; applyEffectiveMix() }
    func setPan(_ p: Double, _ id: UUID) { mutate(id) { $0.pan = p }; applyEffectiveMix() }
    func toggleMute(_ id: UUID) { mutate(id) { $0.mute.toggle() }; applyEffectiveMix() }
    func toggleSolo(_ id: UUID) { mutate(id) { $0.solo.toggle() }; applyEffectiveMix() }

    private func mutate(_ id: UUID, _ f: (inout Track) -> Void) {
        if let i = project.trackIndex(id: id) { f(&project.tracks[i]) }
    }

    /// Apply volume/pan to the engine, honoring solo (any solo mutes the non-soloed).
    func applyEffectiveMix() {
        let anySolo = project.anySolo
        for t in project.tracks {
            let effMute = t.mute || (anySolo && !t.solo)
            engine.setTrackVolume(t.volume, trackID: t.id, muted: effMute)
            engine.setTrackPan(t.pan, trackID: t.id)
        }
    }

    // MARK: - Effects (M4)

    func setEffect(_ kind: VerseAudioEngine.BuiltInEffect, _ id: UUID) {
        engine.setEffect(kind, trackID: id)
        trackEffects[id] = kind
    }
    func effect(for id: UUID) -> VerseAudioEngine.BuiltInEffect { trackEffects[id] ?? .none }
    func trackLevel(_ id: UUID) -> Float { trackLevels[id] ?? 0 }

    // MARK: - Claude copilot (M5)

    func copyRequestToClipboard() {
        let req = Copilot.buildRequest(project: project, userPrompt: copilotPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(req, forType: .string)
        copilotMessage = "Request copied. Paste it into Claude, then paste Claude’s reply below."
    }

    func pasteReplyFromClipboard() {
        copilotReply = NSPasteboard.general.string(forType: .string) ?? ""
    }

    func applyCopilotReply() {
        var working = project
        let outcome = Copilot.apply(reply: copilotReply, to: &working)
        copilotMessage = outcome.userMessage
        guard outcome.status == .applied else { return }
        history.record(project)            // one undo group for the whole patch
        project = working
        syncEngineToProject()
        recovery.autosave(project)
        copilotReply = ""
    }

    // MARK: - Undo / redo (M5)

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        guard let prev = history.undo(current: project) else { return }
        project = prev
        syncEngineToProject()
        statusMessage = "Undid the last change."
    }

    func redo() {
        guard let next = history.redo(current: project) else { return }
        project = next
        syncEngineToProject()
        statusMessage = "Redid the change."
    }

    // MARK: - Analysis + AU hosting (M6)

    func analyzeLastTake() {
        guard let take = takes.first else {
            analysisResult = nil
            statusMessage = "Record a take first, then analyze it."
            return
        }
        analysisBusy = true
        let url = take.url
        Task { [weak self] in
            let r = await Analysis.analyze(url: url)
            await MainActor.run {
                guard let self else { return }
                self.analysisResult = r
                if let bpm = r.tempoBPM { self.project.tempoBPM = (bpm * 10).rounded() / 10 }
                if let k = r.key { self.project.key = k }
                self.analysisBusy = false
            }
        }
    }

    func tapTempo() {
        if let bpm = tapState.tap(at: ProcessInfo.processInfo.systemUptime) {
            project.tempoBPM = (bpm * 10).rounded() / 10
        }
    }
    func resetTapTempo() { tapState.reset() }

    func setKey(tonic: Tonic, mode: Mode) {
        project.key = KeySignature(tonic: tonic, mode: mode)
        recovery.autosave(project)
    }

    func hostEffect(_ au: DiscoveredAU) {
        let tid = activeTrackID
        statusMessage = "Loading \(au.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.insertHostedEffect(au.componentDescription, trackID: tid)
                await MainActor.run {
                    self.trackEffects[tid] = VerseAudioEngine.BuiltInEffect.none   // hosted unit is in place
                    self.statusMessage = "Inserted “\(au.name)” on \(self.project.track(id: tid)?.name ?? "track")."
                }
            } catch {
                await MainActor.run { self.statusMessage = "Couldn’t load \(au.name): \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Hum → MIDI (M7)

    var humToMIDIAvailable: Bool { HumToMIDI.isAvailable }
    var basicPitchAvailable: Bool { HumToMIDI.basicPitchAvailable }

    func humToMIDIFromLastTake() {
        guard let take = takes.first else {
            statusMessage = "Record a hum or melody first, then convert it."
            return
        }
        let bpm = project.tempoBPM ?? 120
        let result = HumToMIDI.convert(url: take.url, bpm: bpm)
        guard !result.notes.isEmpty else { statusMessage = "Couldn’t find clear notes in that take."; return }

        history.record(project)
        let end = result.notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 4
        let clip = Clip(kind: .midi, name: "Hum melody", startBeat: 0,
                        lengthBeats: max(4, end), midiNotes: result.notes)
        let track = Track(kind: .instrument, name: "Hum melody", instrument: .grandPiano, clips: [clip])
        project.tracks.append(track)
        engine.addInstrumentTrack(id: track.id, instrument: track.instrument)
        engine.applyMix(track)
        activeTrackID = track.id
        recovery.autosave(project)
        statusMessage = result.message + (result.mode == .basicPitch ? " (Basic Pitch)" : "")
    }

    /// Rebuild the engine graph + mixer from the current project (after a patch/undo/redo).
    private func syncEngineToProject() {
        engine.reconfigure(with: project)
        applyEffectiveMix()
        rebuildTakesFromModel()
        if project.track(id: activeTrackID) == nil {
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? project.tracks.first?.id ?? activeTrackID
        }
    }
}
