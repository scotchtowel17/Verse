import Foundation
import VerseModel

/// Crash-safety: journaled recording + autosave + recovery scan (Build Contract §11, §G).
///
/// All recovery state lives in a stable workspace under Application Support (NOT a temp dir
/// that the OS could wipe), so it survives a SIGKILL and is found on the next launch:
/// ```
/// ~/Library/Application Support/Verse/Workspace/
///   Media/                  takes stream here during capture (journaled)
///   autosave-project.json   latest autosaved edits (atomic writes)
///   journal.json            in-progress recording marker
///   session.lock            present while a session is live; absent after a clean quit
/// ```
/// A clean quit removes `session.lock`. If the lock is still present at launch, the previous
/// session ended uncleanly (crash) and recovery is offered.
public final class RecoveryManager {

    public let workspaceDir: URL
    public let mediaDir: URL
    private let autosaveURL: URL
    private let journalURL: URL
    private let sessionLockURL: URL

    public init(baseDir: URL? = nil) {
        // Prefer Application Support. If the system returns no URL (should not happen, but
        // `.first!` would trap before any UI exists), fall back to the temporary directory.
        let base: URL
        if let baseDir {
            base = baseDir
        } else if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = appSupport.appendingPathComponent("Verse", isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("Verse", isDirectory: true)
        }
        let ws = base.appendingPathComponent("Workspace", isDirectory: true)
        self.workspaceDir = ws
        self.mediaDir = ws.appendingPathComponent("Media", isDirectory: true)
        self.autosaveURL = ws.appendingPathComponent("autosave-project.json")
        self.journalURL = ws.appendingPathComponent("journal.json")
        self.sessionLockURL = ws.appendingPathComponent("session.lock")
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    // MARK: - Journal

    struct Journal: Codable {
        var recording: Bool
        var takeFilename: String?
        var startedAt: Date?
    }

    // MARK: - Recovery detection (call at launch, BEFORE beginSession)

    public struct RecoveryInfo {
        public let project: Project?
        public let inProgressTakeFilename: String?
        public let inProgressTakeURL: URL?
        /// Present when `autosave-project.json` exists but could not be decoded (for example a
        /// future schemaVersion). Keeps the failure readable instead of pretending nothing was found.
        public let projectLoadFailureMessage: String?
        /// Present when `journal.json` exists but could not be read or decoded. A missing journal
        /// is normal (no recording in progress) and stays a silent no-op; only a corrupt file
        /// is surfaced.
        public let journalLoadFailureMessage: String?
        public var hasSomething: Bool {
            project != nil || inProgressTakeURL != nil
                || projectLoadFailureMessage != nil || journalLoadFailureMessage != nil
        }
    }

    /// If the previous session didn't end cleanly, return what can be recovered.
    public func detectRecovery() -> RecoveryInfo? {
        guard FileManager.default.fileExists(atPath: sessionLockURL.path) else {
            return nil   // previous session ended cleanly
        }
        var project: Project?
        var projectLoadFailureMessage: String?
        if let data = try? Data(contentsOf: autosaveURL) {
            do {
                project = try Project.fromJSON(data)
            } catch {
                // Keep the autosave on disk; surface why it could not be opened.
                projectLoadFailureMessage = Self.readableLoadFailure(
                    error, fallback: "Couldn’t restore the autosaved project.")
            }
        }
        var takeName: String?
        var takeURL: URL?
        var journalLoadFailureMessage: String?
        // Missing journal is normal (no recording in progress): silent no-op.
        // A journal that exists but fails to read/decode is a distinct failure.
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let jdata = try Data(contentsOf: journalURL)
                let journal = try JSONDecoder().decode(Journal.self, from: jdata)
                if journal.recording, let name = journal.takeFilename {
                    let url = mediaDir.appendingPathComponent(name)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       (attrs[.size] as? Int ?? 0) > 0 {
                        takeName = name
                        takeURL = url
                    }
                }
            } catch {
                journalLoadFailureMessage = Self.readableLoadFailure(
                    error, fallback: "Couldn’t read the recovery journal for an in-progress recording.")
            }
        }
        let info = RecoveryInfo(
            project: project,
            inProgressTakeFilename: takeName,
            inProgressTakeURL: takeURL,
            projectLoadFailureMessage: projectLoadFailureMessage,
            journalLoadFailureMessage: journalLoadFailureMessage
        )
        return info.hasSomething ? info : nil
    }

    private static func readableLoadFailure(_ error: Error, fallback: String) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty {
            return d
        }
        let s = error.localizedDescription
        return s.isEmpty ? fallback : s
    }

    // MARK: - Session lifecycle

    public func beginSession() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? "session \(stamp)".data(using: .utf8)?.write(to: sessionLockURL)
    }

    /// Remove the lock + recovery state. After this, the next launch offers no recovery.
    ///
    /// Prefer `pruneMedia(keeping:)` over `clearMedia: true`. Wiping the whole Media directory
    /// can delete takes that still belong to other saved projects sharing this workspace.
    public func endSessionCleanly(clearMedia: Bool = false) {
        try? FileManager.default.removeItem(at: sessionLockURL)
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: autosaveURL)
        if clearMedia { try? FileManager.default.removeItem(at: mediaDir) }
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    /// Discard recovery offer (user declined). Removes session lock, journal, and autosave,
    /// and at most the single in-progress take named in the journal. Never deletes the Media
    /// directory or unrelated takes from other projects.
    public func discardRecovery() {
        var orphanTake: String?
        // Missing journal: nothing to name. Present but unreadable: still clean up below;
        // orphan take name is best-effort only when decode succeeds.
        if FileManager.default.fileExists(atPath: journalURL.path),
           let jdata = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(Journal.self, from: jdata),
           journal.recording, let name = journal.takeFilename {
            orphanTake = name
        }
        endSessionCleanly(clearMedia: false)
        if let name = orphanTake {
            try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(name))
        }
    }

    /// Delete workspace media files whose names are not in `referenced`. Keeps every
    /// referenced file. Safe when `referenced` is empty (removes all files under Media/,
    /// does not throw). Pure against a temp `baseDir` for tests.
    public func pruneMedia(keeping referenced: Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: mediaDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            return
        }
        for url in items {
            guard !referenced.contains(url.lastPathComponent) else { continue }
            try? fm.removeItem(at: url)
        }
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    // MARK: - Autosave + journaling

    public func autosave(_ project: Project) {
        if let data = try? project.jsonData() {
            try? data.write(to: autosaveURL, options: [.atomic])
        }
    }

    public func noteRecordingStarted(takeFilename: String) {
        let j = Journal(recording: true, takeFilename: takeFilename, startedAt: Date())
        if let data = try? JSONEncoder().encode(j) { try? data.write(to: journalURL, options: [.atomic]) }
    }

    public func noteRecordingStopped() {
        let j = Journal(recording: false, takeFilename: nil, startedAt: nil)
        if let data = try? JSONEncoder().encode(j) { try? data.write(to: journalURL, options: [.atomic]) }
    }

    public func newTakeURL() -> URL {
        mediaDir.appendingPathComponent("take-\(Int(Date().timeIntervalSince1970)).caf")
    }
}
