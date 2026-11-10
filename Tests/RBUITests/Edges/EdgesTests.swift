import Foundation
import Testing
import RBContract
@testable import RBUI

@Test func setupNamesTheStartFolder() throws {
    var (state, snapshot) = try FixtureHarness.load("M00.berechtigung")
    state.onboarding = .eingerichtet
    snapshot.settings.startFolder = "~/Test & Ziele"
    let html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("Ziele ohne Projekt starten in ~/Test &amp; Ziele"))
    #expect(html.contains("ändern in den Einstellungen (⌘,)"))
    let terminal = try #require(html.range(of: "Terminal:"))
    let folder = try #require(html.range(of: "Ziele ohne Projekt starten"))
    let hotkey = try #require(html.range(of: "Kürzel"))
    #expect(terminal.lowerBound < folder.lowerBound && folder.lowerBound < hotkey.lowerBound)
    #expect(!html.contains("rb und MCP"))
    snapshot.settings.startFolder = nil
    let automatic = try #require(EdgesArea.regions(state, snapshot)["page"])
    let path = Logic.startFolder(settings: snapshot.settings, projects: snapshot.projects, home: NSHomeDirectory())
    let displayed = path == NSHomeDirectory() ? "~" : (path.hasPrefix(NSHomeDirectory() + "/") ? "~" + path.dropFirst(NSHomeDirectory().count) : path)
    #expect(automatic.contains("Ziele ohne Projekt starten in \(h(displayed))"))
}

@Test func settingsChangeTheStartFolder() throws {
    var (state, snapshot) = try FixtureHarness.load("M02.standard")
    snapshot.settings.startFolder = nil
    snapshot.projects = []
    let html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("data-setting=\"startFolder\""))
    #expect(html.contains("value=\"\" placeholder=\"~\""))
    #expect(html.contains("Ziele ohne Projekt starten hier · leer = Ordner mit den meisten Projekten"))
    let defaultTool = try #require(html.range(of: "Standardwerkzeug"))
    let folder = try #require(html.range(of: "Startordner"))
    let terminal = try #require(html.range(of: "Terminal</div>"))
    #expect(defaultTool.lowerBound < folder.lowerBound && folder.lowerBound < terminal.lowerBound)
    #expect(Reducer.reduce(&state, .setSetting(path: "startFolder", value: "~/Ziele"), snapshot) == [.updateSettings(.startFolder("~/Ziele"))])
    #expect(Reducer.reduce(&state, .setSetting(path: "startFolder", value: ""), snapshot) == [.updateSettings(.startFolder(nil))])
    snapshot.settings.startFolder = "/tmp/A & B"
    let configured = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(configured.contains("value=\"/tmp/A &amp; B\""))
    #expect(configured.contains("AI-Zugriff"))
    #expect(Reducer.reduce(&state, .setSetting(path: "aiEnabled", value: "false"), snapshot) == [.updateSettings(.aiEnabled(false))])
    state.rbLink = .taken
    #expect(try #require(EdgesArea.regions(state, snapshot)["page"]).contains("~/.local/bin/rb ist belegt, rb nicht verknüpft"))
}

@Test func settingsShowTheNewGoalHotkey() throws {
    var (state, snapshot) = try FixtureHarness.load("M02.standard")
    snapshot.settings.hotkeys.task = "⌃⌘T"
    let html = try #require(EdgesArea.regions(state, snapshot)["page"])
    let popover = try #require(html.range(of: "Popover öffnen"))
    let goal = try #require(html.range(of: "Neues Ziel"))
    let pin = try #require(html.range(of: "Strang benennen"))
    #expect(popover.lowerBound < goal.lowerBound && goal.lowerBound < pin.lowerBound)
    #expect(html.contains("⌃⌘T</span><button type=\"button\" class=\"lnk\" data-act=\"record\" data-arg=\"task\">ändern</button>"))
    #expect(html.contains("öffnet das Popover direkt im Modus ziel"))
    #expect(Reducer.reduce(&state, .record(.task), snapshot) == [.recordHotkey(.task)])
    #expect(Reducer.reduce(&state, .recordCombo("⌘T"), snapshot) == [.updateSettings(.hotkey(.task, "⌘T"))])
}

@Test func panelEventsAndStableInput() throws {
    var (s, snap) = try FixtureHarness.load("M01-S1.benennen")
    let id = try #require(s.panel?.sessionId)
    let session = try #require(snap.session(id))
    let before = Renderer.render(s, snap).region("panel")
    #expect(Reducer.reduce(&s, .panelSet("  neues Thema  "), snap).isEmpty)
    #expect(!s.selectAll)
    #expect(Renderer.render(s, snap).region("panel") == before)
    #expect(Renderer.render(s, snap).region("pmirror") == "  neues Thema  ")
    #expect(Reducer.reduce(&s, .panelSave, snap) == [.panelName(sessionId: id, title: "neues Thema")])
    #expect(s.panel?.done == false)
    _ = Reducer.reduce(&s, .result(.topicSet(sessionId: id)), snap)
    #expect(s.panel?.done == true && s.undoHint)
    #expect(Reducer.reduce(&s, .panelSave, snap).isEmpty)
    #expect(Reducer.reduce(&s, .panelUndo, snap) == [.undo])
    #expect(s.panel?.done == false)
    _ = Reducer.reduce(&s, .panelSet(" \n "), snap)
    #expect(Reducer.reduce(&s, .panelSave, snap) == [.panelName(sessionId: id, title: Logic.titleOf(snap, try #require(snap.entry(session.entryId))))])
    #expect(Reducer.reduce(&s, .panelCancel, snap) == [.closePopover])
    #expect(s.toast == Note(kind: .ok, text: t("m01s1.closed")))
}

@Test func onboardingEvents() throws {
    var (s, snap) = try FixtureHarness.load("M00.berechtigung")
    #expect(Reducer.reduce(&s, .allowAx, snap) == [.requestAccessibility])
    #expect(Reducer.reduce(&s, .onboardingNext, snap) == [.requestAccessibility])
    #expect(s.onboarding == .berechtigung)
    snap.permissions.accessibility = true
    #expect(Reducer.reduce(&s, .onboardingNext, snap).isEmpty)
    #expect(s.onboarding == .eingerichtet)
    #expect(Reducer.reduce(&s, .onboardingNext, snap).isEmpty)
    #expect(s.screen == .m01)
}

@Test func settingsEvents() throws {
    var (s, snap) = try FixtureHarness.load("M02.standard")
    #expect(Reducer.reduce(&s, .record(.pin), snap) == [.recordHotkey(.pin)])
    #expect(s.recording == .pin)
    #expect(Reducer.reduce(&s, .recordCombo("⌘X"), snap) == [.updateSettings(.hotkey(.pin, "⌘X"))])
    #expect(s.recording == nil)
    #expect(Reducer.reduce(&s, .recordCombo("⌘Y"), snap).isEmpty)
    _ = Reducer.reduce(&s, .record(.popover), snap)
    #expect(Reducer.reduce(&s, .record(nil), snap).isEmpty)
    #expect(s.recording == nil)
    #expect(KeyMap.events(for: .action("setDefaultTool", arg: "claude"), state: s) == [.setSetting(path: "defaultTool", value: "claude")])
    #expect(Reducer.reduce(&s, .setSetting(path: "defaultTool", value: "claude"), snap) == [.updateSettings(.defaultTool(.claude))])
    #expect(Reducer.reduce(&s, .setTerminal(.terminal), snap) == [.updateSettings(.defaultTerminal(.terminal))])
    #expect(Reducer.reduce(&s, .setSetting(path: "commands.codex", value: "cx"), snap) == [.updateSettings(.command(.codex, "cx"))])
    #expect(Reducer.reduce(&s, .setSetting(path: "commands.claude", value: "cc"), snap) == [.updateSettings(.command(.claude, "cc"))])
    #expect(Reducer.reduce(&s, .setSetting(path: "archiveDays", value: "5"), snap) == [.updateSettings(.archiveDays(5))])
    #expect(Reducer.reduce(&s, .setSetting(path: "cleanupThreshold", value: "4"), snap) == [.updateSettings(.cleanupThreshold(4))])
    #expect(Reducer.reduce(&s, .setSetting(path: "archiveDays", value: "oops"), snap).isEmpty)
    #expect(Reducer.reduce(&s, .setSetting(path: "unknown", value: "4"), snap).isEmpty)
}


@Test func m00AiRowFollowsAccessAndLink() throws {
    var (state, snapshot) = try FixtureHarness.load("M00.berechtigung")
    state.onboarding = .eingerichtet; snapshot.settings.ai.enabled = true
    let original = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(original.contains("<span class=\"g ok\" aria-hidden=\"true\">✓</span><div class=\"o-txt\"><div class=\"o-t\">rb eingerichtet</div><div class=\"o-s\">Claude Code und Codex dürfen auf Nachfrage Ziele im eigenen Projekt lesen und schreiben · ~/.local/bin/rb</div>"))
    state.rbLink = .taken
    let taken = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(taken.contains("rb nicht eingerichtet") && taken.contains("~/.local/bin/rb ist belegt"))
    #expect(taken.contains("<span class=\"g\" aria-hidden=\"true\">○</span>"))
    state.rbLink = .failed
    #expect(try #require(EdgesArea.regions(state, snapshot)["page"]).contains("~/.local/bin/rb ließ sich nicht anlegen"))
    state.rbLink = .unreachable; state.rbOtherCommands = ["/one/rb"]
    let unreachable = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(unreachable.contains("rb nicht eingerichtet") && unreachable.contains("rb erreicht die App nicht, der Zugang ließ sich nicht öffnen"))
    #expect(unreachable.contains("<span class=\"g\" aria-hidden=\"true\">○</span>") && !unreachable.contains("auch /one/rb"))
    state.rbLink = .notRemoved
    snapshot.settings.ai.enabled = false
    let off = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(off.contains("AI-Zugriff aus") && off.contains("einschalten in den Einstellungen (⌘,)"))
    snapshot.settings.ai.enabled = true; state.rbLink = .linked; state.rbOtherCommands = ["/one/rb", "/two/rb"]
    #expect(try #require(EdgesArea.regions(state, snapshot)["page"]).contains("auch /one/rb und /two/rb heißt rb, die Reihenfolge im PATH entscheidet"))
    state.rbOtherCommands = []
    #expect(try #require(EdgesArea.regions(state, snapshot)["page"]) == original)
}
@Test func m02AiHintNamesFailureAndOtherCommands() throws {
    var (state, snapshot) = try FixtureHarness.load("M02.standard")
    snapshot.settings.ai.enabled = true; state.rbLink = .failed; state.rbOtherCommands = ["/one/rb"]
    var html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("~/.local/bin/rb ließ sich nicht anlegen") && !html.contains("auch /one/rb"))
    state.rbLink = .taken; state.rbOtherCommands = ["/one/rb", "/two/rb"]
    html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("~/.local/bin/rb ist belegt") && html.contains("auch /one/rb und /two/rb heißt rb"))
    state.rbLink = .unreachable
    html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("rb erreicht die App nicht, der Zugang ließ sich nicht öffnen") && !html.contains("auch /one/rb"))
    state.rbLink = .notRemoved; snapshot.settings.ai.enabled = false
    html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("~/.local/bin/rb ließ sich nicht entfernen") && !html.contains("auch /one/rb"))
}

@Test func firstRunTerminalsAndAIChoice() throws {
    #expect(Logic.firstRunTerminals(ghosttyInstalled: true) == .init(default: .ghostty, alternate: .terminal))
    #expect(Logic.firstRunTerminals(ghosttyInstalled: false) == .init(default: .terminal, alternate: .terminal))
    var (state, snapshot) = try FixtureHarness.load("M00.eingerichtet")
    state.onboarding = .eingerichtet
    state.rbLink = .linked
    snapshot.settings.ai.enabled = true
    var html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("im Terminal prüfen: command -v rb"))
    #expect(html.contains("data-act=\"setAI\" data-arg=\"false\">ausschalten"))
    let events = KeyMap.events(for: .action("setAI", arg: "false"), state: state)
    #expect(events == [.setSetting(path: "aiEnabled", value: "false")])
    #expect(Reducer.reduce(&state, try #require(events.first), snapshot) == [.updateSettings(.aiEnabled(false))])
    snapshot.settings.ai.enabled = false
    html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("data-act=\"setAI\" data-arg=\"true\">einschalten"))
    #expect(!html.contains("im Terminal prüfen: command -v rb"))
}

@Test func onboardingDoesNotPromiseAnUnavailableTerminal() throws {
    var (state, snapshot) = try FixtureHarness.load("M00.eingerichtet")
    state.onboarding = .eingerichtet
    snapshot.settings.terminal = Logic.firstRunTerminals(ghosttyInstalled: false)
    let html = try #require(EdgesArea.regions(state, snapshot)["page"])
    #expect(html.contains("Terminal: Terminal.app"))
    #expect(html.contains("Ghostty geht auch, wenn es installiert ist"))
    #expect(!html.contains("⌥↵ öffnet stattdessen Ghostty"))
}
