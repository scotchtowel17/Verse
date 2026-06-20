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
        let base = baseDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Verse", isDirectory: true)
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
        public var hasSomething: Bool { project != nil || inProgressTakeURL != nil }
    }

    /// If the previous session didn't end cleanly, return what can be recovered.
    public func detectRecovery() -> RecoveryInfo? {
        guard FileManager.default.fileExists(atPath: sessionLockURL.path) else {
            return nil   // previous session ended cleanly
        }
        var project: Project?
        if let data = try? Data(contentsOf: autosaveURL) {
            project = try? Project.fromJSON(data)
        }
        var takeName: String?
        var takeURL: URL?
        if let jdata = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(Journal.self, from: jdata),
           journal.recording, let name = journal.takeFilename {
            let url = mediaDir.appendingPathComponent(name)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 0 {
                takeName = name
                takeURL = url
            }
        }
        let info = RecoveryInfo(project: project, inProgressTakeFilename: takeName, inProgressTakeURL: takeURL)
        return info.hasSomething ? info : nil
    }

    // MARK: - Session lifecycle

    public func beginSession() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? "session \(stamp)".data(using: .utf8)?.write(to: sessionLockURL)
    }

    /// Remove the lock + recovery state. After this, the next launch offers no recovery.
    public func endSessionCleanly(clearMedia: Bool = false) {
        try? FileManager.default.removeItem(at: sessionLockURL)
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: autosaveURL)
        if clearMedia { try? FileManager.default.removeItem(at: mediaDir) }
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    }

    /// Discard recovery offer (user declined) but keep a fresh workspace.
    public func discardRecovery() {
        endSessionCleanly(clearMedia: true)
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
