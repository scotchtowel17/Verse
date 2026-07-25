import Foundation

/// Lenient locator + normalizer for Claude's reply (Build Contract §E.5).
///
/// Claude's reply is free-form prose that *contains* a `verse-patch` JSON object. The parser:
///  1. strips a UTF-8 BOM and normalizes smart quotes,
///  2. locates the JSON — a fenced ```json block first, else the first balanced `{ … }`
///     that contains `"versePatch"`, tolerating arbitrary surrounding prose,
///  3. strips `// …` line comments and trailing commas,
///  4. parses with a strict JSON decoder.
/// It never applies a partial/ambiguous patch: any failure surfaces a plain-language error.
public enum PatchParser {

    public struct ParsedPatch {
        public let schema: String?
        public let version: Int?
        public let summary: String?
        public let fingerprint: String?
        public let ops: [[String: Any]]
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case noJSONFound
        case notValidJSON(String)
        case missingVersePatch
        case opsNotArray
        public var errorDescription: String? {
            switch self {
            case .noJSONFound:
                return "Couldn’t find a code block in Claude’s reply — make sure you copied the whole ```json block."
            case .notValidJSON(let detail):
                return "Couldn’t read Claude’s reply as JSON (\(detail)). Try copying the whole code block again."
            case .missingVersePatch:
                return "That doesn’t look like a Verse patch (no “versePatch” found)."
            case .opsNotArray:
                return "The patch’s “ops” must be a list."
            }
        }
    }

    public static func parse(_ raw: String) throws -> ParsedPatch {
        let pre = normalizeQuotesAndBOM(raw)
        guard let block = locateJSONObject(in: pre) else { throw ParseError.noJSONFound }
        let cleaned = stripTrailingCommas(stripLineComments(block))

        guard let data = cleaned.data(using: .utf8) else { throw ParseError.notValidJSON("encoding") }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ParseError.notValidJSON(error.localizedDescription) }

        guard let top = obj as? [String: Any] else { throw ParseError.notValidJSON("not an object") }
        guard let patch = top["versePatch"] as? [String: Any] else { throw ParseError.missingVersePatch }
        guard let opsAny = patch["ops"] else { throw ParseError.opsNotArray }
        guard let ops = opsAny as? [[String: Any]] else { throw ParseError.opsNotArray }

        return ParsedPatch(
            schema: patch["schema"] as? String,
            version: (patch["version"] as? Int) ?? (patch["version"] as? NSNumber)?.intValue,
            summary: patch["summary"] as? String,
            fingerprint: patch["fingerprint"] as? String,
            ops: ops)
    }

    // MARK: - Normalization steps

    static func normalizeQuotesAndBOM(_ s: String) -> String {
        var out = s
        if out.first == "\u{FEFF}" { out.removeFirst() }
        out = out.replacingOccurrences(of: "\u{FEFF}", with: "")
        let map: [Character: Character] = [
            "\u{201C}": "\"", "\u{201D}": "\"",   // “ ”
            "\u{201E}": "\"", "\u{201F}": "\"",
            "\u{2018}": "'", "\u{2019}": "'",     // ‘ ’
            "\u{2032}": "'", "\u{2033}": "\""
        ]
        return String(out.map { map[$0] ?? $0 })
    }

    /// Locate the JSON object: prefer a fenced code block; else the first balanced `{ … }`
    /// that contains `"versePatch"`.
    static func locateJSONObject(in s: String) -> String? {
        if let fenced = fencedBlock(in: s),
           let obj = firstBalancedObject(in: fenced, mustContain: "versePatch") ?? firstBalancedObject(in: fenced, mustContain: nil) {
            return obj
        }
        return firstBalancedObject(in: s, mustContain: "versePatch")
    }

    private static func fencedBlock(in s: String) -> String? {
        // ```json … ``` or ``` … ```
        guard let open = s.range(of: "```") else { return nil }
        var afterOpen = s[open.upperBound...]
        // Skip an optional language tag line (e.g. "json").
        if let nl = afterOpen.firstIndex(of: "\n") {
            let firstLine = afterOpen[afterOpen.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if firstLine.count <= 8 && !firstLine.contains("{") {
                afterOpen = afterOpen[afterOpen.index(after: nl)...]
            }
        }
        guard let close = afterOpen.range(of: "```") else { return String(afterOpen) }
        return String(afterOpen[afterOpen.startIndex..<close.lowerBound])
    }

    /// Scan for the first balanced top-level `{ … }` (ignoring braces inside strings).
    static func firstBalancedObject(in s: String, mustContain needle: String?) -> String? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                if let end = matchBrace(chars, from: i) {
                    let candidate = String(chars[i...end])
                    if needle == nil || candidate.contains(needle!) { return candidate }
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return nil
    }

    private static func matchBrace(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return i } }
            }
            i += 1
        }
        return nil
    }

    static func stripLineComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            stripCommentRespectingStrings(String(line))
        }.joined(separator: "\n")
    }

    private static func stripCommentRespectingStrings(_ line: String) -> String {
        var inString = false, escaped = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "/" && i + 1 < chars.count && chars[i+1] == "/" {
                    return String(chars[0..<i])
                }
            }
            i += 1
        }
        return line
    }

    /// Remove commas that immediately precede a closing `}` or `]` (allowing whitespace).
    static func stripTrailingCommas(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var inString = false, escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; result.append(c); i += 1; continue }
            if c == "," {
                // Look ahead past whitespace for } or ]
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1   // drop the comma
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
