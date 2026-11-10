import Foundation
import Testing
import RBContract
import RBStore
import RBUI
@testable import RBEngine

private let emptyNow = Date(timeIntervalSince1970: 2_000_000)
private let runningLive = Live(running: true, pid: 42, tty: nil, terminalApp: nil, windowIndex: nil)

private func emptyIndexed(_ id: String, title: String = "", activity: TimeInterval = 0) -> IndexedSession {
    IndexedSession(id: id, tool: .codex, nativeId: id, projectId: nil, cwd: "/synthetic",
                   transcriptPath: "/synthetic/\(id)", startedAt: emptyNow,
                   lastActivityAt: emptyNow.addingTimeInterval(activity), tokens: nil,
                   firstPrompt: "", threadName: nil, suggestedTopic: title, resumable: true)
}

private func emptyTestStore() -> SQLiteStore {
    SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
}

private func emptyTestEntry(title: String? = nil, deadline: String? = nil) -> Entry {
    Entry(id: "empty-entry", projectId: nil, title: title, status: .offen, deadline: deadline,
          createdBy: .user, createdAt: emptyNow, updatedAt: emptyNow)
}

private func emptyTestSnapshot(_ store: SQLiteStore, sessions: [IndexedSession], running: [String: Live] = [:], ended: [String] = []) async throws -> Snapshot {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    return try await SnapshotBuilder.build(index: IndexResult(projects: [], sessions: sessions, skippedFiles: 0), store: store,
        live: LiveState(running: running, ended: [], resumeCounts: [:]), settings: fixture.snapshot.settings,
        context: nil, windows: fixture.snapshot.windows, ended: ended, permissions: fixture.snapshot.permissions, now: emptyNow)
}

@Test func emptySessionNotRunningIsHidden() async throws {
    let store = emptyTestStore()
    let session = emptyIndexed("empty")
    let first = try await emptyTestSnapshot(store, sessions: [session])
    #expect(first.session(session.id) == nil)
    let links = try await store.loadLinks()
    let entryID = try #require(links[session.id])
    #expect(try await store.loadEntries().contains { $0.id == entryID })
    let titled = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty", title: "A title")])
    #expect(titled.session(session.id)?.entryId == entryID)
    let running = try await emptyTestSnapshot(store, sessions: [session], running: [session.id: runningLive])
    #expect(running.session(session.id)?.entryId == entryID)
    #expect(try await store.loadLinks() == links)
}

@Test func emptySessionRunningStays() async throws {
    let store = emptyTestStore()
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("running")], running: ["running": runningLive])
    let session = try #require(result.session("running"))
    #expect(session.live.running && result.entry(session.entryId) != nil)
}

@Test func emptySessionWithOwnTitleStays() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry(title: "User title")
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty"], to: entry.id, undoLabel: nil)
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty")])
    #expect(result.session("empty")?.entryId == entry.id)
    #expect(result.entry(entry.id) == entry)
}

@Test func emptySessionLeavesEntryHidden() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry(title: "")
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty"], to: entry.id, undoLabel: nil)
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty")])
    #expect(result.entry(entry.id) == nil && result.sessions.isEmpty)
    #expect(try await store.loadEntries().contains(entry))
    #expect(try await store.loadLinks()["empty"] == entry.id)
}

@Test func emptySessionSiblingGivesTitle() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry()
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty", "named"], to: entry.id, undoLabel: nil)
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty", activity: 10), emptyIndexed("named", title: "Sibling")])
    let visible = try #require(result.entry(entry.id))
    #expect(result.session("empty") == nil && result.session("named") != nil)
    #expect(Logic.titleOf(result, visible) == "Sibling")
}

@Test func justEndedSkipsEmptySession() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry()
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty", "named"], to: entry.id, undoLabel: nil)
    let sessions = [emptyIndexed("empty", activity: 10), emptyIndexed("named", title: "Sibling")]
    let result = try await emptyTestSnapshot(store, sessions: sessions, ended: ["empty"])
    #expect(result.entry(entry.id) != nil && result.justEnded.isEmpty)
    let namedEnded = try await emptyTestSnapshot(store, sessions: sessions, ended: ["named"])
    #expect(namedEnded.justEnded == [entry.id])
}

@Test func emptySessionWithDeadlineKeepsEntry() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry(deadline: "2026-12-01")
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty"], to: entry.id, undoLabel: nil)
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty")])
    #expect(result.entry(entry.id) == entry && result.session("empty") == nil)
}

@Test func emptySessionWithPendingChangeKeepsEntry() async throws {
    let store = emptyTestStore()
    let entry = emptyTestEntry()
    let change = Change(id: "change", kind: .add, entryId: entry.id, by: .claude, at: emptyNow)
    try await store.save(entry, change: change, undoLabel: nil)
    try await store.link(["empty"], to: entry.id, undoLabel: nil)
    let result = try await emptyTestSnapshot(store, sessions: [emptyIndexed("empty")])
    #expect(result.entry(entry.id) == entry && result.session("empty") == nil && result.changes == [change])
}

private struct EmptySessionIndex: SessionIndexing {
    let result: IndexResult
    func scan(_ settings: Settings) async throws -> IndexResult { result }
    func updates(_ settings: Settings) -> AsyncStream<IndexResult> { AsyncStream { $0.finish() } }
}

@MainActor @Test func rbListHidesEmptySession() async throws {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let store = emptyTestStore()
    let entry = emptyTestEntry()
    try await store.save(entry, undoLabel: nil)
    try await store.link(["empty"], to: entry.id, undoLabel: nil)
    var services = fixture.services
    services.store = store
    services.index = EmptySessionIndex(result: IndexResult(projects: [], sessions: [emptyIndexed("empty")], skippedFiles: 0))
    let engine = Engine(services: services, clock: { emptyNow })
    await engine.start()
    #expect(engine.snapshot.session("empty") == nil)
    guard case .entries(let lines) = await engine.handle(.list(allProjects: true, project: nil), from: .init(caller: .person, cwd: "/synthetic")) else {
        Issue.record("no list"); return
    }
    #expect(!lines.contains { $0.id == entry.id })
    #expect(try await store.loadEntries().contains(entry))
}
