// Oracle from the design prototype: Tests/RBUITests/Expected/<screen>__<state>.json, extracted by
// tools/expected.swift (WKWebView, live mode). Call `regionMismatches` to compare results.
//
// The prototype fragments are DOM-serialized, the Swift templates are source strings, so both sides
// are canonicalized (entities decoded) before comparing. Known, intended differences of curtain:
//  - The edit input renders `editInitial` (value at edit start), the prototype `editText`.

import Foundation
import RBContract
@testable import RBUI

enum Expected {
    static let dir = FixtureHarness.designRoot.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/RBUITests/Expected")

    static func load(_ key: String) throws -> [String: String] {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let url = dir.appendingPathComponent("\(parts[0])__\(parts[1]).json")
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    static func canonical(_ html: String) -> String {
        html.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            // Intended curtain difference: the edit input renders editInitial, the prototype editText.
            .replacingOccurrences(of: #"<input class="e" value="[^"]*""#, with: #"<input class="e" value="…""#,
                                  options: .regularExpression)
    }

    /// Compares the Swift regions of a fixture state with the prototype. Returns mismatching region
    /// names with both canonical strings (empty = equal).
    static func regionMismatches(_ key: String) throws -> [(region: String, swift: String, prototype: String)] {
        let (s, snap) = try FixtureHarness.load(key)
        let r = Renderer.render(s, snap)
        let exp = try load(key)
        var pairs: [(String, String, String)] = []
        func fill(_ html: String) -> String {
            var out = html
            for (name, inner) in r.regions where out.contains("data-region=\"\(name)\"></") {
                out = out.replacingOccurrences(of: "data-region=\"\(name)\"></", with: "data-region=\"\(name)\">\(inner)</")
            }
            return stripRegionWrappers(out)
        }
        if r.screen == .m01 {
            for name in ["chips", "mirror", "key", "legend", "body", "footer"] {
                pairs.append((name, fill(r.region(name) ?? ""), exp[name] ?? ""))
            }
        } else {
            let mine = r.screen == .m01s1 ? fill(r.region("panel") ?? "") : fill(r.region("page") ?? "")
            pairs.append(("inner", mine, exp["inner"] ?? ""))
        }
        return pairs.map { ($0.0, canonical($0.1), canonical($0.2)) }.filter { $0.1 != $0.2 }
    }

    /// Child regions (`bmirror`, `pmirror`) are the prototype's `.mirror` span itself, carrying an
    /// extra `data-region` attribute; that attribute is the only difference and is removed here.
    static func stripRegionWrappers(_ html: String) -> String {
        html.replacingOccurrences(of: " data-region=\"bmirror\"", with: "")
            .replacingOccurrences(of: " data-region=\"pmirror\"", with: "")
            .replacingOccurrences(of: #"(?s)<span class="region" data-region="toast">(.*?)</span>"#, with: "$1", options: .regularExpression)
    }
}
