import CoreServices
import Foundation
import RBContract
import Testing
@testable import RBIndex

private let stamp = "2026-11-01T10:00:00.000Z"
private let id1 = "01a19000-0000-7000-8000-000000000001"
private let id2 = "01a19000-0000-7000-8000-000000000002"
private let checkoutIsTemporary = isTemporaryFolder(URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL.path)

private struct Fixture {
    let root: URL
    var claude: URL { root.appendingPathComponent("claude") }
    var codex: URL { root.appendingPathComponent("codex/sessions") }
    var names: URL { root.appendingPathComponent("codex/session_index.jsonl") }
    var index: SessionIndex { SessionIndex(claudeRoot: claude, codexRoot: codex, threadIndex: names) }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/resume-bar-test-ZUORDNUNG-B-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex.appendingPathComponent("2026/11/01"), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    @discardableResult func cc(_ id: String = id1, entry: String = "cli", cwd: String? = nil, extra: String = "") throws -> URL {
        let url = claude.appendingPathComponent("project/\(id).jsonl")
        try write("{\"entrypoint\":\"\(entry)\"}\n{\"cwd\":\"\(cwd ?? root.path)\",\"sessionId\":\"\(id)\",\"timestamp\":\"\(stamp)\"}\n" + extra, to: url)
        return url
    }
    @discardableResult func cx(_ id: String = id1, source: String = "\"cli\"", cwd: String? = nil, extra: String = "") throws -> URL {
        let url = codex.appendingPathComponent("2026/11/01/rollout-\(id).jsonl")
        try write("{\"timestamp\":\"\(stamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\(source),\"cwd\":\"\(cwd ?? root.path)\"}}\n" + extra, to: url)
        return url
    }
}
private func result(_ f: Fixture) async throws -> IndexResult { try await f.index.scan(.defaults) }
private func testProject() throws -> URL {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("child"), withIntermediateDirectories: true)
    return project
}
private func rawZstdFrame(_ content: Data) -> Data {
    var frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    let size = UInt32(content.count)
    for shift in stride(from: 0, through: 24, by: 8) { frame.append(UInt8(truncatingIfNeeded: size >> shift)) }
    var offset = 0
    while offset < content.count {
        let count = min(128 * 1024, content.count - offset)
        let block = UInt32(count << 3) | (offset + count == content.count ? 1 : 0)
        for shift in stride(from: 0, through: 16, by: 8) { frame.append(UInt8(truncatingIfNeeded: block >> shift)) }
        frame.append(content[offset..<(offset + count)])
        offset += count
    }
    return frame
}

@Test func temporaryFolderBoundaries() {
    for path in ["/tmp/x", "/private/tmp/x", "/var/folders/x", "/private/var/folders/x"] {
        #expect(isTemporaryFolder(path))
    }
    for path in ["/tmpx", "/Users/a/tmp", "/private/var/db"] {
        #expect(!isTemporaryFolder(path))
    }
}

@Test func claudeFiltersInteractiveAndNames() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(); try f.cc(id2, entry: "sdk-cli")
    try f.write("{}", to: f.claude.appendingPathComponent("project/agent.jsonl"))
    let nested = f.claude.appendingPathComponent("project/nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try f.write("{}", to: nested.appendingPathComponent("\(id2).jsonl"))
    let r = try await result(f)
    #expect(r.sessions.map(\.id) == ["cc_" + id1])
}
@Test func codexFiltersExecAndObjectSources() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(); try f.cx(id2, source: "\"exec\"")
    try f.cx("01a19000-0000-7000-8000-000000000003", source: "{\"subagent\":{}}")
    #expect(try await result(f).sessions.map(\.id) == ["cx_" + id1])
}
@Test func compressedCodexIsRead() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let sample = samples.appendingPathComponent("codex-cli.jsonl.zst")
    try FileManager.default.copyItem(at: sample, to: f.codex.appendingPathComponent("rollout-sample.jsonl.zst"))
    let s = try #require(try await result(f).sessions.first)
    #expect(s.id == "cx_" + id1)
    #expect(s.tokens == 1234)
}
@Test func latestThreadNameAndClearing() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"First sentence. More.\"}}\n")
    try f.write("{\"id\":\"\(id1)\",\"thread_name\":\"Old\"}\n{\"id\":\"\(id1)\",\"thread_name\":\"New\"}\n", to: f.names)
    let index = f.index
    #expect(try await index.scan(.defaults).sessions.first?.suggestedTopic == "New")
    try f.write("{\"id\":\"\(id1)\",\"thread_name\":\"Old\"}\n{\"id\":\"\(id1)\",\"thread_name\":\"  \"}\n", to: f.names)
    let s = try #require(try await index.scan(.defaults).sessions.first)
    #expect(s.threadName == nil)
    #expect(s.suggestedTopic == "First sentence.")
}
@Test func projectGitRootAndClashes() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let a = f.root.appendingPathComponent("a/shared"), b = f.root.appendingPathComponent("b/shared")
    for dir in [a, b] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true) }
    try f.cc(cwd: a.appendingPathComponent("child").path); try f.cx(id2, cwd: b.path)
    let r = try await result(f)
    #expect(Set(r.projects.map(\.rootPath)) == Set([a.resolvingSymlinksInPath().path, b.resolvingSymlinksInPath().path]))
    #expect(Set(r.projects.map(\.id)).count == 2)
    #expect(r.projects.allSatisfy { $0.id.hasPrefix("prj_shared_") })
    #expect(Set(r.sessions.map(\.projectId)) == Set(r.projects.map(\.id)))
}
@Test func claudeLastTitleAndFirstTextBlock() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"  First. Next.  \"}]}}\n{\"type\":\"ai-title\",\"aiTitle\":\"Old\"}\n{\"type\":\"custom-title\",\"customTitle\":\"Final\"}\n")
    let s = try #require(try await result(f).sessions.first)
    #expect(s.firstPrompt == "First. Next.")
    #expect(s.suggestedTopic == "Final")
}
@Test func claudeFallbackAndPromptLimit() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"last-prompt\",\"lastPrompt\":\"\(String(repeating: "x", count: 220))\"}\n")
    let s = try #require(try await result(f).sessions.first)
    #expect(s.firstPrompt.count == 200)
    #expect(s.suggestedTopic.count == 60)
}
@Test func codexLastNonNullTokens() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":42}}}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n")
    #expect(try await result(f).sessions.first?.tokens == 42)
}
@Test func unreadableFileIsCounted() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let url = try f.cc()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    let r = try await result(f)
    #expect(r.skippedFiles == 1)
    #expect(r.sessions.isEmpty)
}
@Test func cacheRefreshesChangedAndDeletedFiles() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let url = try f.cc()
    let index = f.index
    #expect(try await index.scan(.defaults).sessions.count == 1)
    try f.cc(entry: "sdk-cli")
    #expect(try await index.scan(.defaults).sessions.isEmpty)
    try FileManager.default.removeItem(at: url)
    #expect(try await index.scan(.defaults).sessions.isEmpty)
}
@Test func updatesEmitAfterNewFile() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let index = f.index
    let stream = index.updates(.defaults)
    let task = Task { () -> Bool in
        for await value in stream { if !value.sessions.isEmpty { return true } }
        return false
    }
    try await Task.sleep(for: .seconds(1))
    try f.cc()
    let emitted = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await task.value }
        group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
        let first = await group.next() ?? false
        task.cancel(); group.cancelAll()
        return first
    }
    #expect(emitted)
}

@Test func updatesEmitThroughSymlinkedRoot() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let link = f.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
    let index = SessionIndex(claudeRoot: link.appendingPathComponent("claude"),
                             codexRoot: link.appendingPathComponent("codex/sessions"),
                             threadIndex: link.appendingPathComponent("codex/session_index.jsonl"))
    let stream = index.updates(.defaults)
    let task = Task { () -> Bool in
        for await value in stream { if !value.sessions.isEmpty { return true } }
        return false
    }
    try await Task.sleep(for: .seconds(1))
    try f.cc()
    let emitted = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await task.value }
        group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
        let first = await group.next() ?? false
        task.cancel(); group.cancelAll()
        return first
    }
    #expect(emitted)
}

@Test(.disabled(if: checkoutIsTemporary, "The index ignores temporary folders, and this checkout lies in one")) func movedSessionUsesRecentProjectAndCachedParse() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let start = f.root.appendingPathComponent("old")
    let project = try testProject(); defer { try? FileManager.default.removeItem(at: project) }
    let recent = project.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
    try f.cc(cwd: start.path, extra: "{\"cwd\":\"\(recent.path)\"}\n{\"cwd\":\"/private/tmp/temporary\"}\n")
    let index = f.index
    #expect(try await index.scan(.defaults).sessions.first?.cwd == start.path)
    try FileManager.default.removeItem(at: start)
    let result = try await index.scan(.defaults)
    #expect(result.sessions.first?.cwd == project.resolvingSymlinksInPath().path)
    #expect(result.projects.first?.rootPath == project.resolvingSymlinksInPath().path)
    let location = try #require(await index.whereSession(id1))
    #expect(location.startCwd == start.path && !location.startExists && location.resolvedCwd == result.sessions.first?.cwd)
}
@Test(.disabled(if: checkoutIsTemporary, "The index ignores temporary folders, and this checkout lies in one")) func temporaryTailAndCodexTurnContext() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let start = f.root.appendingPathComponent("old").path
    let project = try testProject(); defer { try? FileManager.default.removeItem(at: project) }
    let recent = project.appendingPathComponent("child")
    try f.cc(cwd: start, extra: "{\"cwd\":\"/tmp/transient\"}\n{\"cwd\":\"/var/folders/transient\"}\n")
    try f.cx(id2, cwd: start, extra: "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"\(recent.path)\"}}\n")
    let r = try await result(f)
    #expect(r.sessions.first(where: { $0.nativeId == id1 })?.cwd == start)
    #expect(r.sessions.first(where: { $0.nativeId == id2 })?.cwd == project.resolvingSymlinksInPath().path)
}

@Test(.disabled(if: checkoutIsTemporary, "The index ignores temporary folders, and this checkout lies in one")) func compressedCodexReadsRecentTailBeyondHead() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let project = try testProject(); defer { try? FileManager.default.removeItem(at: project) }
    let recent = project.appendingPathComponent("child").path
    let start = f.root.appendingPathComponent("missing").path
    let header = "{\"timestamp\":\"\(stamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id1)\",\"source\":\"cli\",\"cwd\":\"\(start)\"}}\n"
    let content = Data((header + String(repeating: "{}\n", count: 50000) + "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"\(recent)\"}}\n").utf8)
    try rawZstdFrame(content).write(to: f.codex.appendingPathComponent("rollout-tail.jsonl.zst"))
    #expect(try await result(f).sessions.first?.cwd == project.resolvingSymlinksInPath().path)
}

@Test(.disabled(if: checkoutIsTemporary, "The index ignores temporary folders, and this checkout lies in one")) func compressedTailIsLazyAndCachedByStamp() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let project = try testProject(); defer { try? FileManager.default.removeItem(at: project) }
    let start = f.root.appendingPathComponent("start")
    try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
    let header = "{\"timestamp\":\"\(stamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id1)\",\"source\":\"cli\",\"cwd\":\"\(start.path)\"}}\n"
    let tokens = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":42}}}}\n"
    let tail = "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"\(project.path)\"}}\n"
    let frame = rawZstdFrame(Data((header + tokens + String(repeating: "{}\n", count: 50000) + tail).utf8))
    let url = f.codex.appendingPathComponent("rollout-lazy.jsonl.zst")
    // A truncated tail still permits the head-only scan when the start exists.
    try frame.dropLast(3).write(to: url)
    let index = f.index
    let initial = try #require(try await index.scan(.defaults).sessions.first)
    #expect(initial.cwd == start.path && initial.tokens == 42)
    try frame.write(to: url)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    try FileManager.default.removeItem(at: start)
    #expect(try await index.scan(.defaults).sessions.first?.cwd == project.resolvingSymlinksInPath().path)
    // Same stamp and size must reuse the already decoded tail; a new stamp must refresh it.
    var corrupt = frame
    corrupt[corrupt.count - 1] = 0
    try corrupt.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    #expect(try await index.scan(.defaults).sessions.first?.cwd == project.resolvingSymlinksInPath().path)
    try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(5)], ofItemAtPath: url.path)
    #expect(try await index.scan(.defaults).sessions.first?.cwd == start.path)
}

@Test(.disabled(if: checkoutIsTemporary, "The index ignores temporary folders, and this checkout lies in one")) func missingStartVotesAcrossWorktreeAndMainCheckout() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let main = base.appendingPathComponent("main"), worktree = base.appendingPathComponent("worktree")
    let other = base.appendingPathComponent("other"), gitdir = main.appendingPathComponent(".git/worktrees/linked")
    for dir in [gitdir, worktree, other.appendingPathComponent(".git")] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try Data("gitdir: ../main/.git/worktrees/linked\n".utf8).write(to: worktree.appendingPathComponent(".git"))
    try Data("../..\n".utf8).write(to: gitdir.appendingPathComponent("commondir"))
    let missing = base.appendingPathComponent("removed").path
    let tail = [worktree.path, main.path, other.path].map { "{\"cwd\":\"\($0)\"}\n" }.joined()
    try f.cc(cwd: missing, extra: tail)
    let index = f.index
    #expect(try await index.scan(.defaults).sessions.first?.cwd == main.resolvingSymlinksInPath().path)
    // With equal counts the most recent project wins.
    try f.cc(cwd: missing, extra: [main.path, other.path].map { "{\"cwd\":\"\($0)\"}\n" }.joined())
    #expect(try await index.scan(.defaults).sessions.first?.cwd == other.resolvingSymlinksInPath().path)
    try f.cc(cwd: missing, extra: "{\"cwd\":\"\(missing)\"}\n")
    #expect(try await index.scan(.defaults).sessions.first?.cwd == missing)
    try f.cc(cwd: main.path, extra: tail)
    #expect(try await index.scan(.defaults).sessions.first?.cwd == main.path)
}

@Test func homeFolderSessionHasNoProject() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
    try f.cc(cwd: home)
    let r = try await result(f)
    #expect(r.sessions.count == 1)
    #expect(r.sessions.first?.projectId == nil)
    #expect(r.projects.isEmpty)
}

@Test func enumerateSkipsSymlinksAndSeesChanges() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let original = try f.cc()
    let linked = f.claude.appendingPathComponent("project/\(id2).jsonl")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
    let index = f.index
    #expect(try await index.scan(.defaults).sessions.map(\.id) == ["cc_" + id1])
    try f.cc(extra: "{\"type\":\"custom-title\",\"customTitle\":\"Changed\"}\n")
    let changed = try await index.scan(.defaults)
    #expect(changed.sessions.count == 1)
    #expect(changed.sessions.first?.suggestedTopic == "Changed")
}

@Test func eventFilterKeepsResultChanges() {
    let roots = EventPaths(Roots(claude: URL(fileURLWithPath: "/fixture/claude"), codex: URL(fileURLWithPath: "/fixture/codex/sessions"), index: URL(fileURLWithPath: "/fixture/codex/session_index.jsonl")))
    let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    let cases: [(String, FSEventStreamEventFlags)] = [
        ("/fixture/claude/project/\(id1).jsonl", file),
        ("/fixture/codex/sessions/2026/rollout-x.jsonl", file),
        ("/fixture/codex/sessions/rollout-x.jsonl.zst", file),
        ("/fixture/codex/session_index.jsonl", file),
        ("/fixture/claude/project", dir), ("/fixture/codex/sessions/2026/11", dir),
        ("/fixture", dir), ("/fixture/claude", dir), ("/fixture/codex/sessions", dir),
        ("/unrelated", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)),
        ("/unrelated", FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)),
        ("/unrelated", FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)),
        ("/unrelated", FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))
    ]
    for (path, flags) in cases { #expect(eventCanChangeResult(path: path, flags: flags, roots: roots), "\(path)") }
}

@Test func eventFilterDropsUnrelatedFiles() {
    let roots = EventPaths(Roots(claude: URL(fileURLWithPath: "/fixture/claude"), codex: URL(fileURLWithPath: "/fixture/codex/sessions"), index: URL(fileURLWithPath: "/fixture/codex/session_index.jsonl")))
    let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    let cases: [(String, FSEventStreamEventFlags)] = [
        ("/fixture/claude/project/\(id1)/subagents/x.jsonl", file),
        ("/fixture/claude/project/agent.jsonl", file), ("/fixture/claude/\(id1).jsonl", file),
        ("/fixture/claude/project/nested", dir), ("/fixture/codex/log/x", file),
        ("/fixture/codex/sessions/other.jsonl", file), ("/fixture/codex/sessions/rollout-x.json", file),
        ("/fixture/claude-other/project/\(id1).jsonl", file), ("/fixture/codex/session_index.jsonl.tmp", file)
    ]
    for (path, flags) in cases { #expect(!eventCanChangeResult(path: path, flags: flags, roots: roots), "\(path)") }
}

@Test func eventFilterFollowsSymlinkedRoot() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let link = f.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
    let roots = EventPaths(Roots(claude: link.appendingPathComponent("claude"),
                                 codex: link.appendingPathComponent("codex/sessions"),
                                 index: link.appendingPathComponent("codex/session_index.jsonl")))
    let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    for base in [f.root, link] {
        #expect(eventCanChangeResult(path: base.appendingPathComponent("claude/project/\(id1).jsonl").path, flags: file, roots: roots))
        #expect(!eventCanChangeResult(path: base.appendingPathComponent("claude/project/agent.jsonl").path, flags: file, roots: roots))
        #expect(eventCanChangeResult(path: base.appendingPathComponent("codex/sessions/2026/rollout-x.jsonl").path, flags: file, roots: roots))
        #expect(!eventCanChangeResult(path: base.appendingPathComponent("codex/sessions/2026/other.jsonl").path, flags: file, roots: roots))
        #expect(eventCanChangeResult(path: base.appendingPathComponent("codex/session_index.jsonl").path, flags: file, roots: roots))
        #expect(!eventCanChangeResult(path: base.appendingPathComponent("codex/session_index.jsonl.tmp").path, flags: file, roots: roots))
        #expect(eventCanChangeResult(path: base.appendingPathComponent("claude/project").path + "/", flags: dir, roots: roots))
    }
    let missing = EventPaths(Roots(claude: link.appendingPathComponent("missing/claude"),
                                   codex: link.appendingPathComponent("missing/codex"),
                                   index: link.appendingPathComponent("missing/index.jsonl")))
    #expect(eventCanChangeResult(path: f.root.appendingPathComponent("missing/claude/project/\(id1).jsonl").path, flags: file, roots: missing))
    #expect(eventCanChangeResult(path: f.root.appendingPathComponent("missing/index.jsonl").path, flags: file, roots: missing))
}

private actor HeldScans {
    var count = 0
    var releaseFirst: CheckedContinuation<Void, Never>?
    func scan() async {
        count += 1
        if count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
    }
    func release() { releaseFirst?.resume(); releaseFirst = nil }
}

@Test func scanGateRunsOnceForBurstAndNeverLosesLastChange() async throws {
    let scans = HeldScans()
    let gate = ScanGate(scanSpacing: .milliseconds(50)) { await scans.scan() }
    await gate.request()
    for _ in 0..<100 where await scans.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await scans.count == 1)
    for _ in 0..<100 { await gate.request() }
    await scans.release()
    for _ in 0..<100 where await scans.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await scans.count == 2)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await scans.count == 2)
    await gate.request()
    for _ in 0..<100 where await scans.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await scans.count == 3)
    await gate.stop()
}

@Test func titleStatsNeverContainContent() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let marker = "synthetic_private_marker_73421"
    let path = f.claude.appendingPathComponent(marker)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let transcript = path.appendingPathComponent("\(id1).jsonl")
    try f.write("{\"entrypoint\":\"cli\"}\n{\"cwd\":\"\(path.path)\",\"sessionId\":\"\(id1)\",\"timestamp\":\"\(stamp)\"}\n{\"type\":\"user\",\"message\":{\"content\":\"\(marker)\"}}\n{\"type\":\"custom-title\",\"customTitle\":\"\(marker)\"}\n", to: transcript)
    try f.cx(id2, extra: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(marker)\"}}\n")
    try f.write("{\"id\":\"\(id2)\",\"thread_name\":\"\(marker)\"}\n", to: f.names)
    let stats = await f.index.titleStats()
    #expect(stats.claude.sessions == 1 && stats.claude.titled == 1)
    #expect(stats.codex.sessions == 1 && stats.codex.titled == 1)
    #expect(stats.codex.promptFromEvent == 1 && stats.codex.promptFromResponseItem == 0)
    #expect(stats.plainText.contains("prompt_from_event 1") && stats.plainText.contains("prompt_from_response_item 0") && stats.plainText.contains("prompt_after_head 0"))
    #expect(!stats.plainText.contains(marker))
    #expect(!stats.plainText.contains(id1) && !stats.plainText.contains(id2))
    #expect(!stats.plainText.contains(f.root.path))
}

@Test func titleStatsCountsPromptBeyondHead() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let padding = "{\"type\":\"padding\",\"data\":\"" + String(repeating: "x", count: 200 * 1024) + "\"}\n"
    try f.cx(extra: padding + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"synthetic\"}}\n")
    let counts = await f.index.titleStats().codex
    #expect(counts.sessions == 1 && counts.neither == 0 && counts.promptAfterHead == 1 && counts.promptFromEvent == 1)
    #expect(counts.userPositionP50KB >= 200 && counts.userPositionMaxKB == counts.userPositionP50KB)
}

@Test func titleStatsCountsSessionWithoutUserEvent() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx()
    let counts = await f.index.titleStats().codex
    #expect(counts.sessions == 1 && counts.neither == 1 && counts.noUserEvent == 1)
}

@Test func titleStatsCountsWrapperPrompt() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":\"<wrapper>synthetic</wrapper>\"}}\n")
    let counts = await f.index.titleStats().claude
    #expect(counts.headPrompt == 0 && counts.neither == 1)
}

@Test func titleStatsHandlesCompressedEmptyAndIgnored() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let uncompressed = try f.cx(extra: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"  \"}}\n")
    let data = try Data(contentsOf: uncompressed)
    try rawZstdFrame(data).write(to: f.codex.appendingPathComponent("rollout-compressed.jsonl.zst"))
    try FileManager.default.removeItem(at: uncompressed)
    try f.cx(id2, source: "\"exec\"")
    let counts = await f.index.titleStats().codex
    #expect(counts.sessions == 1 && counts.neither == 1 && counts.emptyUserText == 1)
    #expect(counts.compressedNeither == 1 && counts.unreadable == 0)
}

@Test func titleStatsSeparatesDistanceBucketsAndPercentiles() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let message = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"synthetic\"}}\n"
    let padding: (Int) -> String = { bytes in "{\"data\":\"" + String(repeating: "x", count: bytes) + "\"}\n" }
    try f.cx(extra: padding(7 * 1024 * 1024) + message)
    try f.cx(id2, extra: padding(9 * 1024 * 1024) + message)
    let counts = await f.index.titleStats().codex
    #expect(counts.neither == 1 && counts.beyond1MBTo8MB == 0 && counts.beyond8MB == 1)
    #expect(counts.userPositionSamples == 2 && counts.userPositionP50KB == 7168)
    #expect(counts.userPositionP90KB == 9216 && counts.userPositionMaxKB == 9216)
    #expect(counts.firstLineSamples == 2 && counts.firstLineMaxKB == 0)
}

@Test func titleStatsCountsUnreadableCompressedCandidate() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.write("invalid compressed data", to: f.codex.appendingPathComponent("rollout-invalid.jsonl.zst"))
    let counts = await f.index.titleStats().codex
    #expect(counts.unreadable == 1 && counts.sessions == 0)
}

@Test func codexPromptFromResponseItem() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Synthetic request. Next.\"}]}}\n")
    let session = try #require(try await result(f).sessions.first)
    #expect(session.firstPrompt == "Synthetic request. Next.")
    #expect(session.suggestedTopic == "Synthetic request.")
    let counts = await f.index.titleStats().codex
    #expect(counts.promptFromResponseItem == 1 && counts.promptFromEvent == 0 && counts.neither == 0)
}

@Test func codexSkipsInjectedBlocks() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\" <environment>\"},{\"text\":\" # AGENTS.md instructions injected\"},{\"text\":\"Synthetic request\"}]}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Synthetic request")
}

@Test func codexPrefersUserMessageEvent() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"First response\"}]}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Event request\"}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Event request")
    let stats = await f.index.titleStats().codex
    #expect(stats.promptFromEvent == 1 && stats.promptFromResponseItem == 0)
}

@Test func claudeSkipsCommandWrapper() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":\" <wrapper>synthetic</wrapper>\"}}\n{\"type\":\"last-prompt\",\"lastPrompt\":\"<injected>\"}\n")
    let session = try #require(try await result(f).sessions.first)
    #expect(session.firstPrompt.isEmpty && session.suggestedTopic.isEmpty)
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<wrapper>\"},{\"type\":\"text\",\"text\":\"Synthetic request\"}]}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Synthetic request")
}

@Test func claudeUsesCommandArgsWhenOnlyWrappers() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":\"<wrapper>ignored</wrapper>\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"<command-name>/synthetic</command-name><command-args>  Synthetic argument  </command-args>\"}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Synthetic argument")
}

@Test func claudeUsesCommandNameWithoutArgs() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cc(extra: "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<command-name>/synthetic</command-name><command-args> </command-args>\"}]}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "/synthetic")
}

@Test func claudePrefersTypedTextOverCommandArgs() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let command = "{\"type\":\"user\",\"message\":{\"content\":\"<command-name>/synthetic</command-name><command-args>Argument</command-args>\"}}\n"
    try f.cc(extra: command + "{\"type\":\"last-prompt\",\"lastPrompt\":\"Fallback\"}\n{\"type\":\"user\",\"message\":{\"content\":\"Typed text\"}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Typed text")
    try f.cc(extra: command + "{\"type\":\"last-prompt\",\"lastPrompt\":\"Fallback\"}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Fallback")
}

@Test func titleStatsSplitsNothingFromInjected() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx()
    try f.cx(id2, extra: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"<environment>injected</environment>\"},{\"text\":\"# AGENTS.md instructions injected\"}]}}\n")
    try f.cx("01a19000-0000-7000-8000-000000000003", extra: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"<injected>\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\" \"}}\n")
    let stats = await f.index.titleStats()
    #expect(stats.codex.neither == 3 && stats.codex.noUserEvent == 1 && stats.codex.onlyInjected == 1)
    #expect(stats.plainText.contains("codex neither_no_user 1 neither_only_injected 1"))
}

@Test func codexPromptBeyond2MBIsFound() async throws {
    for compressed in [false, true] {
        let f = try Fixture(); defer { f.cleanup() }
        let padding = "{\"data\":\"" + String(repeating: "x", count: 3 * 1024 * 1024) + "\"}\n"
        let url = try f.cx(extra: padding + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Late request\"}}\n")
        if compressed {
            try rawZstdFrame(Data(contentsOf: url)).write(to: f.codex.appendingPathComponent("rollout-late.jsonl.zst"))
            try FileManager.default.removeItem(at: url)
        }
        #expect(try await result(f).sessions.first?.firstPrompt == "Late request")
    }
}

@Test func codexPromptBeyondHeadIsFound() async throws {
    for compressed in [false, true] {
        let f = try Fixture(); defer { f.cleanup() }
        let padding = "{\"data\":\"" + String(repeating: "x", count: 300 * 1024) + "\"}\n"
        let url = try f.cx(extra: padding + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"Late request\"}]}}\n")
        if compressed {
            try rawZstdFrame(Data(contentsOf: url)).write(to: f.codex.appendingPathComponent("rollout-late.jsonl.zst"))
            try FileManager.default.removeItem(at: url)
        }
        #expect(try await result(f).sessions.first?.firstPrompt == "Late request")
        let stats = await f.index.titleStats().codex
        #expect(stats.promptAfterHead == 1 && stats.promptFromResponseItem == 1 && stats.neither == 0)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func increment() { lock.withLock { reads += 1 } }
    var value: Int { lock.withLock { reads } }
}
@Test func codexReadsNoFurtherWithName() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.cx(extra: String(repeating: "{}\n", count: 100_000))
    try f.write("{\"id\":\"\(id1)\",\"thread_name\":\"Synthetic name\"}\n", to: f.names)
    let counter = ReadCounter()
    let index = SessionIndex(claudeRoot: f.claude, codexRoot: f.codex, threadIndex: f.names, onExtendedRead: { counter.increment() })
    #expect(try await index.scan(.defaults).sessions.first?.threadName == "Synthetic name")
    #expect(counter.value == 0)
    try f.write("", to: f.names)
    _ = try await index.scan(.defaults)
    #expect(counter.value == 1)
}

@Test func codexPromptBeyondLimitIsNotRead() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let padding = "{\"data\":\"" + String(repeating: "x", count: 8 * 1024 * 1024) + "\"}\n"
    try f.cx(extra: padding + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Late request\"}}\n")
    #expect(try await result(f).sessions.first?.firstPrompt.isEmpty == true)
    let counts = await f.index.titleStats().codex
    #expect(counts.neither == 1 && counts.promptAfterHead == 0)
}

@Test func claudeTailFallbackCountsAfterHead() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let padding = "{\"data\":\"" + String(repeating: "x", count: 200 * 1024) + "\"}\n"
    try f.cc(extra: padding + "{\"type\":\"last-prompt\",\"lastPrompt\":\"Synthetic fallback\"}\n")
    #expect(try await result(f).sessions.first?.firstPrompt == "Synthetic fallback")
    let stats = await f.index.titleStats().claude
    #expect(stats.promptAfterHead == 1 && stats.fallbackOnly == 1 && stats.neither == 0)
}
