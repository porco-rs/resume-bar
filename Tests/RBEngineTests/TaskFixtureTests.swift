import Foundation
import Testing
import RBContract
@testable import RBEngine

@MainActor
@Test func v2FixtureLoadsAndReplaysTaskMode() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let fixture = try FixtureServices(fixture: url)
    let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
    await engine.start()
    let update = engine.popoverWillOpen(context: fixture.snapshot.context, mode: .ziel)
    #expect(engine.state.listMode.rawValue == "ziel")
    #expect(engine.snapshot.entries.contains { entry in !engine.snapshot.sessions.contains(where: { $0.entryId == entry.id }) })
    #expect(update.regions.contains { $0.first == "body" && $0.last?.contains("tool task") == true })
    let replay = try engine.replayFixture(data: Data(contentsOf: url), snapshot: fixture.snapshot)
    #expect(engine.state.listMode.rawValue == "ziel")
    #expect(replay.regions.contains { $0.first == "body" && $0.last?.contains("tool task") == true })
}

@MainActor
@Test func taskShortcutOpensTaskModeAndNormalOpenReturnsToResume() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json"))
    let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
    await engine.start()
    _ = engine.popoverWillOpen(context: nil, mode: .ziel)
    #expect(engine.state.listMode == .ziel)
    _ = engine.popoverWillOpen(context: nil)
    #expect(engine.state.listMode == .resume)
}

@MainActor
@Test func taskFixtureReplayKeepsAndStartsEntries() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["aufgabe-neu", "aufgabe-gemerkt", "aufgabe-gestartet"] {
        let url = root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.\(name).json")
        let fixture = try FixtureServices(fixture: url)
        let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
        await engine.start()
        _ = try engine.replayFixture(data: Data(contentsOf: url), snapshot: fixture.snapshot)
        if name == "aufgabe-neu" {
            #expect(engine.state.selectedId == nil)
            #expect(engine.state.chips.contains { $0.kind == .deadline })
        } else if name == "aufgabe-gemerkt" {
            #expect(engine.snapshot.entries.contains { $0.title == "Preisliste-Scanner AT" })
            #expect(engine.state.selectedId == engine.snapshot.entries.first(where: { $0.title == "Preisliste-Scanner AT" }).map { "e:" + $0.id })
        } else {
            #expect(engine.state.listMode == .resume)
            #expect(engine.snapshot.sessions.contains { $0.entryId == "e_t3" && $0.live.running })
        }
    }
}

@MainActor
@Test func taskEditMirrorUpdatesWithoutReplacingInput() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json"))
    let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
    await engine.start()
    _ = engine.popoverWillOpen(context: fixture.snapshot.context, mode: .ziel)
    let edit = engine.handle(.key(.init(key: "d", meta: true)))
    let names = edit.regions.map { $0[0] }
    #expect(try #require(names.firstIndex(of: "body")) < #require(names.firstIndex(of: "emirror")))
    let typed = engine.handle(.text(field: "e", value: "fr"))
    #expect(!typed.regions.contains { $0[0] == "body" })
    #expect(typed.regions.contains { $0[0] == "emirror" && $0[1] == "fr<span class=\"ghost\"></span>" })
}

@MainActor
@Test func editToastVisibleWhileEditing() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try FixtureServices(fixture: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json"))
    let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
    await engine.start()
    let open = engine.popoverWillOpen(context: fixture.snapshot.context, mode: .ziel)
    #expect(open.regions.contains { $0[0] == "body" && $0[1].contains("data-region=\"toast\"") })
    _ = engine.handle(.key(.init(key: "d", meta: true)))
    _ = engine.handle(.text(field: "e", value: "blabla"))
    let error = engine.handle(.key(.init(key: "Enter", field: "e")))
    #expect(engine.state.mode == .edit)
    #expect(!error.regions.contains { $0[0] == "body" })
    #expect(error.regions.contains { $0[0] == "toast" && $0[1].contains("blabla") && $0[1].contains("kein Datum") })
    let cancel = engine.handle(.key(.init(key: "Escape", field: "e")))
    #expect(cancel.regions.contains { $0[0] == "toast" && $0[1].isEmpty })
    _ = engine.handle(.key(.init(key: "d", meta: true)))
    let entryID = try #require(engine.state.editEntryId)
    _ = engine.handle(.text(field: "e", value: "10.12.26"))
    _ = engine.handle(.key(.init(key: "Enter", field: "e")))
    for _ in 0..<100 where engine.snapshot.entry(entryID)?.deadline != "2026-12-10" {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(engine.snapshot.entry(entryID)?.deadline == "2026-12-10")
}
