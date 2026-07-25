import Foundation
import VerseModel

/// Facade for the Claude bridge: parse → validate → preview → commit (Build Contract §15,
/// §E). The project is mutated ONLY on full success of `commit`; preview never mutates.
///
/// Safety model for approval text: the plain-English description shown to the user is built
/// only from validated `TypedOp` values (via `PatchPreviewRenderer`). Claude’s free-form
/// `summary` is never used as the approval text.
public enum Copilot {

    public struct Outcome: Error {
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

    /// Result of a successful parse + validate + plain-English render. Does not mutate the project.
    public struct Preview {
        public let ops: [TypedOp]
        public let clamps: [String]
        /// Claude’s free-form summary, for a secondary “Claude says:” label only. Never approval text.
        public let claudeSummary: String?
        /// Structural fingerprint that matched the project at preview time; re-checked at commit.
        public let fingerprint: String
        /// Approval text: one line per change, built only from `TypedOp` values.
        public let lines: [String]

        public var description: String { lines.joined(separator: "\n") }
    }

    /// Parse and validate Claude’s reply against `project`, and render a plain-English preview.
    /// Never mutates `project`. On failure returns an `Outcome` with status `.parseError` or `.rejected`.
    public static func preview(reply: String, project: Project) -> Result<Preview, Outcome> {
        let parsed: PatchParser.ParsedPatch
        do {
            parsed = try PatchParser.parse(reply)
        } catch let e as PatchParser.ParseError {
            return .failure(Outcome(status: .parseError, summary: nil, opCount: 0, clamps: [],
                                    errors: [], parseMessage: e.errorDescription))
        } catch {
            return .failure(Outcome(status: .parseError, summary: nil, opCount: 0, clamps: [],
                                    errors: [], parseMessage: error.localizedDescription))
        }

        switch PatchValidator.validate(parsed, project: project) {
        case .failure(let pe):
            return .failure(Outcome(status: .rejected, summary: parsed.summary, opCount: 0, clamps: [],
                                    errors: pe.errors, parseMessage: nil))
        case .success(let success):
            // Fingerprint was validated non-empty and matching; store the live value for commit re-check.
            let fingerprint = project.structuralFingerprint
            let lines = PatchPreviewRenderer.render(ops: success.ops, clamps: success.clamps, project: project)
            return .success(Preview(ops: success.ops, clamps: success.clamps,
                                    claudeSummary: success.summary,
                                    fingerprint: fingerprint, lines: lines))
        }
    }

    /// Apply previously previewed ops. Re-checks the project fingerprint so a structural change
    /// while the sheet was open cannot apply against the wrong handles. Mutates `project` only
    /// on full success.
    @discardableResult
    public static func commit(_ preview: Preview, to project: inout Project) -> Outcome {
        commit(ops: preview.ops, expectedFingerprint: preview.fingerprint,
               clamps: preview.clamps, summary: preview.claudeSummary, to: &project)
    }

    /// Apply validated ops after re-checking the structural fingerprint.
    @discardableResult
    public static func commit(ops: [TypedOp], expectedFingerprint: String,
                              clamps: [String] = [], summary: String? = nil,
                              to project: inout Project) -> Outcome {
        let live = project.structuralFingerprint
        if live != expectedFingerprint {
            return Outcome(status: .rejected, summary: summary, opCount: 0, clamps: [],
                           errors: [PatchError(opIndex: nil,
                                               "Your project changed since you copied this request. Copy a fresh one.")],
                           parseMessage: nil)
        }
        let cmd = PatchCommand(name: "Apply Claude patch", ops: ops)
        do {
            // Apply to a local copy so a mid-apply throw never leaves the caller's project half-mutated.
            var working = project
            try cmd.apply(to: &working)
            project = working
            return Outcome(status: .applied, summary: summary, opCount: ops.count,
                           clamps: clamps, errors: [], parseMessage: nil)
        } catch let e as PatchError {
            return Outcome(status: .rejected, summary: summary, opCount: 0, clamps: [],
                           errors: [e], parseMessage: nil)
        } catch {
            return Outcome(status: .rejected, summary: summary, opCount: 0, clamps: [],
                           errors: [PatchError(opIndex: nil, error.localizedDescription)], parseMessage: nil)
        }
    }

    /// Thin wrapper: preview then immediately commit. Used by tests and any non-UI caller.
    /// The UI path must call `preview` and show the rendered lines before `commit`.
    @discardableResult
    public static func apply(reply: String, to project: inout Project) -> Outcome {
        switch preview(reply: reply, project: project) {
        case .failure(let outcome):
            return outcome
        case .success(let prep):
            return commit(prep, to: &project)
        }
    }

    /// Build the request to copy into Claude.
    public static func buildRequest(project: Project, userPrompt: String) -> String {
        RequestBuilder.buildJSON(project: project, userPrompt: userPrompt)
    }
}
