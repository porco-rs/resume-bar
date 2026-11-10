import Foundation
import Testing
import RBContract
import RBUI
@testable import RBEngine

private let tty = "ttys999"
private let folderContext = Context(projectId: nil, source: .ghostty, cwd: "/projects/a/sub", windowIndex: nil, tty: tty)

@MainActor
private func contextSnapshot() async throws -> Snapshot {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let engine = Engine(services: fx.services, settings: fx.snapshot.settings)
    await engine.start()
    var snapshot = engine.snapshot
    snapshot.projects = [
        Project(id: "a", name: "A", rootPath: "/projects/a", lastActivityAt: snapshot.now),
        Project(id: "b", name: "B", rootPath: "/projects/b", lastActivityAt: snapshot.now),
    ]
    snapshot.sessions = [try #require(snapshot.sessions.first)]
    snapshot.sessions[0].projectId = "b"
    snapshot.sessions[0].live = Live(running: true, pid: 1, tty: tty, terminalApp: .ghostty, windowIndex: nil)
    return snapshot
}

@MainActor
@Test func contextPrefersSessionOnTTY() async throws {
    let snapshot = try await contextSnapshot()
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "b")
}

@MainActor
@Test func contextFallsBackToFolderWithoutSession() async throws {
    var snapshot = try await contextSnapshot()
    snapshot.sessions[0].live.running = false
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "a")
    snapshot.sessions[0].live.running = true
    snapshot.sessions[0].live.tty = "ttys998"
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "a")
    snapshot.projects.append(Project(id: "nested", name: "Nested", rootPath: "/projects/a/sub", lastActivityAt: snapshot.now))
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "nested")
    var outside = folderContext
    outside.cwd = "/projects/another"
    outside.projectId = "a"
    #expect(ContextProject.resolve(outside, in: snapshot)?.projectId == nil)
}

@MainActor
@Test func contextFallsBackToFolderOnMixedTTY() async throws {
    var snapshot = try await contextSnapshot()
    var second = snapshot.sessions[0]
    second.projectId = "a"
    snapshot.sessions.append(second)
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "a")
    second.projectId = "b"
    snapshot.sessions[1] = second
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "b")
}

@MainActor
@Test func contextFallsBackToFolderForHomeSession() async throws {
    var snapshot = try await contextSnapshot()
    snapshot.sessions[0].projectId = nil
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "a")
    var second = snapshot.sessions[0]
    second.projectId = "b"
    snapshot.sessions.append(second)
    #expect(ContextProject.resolve(folderContext, in: snapshot)?.projectId == "a")
}

private struct ContextIndex: SessionIndexing {
    let result: IndexResult
    func scan(_ settings: Settings) async throws -> IndexResult { result }
    func updates(_ settings: Settings) -> AsyncStream<IndexResult> { AsyncStream { $0.finish() } }
}

private struct ContextLive: LiveMonitoring {
    let stream: AsyncStream<LiveState>
    func current() async -> LiveState { LiveState(running: [:], ended: [], resumeCounts: [:]) }
    func updates(interval: Duration) -> AsyncStream<LiveState> { stream }
}

@MainActor
@Test func contextFollowsLiveAfterProbe() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    var services = fx.services
    var index = try await services.index.scan(.defaults)
    let id = try #require(index.sessions.first?.id)
    index.sessions[0].projectId = "b"
    index.projects = [
        Project(id: "a", name: "A", rootPath: "/projects/a", lastActivityAt: fx.snapshot.now),
        Project(id: "b", name: "B", rootPath: "/projects/b", lastActivityAt: fx.snapshot.now),
    ]
    let (stream, continuation) = AsyncStream<LiveState>.makeStream()
    defer { continuation.finish() }
    services.index = ContextIndex(result: index)
    services.live = ContextLive(stream: stream)
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    await engine.start()
    _ = engine.popoverWillOpen(context: folderContext, mode: .ziel)
    #expect(engine.snapshot.context?.projectId == "a")
    let live = Live(running: true, pid: 1, tty: tty, terminalApp: .ghostty, windowIndex: nil)
    continuation.yield(LiveState(running: [id: live], ended: [], resumeCounts: [:]))
    for _ in 0..<100 where engine.snapshot.context?.projectId != "b" {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(engine.snapshot.context?.projectId == "b")
    #expect(engine.snapshot.context?.projectId == "b")
    var supplied = folderContext
    supplied.projectId = "a"
    engine.contextChanged(supplied)
    #expect(engine.snapshot.context?.projectId == "b")
    _ = engine.popoverWillOpen(context: supplied, mode: .ziel)
    #expect(engine.snapshot.context?.projectId == "b")
    continuation.yield(LiveState(running: [:], ended: [], resumeCounts: [:]))
    for _ in 0..<100 where engine.snapshot.context?.projectId != "a" {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(engine.snapshot.context?.projectId == "a")
}
