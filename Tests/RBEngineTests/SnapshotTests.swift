import Foundation
import Testing
import RBContract
import RBStore
@testable import RBEngine

@Test func snapshotCreatesAndReusesStrands() async throws {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let services = fixture.services
    let index = try await services.index.scan(.defaults)
    let live = await services.live.current()
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: db)
    let source = fixture.snapshot
    func build() async throws -> Snapshot {
        try await SnapshotBuilder.build(index: index, store: store, live: live, settings: source.settings,
                                          context: source.context, windows: source.windows, ended: [],
                                          permissions: source.permissions, now: source.now)
    }
    let first = try await build()
    let second = try await build()
    #expect(first.sessions.count == index.sessions.count)
    #expect(first.entries.count == index.sessions.count)
    #expect(Set(first.sessions.map(\.entryId)).count == index.sessions.count)
    #expect(first.sessions.map(\.entryId) == second.sessions.map(\.entryId))
    #expect(second.entries.count == first.entries.count)
    let report = SnapshotBuilder.engineCheck(second, links: try await store.loadLinks(),
                                             counts: .init(counts: ["one": 136], historyImportVersion: 2))
    #expect(report.contains("sessions: \(index.sessions.count)"))
    #expect(report.contains("strands untitled: \(index.sessions.count)"))
    #expect(report.contains("tasks: 0"))
    #expect(report.contains("sessions without strand: 0"))
    #expect(report.contains("resume count total: 136"))
}

private func assignmentSession(_ id: String, _ folder: String, at: Date) -> IndexedSession {
    IndexedSession(id: id, tool: .codex, nativeId: id, projectId: nil, cwd: folder,
                   transcriptPath: "/synthetic/\(id)", startedAt: at, lastActivityAt: at,
                   tokens: nil, firstPrompt: "", threadName: nil, suggestedTopic: "", resumable: true)
}

@Test func hintsLinkAndRelinkOnlyAutomaticStrands() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: db)
    let task = Entry(id: "task", projectId: nil, title: "Task", status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
    let archived = Entry(id: "archived", projectId: nil, title: "Archived", status: .offen, createdBy: .user, createdAt: now, updatedAt: now, archivedAt: now)
    try await store.save(task, undoLabel: nil); try await store.save(archived, undoLabel: nil)
    let assignment = SessionAssignment()
    let sessions = ["direct", "late", "unknown", "archived"].map { assignmentSession($0, "/project", at: now) }
    let index = IndexResult(projects: [], sessions: sessions, skippedFiles: 0)
    let live = LiveState(running: [:], ended: [], resumeCounts: [:], entryHints: ["direct": "task", "unknown": "missing", "archived": "archived"])
    let first = try await assignment.assign(index: index, store: store, live: live, now: now)
    #expect(first["direct"] == "task")
    #expect(first["unknown"] != "task" && first["unknown"] != "archived")
    #expect(first["archived"] != "archived")
    let old = try #require(first["late"])
    var later = live; later.entryHints["late"] = "task"
    let second = try await assignment.assign(index: index, store: store, live: later, now: now)
    #expect(second["late"] == "task")
    #expect(try await store.loadEntries().allSatisfy { $0.id != old })
    #expect(try await store.undo() == nil)
}

@Test func fallbackMatchesFirstNewSessionInFolderWithinTenSeconds() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: db)
    let task = Entry(id: "task", projectId: nil, title: "Task", status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
    try await store.save(task, undoLabel: nil)
    let assignment = SessionAssignment()
    _ = await assignment.started(entryID: task.id, folder: "/a", at: now, known: ["existing"])
    let sessions = [assignmentSession("existing", "/a", at: now), assignmentSession("wrong", "/b", at: now),
                    assignmentSession("first", "/a", at: now.addingTimeInterval(1)), assignmentSession("second", "/a", at: now.addingTimeInterval(2))]
    let index = IndexResult(projects: [], sessions: sessions, skippedFiles: 0)
    let live = LiveState(running: [:], ended: [], resumeCounts: [:])
    let links = try await assignment.assign(index: index, store: store, live: live, now: now.addingTimeInterval(9))
    #expect(links["first"] == task.id)
    #expect(links["existing"] != task.id && links["wrong"] != task.id && links["second"] != task.id)
    _ = await assignment.started(entryID: task.id, folder: "/c", at: now, known: [])
    let expired = IndexResult(projects: [], sessions: [assignmentSession("expired", "/c", at: now)], skippedFiles: 0)
    #expect(try await assignment.assign(index: expired, store: store, live: live, now: now.addingTimeInterval(10.01))["expired"] != task.id)
}

@Test func lateHintDoesNotDeleteEditedOrSharedStrand() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: db)
    let task = Entry(id: "task", projectId: nil, title: "Task", status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
    try await store.save(task, undoLabel: nil)
    let assignment = SessionAssignment()
    let index = IndexResult(projects: [], sessions: [assignmentSession("edited", "/a", at: now), assignmentSession("shared", "/a", at: now)], skippedFiles: 0)
    let empty = LiveState(running: [:], ended: [], resumeCounts: [:])
    let original = try await assignment.assign(index: index, store: store, live: empty, now: now)
    let editedID = try #require(original["edited"]); let sharedID = try #require(original["shared"])
    var edited = try #require(try await store.loadEntries().first { $0.id == editedID })
    edited.title = "User title"; try await store.save(edited, undoLabel: nil)
    try await store.link(["another-session"], to: sharedID, undoLabel: nil)
    var hinted = empty; hinted.entryHints = ["edited": task.id, "shared": task.id]
    let after = try await assignment.assign(index: index, store: store, live: hinted, now: now)
    #expect(after["edited"] == editedID && after["shared"] == sharedID)
    #expect(try await store.loadEntries().contains(edited))
    #expect(try await store.loadLinks()["another-session"] == sharedID)
}

private func projectSession(_ id: String, project: String?, activity: TimeInterval) -> IndexedSession {
    let date = Date(timeIntervalSince1970: activity)
    return IndexedSession(id: id, tool: .codex, nativeId: id, projectId: project, cwd: "/synthetic",
                          transcriptPath: "/synthetic/\(id)", startedAt: date, lastActivityAt: date,
                          tokens: nil, firstPrompt: "", threadName: nil, suggestedTopic: "Project session", resumable: true)
}

private func projectFixture() throws -> FixtureServices {
    try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
}

private func projectEntry(_ id: String, title: String? = nil, project: String? = nil) -> Entry {
    let date = Date(timeIntervalSince1970: 100)
    return Entry(id: id, projectId: project, title: title, status: .wartet, deadline: "2026-12-01",
                 createdBy: .user, createdAt: date, updatedAt: date)
}

private func projectSnapshot(_ fixture: FixtureServices, sessions: [IndexedSession]) async throws -> Snapshot {
    let source = fixture.snapshot
    return try await SnapshotBuilder.build(index: IndexResult(projects: [], sessions: sessions, skippedFiles: 0),
        store: fixture.services.store, live: LiveState(running: [:], ended: [], resumeCounts: [:]),
        settings: source.settings, context: source.context, windows: source.windows, ended: [],
        permissions: source.permissions, now: source.now)
}

@Test func strandWithoutProjectTakesSessionProject() async throws {
    let fixture = try projectFixture()
    let store = fixture.services.store
    let entry = projectEntry("migrated", title: "Existing title")
    let session = projectSession("linked", project: "resume_bar", activity: 200)
    _ = try await store.createStrands([StrandSeed(sessionId: session.id, entry: entry)])
    var expected = entry; expected.projectId = "resume_bar"
    let first = try await projectSnapshot(fixture, sessions: [session])
    #expect(first.entry(entry.id) == expected)
    #expect(try await store.loadEntries().first { $0.id == entry.id } == expected)
    #expect(fixture.calls.filter { $0 == "save migrated " }.count == 1)
    #expect(try await store.loadChanges() == first.changes)
    #expect(try await store.undo() == nil)
    let second = try await projectSnapshot(fixture, sessions: [session])
    #expect(second.entry(entry.id) == expected)
    #expect(fixture.calls.filter { $0 == "save migrated " }.count == 1)
}

@Test func strandTakesProjectOfLatestSession() async throws {
    let fixture = try projectFixture()
    let store = fixture.services.store
    let entry = projectEntry("shared")
    let older = projectSession("older", project: "old", activity: 200)
    let latest = projectSession("latest", project: "new", activity: 300)
    let home = projectSession("home", project: nil, activity: 400)
    _ = try await store.createStrands([StrandSeed(sessionId: older.id, entry: entry)])
    try await store.link([latest.id, home.id], to: entry.id, undoLabel: nil)
    let result = try await projectSnapshot(fixture, sessions: [home, older, latest])
    #expect(result.entry(entry.id)?.projectId == "new")
    #expect(try await store.loadEntries().first { $0.id == entry.id }?.projectId == "new")
}

@Test func homeSessionStrandStaysWithoutProject() async throws {
    let fixture = try projectFixture()
    let entry = projectEntry("home-entry")
    let home = projectSession("home-session", project: nil, activity: 200)
    _ = try await fixture.services.store.createStrands([StrandSeed(sessionId: home.id, entry: entry)])
    let result = try await projectSnapshot(fixture, sessions: [home])
    #expect(result.entry(entry.id) == entry)
    #expect(!fixture.calls.contains { $0.hasPrefix("save home-entry ") })
}

@Test func openGoalWithoutProjectStaysWithoutProject() async throws {
    let fixture = try projectFixture()
    let store = fixture.services.store
    let goal = projectEntry("open-goal", title: "Open goal")
    let missing = projectEntry("missing-session", title: "Stored title")
    try await store.save(goal, undoLabel: nil)
    _ = try await store.createStrands([StrandSeed(sessionId: "missing", entry: missing)])
    let before = fixture.calls.count
    let result = try await projectSnapshot(fixture, sessions: [])
    #expect(result.entry(goal.id) == goal)
    #expect(result.entry(missing.id) == missing)
    #expect(fixture.calls.count == before)
}

@Test func existingEntryProjectIsPreserved() async throws {
    let fixture = try projectFixture()
    let entry = projectEntry("existing-project", project: "chosen")
    let session = projectSession("other-project", project: "other", activity: 200)
    _ = try await fixture.services.store.createStrands([StrandSeed(sessionId: session.id, entry: entry)])
    let result = try await projectSnapshot(fixture, sessions: [session])
    #expect(result.entry(entry.id) == entry)
    #expect(!fixture.calls.contains { $0.hasPrefix("save existing-project ") })
}

@Test func startFolderIsNoProject() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: db)
    let project = Project(id: "folder", name: "folder", rootPath: "/synthetic/start", lastActivityAt: now)
    let entry = Entry(id: "task", projectId: project.id, title: "Task", status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
    var session = assignmentSession("session", project.rootPath, at: now)
    session.projectId = project.id
    try await store.save(entry, undoLabel: nil)
    try await store.link([session.id], to: entry.id, undoLabel: nil)
    var settings = Settings.defaults; settings.startFolder = project.rootPath
    let result = try await SnapshotBuilder.build(index: IndexResult(projects: [project], sessions: [session], skippedFiles: 0), store: store,
        live: LiveState(running: [:], ended: [], resumeCounts: [:]), settings: settings,
        context: Context(projectId: project.id, source: nil, cwd: project.rootPath, windowIndex: nil),
        windows: Windows(open: 0, closable: 0), ended: [], permissions: Permissions(accessibility: false, automation: .init(ghostty: .unknown, terminal: .unknown)), now: now)
    #expect(result.projects.isEmpty)
    #expect(result.entry(entry.id)?.projectId == nil && result.session(session.id)?.projectId == nil)
    #expect(result.context?.projectId == nil)
    #expect(try await store.loadEntries().first { $0.id == entry.id }?.projectId == project.id)
    var fresh = session; fresh.id = "fresh"; fresh.suggestedTopic = "Fresh"
    let next = try await SnapshotBuilder.build(index: IndexResult(projects: [project], sessions: [session, fresh], skippedFiles: 0), store: store,
        live: LiveState(running: [:], ended: [], resumeCounts: [:]), settings: settings, context: nil,
        windows: Windows(open: 0, closable: 0), ended: [], permissions: Permissions(accessibility: false, automation: .init(ghostty: .unknown, terminal: .unknown)), now: now)
    let freshID = try #require(next.session(fresh.id)?.entryId)
    #expect(next.entry(freshID)?.projectId == nil)
    #expect(try await store.loadEntries().first { $0.id == freshID }?.projectId == nil)
}

private func emptyEntry(_ id: String, title: String? = nil) -> Entry {
    let now = Date(timeIntervalSince1970: 1000)
    return Entry(id: id, projectId: nil, title: title, status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
}
private func buildEmptySnapshot(_ store: SQLiteStore, sessions: [IndexedSession] = []) async throws -> Snapshot {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let source = fixture.snapshot
    return try await SnapshotBuilder.build(index: IndexResult(projects: [], sessions: sessions, skippedFiles: 0), store: store,
        live: LiveState(running: [:], ended: [], resumeCounts: [:]), settings: source.settings,
        context: nil, windows: source.windows, ended: [], permissions: source.permissions, now: source.now)
}
private func emptyStore() -> SQLiteStore {
    SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
}
@Test func entryWithoutTitleAndSessionIsHidden() async throws {
    let store = emptyStore()
    try await store.save(emptyEntry("nil"), undoLabel: nil)
    try await store.save(emptyEntry("empty", title: ""), undoLabel: nil)
    try await store.save(emptyEntry("named", title: "Named"), undoLabel: nil)
    let snapshot = try await buildEmptySnapshot(store)
    #expect(snapshot.entries.map(\.id) == ["named"])
    #expect(try await store.loadEntries().count == 3)
}
@Test func entryWithoutTitleReturnsWithItsSession() async throws {
    let store = emptyStore()
    let entry = emptyEntry("entry")
    try await store.save(entry, undoLabel: nil)
    try await store.link(["session"], to: entry.id, undoLabel: nil)
    #expect(try await buildEmptySnapshot(store).entry(entry.id) == nil)
    var session = assignmentSession("session", "/synthetic", at: entry.createdAt)
    session.suggestedTopic = "Session title"
    let snapshot = try await buildEmptySnapshot(store, sessions: [session])
    #expect(snapshot.entry(entry.id) != nil)
    #expect(snapshot.sessions.first?.entryId == entry.id)
}
@Test func entryWithoutTitleWithPendingChangeStays() async throws {
    let store = emptyStore()
    let entry = emptyEntry("pending")
    let change = Change(id: "change", kind: .add, entryId: entry.id, by: .claude, at: entry.createdAt)
    try await store.save(entry, change: change, undoLabel: nil)
    let snapshot = try await buildEmptySnapshot(store)
    #expect(snapshot.entry(entry.id) != nil)
    #expect(snapshot.changes == [change])
}
@Test func entryWithoutTitleWithDeadlineStays() async throws {
    let store = emptyStore()
    var entry = emptyEntry("dated"); entry.deadline = "2026-12-01"
    try await store.save(entry, undoLabel: nil)
    #expect(try await buildEmptySnapshot(store).entry(entry.id) == entry)
}
