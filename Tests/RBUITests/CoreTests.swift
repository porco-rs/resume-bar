import Foundation
import Testing
import RBContract
@testable import RBUI

@Test func escapingCoversMarkupCharacters() {
    #expect(h("<script>\"a\" & 'b'</script>") == "&lt;script&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/script&gt;")
}

@Test func copyLookupFillsPlaceholders() {
    #expect(t("m01.title") == "Resume Bar")
    #expect(t("unknown.key") == "unknown.key")
}

@Test func keyMapFollowsFlowsTable() {
    var s = UIState()
    s.screen = .m01
    #expect(KeyMap.events(for: .key(KeyPress(key: "ArrowDown")), state: s) == [.move(1)])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Enter", shift: true)), state: s) == [.shiftEnter])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Enter", alt: true)), state: s) == [.altEnter])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Backspace", meta: true)), state: s) == [.archive])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Backspace", fieldEmpty: true)), state: s) == [.backspaceEmpty])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Backspace", fieldEmpty: false)), state: s) == [])
    #expect(KeyMap.events(for: .key(KeyPress(key: "c", meta: true, hasSelection: true)), state: s) == [])
    #expect(KeyMap.events(for: .key(KeyPress(key: "c", meta: true)), state: s) == [.copy])
    #expect(KeyMap.events(for: .key(KeyPress(key: "w", meta: true, shift: true)), state: s) == [.cleanup])
    #expect(KeyMap.events(for: .key(KeyPress(key: "/", meta: true)), state: s) == [.help])
    #expect(KeyMap.events(for: .doubleSelect("cc_x"), state: s) == [.doubleSelect("cc_x")])
    s.screen = .m02
    s.recording = .popover
    #expect(KeyMap.events(for: .key(KeyPress(key: " ", meta: true, shift: true)), state: s) == [.recordCombo("⇧⌘Space")])
}

@Test func everyFixtureLoadsAndRenders() throws {
    for entry in try FixtureHarness.entries() {
        let (s, snap) = try FixtureHarness.load(entry.key)
        let r = Renderer.render(s, snap)
        // M01-O1 (help) is a layer inside the M01 popover, not a screen of its own.
        #expect(r.screen.rawValue == (entry.screen == "M01-O1" ? "M01" : entry.screen), "\(entry.key)")
        #expect(r.fullHTML.contains("data-screen") || r.screen == .m00 || r.screen == .m02, "\(entry.key)")
    }
}

@Test func replayStepsMapToEvents() {
    #expect(UIEvent.replay(["select", "cc_1"]) == .select("cc_1"))
    #expect(UIEvent.replay(["type", "pp blog"]) == .type("pp blog"))
    #expect(UIEvent.replay(["setEdit", "x"]) == .setEdit("x"))
    #expect(UIEvent.replay(["panelSave"]) == .panelSave)
}

@Test func helpShortcutSupportsUSAndGermanLayouts() {
    var state = UIState()
    state.screen = .m01
    #expect(KeyMap.events(for: .key(.init(key: "/", meta: true)), state: state) == [.help])
    #expect(KeyMap.events(for: .key(.init(key: "?", meta: true, shift: true)), state: state) == [.help])
    #expect(KeyMap.events(for: .key(.init(key: "7", code: "Digit7", meta: true, shift: true)), state: state) == [.help])
    #expect(KeyMap.events(for: .key(.init(key: "7", code: "Digit7", meta: true)), state: state).isEmpty)
}

@Test func escapeSkipsPermissionWithoutRequest() throws {
    var (state, snapshot) = try FixtureHarness.load("M00.berechtigung")
    snapshot.permissions.accessibility = false
    let events = KeyMap.events(for: .key(.init(key: "Escape")), state: state)
    #expect(events == [.onboardingSkip])
    #expect(Reducer.reduce(&state, try #require(events.first), snapshot).isEmpty)
    #expect(state.onboarding == .eingerichtet)
}

@Test func failedPanelSaveKeepsEditorOpen() throws {
    var (state, snapshot) = try FixtureHarness.load("M01-S1.benennen")
    let id = try #require(state.panel?.sessionId)
    _ = Reducer.reduce(&state, .panelSet("Draft"), snapshot)
    _ = Reducer.reduce(&state, .panelSave, snapshot)
    _ = Reducer.reduce(&state, .result(.saveFailed(sessionId: id)), snapshot)
    #expect(state.panel?.done == false)
    #expect(state.panel?.text == "Draft")
    #expect(state.toast?.kind == .error)
}

@Test func missingFolderToastRendersPathAndCopiedCommand() throws {
    var (state, snapshot) = try FixtureHarness.load("M01.kontext")
    _ = Reducer.reduce(&state, .result(.folderMissing(path: "/missing<&")), snapshot)
    #expect(state.toast?.text == "Ordner nicht gefunden: /missing<&\nBefehl kopiert.")
    let html = Renderer.render(state, snapshot).fullHTML
    #expect(html.contains("Ordner nicht gefunden: /missing&lt;&amp;"))
    #expect(html.contains("Befehl kopiert."))
}

@Test func trainerShortcutIsAvailableFromHelpAndCompletedSetup() {
    var state = UIState()
    state.help = true
    #expect(KeyMap.events(for: .key(.init(key: "t", meta: true)), state: state) == [.trainer])
    #expect(KeyMap.events(for: .action("trainer", arg: nil), state: state) == [.trainer])
    state.screen = .m00
    #expect(KeyMap.events(for: .key(.init(key: "t", meta: true)), state: state).isEmpty)
    state.onboarding = .eingerichtet
    #expect(KeyMap.events(for: .key(.init(key: "t", meta: true)), state: state) == [.trainer])
}
