import Foundation
import Testing
import RBContract
import RBStore
@testable import RBUI
@testable import RBEngine

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let practice = root.appendingPathComponent("ui/trainer/uebung.json")
private let englishPractice = root.appendingPathComponent("ui/trainer/uebung.en.json")

@Test func trainerLanguagesDecodeWithMatchingEntryAndProjectIDs() throws {
    let german = try FixtureServices(fixture: practice).snapshot
    let english = try FixtureServices(fixture: englishPractice).snapshot
    #expect(german.entries.map(\.id) == english.entries.map(\.id))
    #expect(german.projects.map(\.id) == english.projects.map(\.id))
    #expect(Set(german.entries.map(\.id)).contains("offen"))
    #expect(Set(german.projects.map(\.id)).contains("prj_karte"))
}

@Test func trainerEnglishInputLabelsAndDeadline() throws {
    #expect(CopyTable.en["trainer.input.find"] == "fence")
    #expect(CopyTable.en["trainer.input.text"] == "Text")
    #expect(CopyTable.en["trainer.input.due"] == "by fri ")
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    #expect(Logic.hasTrailingDeadline(fixture.snapshot, "Flowers by fri"))
}

private struct TrainerIndex: SessionIndexing {
    let initial: IndexResult
    let stream: AsyncStream<IndexResult>
    func scan(_ settings: Settings) async throws -> IndexResult { initial }
    func updates(_ settings: Settings) -> AsyncStream<IndexResult> { stream }
}

private struct TrainerLive: LiveMonitoring {
    let stream: AsyncStream<LiveState>
    func current() async -> LiveState { LiveState(running: [:], ended: [], resumeCounts: [:]) }
    func updates(interval: Duration) -> AsyncStream<LiveState> { stream }
}

@MainActor private func trainerSetup() async throws -> (Engine, FixtureServices, SQLiteStore) {
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var services = fixture.services
    let store = SQLiteStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.sqlite"))
    services.store = store
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    engine.configureTrainer(data: try Data(contentsOf: practice))
    await engine.start()
    _ = engine.popoverWillOpen(context: fixture.snapshot.context)
    return (engine, fixture, store)
}

@MainActor private func key(_ engine: Engine, _ key: String, meta: Bool = false) {
    _ = engine.handle(.key(KeyPress(key: key, meta: meta, fieldEmpty: engine.state.query.isEmpty)))
}

@MainActor private func text(_ engine: Engine, _ value: String) { _ = engine.handle(.text(field: "q", value: value)) }
@MainActor private func seek(_ engine: Engine, entry: String? = nil, project: String? = nil) {
    for _ in 0..<20 {
        let facts = TrainerFacts(state: engine.state, snapshot: engine.snapshot)
        if entry != nil && facts.markedEntryId == entry || project != nil && facts.markedProjectId == project { return }
        key(engine, "ArrowDown")
    }
}
@MainActor private func finishAll(_ engine: Engine) {
    _ = engine.trainerHotkey(); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    text(engine, "zaun"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    _ = engine.popoverWillOpen(context: nil, mode: .ziel); text(engine, "Blumen pflanzen"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    _ = engine.popoverWillOpen(context: nil, mode: .ziel); text(engine, "Blumen pflanzen bis fr "); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    seek(engine, entry: "offen"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    seek(engine, project: "prj_karte"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    key(engine, "Backspace", meta: true)
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    text(engine, "zaun"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    _ = engine.popoverWillOpen(context: nil, mode: .ziel); text(engine, "Blumen bis fr "); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    seek(engine, entry: "offen"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true); key(engine, "Enter")
    #expect(engine.state.trainer?.lesson == 10)
}

@MainActor @Test func trainerNeverTouchesServices() async throws {
    let (engine, fixture, _) = try await trainerSetup()
    let calls = fixture.calls
    _ = engine.beginTrainer()
    finishAll(engine)
    #expect(fixture.calls == calls)
}

@MainActor @Test func trainerRestoresRealListOnExit() async throws {
    let (engine, _, _) = try await trainerSetup()
    let original = engine.snapshot
    _ = engine.beginTrainer()
    key(engine, "Backspace", meta: true)
    #expect(engine.state.trainer?.wrongKey == "trainer.wrong.archive")
    key(engine, "Escape")
    #expect(engine.state.trainer == nil)
    #expect(engine.snapshot.entries == original.entries)
    #expect(engine.snapshot.sessions == original.sessions)
}

@MainActor @Test func trainerProgressPersists() async throws {
    let (engine, _, store) = try await trainerSetup()
    _ = engine.beginTrainer()
    finishAll(engine)
    for _ in 0..<200 {
        if (try await store.loadSettings()).trainerDone.count == 10 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await store.loadSettings().trainerDone == TrainerLessons.all.map(\.id))
    key(engine, "Enter")
    #expect(engine.state.trainer == nil)
}

@MainActor @Test func trainerIgnoresLivePushes() async throws {
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var services = fixture.services
    let initial = try await services.index.scan(.defaults)
    let (indexStream, indexPush) = AsyncStream<IndexResult>.makeStream()
    let (liveStream, livePush) = AsyncStream<LiveState>.makeStream()
    defer { indexPush.finish(); livePush.finish() }
    services.index = TrainerIndex(initial: initial, stream: indexStream)
    services.live = TrainerLive(stream: liveStream)
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    engine.configureTrainer(data: try Data(contentsOf: practice))
    await engine.start()
    _ = engine.popoverWillOpen(context: fixture.snapshot.context)
    _ = engine.beginTrainer()
    let training = engine.snapshot
    var changed = initial
    changed.projects = [Project(id: "new", name: "Neu", rootPath: "/new", lastActivityAt: fixture.snapshot.now)]
    changed.sessions = []
    indexPush.yield(changed)
    livePush.yield(LiveState(running: [:], ended: [], resumeCounts: [:]))
    try await Task.sleep(for: .milliseconds(50))
    #expect(engine.snapshot == training)
    key(engine, "Escape")
    for _ in 0..<100 where !engine.snapshot.projects.contains(where: { $0.id == "new" }) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(engine.snapshot.projects.contains(where: { $0.id == "new" }))
}

private actor DelayedTrainerTerminal: TerminalControlling {
    private var continuation: CheckedContinuation<Int, Never>?
    var waiting: Bool { continuation != nil }
    func openWindowCount() async -> Int { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: 0); continuation = nil }
    func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] { [] }
    func open(app: TerminalApp, cwd: String, command: String) async throws {}
    func focus(app: TerminalApp, tty: String) async throws {}
    func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] { [] }
    nonisolated func quoted(_ text: String) -> String { text }
}

@MainActor @Test func trainerWaitsForInFlightRealWork() async throws {
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var services = fixture.services
    let terminal = DelayedTrainerTerminal()
    services.terminal = terminal
    let engine = Engine(services: services, clock: { fixture.snapshot.now })
    engine.configureTrainer(data: try Data(contentsOf: practice))
    await engine.start()
    _ = engine.popoverWillOpen(context: fixture.snapshot.context)
    let refresh = Task { await engine.refreshWindows() }
    for _ in 0..<100 where !(await terminal.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await terminal.waiting)
    _ = engine.beginTrainer()
    #expect(engine.state.trainer == nil)
    await terminal.release()
    await refresh.value
    #expect(engine.state.trainer != nil)
    #expect(engine.snapshot.projects.contains(where: { $0.id == "prj_garten" }))
}

@MainActor @Test func trainerStepAlwaysNamesNextKey() async throws {
    let (engine, _, _) = try await trainerSetup()
    let cases: [(Int, String)] = [(0, "{popover}"), (1, "zaun"), (2, "{task}"), (3, "{task}"), (4, "↓"), (5, "↓"), (6, "⌘⌫")]
    for (index, label) in cases {
        _ = engine.beginTrainer(lesson: index)
        let lesson = TrainerLessons.all[index], facts = TrainerFacts(state: engine.state, snapshot: engine.snapshot)
        #expect(lesson.currentStep(facts).map { lesson.steps[$0].label } == label)
        engine.endTrainer()
    }
    _ = engine.beginTrainer(lesson: 2)
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    let lesson = TrainerLessons.all[2], facts = TrainerFacts(state: engine.state, snapshot: engine.snapshot)
    #expect(lesson.currentStep(facts).map { lesson.steps[$0].label } == "Text")
}
@MainActor @Test func trainerDeadlineStepAcceptsNoTrailingSpace() async throws {
    let (engine, _, _) = try await trainerSetup()
    _ = engine.beginTrainer(lesson: 3)
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    text(engine, "bla bis Fr")
    let lesson = TrainerLessons.all[3], facts = TrainerFacts(state: engine.state, snapshot: engine.snapshot)
    #expect(lesson.currentStep(facts).map { lesson.steps[$0].label } == "↵")
    key(engine, "Enter")
    #expect(engine.state.trainer?.success == true)
    #expect(engine.snapshot.entries.last?.title == "bla")
    #expect(engine.snapshot.entries.last?.deadline == Logic.parseDeadline(engine.snapshot, "fr"))
}
@MainActor @Test func trainerWrongActionKeepsPracticeData() async throws {
    let (engine, _, _) = try await trainerSetup()
    for index in 0..<TrainerLessons.all.count {
        _ = engine.beginTrainer(lesson: index); text(engine, "falsch")
        for (button, meta) in [("Enter", false), ("Backspace", true)] {
            let snapshot = engine.snapshot, query = engine.state.query
            key(engine, button, meta: meta)
            #expect(engine.snapshot == snapshot); #expect(engine.state.query == query)
            #expect(engine.state.trainer?.wrongKey == (meta ? "trainer.wrong.archive" : "trainer.wrong.other"))
        }
        engine.endTrainer()
    }
}
@MainActor @Test func trainerHotkeyCountsWithoutClosing() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer()
    _ = engine.trainerHotkey(); #expect(engine.state.trainer?.hotkeyPressed == true)
    #expect(engine.state.trainer != nil); key(engine, "Enter"); #expect(engine.state.trainer?.success == true)
}
@MainActor @Test func trainerTaskHotkeySwitchesToGoalMode() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer(lesson: 2)
    text(engine, "Blumen"); _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    #expect(engine.state.listMode == .ziel); #expect(engine.state.query == "Blumen")
}
@MainActor @Test func trainerShowsRealHotkeys() async throws {
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.kontext.json"))
    var settings = Settings.defaults
    settings.hotkeys = .init(popover: "⌃⌘P", pin: "⌃⌘R", task: "⌃⌘N")
    let engine = Engine(services: fixture.services, settings: settings)
    engine.configureTrainer(data: try Data(contentsOf: practice)); _ = engine.beginTrainer()
    let html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(engine.snapshot.settings.hotkeys == settings.hotkeys); #expect(html.contains("⌃⌘P"))
    _ = engine.trainerHotkey(); key(engine, "Enter")
    #expect(Renderer.render(engine.state, engine.snapshot).fullHTML.contains("⌃⌘P · ↵"))
    key(engine, "t", meta: true); key(engine, "t", meta: true)
    #expect(Renderer.render(engine.state, engine.snapshot).fullHTML.contains("⌃⌘N"))
}
@MainActor @Test func trainerSkipMovesOnWithoutMarkingDone() async throws {
    let (engine, _, store) = try await trainerSetup(); _ = engine.beginTrainer()
    key(engine, "t", meta: true); #expect(engine.state.trainer?.lesson == 1)
    #expect(try await store.loadSettings().trainerDone.isEmpty)
    engine.feed(.trainer); #expect(engine.state.trainer?.lesson == 2)
}
@MainActor @Test func trainerFinalRoundHidesStepsUntilWrongAction() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer(lesson: 7)
    var html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(!html.contains("trainer-steps")); key(engine, "Enter")
    html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(html.contains("trainer-steps")); #expect(engine.state.trainer?.tipped == true)
    text(engine, "zaun"); key(engine, "Enter"); key(engine, "Enter")
    _ = engine.popoverWillOpen(context: nil, mode: .ziel); text(engine, "Blumen bis fr "); key(engine, "Enter"); key(engine, "Enter")
    seek(engine, entry: "offen"); key(engine, "Enter"); key(engine, "Enter")
    #expect(engine.state.trainer?.finalWithoutTip == 2)
    html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(html.contains("2 von 3 ohne Tipp."))
    let end = engine.state.trainer
    key(engine, "t", meta: true); #expect(engine.state.trainer == end)
}

@MainActor @Test func trainerGuidedIntentBeforeEarlierStepIsRejected() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer()
    let before = engine.snapshot
    key(engine, "Enter")
    #expect(engine.snapshot == before)
    #expect(engine.state.trainer?.wrongKey == "trainer.wrong.first")
    #expect(engine.state.trainer?.success == false)
    _ = engine.trainerHotkey(); #expect(engine.state.trainer?.wrongKey == nil)
}

@MainActor @Test func trainerTaskHotkeyKeepsRealContext() async throws {
    let (engine, _, _) = try await trainerSetup()
    let real = engine.snapshot.context
    _ = engine.beginTrainer(lesson: 2)
    let practiceContext = Context(projectId: nil, source: nil, cwd: "/practice/garten", windowIndex: nil)
    _ = engine.popoverWillOpen(context: practiceContext, mode: .ziel)
    engine.contextChanged(practiceContext)
    engine.endTrainer()
    try await Task.sleep(for: .milliseconds(100))
    #expect(engine.snapshot.context == real)
}

@MainActor @Test func trainerEndCardNamesSkippedLessons() async throws {
    let (engine, _, _) = try await trainerSetup()
    _ = engine.beginTrainer()
    _ = engine.trainerHotkey(); key(engine, "Enter"); key(engine, "Enter")
    for _ in 1..<TrainerLessons.all.count { key(engine, "t", meta: true) }
    let html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(engine.state.trainer?.passed == 1)
    #expect(html.contains("1 von 10 geschafft, 0 von 3 ohne Tipp."))
    #expect(!html.contains("Alle Wege einmal geschafft"))
    let footer = try #require(html.components(separatedBy: "<footer data-region=\"footer\">").last)
    #expect(!footer.contains("data-act=\"enter\""))
    engine.endTrainer()
    _ = engine.beginTrainer(); finishAll(engine)
    let complete = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(engine.state.trainer?.passed == 10)
    #expect(complete.contains("Alle Wege einmal geschafft, 3 von 3 ohne Tipp."))
}

@MainActor @Test func trainerSuccessShowsNewGoalInFullList() async throws {
    let (engine, _, _) = try await trainerSetup()
    for lesson in [2, 3, 8] {
        _ = engine.beginTrainer(lesson: lesson)
        _ = engine.popoverWillOpen(context: nil, mode: .ziel)
        text(engine, lesson == 2 ? "Blumen pflanzen" : "Blumen pflanzen bis fr ")
        key(engine, "Enter")
        let entry = try #require(engine.snapshot.entries.last)
        #expect(engine.state.trainer?.success == true)
        #expect(engine.state.query.isEmpty && engine.state.chips.isEmpty)
        #expect(engine.state.selectedId == "e:" + entry.id)
        let html = Renderer.render(engine.state, engine.snapshot).fullHTML
        #expect(html.contains("Blumen pflanzen"))
        #expect(html.contains("Saatgut sortieren"))
        let footer = try #require(html.components(separatedBy: "<footer data-region=\"footer\">").last)
        #expect(!footer.contains("data-act=\"enter\""))
        engine.endTrainer()
    }
}

@MainActor @Test func trainerFinalHintDisappearsWithTheTip() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer(lesson: 7)
    var html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(html.contains("Ohne Tipp. Nach einer falschen Taste kommt er."))
    key(engine, "Enter")
    html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(html.contains("trainer-steps"))
    #expect(!html.contains("Ohne Tipp. Nach einer falschen Taste kommt er."))
    text(engine, "zaun"); key(engine, "Enter")
    html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(engine.state.trainer?.success == true)
    #expect(!html.contains("Ohne Tipp. Nach einer falschen Taste kommt er."))
}

@MainActor @Test func trainerSkipAfterSuccessKeepsTheLessonPassed() async throws {
    let (engine, _, _) = try await trainerSetup(); _ = engine.beginTrainer()
    _ = engine.trainerHotkey(); key(engine, "Enter")
    let html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(!html.contains("⌘T überspringen"))
    let footer = try #require(html.components(separatedBy: "<footer data-region=\"footer\">").last)
    #expect(!footer.contains("data-act=\"enter\""))
    key(engine, "t", meta: true)
    #expect(engine.state.trainer?.lesson == 1)
    #expect(engine.state.trainer?.passed == 1)
    for _ in 1..<TrainerLessons.all.count { engine.feed(.trainer) }
    #expect(engine.state.trainer?.passed == 1)
    #expect(Renderer.render(engine.state, engine.snapshot).fullHTML.contains("1 von 10 geschafft"))
}

@MainActor @Test func trainerSuccessShowsNoUndoPromise() async throws {
    let (engine, _, _) = try await trainerSetup()
    _ = engine.beginTrainer(lesson: 2)
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    text(engine, "Blumen pflanzen"); key(engine, "Enter")
    #expect(engine.state.trainer?.success == true)
    #expect(engine.state.toast == nil && !engine.state.undoHint)
    var html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(!html.contains("⌘Z"))
    engine.endTrainer()
    _ = engine.beginTrainer(lesson: 6)
    key(engine, "Backspace", meta: true)
    #expect(engine.state.trainer?.success == true)
    #expect(engine.state.toast == nil && !engine.state.undoHint)
    html = Renderer.render(engine.state, engine.snapshot).fullHTML
    #expect(html.contains("⌘⌫, in der echten Liste nimmt ⌘Z es zurück"))
}
