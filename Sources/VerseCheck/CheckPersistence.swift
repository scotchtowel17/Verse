import Foundation
import AVFoundation
import VerseModel
import VersePersistence

func runPersistenceChecks(_ tk: TestKit) {
    let fm = FileManager.default

    tk.suite("Persistence: .verse package round-trip") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-pkg-\(UUID().uuidString)")
        let mediaSrc = root.appendingPathComponent("src-media")
        try fm.createDirectory(at: mediaSrc, withIntermediateDirectories: true)

        // A real take file the project will reference.
        let takeName = "take1.caf"
        try writeSineCAF(to: mediaSrc.appendingPathComponent(takeName), seconds: 0.25)

        var project = Project.newUntitled()
        project.title = "Vertical Slice"
        project.tempoBPM = 96
        var audio = Track(kind: .audio, name: "Recordings")
        audio.clips = [Clip(kind: .audio, name: "Take 1", startBeat: 0, lengthBeats: 4, mediaFile: takeName)]
        project.tracks.append(audio)

        let pkg = root.appendingPathComponent("Untitled.verse")
        try ProjectPackage.write(project, to: pkg, mediaSourceDir: mediaSrc)

        tk.expect(fm.fileExists(atPath: pkg.appendingPathComponent("project.json").path),
                  "package contains project.json")
        tk.expect(fm.fileExists(atPath: pkg.appendingPathComponent("Media/\(takeName)").path),
                  "package contains Media/take1.caf")

        let back = try ProjectPackage.read(pkg)
        tk.expectEqual(back.title, "Vertical Slice", "title round-trips through package")
        tk.expectEqual(back.tempoBPM, 96, "tempo round-trips")
        tk.expectEqual(back.tracks.last?.clips.first?.mediaFile, takeName, "clip media reference preserved")

        // The reopened take is playable (non-empty, valid audio).
        let mediaURL = ProjectPackage.mediaURL(in: pkg).appendingPathComponent(takeName)
        if let f = try? AVAudioFile(forReading: mediaURL) {
            tk.expect(f.length > 0, "reopened take has audio frames (playback path)")
        } else {
            tk.expect(false, "reopened take is a readable audio file")
        }
        try? fm.removeItem(at: root)
    }

    tk.suite("Persistence: atomic overwrite preserves prior good copy") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-atomic-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pkg = root.appendingPathComponent("Song.verse")
        var p = Project.newUntitled(); p.title = "v1"
        try ProjectPackage.write(p, to: pkg, mediaSourceDir: nil)
        p.title = "v2"
        try ProjectPackage.write(p, to: pkg, mediaSourceDir: nil)   // overwrite in place
        let back = try ProjectPackage.read(pkg)
        tk.expectEqual(back.title, "v2", "overwrite produced the new version, package still valid")
        try? fm.removeItem(at: root)
    }

    tk.suite("Recovery: reconstructs autosave + in-progress take (in-process)") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-recov-\(UUID().uuidString)")
        let rec = RecoveryManager(baseDir: base)
        rec.beginSession()
        // Simulate an in-progress recording + an autosaved edit, then DON'T end cleanly.
        let takeURL = rec.newTakeURL()
        try writeSineCAF(to: takeURL, seconds: 0.2)
        rec.noteRecordingStarted(takeFilename: takeURL.lastPathComponent)
        var edited = Project.newUntitled(); edited.title = "Unsaved edit"
        rec.autosave(edited)

        // A fresh manager (as on relaunch) should detect recoverable state.
        let relaunch = RecoveryManager(baseDir: base)
        let info = relaunch.detectRecovery()
        tk.expect(info != nil, "recovery detected after unclean session")
        tk.expectEqual(info?.project?.title, "Unsaved edit", "autosaved edits recovered")
        tk.expect(info?.inProgressTakeURL != nil, "in-progress take recovered")

        relaunch.endSessionCleanly()
        tk.expect(RecoveryManager(baseDir: base).detectRecovery() == nil,
                  "clean shutdown clears recovery state")
        try? fm.removeItem(at: base)
    }

    // MARK: - Step G3: Workspace retention

    tk.suite("Recovery: pruneMedia keeps referenced, removes unreferenced") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-prune-\(UUID().uuidString)")
        let rec = RecoveryManager(baseDir: base)
        let keepName = "keep-me.caf"
        let dropName = "orphan.caf"
        try writeSineCAF(to: rec.mediaDir.appendingPathComponent(keepName), seconds: 0.1)
        try writeSineCAF(to: rec.mediaDir.appendingPathComponent(dropName), seconds: 0.1)
        tk.expect(fm.fileExists(atPath: rec.mediaDir.appendingPathComponent(keepName).path),
                  "keep file present before prune")
        tk.expect(fm.fileExists(atPath: rec.mediaDir.appendingPathComponent(dropName).path),
                  "orphan file present before prune")

        rec.pruneMedia(keeping: [keepName])
        tk.expect(fm.fileExists(atPath: rec.mediaDir.appendingPathComponent(keepName).path),
                  "referenced take kept")
        tk.expect(!fm.fileExists(atPath: rec.mediaDir.appendingPathComponent(dropName).path),
                  "unreferenced take removed")
        tk.expect(fm.fileExists(atPath: rec.mediaDir.path), "Media directory still exists")
        try? fm.removeItem(at: base)
    }

    tk.suite("Recovery: pruneMedia on empty set does not throw") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-prune-empty-\(UUID().uuidString)")
        let rec = RecoveryManager(baseDir: base)
        try writeSineCAF(to: rec.mediaDir.appendingPathComponent("temp.caf"), seconds: 0.1)
        // Empty set: nothing is referenced, so every file may go. Must not throw.
        rec.pruneMedia(keeping: [])
        tk.expect(fm.fileExists(atPath: rec.mediaDir.path), "Media directory still exists after empty prune")
        let left = (try? fm.contentsOfDirectory(atPath: rec.mediaDir.path)) ?? []
        tk.expect(left.isEmpty, "empty keep-set removes all media files")
        // Second call on already-empty dir must also be safe.
        rec.pruneMedia(keeping: [])
        tk.expect(true, "second empty prune did not throw")
        try? fm.removeItem(at: base)
    }

    tk.suite("Recovery: missing journal is silent; corrupt journal is observable") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-journal-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }

        // Unclean session + valid autosave, no journal file: normal silent no-op for journal.
        let rec = RecoveryManager(baseDir: base)
        rec.beginSession()
        var edited = Project.newUntitled(); edited.title = "no journal"
        rec.autosave(edited)
        let noJournal = RecoveryManager(baseDir: base).detectRecovery()
        tk.expect(noJournal != nil, "autosave alone still surfaces recovery")
        tk.expectEqual(noJournal?.project?.title, "no journal", "autosave recovered without journal")
        tk.expect(noJournal?.journalLoadFailureMessage == nil,
                  "missing journal stays silent (no journalLoadFailureMessage)")
        tk.expect(noJournal?.inProgressTakeURL == nil, "no take without journal")

        // Same session: write a journal that exists but cannot decode.
        let journalURL = rec.workspaceDir.appendingPathComponent("journal.json")
        try "{not valid journal json".data(using: .utf8)!
            .write(to: journalURL, options: [.atomic])
        let corrupt = RecoveryManager(baseDir: base).detectRecovery()
        tk.expect(corrupt != nil, "corrupt journal still surfaces recovery")
        tk.expectEqual(corrupt?.project?.title, "no journal", "autosave still recovered with corrupt journal")
        let jfail = corrupt?.journalLoadFailureMessage ?? ""
        tk.expect(!jfail.isEmpty, "journalLoadFailureMessage is set for corrupt journal")
        tk.expect(corrupt?.inProgressTakeURL == nil, "corrupt journal yields no take URL")
        // Journal file retained (not treated as disposable garbage).
        tk.expect(fm.fileExists(atPath: journalURL.path),
                  "corrupt journal retained after detectRecovery")

        // Corrupt journal alone (no autosave) must still be observable, not silent nothing.
        try? fm.removeItem(at: rec.workspaceDir.appendingPathComponent("autosave-project.json"))
        let journalOnly = RecoveryManager(baseDir: base).detectRecovery()
        tk.expect(journalOnly != nil, "corrupt journal alone is observable recovery")
        tk.expect(journalOnly?.project == nil, "no project without autosave")
        tk.expect(!(journalOnly?.journalLoadFailureMessage ?? "").isEmpty,
                  "journal-only corruption sets journalLoadFailureMessage")
    }

    tk.suite("Recovery: discardRecovery leaves unrelated takes on disk") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-discard-\(UUID().uuidString)")
        let rec = RecoveryManager(baseDir: base)
        rec.beginSession()

        // Unrelated take that belongs to another (or saved) project, not the journal.
        let otherName = "other-project-take.caf"
        try writeSineCAF(to: rec.mediaDir.appendingPathComponent(otherName), seconds: 0.1)

        // In-progress take named in the journal (the only file discard may remove).
        let orphanURL = rec.newTakeURL()
        try writeSineCAF(to: orphanURL, seconds: 0.1)
        rec.noteRecordingStarted(takeFilename: orphanURL.lastPathComponent)
        var edited = Project.newUntitled(); edited.title = "discard me"
        rec.autosave(edited)

        rec.discardRecovery()
        tk.expect(fm.fileExists(atPath: rec.mediaDir.appendingPathComponent(otherName).path),
                  "unrelated take still on disk after discardRecovery")
        tk.expect(!fm.fileExists(atPath: orphanURL.path),
                  "journaled in-progress take removed by discardRecovery")
        tk.expect(fm.fileExists(atPath: rec.mediaDir.path),
                  "Media directory was not wiped")
        tk.expect(RecoveryManager(baseDir: base).detectRecovery() == nil,
                  "recovery artifacts cleared")
        try? fm.removeItem(at: base)
    }

    // MARK: - Step G4

    tk.suite("Recovery G4: injected baseDir still works (no Application Support required)") {
        let base = fm.temporaryDirectory.appendingPathComponent("verse-g4-rec-\(UUID().uuidString)")
        let rec = RecoveryManager(baseDir: base)
        tk.expect(rec.mediaDir.path.hasPrefix(base.path), "mediaDir under injected base")
        rec.beginSession()
        var p = Project.newUntitled(); p.title = "g4"
        rec.autosave(p)
        let relaunch = RecoveryManager(baseDir: base)
        let info = relaunch.detectRecovery()
        tk.expect(info != nil, "recovery works with injected baseDir")
        tk.expectEqual(info?.project?.title, "g4", "autosave recovered from injected baseDir")
        relaunch.endSessionCleanly()
        try? fm.removeItem(at: base)
    }

    tk.suite("Persistence G4: package with duplicate track ids opens with unique ids") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-dup-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let shared = UUID()
        var project = Project(title: "Dup Tracks")
        project.tracks = [
            Track(id: shared, kind: .instrument, name: "First", instrument: .grandPiano),
            Track(id: shared, kind: .instrument, name: "Second", instrument: .grandPiano)
        ]
        let pkg = root.appendingPathComponent("Dup.verse")
        try ProjectPackage.write(project, to: pkg, mediaSourceDir: nil)

        // Raw read still has the duplicate (package did not rewrite ids).
        var loaded = try ProjectPackage.read(pkg)
        tk.expectEqual(loaded.tracks[0].id, loaded.tracks[1].id, "package preserved duplicate ids")
        let n = loaded.ensureUniqueTrackIDs()
        tk.expectEqual(n, 1, "one track re-keyed on open path")
        tk.expect(loaded.tracks[0].id != loaded.tracks[1].id, "ids distinct after ensureUniqueTrackIDs")
        tk.expectEqual(loaded.tracks[0].name, "First", "first track kept its id and name")
        tk.expectEqual(loaded.tracks[1].name, "Second", "second track kept its name")
    }

    // MARK: - Step G5: Persistence round trips

    tk.suite("Persistence G5: save then read preserves model fields including inserts") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-g5-fields-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let trackID = UUID()
        let clipID = UUID()
        let noteID = UUID()
        let insert = AudioUnitRef(
            type: "aufx", subtype: "reverb", manufacturer: "verse.builtin",
            name: "Reverb", stateBlob: Data([0x01, 0x02, 0xAB]))
        let note = Note(id: noteID, startBeat: 0.5, lengthBeats: 1.25, pitch: 64, velocity: 97,
                        pitchBend: [0.0, 0.1, -0.05])
        let midiClip = Clip(id: clipID, kind: .midi, name: "Phrase", startBeat: 2, lengthBeats: 8,
                            midiNotes: [note])
        let track = Track(id: trackID, kind: .instrument, name: "Lead",
                          volume: 0.55, pan: -0.3, mute: true, solo: true,
                          instrument: Instrument(sf2: "GeneralUserGS", program: 24, bankMSB: 121, bankLSB: 0),
                          inserts: [insert], clips: [midiClip])
        let project = Project(
            title: "Field Sweep",
            tempoBPM: 93.5,
            key: KeySignature(tonic: .Fs, mode: .minor),
            timeSignature: TimeSignature(num: 3, den: 4),
            tracks: [track],
            masterVolume: 0.7)
        let fixedID = project.id
        let fixedCreated = project.createdAt

        let pkg = root.appendingPathComponent("Fields.verse")
        try ProjectPackage.write(project, to: pkg, mediaSourceDir: nil)
        let back = try ProjectPackage.read(pkg)

        tk.expectEqual(back.schemaVersion, Schema.current, "schemaVersion preserved")
        tk.expectEqual(back.id, fixedID, "project id preserved")
        tk.expectEqual(back.title, "Field Sweep", "title preserved")
        tk.expectEqual(back.tempoBPM, 93.5, "tempoBPM preserved")
        tk.expectEqual(back.key?.tonic, .Fs, "key tonic preserved")
        tk.expectEqual(back.key?.mode, .minor, "key mode preserved")
        tk.expectEqual(back.timeSignature.num, 3, "time signature numerator preserved")
        tk.expectEqual(back.timeSignature.den, 4, "time signature denominator preserved")
        tk.expectEqual(back.masterVolume, 0.7, "masterVolume preserved")
        // write() stamps modifiedAt; createdAt must stay put. ISO8601 encoding is whole-second.
        tk.expectEqual(Int(back.createdAt.timeIntervalSince1970),
                       Int(fixedCreated.timeIntervalSince1970),
                       "createdAt preserved (to the second; ISO8601)")

        tk.expectEqual(back.tracks.count, 1, "one track")
        let t = back.tracks[0]
        tk.expectEqual(t.id, trackID, "track id preserved")
        tk.expectEqual(t.kind, .instrument, "track kind preserved")
        tk.expectEqual(t.name, "Lead", "track name preserved")
        tk.expectEqual(t.volume, 0.55, "volume preserved")
        tk.expectEqual(t.pan, -0.3, "pan preserved")
        tk.expect(t.mute, "mute preserved")
        tk.expect(t.solo, "solo preserved")
        tk.expectEqual(t.instrument?.program, 24, "instrument program preserved")
        tk.expectEqual(t.instrument?.bankMSB, 121, "instrument bankMSB preserved")
        tk.expectEqual(t.inserts.count, 1, "inserts count preserved")
        tk.expectEqual(t.inserts[0].type, "aufx", "insert type preserved")
        tk.expectEqual(t.inserts[0].subtype, "reverb", "insert subtype preserved")
        tk.expectEqual(t.inserts[0].manufacturer, "verse.builtin", "insert manufacturer preserved")
        tk.expectEqual(t.inserts[0].name, "Reverb", "insert name preserved")
        tk.expectEqual(t.inserts[0].stateBlob, Data([0x01, 0x02, 0xAB]), "insert stateBlob preserved")
        tk.expectEqual(t.clips.count, 1, "clip count preserved")
        tk.expectEqual(t.clips[0].id, clipID, "clip id preserved")
        tk.expectEqual(t.clips[0].kind, .midi, "clip kind preserved")
        tk.expectEqual(t.clips[0].name, "Phrase", "clip name preserved")
        tk.expectEqual(t.clips[0].startBeat, 2, "clip startBeat preserved")
        tk.expectEqual(t.clips[0].lengthBeats, 8, "clip lengthBeats preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.id, noteID, "note id preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.pitch, 64, "note pitch preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.velocity, 97, "note velocity preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.startBeat, 0.5, "note startBeat preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.lengthBeats, 1.25, "note lengthBeats preserved")
        tk.expectEqual(t.clips[0].midiNotes?.first?.pitchBend, [0.0, 0.1, -0.05],
                       "note pitchBend preserved")
    }

    tk.suite("Persistence G5: package missing project.json yields readable error") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-g5-missing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Directory shaped like a .verse package but without project.json.
        let pkg = root.appendingPathComponent("Broken.verse")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "not the project".write(to: pkg.appendingPathComponent("readme.txt"),
                                    atomically: true, encoding: .utf8)

        var sawExpected = false
        var message = ""
        do {
            _ = try ProjectPackage.read(pkg)
        } catch let err as ProjectPackage.PackageError {
            if case .missingProjectJSON = err { sawExpected = true }
            message = err.errorDescription ?? ""
        } catch {
            message = String(describing: error)
        }
        tk.expect(sawExpected, "throws PackageError.missingProjectJSON")
        tk.expect(message.contains("missing") || message.contains("project"),
                  "error message is readable: “\(message)”")
    }

    tk.suite("Persistence G5: unreadable media is reported as skipped, save still succeeds") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-g5-skip-\(UUID().uuidString)")
        let mediaSrc = root.appendingPathComponent("src-media")
        try fm.createDirectory(at: mediaSrc, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let goodName = "good.caf"
        let missingName = "missing-take.caf"
        try writeSineCAF(to: mediaSrc.appendingPathComponent(goodName), seconds: 0.1)

        var project = Project.newUntitled()
        project.title = "Partial Media"
        var audio = Track(kind: .audio, name: "Rec")
        audio.clips = [
            Clip(kind: .audio, name: "Good", startBeat: 0, lengthBeats: 2, mediaFile: goodName),
            Clip(kind: .audio, name: "Gone", startBeat: 4, lengthBeats: 2, mediaFile: missingName)
        ]
        project.tracks.append(audio)

        let pkg = root.appendingPathComponent("Partial.verse")
        let skipped = try ProjectPackage.write(project, to: pkg, mediaSourceDir: mediaSrc)
        tk.expectEqual(skipped, [missingName], "missing media name reported in skipped list")
        tk.expect(fm.fileExists(atPath: pkg.appendingPathComponent("Media/\(goodName)").path),
                  "readable media was still packaged")
        tk.expect(!fm.fileExists(atPath: pkg.appendingPathComponent("Media/\(missingName)").path),
                  "missing media was not silently invented")
        let back = try ProjectPackage.read(pkg)
        tk.expectEqual(back.title, "Partial Media", "project still saved when media skipped")
        tk.expectEqual(back.tracks.last?.clips.count, 2, "clip references preserved even if media skipped")
    }

    tk.suite("Persistence G5: extractMedia reports copy failures") {
        let root = fm.temporaryDirectory.appendingPathComponent("verse-g5-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let mediaSrc = root.appendingPathComponent("src")
        try fm.createDirectory(at: mediaSrc, withIntermediateDirectories: true)
        let takeName = "take-block.caf"
        try writeSineCAF(to: mediaSrc.appendingPathComponent(takeName), seconds: 0.1)

        var project = Project.newUntitled()
        var audio = Track(kind: .audio, name: "Rec")
        audio.clips = [Clip(kind: .audio, name: "T", startBeat: 0, lengthBeats: 1, mediaFile: takeName)]
        project.tracks.append(audio)
        let pkg = root.appendingPathComponent("Extract.verse")
        try ProjectPackage.write(project, to: pkg, mediaSourceDir: mediaSrc)

        let work = root.appendingPathComponent("work-media", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        // Force a copy failure: leave an immutable file at the destination path so
        // extractMedia's try? removeItem cannot clear it and copyItem throws.
        var blocker = work.appendingPathComponent(takeName)
        try Data([0x00]).write(to: blocker)
        var values = URLResourceValues()
        values.isUserImmutable = true
        try blocker.setResourceValues(values)
        defer {
            var clear = URLResourceValues()
            clear.isUserImmutable = false
            try? blocker.setResourceValues(clear)
        }

        let failed = try ProjectPackage.extractMedia(from: pkg, to: work)
        tk.expect(failed.contains(takeName), "failed extract reports the take name, not silent success")
        // Control: clean destination gets a successful (empty failed) extract.
        let clean = root.appendingPathComponent("work-clean", isDirectory: true)
        let cleanFailed = try ProjectPackage.extractMedia(from: pkg, to: clean)
        tk.expect(cleanFailed.isEmpty, "unblocked extract reports no failures")
        tk.expect(fm.fileExists(atPath: clean.appendingPathComponent(takeName).path),
                  "unblocked extract places the take on disk")
    }
}

// MARK: - SIGKILL crash-injection modes (driven by scripts/crash-recovery-test.sh)

/// Sets up an unclean-session on-disk state, signals readiness, then blocks forever so the
/// test script can `kill -9` this process to simulate a real crash.
func crashWriter(dir: String) -> Never {
    let base = URL(fileURLWithPath: dir)
    let rec = RecoveryManager(baseDir: base)
    rec.beginSession()
    let takeURL = rec.newTakeURL()
    _ = try? writeSineCAF(to: takeURL, seconds: 0.5)
    rec.noteRecordingStarted(takeFilename: takeURL.lastPathComponent)
    var edited = Project.newUntitled()
    edited.title = "CRASH EDIT"
    rec.autosave(edited)
    // Signal the harness that crash state is fully on disk.
    try? "ready".data(using: .utf8)?.write(to: base.appendingPathComponent("ready"))
    fputs("READY\n", stderr)
    while true { Thread.sleep(forTimeInterval: 1) }   // wait to be SIGKILL'd
}

/// After a SIGKILL, verify recovery reconstructs the autosaved project + in-progress take.
func crashRecover(dir: String) -> Never {
    let base = URL(fileURLWithPath: dir)
    let rec = RecoveryManager(baseDir: base)
    guard let info = rec.detectRecovery() else {
        fputs("FAIL: no recovery detected after SIGKILL\n", stderr); exit(1)
    }
    guard info.project?.title == "CRASH EDIT" else {
        fputs("FAIL: autosaved edit not recovered (got \(info.project?.title ?? "nil"))\n", stderr); exit(1)
    }
    guard let take = info.inProgressTakeURL,
          FileManager.default.fileExists(atPath: take.path),
          let f = try? AVAudioFile(forReading: take), f.length > 0 else {
        fputs("FAIL: in-progress take not recovered/playable\n", stderr); exit(1)
    }
    print("✅ Crash recovery OK: recovered project ‘\(info.project!.title)’ + take \(take.lastPathComponent) (\(f.length) frames)")
    exit(0)
}

// MARK: - helper

@discardableResult
func writeSineCAF(to url: URL, seconds: Double, sampleRate: Double = 44_100) throws -> URL {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return url }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: true
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return url }
    buf.frameLength = frames
    let ch = buf.floatChannelData![0]
    for i in 0..<Int(frames) { ch[i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / sampleRate)) }
    try file.write(from: buf)
    return url
}
