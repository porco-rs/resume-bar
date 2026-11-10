import Foundation
import Testing
@testable import RBUI

@Test func contentPolicyAllowsOnlyLocalScriptsAndStyles() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let html = try String(contentsOf: root.appendingPathComponent("ui/index.html"), encoding: .utf8)
    let meta = try NSRegularExpression(
        pattern: #"<meta\b(?=[^>]*\bhttp-equiv\s*=\s*["']Content-Security-Policy["'])[^>]*\bcontent\s*=\s*"([^"]*)"[^>]*>"#,
        options: [.caseInsensitive]
    )
    let matches = meta.matches(in: html, range: NSRange(html.startIndex..., in: html))
    #expect(matches.count == 1)
    let match = try #require(matches.first)
    let range = try #require(Range(match.range(at: 1), in: html))
    let policy = String(html[range])
    #expect(!policy.lowercased().contains("'unsafe-eval'"))
    #expect(!policy.lowercased().contains("'unsafe-inline'"))

    let directives = policy.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        .filter { !$0.isEmpty }
    #expect(directives.count == 5)
    for (name, sources) in [
        ("default-src", ["'none'"]), ("script-src", ["'self'"]),
        ("style-src", ["'self'"]), ("base-uri", ["'none'"]), ("form-action", ["'none'"])
    ] {
        let matching = directives.filter { $0.first == name }
        #expect(matching.count == 1, "\(name)")
        #expect(matching.first.map { Array($0.dropFirst()) } == sources, "\(name)")
    }
}

@Test func renderedFixturesContainNoInlineResources() throws {
    let forbidden = try NSRegularExpression(
        pattern: #"(?i)<(?:style|script|img)\b|\sstyle\s*="#
    )
    let entries = try FixtureHarness.entries()
    #expect(!entries.isEmpty)
    for entry in entries {
        let (state, snapshot) = try FixtureHarness.load(entry.key)
        let rendered = Renderer.render(state, snapshot)
        for html in [rendered.fullHTML, rendered.skeleton] + rendered.regions.map(\.1) {
            #expect(forbidden.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) == nil, "\(entry.key)")
        }
    }
}
