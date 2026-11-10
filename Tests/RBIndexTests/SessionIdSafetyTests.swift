import Foundation
import RBContract
import Testing
@testable import RBIndex

@Test func unsafeSessionIDsAreIgnoredByBothSources() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/resume_bar-OS-SEC-ID-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = root.appendingPathComponent("claude/project")
    let codex = root.appendingPathComponent("codex/sessions")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let bad = ["a;touch x", "a$(touch x)", "a`touch x`", "a\nb", "a'b", "-option"]
    let uuid = "01a19000-0000-7000-8000-000000000001"
    let codexID = "codex:normal_1"
    let stamp = "2026-11-01T10:00:00.000Z"
    func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n"
    }
    for (n, id) in (bad + [uuid]).enumerated() {
        let filename = String(format: "00000000-0000-4000-8000-%012d.jsonl", n)
        let text = try json(["entrypoint": "cli"]) + json(["cwd": root.path, "sessionId": id, "timestamp": stamp])
        try Data(text.utf8).write(to: claude.appendingPathComponent(filename))
    }
    for (n, id) in (bad + [codexID]).enumerated() {
        let text = try json(["type": "session_meta", "timestamp": stamp,
                             "payload": ["source": "cli", "id": id, "cwd": root.path]])
        try Data(text.utf8).write(to: codex.appendingPathComponent("rollout-\(n).jsonl"))
    }
    let index = SessionIndex(claudeRoot: claude.deletingLastPathComponent(), codexRoot: codex,
                             threadIndex: root.appendingPathComponent("names.jsonl"))
    let result = try await index.scan(.defaults)
    #expect(Set(result.sessions.map(\.nativeId)) == Set([uuid, codexID]))
}

@Test func sessionIDGrammarBoundaries() {
    for id in ["a", "A0._:-z", String(repeating: "a", count: 128)] { #expect(SessionID.isSafe(id)) }
    for id in ["", "-a", ".a", "a b", "a\n", "é", "a\0b", String(repeating: "a", count: 129)] {
        #expect(!SessionID.isSafe(id))
    }
}
