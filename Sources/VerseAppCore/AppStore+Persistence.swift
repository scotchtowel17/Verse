import AppKit
import UniformTypeIdentifiers
import VerseModel
import VersePersistence

// MARK: - Recovery, new / open / save

extension AppStore {
    // MARK: Recovery

    func applyRecovery() {
        guard let info = pendingRecovery else { return }
        if let recovered = info.project { project = recovered }
        let rekeyed = project.ensureUniqueTrackIDs()
        activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? activeTrackID
        engine.reconfigure(with: project)
        restoreEffectsFromProject()
        if let takeURL = info.inProgressTakeURL {
            addRecordingClip(filename: takeURL.lastPathComponent, seconds: durationOf(takeURL))
        }
        rebuildTakesFromModel()
        history.clear()
        if rekeyed > 0 {
            let n = rekeyed == 1 ? "1 duplicate track id" : "\(rekeyed) duplicate track ids"
            statusMessage = "Recovered your unsaved work. Fixed \(n) so every track can play."
        } else {
            statusMessage = "Recovered your unsaved work."
        }
        pendingRecovery = nil
    }

    func dismissRecovery() {
        recovery.discardRecovery()
        pendingRecovery = nil
    }

    // MARK: New / Open / Save

    public func newProject() {
        engine.allNotesOff()
        let p = Project.newUntitled()
        project = p
        activeTrackID = p.tracks.first?.id ?? UUID()
        currentPackageURL = nil
        takes.removeAll()
        trackEffects.removeAll()
        engine.reconfigure(with: project)
        restoreEffectsFromProject()
        history.clear()
    }

    public func open() {
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
            var loaded = try ProjectPackage.read(url)
            let rekeyed = loaded.ensureUniqueTrackIDs()
            let failedMedia = (try? ProjectPackage.extractMedia(from: url, to: workingMediaDir)) ?? []
            project = loaded
            currentPackageURL = url
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? project.tracks.first?.id ?? UUID()
            engine.reconfigure(with: project)
            restoreEffectsFromProject()
            rebuildTakesFromModel()
            history.clear()
            var parts: [String] = []
            if failedMedia.isEmpty {
                parts.append("Opened “\(documentName)”.")
            } else {
                parts.append("Opened “\(documentName)” — \(failedMedia.count) audio file(s) couldn’t be loaded.")
            }
            if rekeyed > 0 {
                let n = rekeyed == 1 ? "1 duplicate track id" : "\(rekeyed) duplicate track ids"
                parts.append("Fixed \(n) so every track can play.")
            }
            statusMessage = parts.joined(separator: " ")
        } catch {
            statusMessage = "Couldn’t open: \(error.localizedDescription)"
        }
    }

    public func save() {
        if let url = currentPackageURL { writePackage(to: url) } else { saveAs() }
    }

    public func saveAs() {
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
            let skipped = try ProjectPackage.write(project, to: url, mediaSourceDir: workingMediaDir)
            let name = url.deletingPathExtension().lastPathComponent
            statusMessage = skipped.isEmpty
                ? "Saved “\(name)”."
                : "Saved “\(name)” — but \(skipped.count) audio file(s) couldn’t be included."
        } catch {
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    static let verseType = UTType(filenameExtension: ProjectPackage.fileExtension,
                                  conformingTo: .package) ?? .package
}
