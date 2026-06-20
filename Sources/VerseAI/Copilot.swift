import Foundation
import VerseModel

/// Facade for the Claude bridge: parse → validate → transactionally apply (Build Contract §15,
/// §E). The project is mutated ONLY on full success; any parse or validation failure leaves it
/// untouched and reports plain-language problems.
public enum Copilot {

    public struct Outcome {
        public enum Status: Equatable { case applied, rejected, parseError }
        public let status: Status
        public let summary: String?
        public let opCount: Int
        public let clamps: [String]
        public let errors: [PatchError]
        public let parseMessage: String?

        public var userMessage: String {
            switch status {
            case .applied:
                var m = "Applied \(opCount) change\(opCount == 1 ? "" : "s")."
                if let s = summary { m = "\(s) (\(opCount) op\(opCount == 1 ? "" : "s"))" }
                if !clamps.isEmpty { m += " " + clamps.joined(separator: " ") }
                return m
            case .rejected:
                return "Nothing was applied — the patch had \(errors.count) problem\(errors.count == 1 ? "" : "s"):\n"
                    + errors.map { "• \($0.description)" }.joined(separator: "\n")
            case .parseError:
                return parseMessage ?? "Couldn’t read Claude’s reply."
            }
        }
    }

    /// Apply Claude's reply to `project`. Returns an outcome; mutates `project` only when applied.
    @discardableResult
    public static func apply(reply: String, to project: inout Project) -> Outcome {
        let parsed: PatchParser.ParsedPatch
        do {
            parsed = try PatchParser.parse(reply)
        } catch let e as PatchParser.ParseError {
            return Outcome(status: .parseError, summary: nil, opCount: 0, clamps: [],
                           errors: [], parseMessage: e.errorDescription)
        } catch {
            return Outcome(status: .parseError, summary: nil, opCount: 0, clamps: [],
                           errors: [], parseMessage: error.localizedDescription)
        }

        switch PatchValidator.validate(parsed, project: project) {
        case .failure(let pe):
            return Outcome(status: .rejected, summary: parsed.summary, opCount: 0, clamps: [],
                           errors: pe.errors, parseMessage: nil)
        case .success(let success):
            let cmd = PatchCommand(name: success.summary ?? "Apply Claude patch", ops: success.ops)
            try? cmd.apply(to: &project)   // validated → never throws
            return Outcome(status: .applied, summary: success.summary, opCount: success.ops.count,
                           clamps: success.clamps, errors: [], parseMessage: nil)
        }
    }

    /// Build the request to copy into Claude.
    public static func buildRequest(project: Project, userPrompt: String) -> String {
        RequestBuilder.buildJSON(project: project, userPrompt: userPrompt)
    }
}
