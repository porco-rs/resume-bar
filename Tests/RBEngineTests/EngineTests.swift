import Foundation
import Testing
import RBContract
import RBUI
import RBTerminal
import RBStore
@testable import RBEngine

private actor CleanupTerminal: TerminalControlling {
    let candidates = [TerminalWindow(app: .terminal, windowId: "1", cwd: "/closed", tty: "ttys001"),
                      TerminalWindow(app: .terminal, windowId: "2", cwd: "/skipped", tty: "ttys002"),
                      TerminalWindow(app: .terminal, windowId: "3", cwd: "/failed", tty: "ttys003")]
    var remaining = 3
    var reopened: [String] = []
    func open(app: TerminalApp, cwd: String, command: String) async throws { reopened.append(cwd) }
    func focus(app: TerminalApp, tty: String) async throws {}
    func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] { Array(candidates.suffix(remaining)) }
    func openWindowCount() async -> Int { remaining }
    func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] {
        guard let window = windows.first else { return [] }
        if window.windowId == "3" { throw CocoaError(.fileWriteUnknown) }
        if window.windowId == "2" { return [] }
        remaining -= 1
        return [window]
    }
    nonisolated func quoted(_ text: String) -> String { text }
    func openedDirectories() -> [String] { reopened }
}

private protocol ForwardingStore: EntryStoring { var base: any EntryStoring { get } }
private extension ForwardingStore {
    func loadEntries() async throws -> [Entry] { try await base.loadEntries() }
    func loadLinks() async throws -> [String: String] { try await base.loadLinks() }
    func loadChanges() async throws -> [Change] { try await base.loadChanges() }
    func loadSettings() async throws -> Settings { try await base.loadSettings() }
    func loadResumeCountState() async throws -> ResumeCountState { try await base.loadResumeCountState() }
    func saveResumeCountState(_ state: ResumeCountState) async throws { try await base.saveResumeCountState(state) }
    func createStrands(_ seeds: [StrandSeed]) async throws -> [String: String] { try await base.createStrands(seeds) }
    func save(_ entry: Entry, undoLabel: String?) async throws { try await base.save(entry, undoLabel: undoLabel) }
    func link(_ ids: [String], to entryId: String, undoLabel: String?) async throws { try await base.link(ids, to: entryId, undoLabel: undoLabel) }
    func delete(entryId: String, undoLabel: String?) async throws { try await base.delete(entryId: entryId, undoLabel: undoLabel) }
    func addChange(_ change: Change) async throws { try await base.addChange(change) }
    func removeChanges(_ ids: [String]) async throws { try await base.removeChanges(ids) }
    func apply(_ patch: SettingsPatch) async throws -> Settings { try await base.apply(patch) }
    func undo() async throws -> String? { try await base.undo() }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async { await base.pushUndo(label: label, restore: restore) }
}

private actor CleanupStore: ForwardingStore {
    let base: any EntryStoring
    var restore: (@Sendable () async -> Void)?
    init(base: any EntryStoring) { self.base = base }
    func loadSettings() async throws -> Settings { try await base.loadSettings() }
    func apply(_ patch: SettingsPatch) async throws -> Settings { try await base.apply(patch) }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async { self.restore = restore }
    func undo() async throws -> String? {
        guard let restore else { return nil }
        self.restore = nil
        await restore()
        return "undo.cleanup"
    }
}

@MainActor
@Test func cleanupCountsAndRestoresOnlyClosedWindows() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    var services = fx.services
    let terminal = CleanupTerminal()
    let store = CleanupStore(base: services.store)
    services.terminal = terminal; services.store = store
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    await engine.start()
    _ = engine.popoverWillOpen(context: nil)
    await engine.refreshWindows()
    _ = engine.handle(.action("cleanup", arg: nil))
    for _ in 0..<100 where engine.state.toast == nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(engine.state.toast?.text.contains("1 Fenster geschlossen") == true)
    #expect(engine.state.undoHint)
    #expect(engine.snapshot.windows.open == 2 && engine.snapshot.windows.closable == 2)
    _ = try await store.undo()
    #expect(await terminal.openedDirectories() == ["/closed"])
}

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/design/fixtures")

@Test func builderMergesIndexFieldsAndLive() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let svc = fx.services
    let v2 = try await SnapshotBuilder.build(index: try await svc.index.scan(.defaults), store: svc.store,
                                              live: await svc.live.current(), settings: fx.snapshot.settings,
                                              context: fx.snapshot.context, windows: fx.snapshot.windows,
                                              ended: fx.snapshot.justEnded, permissions: fx.snapshot.permissions,
                                              now: fx.snapshot.now)
    var expected = fx.snapshot.sessions
    for i in expected.indices { expected[i].updatedAt = expected[i].startedAt }
    #expect(v2.sessions == expected)
    #expect(v2.projects == fx.snapshot.projects)
}

@Test func resumeCommandReplacesId() throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let s = try #require(fx.snapshot.sessions.first { $0.tool == .codex })
    #expect(SnapshotBuilder.command(for: s, settings: fx.snapshot.settings) == "codex resume \(s.nativeId)")
}

@MainActor
@Test func engineSendsSkeletonOnceAndOnlyChangedRegions() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let engine = Engine(services: fx.services, settings: fx.snapshot.settings, now: fx.snapshot.now)
    await engine.start()
    let first = engine.popoverWillOpen(context: fx.snapshot.context)
    #expect(first.skeleton != nil)
    #expect(first.screen == "M01")
    let second = engine.render(force: false)
    #expect(second.skeleton == nil)
    #expect(second.regions.isEmpty)
}

@MainActor
@Test func pinPanelFindsSessionFromResumeLineAndPrefillsTopic() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01-s1.benennen.json"))
    let engine = Engine(services: fx.services, settings: fx.snapshot.settings, now: fx.snapshot.now)
    await engine.start()
    let id = "cx_af2744b4-0000-4000-8000-52355bbd24a8"
    let u = engine.openPinPanel(selection: "  codex resume af2744b4-0000-4000-8000-52355bbd24a8\n", context: nil)
    #expect(u.screen == "M01-S1")
    #expect(engine.state.panel?.sessionId == id)
    let entry = try #require(fx.snapshot.session(id)).entryId
    #expect(engine.state.panel?.initialText == Logic.titleOf(fx.snapshot, try #require(fx.snapshot.entry(entry))))
    #expect(u.focus == "p")
}

@MainActor
@Test func pinPanelWithoutKnownIdShowsNotRecognized() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01-s1.benennen.json"))
    let engine = Engine(services: fx.services, settings: fx.snapshot.settings, now: fx.snapshot.now)
    await engine.start()
    _ = engine.openPinPanel(selection: "npm run build && npm test", context: nil)
    #expect(engine.state.panel?.sessionId == nil)
    #expect(engine.render(force: true).focus == nil)
}

@MainActor
private func fixtureEngine(_ name: String) async throws -> (Engine, FixtureServices) {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent(name + ".json"))
    let engine = Engine(services: fx.services, settings: fx.snapshot.settings, now: fx.snapshot.now,
                        clock: { fx.snapshot.now })
    await engine.start()
    return (engine, fx)
}

@MainActor
@Test func replacingBodyResendsBannerMirror() async throws {
    let (engine, fx) = try await fixtureEngine("m01.gerade-beendet")
    _ = engine.popoverWillOpen(context: fx.snapshot.context)
    _ = engine.handle(.key(.init(key: "/", meta: true)))
    let update = engine.handle(.key(.init(key: "/", meta: true)))
    let names = update.regions.map { $0[0] }
    #expect(names.contains("body") && names.contains("bmirror"))
    #expect(try #require(names.firstIndex(of: "body")) < #require(names.firstIndex(of: "bmirror")))
}

@MainActor
@Test func contextArrivalKeepsUserQueryAndMode() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    _ = engine.popoverWillOpen(context: nil)
    _ = engine.handle(.text(field: "q", value: "blog"))
    let before = engine.state
    engine.contextChanged(try #require(fx.snapshot.context))
    #expect(engine.state.query == before.query)
    #expect(engine.state.chips == before.chips)
    #expect(engine.state.mode == before.mode)
    #expect(engine.state.selectedId == before.selectedId)
}

@MainActor
@Test func contextArrivalKeepsEditedTopic() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    _ = engine.popoverWillOpen(context: nil)
    _ = engine.handle(.key(.init(key: "Enter")))
    _ = engine.handle(.key(.init(key: "ArrowDown")))
    _ = engine.handle(.key(.init(key: "p", meta: true)))
    _ = engine.handle(.text(field: "e", value: "Draft"))
    let host = TestHost()
    engine.host = host
    engine.contextChanged(try #require(fx.snapshot.context))
    let update = try #require(host.updates.last)
    #expect(!update.regions.contains { $0[0] == "body" })
    #expect(update.values["e"] == "Draft")
    #expect(engine.state.mode == .edit && engine.state.editText == "Draft")
    let cancel = engine.handle(.key(.init(key: "Escape", field: "e")))
    #expect(cancel.regions.contains { $0[0] == "body" })
}

@MainActor
@Test func resumeEditToastVisibleWhileEditing() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    _ = engine.popoverWillOpen(context: fx.snapshot.context)
    _ = engine.handle(.key(.init(key: "p", meta: true)))
    let host = TestHost()
    engine.host = host
    _ = engine.handle(.key(.init(key: "z", meta: true, field: "e")))
    for _ in 0..<100 where engine.state.toast == nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(engine.state.mode == .edit)
    #expect(host.updates.contains { update in
        !update.regions.contains { $0[0] == "body" } && update.regions.contains { $0[0] == "toast" && !$0[1].isEmpty }
    })
}

@MainActor
@Test func pinUsesTTYBeforeFolder() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    let running = try #require(fx.snapshot.sessions.first { $0.live.running && $0.live.tty != nil })
    let context = Context(projectId: nil, source: nil, cwd: "/other", windowIndex: nil, tty: running.live.tty)
    _ = engine.openPinPanel(selection: nil, context: context)
    #expect(engine.state.panel?.sessionId == running.id)
}

@MainActor
@Test func pinDoesNotGuessWhenTTYDoesNotMatch() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    let running = try #require(fx.snapshot.sessions.first { $0.live.running })
    _ = engine.openPinPanel(selection: nil, context: Context(projectId: nil, source: nil, cwd: running.cwd, windowIndex: nil, tty: "ttys999"))
    #expect(engine.state.panel?.sessionId == nil)
}

@MainActor
@Test func pinWithoutTTYAcceptsUniqueFolder() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    let running = try #require(fx.snapshot.sessions.first { $0.live.running })
    _ = engine.openPinPanel(selection: nil, context: Context(projectId: nil, source: nil, cwd: running.cwd, windowIndex: nil))
    #expect(engine.state.panel?.sessionId == running.id)
}

@MainActor
@Test func pinWithoutTTYRejectsAmbiguousFolder() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    var snapshot = fx.snapshot
    let indexes = snapshot.sessions.indices.filter { snapshot.sessions[$0].live.running }
    #expect(indexes.count >= 2)
    snapshot.sessions[indexes[1]].cwd = snapshot.sessions[indexes[0]].cwd
    let data = try Data(contentsOf: fixtures.appendingPathComponent("m01.kontext.json"))
    _ = try engine.replayFixture(data: data, snapshot: snapshot)
    _ = engine.openPinPanel(selection: nil, context: Context(projectId: nil, source: nil, cwd: snapshot.sessions[indexes[0]].cwd, windowIndex: nil))
    #expect(engine.state.panel?.sessionId == nil)
}

@MainActor
@Test func replayAppliesSearchSteps() async throws {
    let (engine, fx) = try await fixtureEngine("m01.suche")
    let data = try Data(contentsOf: fixtures.appendingPathComponent("m01.suche.json"))
    _ = try engine.replayFixture(data: data, snapshot: fx.snapshot)
    #expect(engine.state.query == "pp blog")
}

@MainActor
@Test func replayAppliesPanelPersistenceEffect() async throws {
    let (engine, fx) = try await fixtureEngine("m01-s1.gespeichert")
    let data = try Data(contentsOf: fixtures.appendingPathComponent("m01-s1.gespeichert.json"))
    _ = try engine.replayFixture(data: data, snapshot: fx.snapshot)
    #expect(engine.state.panel?.done == true)
    let id = try #require(engine.state.panel?.sessionId)
    #expect(engine.snapshot.session(id).flatMap { engine.snapshot.entry($0.entryId) }?.title != nil)
}

@MainActor
@Test func replayMatchesAllDesignOracles() async throws {
    struct Entry: Decodable { let screen: String; let state: String; let file: String }
    let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fixtures.appendingPathComponent("index.json")))
    #expect(entries.count == 36)
    func canonical(_ html: String) -> String {
        html.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: " data-region=\"bmirror\"", with: "")
            .replacingOccurrences(of: " data-region=\"pmirror\"", with: "")
            .replacingOccurrences(of: #"(?s)<span class="region" data-region="toast">(.*?)</span>"#, with: "$1", options: .regularExpression)
    }
    let expected = fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/RBUITests/Expected")
    for entry in entries where entry.screen == "M00" || entry.screen == "M02" || entry.screen == "M01-S1" {
        let url = fixtures.appendingPathComponent(entry.file)
        let fx = try FixtureServices(fixture: url)
        let engine = Engine(services: fx.services, now: fx.snapshot.now, clock: { fx.snapshot.now })
        _ = try engine.replayFixture(data: Data(contentsOf: url), snapshot: fx.snapshot)
        let rendered = Renderer.render(engine.state, engine.snapshot)
        let oracle = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expected.appendingPathComponent("\(entry.screen)__\(entry.state).json")))
        let names = rendered.screen == .m01 ? ["chips", "mirror", "key", "legend", "body", "footer"] : ["inner"]
        for name in names {
            var html = rendered.region(name == "inner" ? (rendered.screen == .m01s1 ? "panel" : "page") : name) ?? ""
            if let edit = rendered.fieldValues["e"] {
                html = html.replacingOccurrences(of: "<input class=\"e\" value=\"\(h(engine.state.editInitial))\"",
                                                 with: "<input class=\"e\" value=\"\(h(edit))\"")
            }
            for (child, inner) in rendered.regions {
                html = html.replacingOccurrences(of: "data-region=\"\(child)\"></", with: "data-region=\"\(child)\">\(inner)</")
            }
            #expect(canonical(html) == canonical(oracle[name] ?? ""), "\(entry.screen)__\(entry.state) \(name)")
        }
    }
}

private struct RejectingStore: ForwardingStore {
    let base: any EntryStoring
    func loadSettings() async throws -> Settings { try await base.loadSettings() }
    func save(_ entry: Entry, undoLabel: String?) async throws { throw CocoaError(.fileWriteNoPermission) }
    func apply(_ patch: SettingsPatch) async throws -> Settings { throw CocoaError(.fileWriteNoPermission) }
    func undo() async throws -> String? { try await base.undo() }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async { await base.pushUndo(label: label, restore: restore) }
}

@MainActor
private final class TestHost: EngineHost {
    var updates: [ViewUpdate] = []
    var hotkeyAllowed = true
    var endedRecordings = 0
    var copied: [String] = []
    var closed = 0
    func push(_ update: ViewUpdate) { updates.append(update) }
    func closePopover() { closed += 1 }
    func openSettings() {}
    func copyToPasteboard(_ text: String) { copied.append(text) }
    func startHotkeyRecording(_ slot: HotkeySlot) {}
    func endHotkeyRecording() { endedRecordings += 1 }
    func screenChanged(_ screen: Screen) {}
    func activate(_ app: TerminalApp) {}
    func settingsChanged(_ settings: Settings) {}
    func justEndedChanged(_ count: Int) {}
    func prepareHotkey(_ slot: HotkeySlot, combo: String) -> Bool { hotkeyAllowed }
}

@MainActor
@Test func rejectedSettingRestoresAcceptedInput() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m02.standard.json"))
    var services = fx.services
    services.store = RejectingStore(base: services.store)
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    let host = TestHost()
    engine.host = host
    await engine.start()
    _ = engine.show(.m02)
    _ = engine.handle(.setting(path: "archiveDays", value: "0"))
    for _ in 0..<100 where !host.updates.contains(where: { $0.values["setting:archiveDays"] != nil }) {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(host.updates.contains { $0.values["setting:archiveDays"] == String(fx.snapshot.settings.archiveDays) })
    #expect(engine.snapshot.settings.archiveDays == fx.snapshot.settings.archiveDays)
}

@MainActor
@Test func failedStoreSaveLeavesPanelEditable() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01-s1.benennen.json"))
    var services = fx.services
    services.store = RejectingStore(base: services.store)
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    await engine.start()
    _ = engine.openPinPanel(selection: "codex resume af2744b4-0000-4000-8000-52355bbd24a8", context: nil)
    _ = engine.handle(.text(field: "p", value: "Draft"))
    _ = engine.handle(.key(.init(key: "Enter")))
    for _ in 0..<100 where engine.state.panel?.saving == true { try await Task.sleep(for: .milliseconds(2)) }
    #expect(engine.state.panel?.done == false && engine.state.panel?.saving == false)
    #expect(engine.state.panel?.text == "Draft" && engine.state.toast?.kind == .error)
}


@MainActor
@Test func fallbackShortcutEndsNativeRecordingBeforeRejection() async throws {
    let (engine, _) = try await fixtureEngine("m02.standard")
    let host = TestHost()
    host.hotkeyAllowed = false
    engine.host = host
    _ = engine.show(.m02)
    _ = engine.handle(.action("record", arg: "popover"))
    let old = engine.snapshot.settings.hotkeys
    _ = engine.handle(.key(.init(key: "F1", meta: true)))
    #expect(host.endedRecordings == 1)
    #expect(engine.state.recording == nil)
    for _ in 0..<100 where !host.updates.contains(where: { $0.values["setting:archiveDays"] != nil }) {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(engine.snapshot.settings.hotkeys == old)
}

private actor PausedStore: ForwardingStore {
    let base: any EntryStoring
    var pending: CheckedContinuation<Void, Never>?
    init(base: any EntryStoring) { self.base = base }
    func loadSettings() async throws -> Settings { try await base.loadSettings() }
    func save(_ entry: Entry, undoLabel: String?) async throws {
        if undoLabel != nil { await withCheckedContinuation { pending = $0 } }
        try await base.save(entry, undoLabel: undoLabel)
    }
    func apply(_ patch: SettingsPatch) async throws -> Settings { try await base.apply(patch) }
    func undo() async throws -> String? { try await base.undo() }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async { await base.pushUndo(label: label, restore: restore) }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
@Test func lateSaveCannotConfirmReplacementPanel() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01-s1.benennen.json"))
    var services = fx.services
    let store = PausedStore(base: services.store)
    services.store = store
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    await engine.start()
    let selection = "codex resume af2744b4-0000-4000-8000-52355bbd24a8"
    _ = engine.openPinPanel(selection: selection, context: nil)
    _ = engine.handle(.text(field: "p", value: "First"))
    _ = engine.handle(.key(.init(key: "Enter")))
    for _ in 0..<100 where !(await store.waiting()) { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await store.waiting())
    _ = engine.handle(.key(.init(key: "Escape")))
    _ = engine.openPinPanel(selection: selection, context: nil)
    _ = engine.handle(.text(field: "p", value: "Second"))
    await store.release()
    for _ in 0..<100 where engine.snapshot.session("cx_af2744b4-0000-4000-8000-52355bbd24a8").flatMap { engine.snapshot.entry($0.entryId) }?.title != "First" {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(engine.snapshot.session("cx_af2744b4-0000-4000-8000-52355bbd24a8").flatMap { engine.snapshot.entry($0.entryId) }?.title == "First")
    #expect(engine.state.panel?.text == "Second" && engine.state.panel?.done == false)
}


@MainActor
@Test func replaySynchronizesEditedInputValue() async throws {
    let (engine, fx) = try await fixtureEngine("m01.titel-bearbeiten")
    let data = try Data(contentsOf: fixtures.appendingPathComponent("m01.titel-bearbeiten.json"))
    let update = try engine.replayFixture(data: data, snapshot: fx.snapshot)
    #expect(update.values["e"] == "CallKit + Push prüfen")
    #expect(update.values["e"] == engine.state.editText)
}

@MainActor
@Test func helpCanOpenAndRestoreEditDraft() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    _ = engine.popoverWillOpen(context: fx.snapshot.context)
    _ = engine.handle(.key(.init(key: "p", meta: true)))
    _ = engine.handle(.text(field: "e", value: "Draft"))
    let help = engine.handle(.key(.init(key: "/", meta: true)))
    #expect(help.regions.contains { $0[0] == "body" && $0[1].contains("class=\"help\"") })
    let back = engine.handle(.key(.init(key: "Escape")))
    #expect(back.regions.contains { $0[0] == "body" && $0[1].contains("class=\"e\"") })
    #expect(back.values["e"] == "Draft")
}

private struct MissingFolderTerminal: TerminalControlling {
    func open(app: TerminalApp, cwd: String, command: String) async throws { throw AppleScriptTerminal.Failure.missingDirectory(cwd) }
    func focus(app: TerminalApp, tty: String) async throws {}
    func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] { [] }
    func openWindowCount() async -> Int { 0 }
    func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] { [] }
    func quoted(_ text: String) -> String { "'" + text + "'" }
}

@MainActor
@Test func missingFolderCopiesResumeCommand() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    var services = fx.services
    services.terminal = MissingFolderTerminal()
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    let host = TestHost(); engine.host = host
    let session = try #require(fx.snapshot.sessions.first { !$0.live.running && $0.resumable })
    await engine.start()
    let resume = await engine.run(.resumeEntry(entryId: session.entryId, sessionId: session.id, terminal: nil), services, fx.snapshot)
    #expect(resume == .folderMissing(path: session.cwd))
    #expect(host.copied.last == SnapshotBuilder.command(for: session, settings: fx.snapshot.settings))
    #expect(host.closed == 0)
}

@MainActor
@Test func entryMissingFolderReturnsPathAndCopiesEntryCommand() async throws {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    var services = fx.services
    services.terminal = MissingFolderTerminal()
    let engine = Engine(services: services, settings: fx.snapshot.settings)
    let host = TestHost(); engine.host = host
    await engine.start()
    let project = try #require(engine.snapshot.projects.first)
    let added = await engine.run(.addTask(title: "Task", projectId: project.id, deadline: nil, start: nil), services, engine.snapshot)
    guard case let .taskAdded(id) = added else { Issue.record("task not added"); return }
    #expect(await engine.run(.startEntry(entryId: id, tool: .codex, terminal: nil), services, engine.snapshot) == .folderMissing(path: project.rootPath))
    #expect(host.copied.last == "RB_ENTRY=\(id) \(engine.snapshot.settings.newCommands[.codex]) 'Task'")
}

@Test func recoveredProjectRemainsVisibleWhenSaveFails() async throws {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let base = fixture.services.store
    let now = Date(timeIntervalSince1970: 100)
    let entry = Entry(id: "recovery-failure", projectId: nil, title: nil, status: .offen,
                      createdBy: .user, createdAt: now, updatedAt: now)
    let session = IndexedSession(id: "recovery-session", tool: .codex, nativeId: "recovery-session",
        projectId: "project", cwd: "/synthetic", transcriptPath: "/synthetic/session", startedAt: now,
        lastActivityAt: now, tokens: nil, firstPrompt: "", threadName: nil, suggestedTopic: "Recovery session", resumable: true)
    _ = try await base.createStrands([StrandSeed(sessionId: session.id, entry: entry)])
    let source = fixture.snapshot
    let result = try await SnapshotBuilder.build(index: IndexResult(projects: [], sessions: [session], skippedFiles: 0),
        store: RejectingStore(base: base), live: LiveState(running: [:], ended: [], resumeCounts: [:]),
        settings: source.settings, context: source.context, windows: source.windows, ended: [],
        permissions: source.permissions, now: source.now)
    #expect(result.entry(entry.id)?.projectId == "project")
    #expect(try await base.loadEntries().first { $0.id == entry.id } == entry)
}

@MainActor
@Test func lateWindowContextOnlySeedsUnchangedMark() async throws {
    let (engine, fx) = try await fixtureEngine("m01.kontext")
    let context = try #require(fx.snapshot.context)
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    _ = engine.handle(.text(field: "q", value: "Ein neues Ziel"))
    engine.contextChanged(context)
    #expect(engine.state.markedProjectId == engine.snapshot.context?.projectId)

    _ = engine.popoverWillOpen(context: nil)
    let other = try #require(engine.snapshot.projects.first { $0.id != context.projectId })
    _ = engine.handle(.action("select", arg: "p:" + other.id))
    #expect(engine.state.markedProjectId == other.id)
    engine.contextChanged(context)
    #expect(engine.state.markedProjectId == other.id)
}

private actor FailingAcceptStore: ForwardingStore, EntryChangeStoring {
    let base: any EntryStoring
    private(set) var attempts = 0
    init(base: any EntryStoring) { self.base = base }
    func acceptChanges(undoLabel: String) async throws { attempts += 1; throw CocoaError(.fileWriteUnknown) }
    func acceptSeenChanges(_ ids: Set<String>) async throws { attempts += 1; throw CocoaError(.fileWriteUnknown) }
    func revertAddedChange(id: String, seeds: [StrandSeed], undoLabel: String) async throws { throw CocoaError(.fileWriteUnknown) }
    func revertDoneChange(id: String, entry: Entry, undoLabel: String) async throws { throw CocoaError(.fileWriteUnknown) }
}

@MainActor @Test func popoverCloseFailedAcceptShowsChangesAgain() async throws {
    let fixture = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.seit-zuletzt.json"))
    var services = fixture.services
    let store = FailingAcceptStore(base: services.store); services.store = store
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    await engine.start()
    _ = engine.popoverWillOpen(context: nil)
    #expect(!engine.snapshot.changes.isEmpty)
    engine.popoverDidClose()
    for _ in 0..<100 {
        if await store.attempts > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await store.attempts == 1)
    #expect(try await store.loadChanges().count == fixture.snapshot.changes.count)
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(reopened.regions.contains { $0.last?.contains("class=\"strip\"") == true })
}

private actor BannerTestStore: ForwardingStore {
    let base: any EntryStoring
    init(base: any EntryStoring) { self.base = base }
}

private struct BannerTestLive: LiveMonitoring {
    let initial: LiveState
    let stream: AsyncStream<LiveState>
    func current() async -> LiveState { initial }
    func updates(interval: Duration) -> AsyncStream<LiveState> { stream }
}

@MainActor
private func bannerEngine(endedCount: Int) async throws -> (Engine, [String], AsyncStream<LiveState>.Continuation) {
    let fx = try FixtureServices(fixture: fixtures.appendingPathComponent("m01.kontext.json"))
    let sessions = fx.snapshot.sessions.filter { fx.snapshot.entry($0.entryId) != nil }
    let first = try #require(sessions.first)
    let second = try #require(sessions.first { $0.entryId != first.entryId })
    for session in [first, second] {
        var entry = try #require(fx.snapshot.entry(session.entryId))
        entry.title = nil; entry.archivedAt = nil
        try await fx.services.store.save(entry, undoLabel: nil)
    }
    let ids = [first.id, second.id]
    let (stream, continuation) = AsyncStream<LiveState>.makeStream()
    var services = fx.services
    services.store = BannerTestStore(base: services.store)
    services.live = BannerTestLive(initial: LiveState(running: [:], ended: Array(ids.prefix(endedCount)), resumeCounts: [:]), stream: stream)
    let engine = Engine(services: services, settings: fx.snapshot.settings, clock: { fx.snapshot.now })
    await engine.start()
    return (engine, ids, continuation)
}

@MainActor @Test func drawnBannerDisappearsOnCloseAndStrandRemains() async throws {
    let (engine, _, continuation) = try await bannerEngine(endedCount: 1)
    defer { continuation.finish() }
    let id = try #require(engine.snapshot.justEnded.first)
    let opened = engine.popoverWillOpen(context: nil)
    #expect(opened.regions.contains { $0.first == "body" && $0.last?.contains("class=\"banner\"") == true })
    engine.popoverDidClose()
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(!reopened.regions.contains { $0.last?.contains("class=\"banner\"") == true })
    #expect(engine.snapshot.entry(id) != nil && !engine.snapshot.justEnded.contains(id))
    var state = engine.state
    state.openProjects.append(engine.snapshot.entry(id)?.projectId ?? "_none")
    #expect(Renderer.render(state, engine.snapshot).fullHTML.contains("data-sel=\"e:\(id)\""))
}

@MainActor @Test func bannerEndedWhileClosedAppearsOnOpen() async throws {
    let (engine, ids, continuation) = try await bannerEngine(endedCount: 0)
    defer { continuation.finish() }
    _ = engine.popoverWillOpen(context: nil)
    engine.popoverDidClose()
    continuation.yield(LiveState(running: [:], ended: [ids[0]], resumeCounts: [:]))
    for _ in 0..<100 where engine.snapshot.justEnded.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!engine.snapshot.justEnded.isEmpty)
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(reopened.regions.contains { $0.last?.contains("class=\"banner\"") == true })
}

@MainActor @Test func closeRemovesOnlyDrawnQueuedBanner() async throws {
    let (engine, _, continuation) = try await bannerEngine(endedCount: 2)
    defer { continuation.finish() }
    #expect(engine.snapshot.justEnded.count == 2)
    let drawn = try #require(engine.snapshot.justEnded.first)
    let waiting = try #require(engine.snapshot.justEnded.last)
    _ = engine.popoverWillOpen(context: nil)
    engine.popoverDidClose()
    #expect(engine.snapshot.justEnded == [waiting])
    let reopened = engine.popoverWillOpen(context: nil)
    #expect(reopened.regions.contains { $0.last?.contains("class=\"banner\"") == true })
    #expect(engine.snapshot.justEnded != [drawn])
}
