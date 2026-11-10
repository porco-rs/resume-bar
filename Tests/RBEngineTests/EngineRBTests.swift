import Foundation
import Testing
import RBContract
import RBStore
@testable import RBEngine

private let rbRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let rbCwd = "/Users/mira/projects/vesper_ios/subfolder"
@MainActor private func rbSetup(enabled: Bool = true) async throws -> (Engine, SQLiteStore) {
    let fixture = try FixtureServices(fixture: rbRoot.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var services = fixture.services
    let store = SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
    if !enabled { _ = try await store.apply(.aiEnabled(false)) }
    services.store = store
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    engine.configureTrainer(data: try Data(contentsOf: rbRoot.appendingPathComponent("ui/trainer/uebung.json")))
    await engine.start()
    return (engine, store)
}
@MainActor @Test func rbAddFromPersonMakesNoChange() async throws {
    let (engine, store) = try await rbSetup()
    let before = try await store.loadEntries()
    let response = await engine.handle(.add(text: "Blumen", deadline: "fr", project: nil), from: .init(caller: .person, cwd: rbCwd))
    guard case .entry(let entry) = response else { Issue.record("no entry"); return }
    #expect(entry.projectName == "vesper_ios" && entry.deadline == "2026-11-06")
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await store.undo() != nil)
    #expect(try await store.loadEntries() == before)
}
@MainActor @Test func rbAddFromClaudeCreatesChange() async throws {
    let (engine, store) = try await rbSetup()
    let response = await engine.handle(.add(text: "Blumen", deadline: nil, project: nil), from: .init(caller: .claude, cwd: rbCwd))
    guard case .entry(let entry) = response else { Issue.record("no entry"); return }
    let changes = try await store.loadChanges(); #expect(changes.count == 1 && changes[0].entryId == entry.id && changes[0].by == .claude)
    #expect(entry.awaitsConfirmation)
    let listed = await engine.handle(.list(allProjects: false, project: nil), from: .init(caller: .claude, cwd: rbCwd))
    guard case .entries(let lines) = listed else { Issue.record("no list"); return }
    #expect(lines.first { $0.id == entry.id }?.awaitsConfirmation == true)
    #expect(engine.snapshot.changes.count == 1)
    #expect(try await store.undo() != nil); #expect(try await store.loadChanges().isEmpty)
}
@MainActor @Test func rbAddCleansControlCharacters() async throws {
    let (engine, store) = try await rbSetup()
    let caller = RBCallerInfo(caller: .person, cwd: rbCwd)
    for (input, expected) in [("vor\u{0}nach", "vor nach"), ("a\u{202E}b", "a b"), (" \t a  \n b ", "a b")] {
        let response = await engine.handle(.add(text: input, deadline: nil, project: nil), from: caller)
        guard case .entry(let entry) = response else { Issue.record("no entry"); continue }
        #expect(entry.title == expected)
        #expect(try await store.loadEntries().first { $0.id == entry.id }?.title == expected)
        let listed = await engine.handle(.list(allProjects: false, project: nil), from: caller)
        guard case .entries(let lines) = listed else { Issue.record("no list"); continue }
        #expect(lines.first { $0.id == entry.id }?.title == expected)
    }
}
@MainActor @Test func rbAddRefusesTitleTooLongInBytes() async throws {
    let (engine, store) = try await rbSetup()
    let caller = RBCallerInfo(caller: .person, cwd: rbCwd)
    let before = try await store.loadEntries()
    let overLimit = "a" + String(repeating: "\u{301}", count: 400)
    #expect(overLimit.count == 1 && overLimit.utf8.count == 801)
    #expect(await engine.handle(.add(text: overLimit, deadline: nil, project: nil), from: caller) == .failed(.badRequest, matches: []))
    #expect(try await store.loadEntries() == before)
    let atLimit = String(repeating: "😀", count: 200)
    guard case .entry(let entry) = await engine.handle(.add(text: atLimit, deadline: nil, project: nil), from: caller) else {
        Issue.record("800-byte title refused"); return
    }
    #expect(entry.title == atLimit)
    #expect(await engine.handle(.add(text: String(repeating: "a", count: 201), deadline: nil, project: nil), from: caller) == .failed(.badRequest, matches: []))
    #expect(await engine.handle(.add(text: "\u{0} \u{202E}", deadline: nil, project: nil), from: caller) == .failed(.badRequest, matches: []))
}
@MainActor @Test func rbAddForeignProjectRefused() async throws {
    let (engine, store) = try await rbSetup()
    let before = try await store.loadEntries()
    #expect(await engine.handle(.add(text: "x", deadline: nil, project: "devboardkit"), from: .init(caller: .codex, cwd: rbCwd)) == .failed(.foreignProject, matches: []))
    #expect(try await store.loadEntries() == before)
}
@MainActor @Test func rbAddInvalidDeadlineRefused() async throws {
    let (engine, store) = try await rbSetup()
    let before = try await store.loadEntries()
    #expect(await engine.handle(.add(text: "x", deadline: "unsinn", project: nil), from: .init(caller: .person, cwd: rbCwd)) == .failed(.invalidDeadline, matches: []))
    #expect(try await store.loadEntries() == before)
}
@MainActor @Test func rbListOwnProject() async throws {
    let (engine, _) = try await rbSetup()
    _ = await engine.handle(.add(text: "eins", deadline: nil, project: nil), from: .init(caller: .person, cwd: rbCwd))
    _ = await engine.handle(.add(text: "zwei", deadline: nil, project: "devboardkit"), from: .init(caller: .person, cwd: rbCwd))
    let response = await engine.handle(.list(allProjects: false, project: nil), from: .init(caller: .codex, cwd: rbCwd))
    guard case .entries(let entries) = response else { Issue.record("no list"); return }
    #expect(entries.contains { $0.title == "eins" })
    #expect(!entries.contains { $0.title == "zwei" })
    #expect(entries.allSatisfy { $0.projectName == "vesper_ios" })
}
@MainActor @Test func rbAddDuringTrainerLeavesPracticeData() async throws {
    let (engine, store) = try await rbSetup(); _ = engine.beginTrainer()
    let practice = engine.snapshot
    _ = await engine.handle(.add(text: "echt", deadline: nil, project: nil), from: .init(caller: .claude, cwd: rbCwd))
    #expect(engine.snapshot == practice)
    #expect(try await store.loadEntries().contains { $0.title == "echt" })
    engine.endTrainer()
    for _ in 0..<100 where !engine.snapshot.entries.contains(where: { $0.title == "echt" }) {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(engine.snapshot.entries.contains { $0.title == "echt" })
}

@MainActor @Test func rbAccessOffSaysSo() async throws {
    let (engine, _) = try await rbSetup(enabled: false)
    #expect(await engine.handle(.list(allProjects: true, project: nil), from: .init(caller: .person, cwd: rbCwd)) == .failed(.accessOff, matches: []))
}

@MainActor @Test func rbDoneFromClaudeCreatesChange() async throws {
    let (engine, store) = try await rbSetup()
    let person = RBCallerInfo(caller: .person, cwd: rbCwd)
    guard case .entry(let added) = await engine.handle(.add(text: "Abschluss", deadline: nil, project: nil), from: person),
          case .entry(let done) = await engine.handle(.done(query: added.id, project: nil), from: .init(caller: .claude, cwd: rbCwd)) else {
        Issue.record("done failed"); return
    }
    let entry = try #require(await store.loadEntries().first { $0.id == added.id })
    #expect(entry.status == .erledigt && entry.archivedAt != nil && entry.doneBy == .claude)
    #expect(done.awaitsConfirmation)
    #expect(try await store.loadChanges().contains { $0.entryId == added.id && $0.kind == .done && $0.by == .claude })
    #expect(try await store.undo() != nil)
    #expect(try await store.loadEntries().first { $0.id == added.id }?.status == .offen)
}
@MainActor @Test func rbDoneWithoutTargetUsesCallingSession() async throws {
    let (engine, store) = try await rbSetup()
    let sessionEntry = try #require(engine.snapshot.sessions.first { $0.live.pid == 47102 }?.entryId)
    let result = await engine.handle(.done(query: nil, project: nil), from: .init(caller: .codex, cwd: rbCwd, processChain: [900, 47102]))
    guard case .entry(let line) = result else { Issue.record("session not found"); return }
    #expect(line.id == sessionEntry)
    #expect(try await store.loadEntries().first { $0.id == sessionEntry }?.doneBy == .codex)
    #expect(await engine.handle(.done(query: nil, project: nil), from: .init(caller: .codex, cwd: rbCwd, processChain: [123])) == .failed(.notFound, matches: []))
}
@MainActor @Test func rbDoneForeignProjectRefused() async throws {
    let (engine, store) = try await rbSetup()
    let before = try await store.loadEntries()
    #expect(await engine.handle(.done(query: "e_s1", project: "parkway-portal"), from: .init(caller: .claude, cwd: rbCwd)) == .failed(.foreignProject, matches: []))
    #expect(try await store.loadEntries() == before)
}
@MainActor @Test func rbStartOnlyForPerson() async throws {
    let (engine, _) = try await rbSetup()
    guard case .entry(let added) = await engine.handle(.add(text: "Startziel", deadline: nil, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("add failed"); return }
    let request = RBRequest.start(query: added.id, tool: .claude, project: nil)
    #expect(await engine.handle(request, from: .init(caller: .claude, cwd: rbCwd)) == .failed(.notAllowed, matches: []))
    guard case .entry = await engine.handle(request, from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("start failed"); return }
}
@MainActor @Test func rbSetDeadlineOnlyForPerson() async throws {
    let (engine, store) = try await rbSetup()
    guard case .entry(let added) = await engine.handle(.add(text: "Deadlineziel", deadline: nil, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("add failed"); return }
    let request = RBRequest.setDeadline(query: added.id, deadline: "fr", project: nil)
    #expect(await engine.handle(request, from: .init(caller: .codex, cwd: rbCwd)) == .failed(.notAllowed, matches: []))
    guard case .entry(let result) = await engine.handle(request, from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("deadline failed"); return }
    #expect(result.deadline == "2026-11-06")
    #expect(try await store.loadEntries().first { $0.id == added.id }?.deadline == result.deadline)
    guard case .entry(let cleared) = await engine.handle(.setDeadline(query: added.id, deadline: nil, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("clear failed"); return }
    #expect(cleared.deadline == nil)
}
@MainActor @Test func rbExportOnlyForPerson() async throws {
    let (engine, _) = try await rbSetup()
    #expect(await engine.handle(.export, from: .init(caller: .claude, cwd: rbCwd)) == .failed(.notAllowed, matches: []))
    guard case .exported(let json) = await engine.handle(.export, from: .init(caller: .person, cwd: rbCwd)),
          let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { Issue.record("export failed"); return }
    #expect(Set(object.keys) == ["entries", "links", "changes", "settings", "resumeCounts"])
    #expect(!json.contains("firstPrompt") && !json.contains("transcriptPath"))
}
@MainActor @Test func rbFindExactIdBeforeAmbiguousTitle() async throws {
    let (engine, _) = try await rbSetup()
    let caller = RBCallerInfo(caller: .person, cwd: rbCwd)
    guard case .entry(let first) = await engine.handle(.add(text: "Beispiel eins", deadline: nil, project: nil), from: caller),
          case .entry = await engine.handle(.add(text: "Beispiel zwei", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    guard case .failed(.ambiguous, let matches) = await engine.handle(.done(query: "beispiel", project: nil), from: caller) else { Issue.record("ambiguous missing"); return }
    #expect(matches.count == 2)
    guard case .entry(let result) = await engine.handle(.done(query: first.id, project: nil), from: caller) else { Issue.record("id missing"); return }
    #expect(result.id == first.id)
}

@MainActor @Test func rbWithoutOwnProjectRefusedForAI() async throws {
    let (engine, store) = try await rbSetup()
    let person = RBCallerInfo(caller: .person, cwd: "/no/such/project")
    guard case .entry(let added) = await engine.handle(.add(text: "Ohne Projekt", deadline: nil, project: nil), from: person) else { Issue.record("add failed"); return }
    for who in [RBCaller.claude, .codex] {
        let ai = RBCallerInfo(caller: who, cwd: "/no/such/project")
        #expect(await engine.handle(.list(allProjects: false, project: nil), from: ai) == .failed(.foreignProject, matches: []))
        #expect(await engine.handle(.list(allProjects: true, project: nil), from: ai) == .failed(.foreignProject, matches: []))
        #expect(await engine.handle(.start(query: added.id, tool: nil, project: nil), from: ai) == .failed(.notAllowed, matches: []))
        #expect(await engine.handle(.add(text: "x", deadline: nil, project: nil), from: ai) == .failed(.foreignProject, matches: []))
        #expect(await engine.handle(.done(query: added.id, project: nil), from: ai) == .failed(.foreignProject, matches: []))
    }
    #expect(try await store.loadEntries().first { $0.id == added.id }?.status == .offen)
}
@MainActor @Test func rbStartDuringTrainerFindsNewEntry() async throws {
    let (engine, _) = try await rbSetup(); _ = engine.beginTrainer()
    let practice = engine.snapshot
    let person = RBCallerInfo(caller: .person, cwd: rbCwd)
    guard case .entry(let added) = await engine.handle(.add(text: "Neues Ziel", deadline: nil, project: nil), from: person) else { Issue.record("add failed"); return }
    guard case .entry(let started) = await engine.handle(.start(query: added.id, tool: .claude, project: nil), from: person) else { Issue.record("start failed"); return }
    #expect(started.id == added.id)
    #expect(engine.snapshot == practice)
}

@MainActor @Test func rbListIsStableInCreationOrder() async throws {
    let (engine, store) = try await rbSetup()
    let caller = RBCallerInfo(caller: .person, cwd: rbCwd)
    let project = try #require(engine.snapshot.projects.first { $0.name == "vesper_ios" })
    let base = Date(timeIntervalSince1970: 100)
    for (id, time) in [("z_order", base), ("b_order", base.addingTimeInterval(-1)), ("a_order", base)] {
        let entry = Entry(id: id, projectId: project.id, title: "Sortierprobe", status: .offen, createdBy: .user, createdAt: time, updatedAt: time)
        try await store.save(entry, undoLabel: "test")
    }
    guard case .entries(let listed) = await engine.handle(.list(allProjects: false, project: nil), from: caller) else { Issue.record("no list"); return }
    #expect(listed.filter { $0.title == "Sortierprobe" }.map(\.id) == ["b_order", "a_order", "z_order"])
    guard case .failed(.ambiguous, let matches) = await engine.handle(.done(query: "Sortierprobe", project: nil), from: caller) else { Issue.record("no matches"); return }
    #expect(matches.map(\.id) == ["b_order", "a_order", "z_order"])
}

private actor RBFailingStore: EntryStoring {
    let base: any EntryStoring
    var failing = false
    init(_ base: any EntryStoring) { self.base = base }
    func fail() { failing = true }
    func loadEntries() async throws -> [Entry] { if failing { throw CocoaError(.fileReadUnknown) }; return try await base.loadEntries() }
    func loadLinks() async throws -> [String: String] { try await base.loadLinks() }
    func loadChanges() async throws -> [Change] { try await base.loadChanges() }
    func loadSettings() async throws -> Settings { try await base.loadSettings() }
    func loadResumeCountState() async throws -> ResumeCountState { try await base.loadResumeCountState() }
    func saveResumeCountState(_ state: ResumeCountState) async throws { try await base.saveResumeCountState(state) }
    func createStrands(_ seeds: [StrandSeed]) async throws -> [String: String] { try await base.createStrands(seeds) }
    func save(_ entry: Entry, undoLabel: String?) async throws { try await base.save(entry, undoLabel: undoLabel) }
    func link(_ ids: [String], to id: String, undoLabel: String?) async throws { try await base.link(ids, to: id, undoLabel: undoLabel) }
    func delete(entryId: String, undoLabel: String?) async throws { try await base.delete(entryId: entryId, undoLabel: undoLabel) }
    func addChange(_ change: Change) async throws { try await base.addChange(change) }
    func removeChanges(_ ids: [String]) async throws { try await base.removeChanges(ids) }
    func apply(_ patch: SettingsPatch) async throws -> Settings { try await base.apply(patch) }
    func undo() async throws -> String? { try await base.undo() }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async { await base.pushUndo(label: label, restore: restore) }
}

private struct RBFailingTerminal: TerminalControlling {
    func openWindowCount() async -> Int { 0 }
    func quoted(_ text: String) -> String { text }
    func open(app: TerminalApp, cwd: String, command: String) async throws { throw CocoaError(.fileWriteUnknown) }
    func focus(app: TerminalApp, tty: String) async throws {}
    func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] { [] }
    func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] { [] }
}

@MainActor @Test func rbStoreFailureSaysSo() async throws {
    let fixture = try FixtureServices(fixture: rbRoot.appendingPathComponent("ui/trainer/uebung.json"))
    var services = fixture.services
    let store = RBFailingStore(services.store); services.store = store
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    await engine.start(); await store.fail()
    let caller = RBCallerInfo(caller: .person, cwd: "/practice/garten")
    #expect(await engine.handle(.list(allProjects: false, project: nil), from: caller) == .failed(.storeFailed, matches: []))
}

@MainActor @Test func rbStartFailureSaysSo() async throws {
    let fixture = try FixtureServices(fixture: rbRoot.appendingPathComponent("ui/trainer/uebung.json"))
    var services = fixture.services; services.terminal = RBFailingTerminal()
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    await engine.start()
    let caller = RBCallerInfo(caller: .person, cwd: "/practice/garten")
    #expect(await engine.handle(.start(query: "Pflanzen", tool: nil, project: nil), from: caller) == .failed(.startFailed, matches: []))
}

@MainActor @Test func rbListHidesEntriesWithoutTitle() async throws {
    let (engine, store) = try await rbSetup()
    let now = engine.snapshot.now
    for (id, title) in [("nil", Optional<String>.none), ("empty", ""), ("named", "Named")] {
        try await store.save(Entry(id: id, projectId: nil, title: title, status: .offen, createdBy: .user, createdAt: now, updatedAt: now), undoLabel: nil)
    }
    guard case .entries(let lines) = await engine.handle(.list(allProjects: true, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("no list"); return }
    #expect(!lines.contains { $0.id == "nil" || $0.id == "empty" })
    #expect(lines.contains { $0.id == "named" && $0.title == "Named" })
    let session = try #require(engine.snapshot.sessions.first { !$0.suggestedTitle.isEmpty })
    let linked = try #require(try await store.loadEntries().first { $0.id == session.entryId })
    #expect(lines.contains { $0.id == linked.id && $0.title == session.suggestedTitle })
}
@MainActor @Test func rbCannotReachHiddenEntryById() async throws {
    let (engine, store) = try await rbSetup()
    let project = try #require(engine.snapshot.projects.first { $0.name == "vesper_ios" })
    let now = engine.snapshot.now
    let hidden = Entry(id: "hidden", projectId: project.id, title: nil, status: .offen, createdBy: .user, createdAt: now, updatedAt: now)
    var dated = hidden; dated.id = "dated"; dated.deadline = "2026-12-01"
    var pending = hidden; pending.id = "pending"
    try await store.save(hidden, undoLabel: nil)
    try await store.save(dated, undoLabel: nil)
    try await store.save(pending, change: Change(id: "pending-change", kind: .add, entryId: pending.id, by: .claude, at: now), undoLabel: nil)
    let caller = RBCallerInfo(caller: .person, cwd: rbCwd)
    for request in [RBRequest.done(query: hidden.id, project: nil), .setDeadline(query: hidden.id, deadline: "fr", project: nil), .start(query: hidden.id, tool: nil, project: nil)] {
        #expect(await engine.handle(request, from: caller) == .failed(.notFound, matches: []))
    }
    guard case .entries(let lines) = await engine.handle(.list(allProjects: false, project: nil), from: caller) else { Issue.record("no list"); return }
    #expect(!lines.contains { $0.id == hidden.id })
    #expect(lines.contains { $0.id == dated.id && $0.title == "ohne Titel" })
    #expect(lines.contains { $0.id == pending.id && $0.title == "ohne Titel" })
    guard case .entry(let updated) = await engine.handle(.setDeadline(query: dated.id, deadline: "fr", project: nil), from: caller) else { Issue.record("dated entry not found"); return }
    #expect(updated.id == dated.id && updated.title == "ohne Titel")
    #expect(try await store.loadEntries().first { $0.id == hidden.id } == hidden)
}

private struct RBEmptyPromptIndex: SessionIndexing {
    let base: any SessionIndexing
    let sessionID: String
    func scan(_ settings: Settings) async throws -> IndexResult {
        var result = try await base.scan(settings)
        for i in result.sessions.indices where result.sessions[i].id == sessionID {
            result.sessions[i].firstPrompt = ""; result.sessions[i].threadName = nil; result.sessions[i].suggestedTopic = ""
        }
        return result
    }
    func updates(_ settings: Settings) -> AsyncStream<IndexResult> { AsyncStream { $0.finish() } }
}
@MainActor @Test func rbListsRunningSessionWithoutTitle() async throws {
    let fixture = try FixtureServices(fixture: rbRoot.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    let session = try #require(fixture.snapshot.sessions.first { $0.live.running })
    var services = fixture.services
    services.index = RBEmptyPromptIndex(base: services.index, sessionID: session.id)
    let store = SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
    services.store = store
    let entry = Entry(id: session.entryId, projectId: session.projectId, title: nil, status: .offen, createdBy: .user, createdAt: session.startedAt, updatedAt: session.startedAt)
    try await store.save(entry, undoLabel: nil)
    try await store.link([session.id], to: entry.id, undoLabel: nil)
    let engine = Engine(services: services, clock: { fixture.snapshot.now }); await engine.start()
    guard case .entries(let lines) = await engine.handle(.list(allProjects: true, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("no list"); return }
    #expect(lines.contains { $0.id == entry.id && $0.title == "ohne Titel" && $0.sessionCount > 0 })
}

@MainActor private func waitForClosedChanges(_ engine: Engine, _ store: SQLiteStore) async throws {
    for _ in 0..<200 {
        if try await store.loadChanges().isEmpty && engine.snapshot.changes.isEmpty { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test func popoverCloseAcceptsSeenChanges() async throws {
    let (engine, store) = try await rbSetup()
    _ = engine.popoverWillOpen(context: nil)
    let caller = RBCallerInfo(caller: .codex, cwd: rbCwd)
    guard case .entry(let added) = await engine.handle(.add(text: "Einmal sichtbar", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    #expect(engine.snapshot.changes.count == 1)
    engine.popoverDidClose()
    try await waitForClosedChanges(engine, store)
    #expect(try await store.loadChanges().isEmpty)
    #expect(engine.snapshot.changes.isEmpty)
    #expect(try await store.loadEntries().contains { $0.id == added.id && $0.createdBy == .codex })
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(!reopened.regions.contains { $0.last?.contains("class=\"strip\"") == true })
    #expect(try await store.undo() != nil)
    #expect(try await store.loadChanges().isEmpty)
}

@MainActor @Test func popoverCloseKeepsUnseenChanges() async throws {
    let (engine, store) = try await rbSetup()
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    let caller = RBCallerInfo(caller: .codex, cwd: rbCwd)
    guard case .entry = await engine.handle(.add(text: "Nicht gesehen", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    engine.popoverDidClose()
    #expect(try await store.loadChanges().count == 1)
    _ = engine.popoverWillOpen(context: nil)
    #expect(engine.snapshot.changes.count == 1)
}

@MainActor @Test func popoverCloseInTrainerKeepsRealChanges() async throws {
    let (engine, store) = try await rbSetup()
    let caller = RBCallerInfo(caller: .codex, cwd: rbCwd)
    guard case .entry = await engine.handle(.add(text: "Echtes Ziel", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    _ = engine.popoverWillOpen(context: nil)
    _ = engine.beginTrainer()
    #expect(engine.state.trainer != nil)
    engine.popoverDidClose()
    engine.endTrainer()
    #expect(try await store.loadChanges().count == 1)
}

@MainActor @Test func rbListHidesAutoArchivedStrands() async throws {
    let fixture = try FixtureServices(fixture: rbRoot.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var services = fixture.services
    let store = SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
    services.store = store
    let session = try #require(fixture.snapshot.sessions.first { !$0.live.running && !$0.suggestedTitle.isEmpty })
    let old = Entry(id: session.entryId, projectId: session.projectId, title: nil, status: .offen, createdBy: .user, createdAt: session.startedAt, updatedAt: session.startedAt)
    try await store.save(old, undoLabel: nil)
    try await store.link([session.id], to: old.id, undoLabel: nil)
    let engine = Engine(services: services, clock: { fixture.snapshot.now.addingTimeInterval(365 * 86400) })
    await engine.start()
    guard case .entries(let lines) = await engine.handle(.list(allProjects: true, project: nil), from: .init(caller: .person, cwd: rbCwd)) else { Issue.record("no list"); return }
    #expect(!lines.contains { $0.id == old.id })
}

@MainActor @Test func popoverCloseKeepsChangesHiddenBySearchOrOtherScreen() async throws {
    for onboarding in [false, true] {
        let (engine, store) = try await rbSetup()
        _ = engine.popoverWillOpen(context: nil, onboarding: onboarding)
        if !onboarding { _ = engine.handle(.text(field: "q", value: "suche")) }
        let caller = RBCallerInfo(caller: .codex, cwd: rbCwd)
        guard case .entry = await engine.handle(.add(text: "Nicht sichtbar", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
        engine.popoverDidClose()
        #expect(try await store.loadChanges().count == 1)
    }
}

@MainActor @Test func popoverCloseKeepsChangeArrivedDuringSearch() async throws {
    let (engine, store) = try await rbSetup()
    let caller = RBCallerInfo(caller: .codex, cwd: rbCwd)
    _ = engine.popoverWillOpen(context: nil)
    guard case .entry = await engine.handle(.add(text: "Visible", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    let seen = try #require(try await store.loadChanges().first)
    _ = engine.handle(.text(field: "q", value: "search"))
    guard case .entry = await engine.handle(.add(text: "Hidden", deadline: nil, project: nil), from: caller) else { Issue.record("add failed"); return }
    let unseen = try #require(try await store.loadChanges().first { $0.id != seen.id })
    engine.popoverDidClose()
    for _ in 0..<200 {
        if try await store.loadChanges().map(\.id) == [unseen.id] && engine.snapshot.changes.map(\.id) == [unseen.id] { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await store.loadChanges().map(\.id) == [unseen.id])
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(reopened.regions.contains { $0.last?.contains("class=\"strip\"") == true })
}
