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
