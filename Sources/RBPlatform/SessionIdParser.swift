import Foundation
import RBContract

public enum SessionIdParser {
    public static func parse(_ text: String, commands: ToolStrings, known: (String) -> Bool) -> (Tool, String)? {
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        func executable(_ command: String) -> String? {
            command.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        func names(_ standard: String, _ command: String) -> String {
            Set([standard, executable(command)].compactMap { $0 }).map {
                NSRegularExpression.escapedPattern(for: $0)
            }.sorted().joined(separator: "|")
        }
        let forms: [(Tool, String)] = [
            (.codex, "(?<![A-Za-z0-9_/-])(?:\(names("codex", commands.codex)))\\s+(?:resume|--resume|-r)\\s+(\(uuid))"),
            (.claude, "(?<![A-Za-z0-9_/-])(?:\(names("claude", commands.claude)))\\s+(?:resume|--resume|-r)\\s+(\(uuid))")
        ]
        for (tool, pattern) in forms {
            if let match = first(pattern, text), let range = Range(match.range(at: 1), in: text) {
                return (tool, String(text[range]))
            }
        }
        let regex = try! NSRegularExpression(pattern: uuid, options: .caseInsensitive)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let id = String(text[range])
            if known(Tool.codex.idPrefix + id) { return (.codex, id) }
            if known(Tool.claude.idPrefix + id) { return (.claude, id) }
        }
        return nil
    }
    private static func first(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
