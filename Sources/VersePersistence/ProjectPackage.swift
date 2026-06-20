import Foundation
import VerseModel

/// Reads and writes the versioned `.verse` file package (Build Contract §10, §11).
///
/// Layout:
/// ```
/// MySong.verse/            (NSFileWrapper directory)
///   project.json           versioned model
///   Media/                 recorded takes / imported audio referenced by clips
///   Analysis/              cached Music Understanding results
///   autosave/              reserved for in-package autosave snapshots
/// ```
/// Saves are atomic: `FileWrapper.write(to:options:.atomic, originalContentsURL:)` swaps the
/// package in place so a crash mid-save never corrupts the prior good copy.
public enum ProjectPackage {
    public static let fileExtension = "verse"
    static let projectFile = "project.json"
    static let mediaDirName = "Media"
    static let analysisDirName = "Analysis"
    static let autosaveDirName = "autosave"

    public enum PackageError: Error, LocalizedError {
        case missingProjectJSON
        public var errorDescription: String? {
            switch self {
            case .missingProjectJSON: return "This Verse song is missing its project data."
            }
        }
    }

    /// Atomically write `project` to a `.verse` package, copying referenced media from
    /// `mediaSourceDir` into the package's `Media/`.
    public static func write(_ project: Project, to url: URL, mediaSourceDir: URL?) throws {
        var proj = project
        proj.modifiedAt = Date()
        let json = try proj.jsonData()

        let root = FileWrapper(directoryWithFileWrappers: [:])

        let jsonWrapper = FileWrapper(regularFileWithContents: json)
        jsonWrapper.preferredFilename = projectFile
        root.addFileWrapper(jsonWrapper)

        // Media/: copy every file referenced by a clip.
        let referenced = Set(project.tracks.flatMap { $0.clips.compactMap { $0.mediaFile } })
        let mediaWrapper = FileWrapper(directoryWithFileWrappers: [:])
        mediaWrapper.preferredFilename = mediaDirName
        if let src = mediaSourceDir {
            for name in referenced.sorted() {
                let fileURL = src.appendingPathComponent(name)
                if let data = try? Data(contentsOf: fileURL) {
                    let w = FileWrapper(regularFileWithContents: data)
                    w.preferredFilename = name
                    mediaWrapper.addFileWrapper(w)
                }
            }
        }
        root.addFileWrapper(mediaWrapper)

        // Empty Analysis/ + autosave/ placeholders.
        for name in [analysisDirName, autosaveDirName] {
            let w = FileWrapper(directoryWithFileWrappers: [:])
            w.preferredFilename = name
            root.addFileWrapper(w)
        }

        let original = FileManager.default.fileExists(atPath: url.path) ? url : nil
        try root.write(to: url, options: [.atomic], originalContentsURL: original)
    }

    /// Read and migrate the project model from a `.verse` package.
    public static func read(_ url: URL) throws -> Project {
        let wrapper = try FileWrapper(url: url, options: [])
        guard let projWrapper = wrapper.fileWrappers?[projectFile],
              let data = projWrapper.regularFileContents else {
            throw PackageError.missingProjectJSON
        }
        return try Project.fromJSON(data)
    }

    /// The package's Media/ directory URL (the package is a directory on disk).
    public static func mediaURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(mediaDirName, isDirectory: true)
    }

    /// Copy a package's media into a working directory and return that directory.
    @discardableResult
    public static func extractMedia(from packageURL: URL, to workingMediaDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: workingMediaDir, withIntermediateDirectories: true)
        let media = mediaURL(in: packageURL)
        if let items = try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil) {
            for item in items {
                let dst = workingMediaDir.appendingPathComponent(item.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: item, to: dst)
            }
        }
        return workingMediaDir
    }
}
