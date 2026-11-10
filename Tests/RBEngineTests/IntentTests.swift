import Foundation
import Testing
import RBContract
import RBStore
import RBUI
@testable import RBEngine

@MainActor
private func setup() async throws -> (Engine, Services, FixtureServices, SQLiteStore) {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let base = fixture.services
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/store.sqlite")
    let store = SQLiteStore(databaseURL: url)
    let services = Services(index: base.index, live: base.live, store: store, terminal: base.terminal, platform: base.platform)
    let engine = Engine(services: services, settings: fixture.snapshot.settings)
    await engine.start()
    return (engine, services, fixture, store)
}

@MainActor
@Test func entryEditingAndUndo() async throws {
    let (engine, services, _, store) = try await setup()
    let strand = try #require(engine.snapshot.sessions.first)
    let id = strand.entryId
    let before = try #require(engine.snapshot.entry(id))
    #expect(await engine.run(.cycleStatus(entryId: id), services, engine.snapshot) == .entryStatusSet(entryId: id, from: .offen, to: .wartet))
    #expect(engine.snapshot.entry(id)?.title == strand.suggestedTitle)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(await engine.run(.setTitle(entryId: id, title: "A"), services, engine.snapshot) == .entryTitleSet(entryId: id))
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(await engine.run(.setDeadline(entryId: id, deadline: "2026-12-01"), services, engine.snapshot) == .deadlineSet(entryId: id, deadline: "2026-12-01"))
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(await engine.run(.archiveEntry(entryId: id), services, engine.snapshot) == .entryArchived(entryId: id))
    #expect(engine.snapshot.entry(id)?.archivedAt != nil)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(await engine.run(.panelName(sessionId: strand.id, title: "Panel"), services, engine.snapshot) == .entryTitleSet(entryId: id))
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(await engine.run(.nameJustEnded(entryId: id, title: nil), services, engine.snapshot) == .entryTitleSet(entryId: id))
    #expect(engine.snapshot.entry(id)?.title == strand.suggestedTitle)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == before)
    #expect(try await store.loadEntries().contains(before))
}

@MainActor
@Test func tasksStartAndResume() async throws {
    let (engine, services, fixture, _) = try await setup()
    let project = try #require(engine.snapshot.projects.first)
    let count = engine.snapshot.entries.count
    if case .entrySaveFailed = await engine.run(.addTask(title: " \n ", projectId: project.id, deadline: nil, start: nil), services, engine.snapshot) {} else { Issue.record("empty title accepted") }
    #expect(engine.snapshot.entries.count == count)
    let result = await engine.run(.addTask(title: "  a 'quoted' title  ", projectId: project.id, deadline: nil, start: nil), services, engine.snapshot)
    guard case let .taskAdded(id) = result else { Issue.record("task not added"); return }
    #expect(engine.snapshot.entry(id)?.title == "a 'quoted' title")
    #expect(await engine.run(.startEntry(entryId: id, tool: .codex, terminal: nil), services, engine.snapshot) == .opened(app: engine.snapshot.settings.terminal.default, sessionId: nil))
    let call = try #require(fixture.calls.last { $0.hasPrefix("open ") })
    #expect(call.contains("\(project.rootPath) RB_ENTRY=\(id) \(engine.snapshot.settings.newCommands[.codex]) 'a '\\''quoted'\\'' title'"))
    #expect(await engine.run(.setProject(entryId: id, projectId: project.id), services, engine.snapshot) == .projectSet(entryId: id))
    _ = await engine.run(.undo, services, engine.snapshot)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(id) == nil)
    let strand = try #require(engine.snapshot.sessions.first)
    #expect(await engine.run(.setProject(entryId: strand.entryId, projectId: project.id), services, engine.snapshot) == .entrySaveFailed(entryId: strand.entryId))
    let newest = try #require(engine.snapshot.sessions(of: strand.entryId).first)
    let resume = await engine.run(.resumeEntry(entryId: strand.entryId, sessionId: newest.id, terminal: nil), services, engine.snapshot)
    let implicit = await engine.run(.resumeEntry(entryId: strand.entryId, sessionId: nil, terminal: nil), services, engine.snapshot)
    #expect(resume == implicit)
    let created = await engine.run(.newStrang(title: "New", projectId: project.id, tool: .claude, terminal: nil), services, engine.snapshot)
    guard case let .taskAdded(newID) = created else { Issue.record("strand not started"); return }
    #expect(fixture.calls.contains { $0.contains("RB_ENTRY=\(newID)") })
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(newID) == nil)
    let started = await engine.run(.addTask(title: "Started", projectId: project.id, deadline: nil, start: .codex), services, engine.snapshot)
    guard case let .taskAdded(startID) = started else { Issue.record("task not started"); return }
    #expect(fixture.calls.contains { $0.contains("RB_ENTRY=\(startID)") })
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(startID) == nil)
}

@MainActor
@Test func changesAreAtomicAndUndoable() async throws {
    let (engine, services, _, store) = try await setup()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = Entry(id: "e_change", projectId: nil, title: "Change", status: .erledigt, createdBy: .claude, createdAt: now, updatedAt: now, archivedAt: now)
    try await store.save(entry, undoLabel: nil)
    try await store.addChange(Change(id: "c_done", kind: .done, entryId: entry.id, by: .claude, at: now))
    await engine.start()
    #expect(await engine.run(.revertChange(changeId: "c_done"), services, engine.snapshot) == .changeReverted(title: "Change"))
    #expect(engine.snapshot.entry(entry.id)?.status == .offen)
    #expect(engine.snapshot.entry(entry.id)?.archivedAt == nil)
    #expect(engine.snapshot.changes.isEmpty)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(entry.id) == entry)
    #expect(engine.snapshot.changes.count == 1)
    #expect(await engine.run(.acceptChanges, services, engine.snapshot) == .changesAccepted)
    #expect(engine.snapshot.changes.isEmpty)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.changes.count == 1)
    try await store.addChange(Change(id: "c_add", kind: .add, entryId: entry.id, by: .claude, at: now))
    await engine.start()
    #expect(await engine.run(.revertChange(changeId: "c_add"), services, engine.snapshot) == .changeReverted(title: "Change"))
    #expect(engine.snapshot.entry(entry.id) == nil)
    #expect(engine.snapshot.changes.isEmpty)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(entry.id) == entry)
    #expect(engine.snapshot.changes.count == 2)
}

@Test func replayRestoresEntryAndChanges() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json")
    var snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let session = try #require(snapshot.sessions.first)
    let before = snapshot
    var effects = ReplayEffects()
    #expect(effects.apply(.setTitle(entryId: session.entryId, title: "Replay"), to: &snapshot) == .entryTitleSet(entryId: session.entryId))
    _ = effects.apply(.undo, to: &snapshot)
    #expect(snapshot == before)
}

@MainActor
@Test func revertAddRestoresLinksWithoutOrphanStrands() async throws {
    let (engine, services, _, store) = try await setup()
    let session = try #require(engine.snapshot.sessions.first)
    let entry = try #require(engine.snapshot.entry(session.entryId))
    let beforeCount = engine.snapshot.entries.count
    try await store.addChange(Change(id: "c_linked", kind: .add, entryId: entry.id, by: .codex, at: Date()))
    await engine.start()
    #expect(await engine.run(.revertChange(changeId: "c_linked"), services, engine.snapshot) != nil)
    #expect(engine.snapshot.entry(entry.id) == nil)
    #expect(engine.snapshot.session(session.id)?.entryId != entry.id)
    _ = await engine.run(.undo, services, engine.snapshot)
    #expect(engine.snapshot.entry(entry.id) == entry)
    #expect(engine.snapshot.session(session.id)?.entryId == entry.id)
    #expect(engine.snapshot.entries.count == beforeCount)
    #expect(engine.snapshot.changes.contains { $0.id == "c_linked" })
}

@Test func replayIntentEffectsAndUndo() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json")
    let original = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let session = try #require(original.sessions.first)
    let project = try #require(original.projects.first)
    var snap = original
    var effects = ReplayEffects()
    func checkUndo(_ intent: Intent) {
        let before = snap
        #expect(effects.apply(intent, to: &snap) != nil)
        #expect(effects.apply(.undo, to: &snap) != .undoEmpty)
        #expect(snap == before)
    }
    checkUndo(.cycleStatus(entryId: session.entryId))
    checkUndo(.archiveEntry(entryId: session.entryId))
    checkUndo(.setDeadline(entryId: session.entryId, deadline: "2026-12-01"))
    checkUndo(.nameJustEnded(entryId: session.entryId, title: nil))
    checkUndo(.panelName(sessionId: session.id, title: "Panel"))
    checkUndo(.addTask(title: "Task", projectId: project.id, deadline: nil, start: nil))
    checkUndo(.newStrang(title: "New", projectId: project.id, tool: .codex, terminal: nil))
    guard case let .taskAdded(taskID) = effects.apply(.addTask(title: "Task", projectId: project.id, deadline: nil, start: nil), to: &snap) else { Issue.record("task missing"); return }
    checkUndo(.setProject(entryId: taskID, projectId: project.id))
    #expect(effects.apply(.startEntry(entryId: taskID, tool: .codex, terminal: nil), to: &snap) != nil)
    #expect(effects.apply(.resumeEntry(entryId: session.entryId, sessionId: session.id, terminal: nil), to: &snap) != nil)
    let change = Change(id: "replay", kind: .done, entryId: taskID, by: .codex, at: snap.now)
    snap.changes = [change]
    checkUndo(.acceptChanges)
    checkUndo(.revertChange(changeId: change.id))
    snap.changes[0].kind = .add
    checkUndo(.revertChange(changeId: change.id))
    let before = snap
    if case .entrySaveFailed = effects.apply(.addTask(title: " ", projectId: nil, deadline: nil, start: nil), to: &snap) {} else { Issue.record("empty title accepted") }
    #expect(snap == before)
}

@MainActor
@Test func startGoalPromptHasGoalPrefix() async throws {
    let (engine, services, fixture, _) = try await setup()
    let project = try #require(engine.snapshot.projects.first)
    let result = await engine.run(.addTask(title: "A 'goal'", projectId: project.id, deadline: nil, start: nil), services, engine.snapshot)
    guard case let .taskAdded(id) = result else { Issue.record("task not added"); return }
    #expect(await engine.run(.startGoal(entryId: id, tool: .codex, terminal: nil), services, engine.snapshot) == .opened(app: engine.snapshot.settings.terminal.default, sessionId: nil))
    let call = try #require(fixture.calls.last { $0.hasPrefix("open ") })
    #expect(call.contains("\(project.rootPath) RB_ENTRY=\(id) \(engine.snapshot.settings.newCommands[.codex]) '/goal A '\\''goal'\\'''"))
}

@MainActor
@Test func startWithoutProjectUsesStartFolder() async throws {
    let (engine, services, fixture, store) = try await setup()
    let folder = URL(fileURLWithPath: try #require(engine.snapshot.projects.first?.rootPath)).deletingLastPathComponent().path
    let result = await engine.run(.addTask(title: "No project", projectId: nil, deadline: nil, start: nil), services, engine.snapshot)
    guard case let .taskAdded(id) = result else { Issue.record("task not added"); return }
    #expect(await engine.run(.startGoal(entryId: id, tool: .codex, terminal: nil), services, engine.snapshot) == .opened(app: engine.snapshot.settings.terminal.default, sessionId: nil))
    #expect(fixture.calls.contains { $0.contains("open ") && $0.contains("\(folder) RB_ENTRY=\(id)") && $0.contains("/goal No project") })
    #expect(try await store.loadEntries().first { $0.id == id }?.projectId == nil)
    let created = await engine.run(.newStrang(title: "New without project", projectId: nil, tool: .claude, terminal: nil), services, engine.snapshot)
    guard case let .taskAdded(newID) = created else { Issue.record("strand not started"); return }
    #expect(fixture.calls.contains { $0.contains("\(folder) RB_ENTRY=\(newID)") })
    #expect(try await store.loadEntries().first { $0.id == newID }?.projectId == nil)
}

@Test func replayMissingStartFolderReturnsFolderMissing() throws {
    let url = fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/fixtures/m01.kontext.json")
    var snap = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let index = try #require(snap.entries.firstIndex { $0.title != nil })
    snap.entries[index].projectId = nil
    snap.settings.startFolder = "/synthetic/missing"
    var effects = ReplayEffects(); effects.missingDirectories = ["/synthetic/missing"]
    #expect(effects.apply(.startGoal(entryId: snap.entries[index].id, tool: .codex, terminal: nil), to: &snap) == .folderMissing(path: "/synthetic/missing"))
}

@MainActor
@Test func panelNamesStrandAndUndoThroughKeys() async throws {
    let (engine, _, _, store) = try await setup()
    let session = try #require(engine.snapshot.sessions.first { $0.tool == .codex })
    let before = try #require(engine.snapshot.entry(session.entryId))
    _ = engine.openPinPanel(selection: "codex resume \(session.nativeId)", context: nil)
    #expect(engine.state.panel?.sessionId == session.id)
    _ = engine.handle(.text(field: "p", value: "Neuer Titel"))
    _ = engine.handle(.key(.init(key: "Enter", field: "p")))
    for _ in 0..<200 where engine.state.panel?.saving == true { try await Task.sleep(for: .milliseconds(2)) }
    #expect(engine.state.panel?.done == true)
    #expect(engine.snapshot.entry(session.entryId)?.title == "Neuer Titel")
    #expect(try await store.loadEntries().first { $0.id == session.entryId }?.title == "Neuer Titel")
    _ = engine.handle(.key(.init(key: "z", meta: true, field: "p")))
    for _ in 0..<200 where engine.snapshot.entry(session.entryId) != before { try await Task.sleep(for: .milliseconds(2)) }
    #expect(engine.state.panel?.done == false)
    #expect(engine.snapshot.entry(session.entryId) == before)
    #expect(try await store.loadEntries().first { $0.id == session.entryId } == before)
}

@Test func panelEmptyTitleUsesLatestSessionOfStrand() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json")
    var snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let entryID = snapshot.sessions[0].entryId
    let entryIndex = try #require(snapshot.entries.firstIndex { $0.id == entryID })
    snapshot.entries[entryIndex].title = nil
    snapshot.sessions[0].suggestedTitle = "Älterer Vorschlag"
    snapshot.sessions[0].lastActivityAt = Date(timeIntervalSince1970: 1)
    snapshot.sessions[1].entryId = entryID
    snapshot.sessions[1].suggestedTitle = "Neuer Vorschlag"
    snapshot.sessions[1].lastActivityAt = Date(timeIntervalSince1970: 2)
    let id = snapshot.sessions[0].id
    var state = UIState()
    state.screen = .m01s1
    state.panel = PanelState(sessionId: id, source: .selection, selectionText: "", text: " ", done: false)
    #expect(Reducer.reduce(&state, .panelSave, snapshot) == [.panelName(sessionId: id, title: "Neuer Vorschlag")])
}
