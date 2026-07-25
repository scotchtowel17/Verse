import AppKit
import VerseAI
import VerseModel

// MARK: - Claude copilot (M5)

extension AppStore {
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
        history.record(project, name: "Apply Claude Patch")  // one undo group for the whole patch
        project = working
        syncEngineToProject()
        recovery.autosave(project)
        copilotReply = ""
    }
}
