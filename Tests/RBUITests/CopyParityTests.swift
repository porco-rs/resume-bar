import Foundation
import Testing
@testable import RBUI

private func copyRows(_ text: String) -> [[String]] {
    let chars = Array(text)
    var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" { cell.append("\""); i += 1 }
            else if c == "\"" { quoted = false }
            else { cell.append(c) }
        } else if c == "\"" { quoted = true }
        else if c == "," { row.append(cell); cell = "" }
        else if c == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
        else if c != "\r" { cell.append(c) }
        i += 1
    }
    if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
    return rows
}

private func placeholderNames(_ text: String) -> Set<String> {
    let regex = try! NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
    return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    })
}

private let identicalEnglishCopy: Set<String> = [
    "m01.title", "m01.mode.resume", "m01.legend.tool", "by.claude", "by.codex",
    "m01.row.status", "m01.row.sessions", "m01.detail.sessions", "m01.duehint.one",
    "undo.deadline", "undo.status", "m01.hint.deadline", "m01.hint.sessions",
    "m01.hint.new_codex", "m01.hint.new_claude", "m01.hint.ok", "m00.perm.ae.title",
    "m00.line.terminal", "m02.terminal", "m02.ai.hint", "m02.ai.clients",
    "time.short.min", "time.short.hour", "a11y.popover", "a11y.strang", "a11y.session",
    "a11y.due", "menubar.a11y", "m01.start.codex", "m01.start.claude",
    "trainer.weitermachen.way", "m01.strip.ok", "trainer.input.text"
]

@Test func copyCatalogsHaveParity() throws {
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("resources")
    func load(_ name: String, into table: inout [String: String], override: Bool = false) throws {
        let rows = copyRows(try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8))
        let header = try #require(rows.first)
        let key = try #require(header.firstIndex(of: "key")), text = try #require(header.firstIndex(of: "text"))
        for row in rows.dropFirst() where row.count > max(key, text) && !row[key].isEmpty {
            if override || table[row[key]] == nil { table[row[key]] = row[text] }
        }
    }
    var de: [String: String] = [:], en: [String: String] = [:]
    try load("copy.csv", into: &de)
    try load("copy-supplement.csv", into: &de)
    try load("copy-app.csv", into: &de, override: true)
    try load("copy.en.csv", into: &en)
    #expect(Set(de.keys) == Set(en.keys))
    for (key, value) in de {
        #expect(placeholderNames(value) == placeholderNames(en[key] ?? ""), "Placeholder mismatch: \(key)")
        if let translation = en[key] {
            #expect(translation.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß")) == nil, "German character: \(key)")
            #expect(value != translation || identicalEnglishCopy.contains(key), "Untranslated: \(key)")
        }
    }
    for name in ["copy.csv", "copy-supplement.csv", "copy-app.csv"] {
        let rows = copyRows(try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8))
        let header = try #require(rows.first)
        guard let keyIndex = header.firstIndex(of: "key"), let maxIndex = header.firstIndex(of: "max") else { continue }
        for row in rows.dropFirst() where row.count > max(keyIndex, maxIndex) {
            guard let limit = Int(row[maxIndex]), let translation = en[row[keyIndex]] else { continue }
            #expect(translation.count <= limit, "English text exceeds max for \(row[keyIndex]): \(translation.count) > \(limit)")
        }
    }
    #expect(CopyTable.de == de.filter { !$0.key.hasPrefix("rb.") })
    #expect(CopyTable.en == en.filter { !$0.key.hasPrefix("rb.") })
    #expect(!CopyTable.de.keys.contains { $0.hasPrefix("rb.") })
    #expect(t("m01.title") == de["m01.title"])
    #expect(CopyTable.active == CopyTable.de)
}
