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
///
/// Stored properties, timers, `init`, and lifecycle live here. Domain methods live in
/// `AppStore+Transport`, `AppStore+Persistence`, and `AppStore+Copilot`.
@MainActor
@Observable
public final class AppStore {
    public var project: Project
    public var activeTrackID: UUID
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
    /// True when every effects-map key names a track that still exists on the project.
    /// Used by VerseCheck (Step G1); the UI uses `effect(for:)` instead.
    public var effectMapOnlyNamesLiveTracks: Bool {
        let live = Set(project.tracks.map(\.id))
        return trackEffects.keys.allSatisfy { live.contains($0) }
    }

    // Claude copilot state
    public var showCopilot = false
    var copilotPrompt = ""
    public var copilotReply = ""
    var copilotMessage: String?
    /// Mandatory preview sheet is up: transport/record must stay disabled (SwiftUI sheets do
    /// not disable CommandGroup / keyboard shortcuts on their own).
    public var showCopilotPreview = false
    /// Validated preview waiting for Apply / Cancel. Built only from TypedOp values.
    public var pendingCopilotPreview: Copilot.Preview?

    // Analysis + AU hosting state (M6)
    var showTools = false
    var analysisResult: AnalysisResult?
    var analysisBusy = false
    @ObservationIgnored var tapState = TapTempo()
    @ObservationIgnored lazy var installedEffects: [DiscoveredAU] = AudioUnitDiscovery.effects()
    var musicUnderstandingAvailable: Bool { Analysis.isMusicUnderstandingAvailable }

    @ObservationIgnored let engine = VerseAudioEngine()
    @ObservationIgnored let recovery: RecoveryManager
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

    /// - Parameter recoveryBaseDir: Optional workspace root for crash recovery. Tests pass a
    ///   temporary directory so nothing is written under Application Support. When omitted,
    ///   behavior matches the production default (`RecoveryManager()` Application Support path).
    public init(recoveryBaseDir: URL? = nil) {
        self.recovery = RecoveryManager(baseDir: recoveryBaseDir)
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

    public func startEngineIfNeeded() {
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
            MainActor.assumeIsolated {
                // Prune orphan takes only; keep every media file still referenced by a clip.
                guard let self else { return }
                self.recovery.pruneMedia(keeping: self.referencedMediaFilenames())
                self.recovery.endSessionCleanly(clearMedia: false)
            }
        }
    }

    /// Filenames under the workspace Media directory that clips still reference.
    func referencedMediaFilenames() -> Set<String> {
        Set(project.tracks.flatMap(\.clips).compactMap(\.mediaFile))
    }

    // MARK: - Playing notes

    func noteOn(_ pitch: Int) {
        guard heldNotes.insert(pitch).inserted else { return }
        engine.noteOn(pitch, velocity: 96, trackID: activeTrackID)
    }
    func noteOff(_ pitch: Int) {
        guard heldNotes.remove(pitch) != nil else { return }
        engine.noteOff(pitch, trackID: activeTrackID)
    }
    public func panic() { engine.allNotesOff(); heldNotes.removeAll() }

    // MARK: - Instrument selection

    public func selectPreset(_ preset: SoundBank.Preset, for id: UUID? = nil) {
        let tid = id ?? activeTrackID
        guard let idx = project.trackIndex(id: tid) else { return }
        history.record(project, name: "Select Preset")
        let inst = Instrument(sf2: SoundBank.generalUserGS,
                              program: preset.program, bankMSB: preset.bankMSB, bankLSB: preset.bankLSB)
        project.tracks[idx].instrument = inst
        project.tracks[idx].name = preset.name
        engine.loadInstrument(id: tid, instrument: inst)
        recovery.autosave(project)
    }
    var currentPresetName: String { activeTrack?.name ?? "Instrument" }

    // MARK: - Recording → clips

    func toggleRecording() {
        // Copilot preview sheet does not disable menu/keyboard shortcuts on its own.
        guard !copilotPreviewBlocksTransport else { return }
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !copilotPreviewBlocksTransport else { return }
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
            history.record(project, name: "Record Take")
            takes.insert(Take(url: url, seconds: result.seconds), at: 0)
            addRecordingClip(filename: url.lastPathComponent, seconds: result.seconds)
            recovery.autosave(project)
        }
    }

    func setMonitoring(_ on: Bool) { monitoring = on; engine.setMonitoring(on) }

    func play(_ take: Take) { try? engine.playFile(url: take.url) }

    // MARK: - Recordings track helpers

    func recordingsTrackIndex() -> Int {
        if let i = project.tracks.firstIndex(where: { $0.kind == .audio && $0.name == "Recordings" }) { return i }
        let t = Track(kind: .audio, name: "Recordings")
        project.tracks.append(t)
        engine.addAudioTrack(id: t.id)
        return project.tracks.count - 1
    }

    func addRecordingClip(filename: String, seconds: Double) {
        let i = recordingsTrackIndex()
        let beats = max(1, (project.tempoBPM ?? 120) / 60.0 * seconds)
        let clip = Clip(kind: .audio, name: "Take \(project.tracks[i].clips.count + 1)",
                        startBeat: 0, lengthBeats: beats, mediaFile: filename)
        project.tracks[i].clips.append(clip)
    }

    func durationOf(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    func rebuildTakesFromModel() {
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

    // MARK: - Undo / redo (M5)

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }

    public func undo() {
        guard let prev = history.undo(current: project) else { return }
        project = prev
        syncEngineToProject()
        statusMessage = "Undid the last change."
    }

    public func redo() {
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
                // Snapshot immediately before the project mutation (not before the Task).
                if r.tempoBPM != nil || r.key != nil {
                    self.history.record(self.project, name: "Analyze Take")
                }
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

    public func setKey(tonic: Tonic, mode: Mode) {
        history.record(project, name: "Set Key")
        project.key = KeySignature(tonic: tonic, mode: mode)
        recovery.autosave(project)
    }

    func hostEffect(_ au: DiscoveredAU) {
        let tid = activeTrackID
        statusMessage = "Loading \(au.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                // Instantiate off-main; wire into the graph ON main so it can't race.
                let unit = try await VerseAudioEngine.instantiateUnit(au.componentDescription)
                await MainActor.run {
                    do {
                        try self.engine.insertHostedUnit(unit, trackID: tid)
                        // Hosted AUs are session-only; clear any persisted built-in marker so a
                        // later reconfigure does not resurrect the old built-in as if it were still chosen.
                        self.trackEffects[tid] = VerseAudioEngine.BuiltInEffect.none
                        if let i = self.project.trackIndex(id: tid) {
                            self.project.tracks[i].inserts = Self.insertsReplacingBuiltIn(
                                .none, in: self.project.tracks[i].inserts)
                        }
                        self.statusMessage = "Inserted “\(au.name)” on \(self.project.track(id: tid)?.name ?? "track")."
                    } catch {
                        self.statusMessage = "Couldn’t insert \(au.name): \(error.localizedDescription)"
                    }
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

        history.record(project, name: "Hum to MIDI")
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
    ///
    /// `engine.reconfigure` tears down every effect node. Built-in effects are restored from
    /// `Track.inserts`. Hosted third-party Audio Units are session-only and are not restored;
    /// the UI is told so it never claims an effect that is not in the graph.
    public func syncEngineToProject() {
        // Re-key any duplicate track ids before reconfigure so no track is left silent.
        let rekeyed = project.ensureUniqueTrackIDs()
        var droppedHostedNames: [String] = []
        for track in project.tracks {
            // Hosted insert: graph has a unit that is not a recognized built-in.
            if engine.hasInsert(trackID: track.id),
               engine.currentEffect(trackID: track.id) == .none {
                droppedHostedNames.append(track.name)
            }
        }
        engine.reconfigure(with: project)
        applyEffectiveMix()
        restoreEffectsFromProject()
        rebuildTakesFromModel()
        if project.track(id: activeTrackID) == nil {
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? project.tracks.first?.id ?? activeTrackID
        }
        if rekeyed > 0 {
            let n = rekeyed == 1 ? "1 duplicate track id" : "\(rekeyed) duplicate track ids"
            statusMessage = "Fixed \(n) so every track can play."
        } else if !droppedHostedNames.isEmpty {
            if droppedHostedNames.count == 1 {
                statusMessage = "Reverted \(droppedHostedNames[0]) to no effect (hosted plug-ins are not restored yet)."
            } else {
                let list = droppedHostedNames.joined(separator: ", ")
                statusMessage = "Reverted \(list) to no effect (hosted plug-ins are not restored yet)."
            }
        }
    }

    /// Rebuild `trackEffects` and re-insert built-in effect nodes from `Track.inserts`.
    /// Drops map entries whose track no longer exists. Safe after reconfigure/open.
    public func restoreEffectsFromProject() {
        let liveIDs = Set(project.tracks.map(\.id))
        var next: [UUID: VerseAudioEngine.BuiltInEffect] = [:]
        for track in project.tracks {
            let kind = Self.builtInEffect(fromInserts: track.inserts)
            if kind != .none {
                next[track.id] = kind
                engine.setEffect(kind, trackID: track.id)
            }
        }
        // Only keep live tracks; never leave a map entry naming a deleted track.
        trackEffects = next.filter { liveIDs.contains($0.key) }
    }
}
