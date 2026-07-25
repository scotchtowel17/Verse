import AppKit
import VerseAI
import VerseModel

// MARK: - Claude copilot (M5)

extension AppStore {
    /// True while the mandatory patch-preview sheet is showing. Transport and record
    /// must refuse work in this state so a play/record gesture cannot race the apply.
    var copilotPreviewBlocksTransport: Bool { showCopilotPreview && pendingCopilotPreview != nil }

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

    /// Parse + validate + render. On success, present the mandatory preview sheet.
    /// Does not mutate the project. Claude’s summary is never the approval text.
    func applyCopilotReply() {
        switch Copilot.preview(reply: copilotReply, project: project) {
        case .failure(let outcome):
            copilotMessage = outcome.userMessage
            pendingCopilotPreview = nil
            showCopilotPreview = false
        case .success(let prep):
            pendingCopilotPreview = prep
            showCopilotPreview = true
            copilotMessage = nil
        }
    }

    /// User confirmed the rendered ops. Re-checks fingerprint, then applies as one undo group.
    func commitCopilotPreview() {
        guard let prep = pendingCopilotPreview else {
            showCopilotPreview = false
            return
        }
        // Drop pending first so sheet dismiss does not look like a Cancel.
        pendingCopilotPreview = nil
        showCopilotPreview = false

        var working = project
        let outcome = Copilot.commit(prep, to: &working)
        copilotMessage = outcome.userMessage
        guard outcome.status == .applied else { return }
        history.record(project, name: "Apply Claude Patch")  // one undo group for the whole patch
        project = working
        syncEngineToProject()
        recovery.autosave(project)
        copilotReply = ""
    }

    /// User cancelled, or the sheet was dismissed. Only records a cancel message when a
    /// preview was still pending (successful Apply clears pending first).
    func cancelCopilotPreview() {
        let hadPending = pendingCopilotPreview != nil
        pendingCopilotPreview = nil
        showCopilotPreview = false
        if hadPending {
            copilotMessage = "Apply cancelled. Nothing was changed."
        }
    }
}
