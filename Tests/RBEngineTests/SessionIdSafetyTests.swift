import Foundation
import RBContract
import Testing
@testable import RBEngine

@Test func hostileSessionIDsAreNeverInserted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-session-id-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("marker").path
    let output = root.appendingPathComponent("argument").path
    let ids = ["a; touch \(marker)", "a$(touch \(marker))", "a`touch \(marker)`",
               "a\ntouch \(marker)", "a'; touch \(marker); '", "-option"]
    let templates = ["printf '%s' {id} > '\(output)'", "printf '%s' '{id}' > '\(output)'", "printf '%s' \"{id}\" > '\(output)'"]
    var settings = Settings.defaults
    let now = Date()
    var session = Session(id: "cx_test", tool: .codex, nativeId: "", entryId: "e", projectId: nil,
                          cwd: root.path, transcriptPath: "", startedAt: now, lastActivityAt: now,
                          tokens: nil, firstPrompt: "", threadName: nil, suggestedTitle: "", resumable: true,
                          resumeCount: 0, live: .notRunning, createdAt: now, updatedAt: now)
    for template in templates {
        settings.commands.codex = template
        for id in ids {
            session.nativeId = id
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", SnapshotBuilder.command(for: session, settings: settings)]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(!FileManager.default.fileExists(atPath: marker))
            #expect(try String(contentsOfFile: output, encoding: .utf8) == "invalid-session-id")
        }
    }
    session.nativeId = "01a19000-0000-7000-8000-000000000001"
    #expect(SnapshotBuilder.command(for: session, settings: .defaults) == "codex resume \(session.nativeId)")
    session.tool = .claude
    #expect(SnapshotBuilder.command(for: session, settings: .defaults) == "claude --resume \(session.nativeId)")
}
