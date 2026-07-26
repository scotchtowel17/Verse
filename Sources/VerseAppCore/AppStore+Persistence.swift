import AppKit
import UniformTypeIdentifiers
import VerseModel
import VersePersistence

// MARK: - Recovery, new / open / save

extension AppStore {
    // MARK: Recovery

    func applyRecovery() {
        // Nothing pending (already applied or dismissed): deliberate no-op.
        guard let info = pendingRecovery else { return }
        if let recovered = info.project {
            project = recovered
            let rekeyed = project.ensureUniqueTrackIDs()
            activeTrackID = project.tracks.first(where: { $0.kind == .instrument })?.id ?? activeTrackID
            rollTrackID = activeTrackID
            pianoRollClipID = nil
            engine.reconfigure(with: project)
            restoreEffectsFromProject()
            if let takeURL = info.inProgressTakeURL {
                addRecordingClip(filename: takeURL.lastPathComponent, seconds: durationOf(takeURL))
            }
            rebuildTakesFromModel()
            history.clear()
            var msg: String
            if rekeyed > 0 {
                let n = rekeyed == 1 ? "1 duplicate track id" : "\(rekeyed) duplicate track ids"
                msg = "Recovered your unsaved work. Fixed \(n) so every track can play."
            } else {
                msg = "Recovered your unsaved work."
            }
            if let jfail = info.journalLoadFailureMessage {
                msg = "\(msg) \(jfail)"
            }
            statusMessage = msg
        } else {
            // Autosave missing or unreadable. Still restore any take the journal named.
            if let takeURL = info.inProgressTakeURL {
                addRecordingClip(filename: takeURL.lastPathComponent, seconds: durationOf(takeURL))
                rebuildTakesFromModel()
            }
            if let fail = info.projectLoadFailureMessage {
                statusMessage = info.inProgressTakeURL == nil
                    ? fail
                    : "\(fail) Restored the in-progress recording."
            } else if let jfail = info.journalLoadFailureMessage {
                statusMessage = jfail
            } else {
                statusMessage = "Couldn’t restore the autosaved project."
            }
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
        let firstID = p.tracks.first?.id ?? UUID()
        activeTrackID = firstID
        rollTrackID = firstID
        pianoRollClipID = nil
        showPianoRoll = true
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
        // User cancelled the open panel: nothing was asked to load.
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
            rollTrackID = activeTrackID
            pianoRollClipID = nil
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
        // User cancelled the save panel: nothing was asked to write.
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
