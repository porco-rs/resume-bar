import Foundation
import Testing
import RBContract
@testable import RBTerminal

private actor FakeRunner: ScriptRunning {
    var scripts: [String] = []
    let version: String
    let ghostty: String
    let terminal: String
    let error: AppleScriptTerminal.Failure?
    let closeResult: String
    init(version: String = "1.4.0", ghostty: String = "0", terminal: String = "0", error: AppleScriptTerminal.Failure? = nil, closeResult: String = "closed") {
        self.version = version; self.ghostty = ghostty; self.terminal = terminal; self.error = error; self.closeResult = closeResult
    }
    func run(_ script: String) async throws -> String {
        scripts.append(script)
        if let error { throw error }
        if script.contains("to return version") { return version }
        if script.contains("set rows to") { return script.contains("Ghostty") ? ghostty : terminal }
        if script.contains("set itemsToCheck") { return closeResult }
        return ""
    }
    func recorded() -> [String] { scripts }
}
private struct FakeProcesses: TerminalProcessSource {
    var byTTY: [String: [TerminalProcess]] = [:]
    func processes(tty: String) async -> [TerminalProcess]? { byTTY[tty] }
}
private func row(_ id: String, _ tty: String, _ cwd: String = "") -> String { "\u{1e}\(id)\u{1f}\(tty)\u{1f}\(cwd)" }
private func process(_ name: String, pid: Int32 = 100, parent: Int32 = 1, session: Int32 = 100, group: Int32 = 100, foreground: Int32 = 100, start: UInt64 = 1, cwd: String? = "/project") -> TerminalProcess {
    TerminalProcess(name: name, cwd: cwd, pid: pid, start: start, parentPID: parent, sessionID: session, processGroupID: group, foregroundGroupID: foreground)
}
private func shell(_ cwd: String = "/project") -> TerminalProcess { process("zsh", cwd: cwd) }
private func login() -> TerminalProcess { process("login", pid: 90, session: 90, group: 90, foreground: 100, cwd: nil) }
private func loginShell(_ name: String = "zsh") -> TerminalProcess { process(name, parent: 90, session: 90) }

@Test func openInExistingDirectoryAndRejectMissing() async throws {
    let folder = URL(fileURLWithPath: "/private/tmp/resume_bar-W2-FIX9-CWD-" + UUID().uuidString + " a'b")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = FakeRunner(); let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses())
    try await terminal.open(app: .ghostty, cwd: folder.path, command: "echo test")
    let expected = AppleScriptTerminal.literal("cd " + terminal.quoted(folder.path) + " && echo test")
    let script = await runner.recorded()[0]
    #expect(script.contains("initial working directory of cfg to " + AppleScriptTerminal.literal(folder.path)))
    #expect(script.contains("initial input of cfg to " + expected + " & linefeed"))
    try await terminal.open(app: .terminal, cwd: folder.path, command: "echo test")
    #expect(await runner.recorded()[1].contains("do script " + expected))
    try await terminal.open(app: .ghostty, cwd: folder.path, command: "")
    #expect(await !runner.recorded()[2].contains("initial input"))
    let missing = folder.appendingPathComponent("missing").path
    await #expect(throws: AppleScriptTerminal.Failure.missingDirectory(missing)) {
        try await terminal.open(app: .ghostty, cwd: missing, command: "echo test")
    }
    #expect(await runner.recorded().count == 3)
}
@Test func ghosttyFocusAndVersion() async throws {
    let runner = FakeRunner(); let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses())
    try await terminal.focus(app: .ghostty, tty: "/dev/ttys000")
    let scripts = await runner.recorded()
    #expect(scripts[1].contains("focus (first terminal whose tty is \"/dev/ttys000\")"))
    #expect(scripts[1].contains("activate"))
    let old = AppleScriptTerminal(runner: FakeRunner(version: "1.3.1"), processes: FakeProcesses())
    await #expect(throws: AppleScriptTerminal.Failure.unsupported) { try await old.focus(app: .ghostty, tty: "ttys001") }
}
@Test func terminalFocusSelectsTabAndWindow() async throws {
    let runner = FakeRunner(); let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses())
    try await terminal.focus(app: .terminal, tty: "ttys009")
    let script = await runner.recorded()[0]
    #expect(script.contains("tty of t is \"/dev/ttys009\""))
    #expect(script.contains("set selected of t to true"))
    #expect(script.contains("set frontmost of w to true"))
}
@Test func countsBothAppsAndSkipsOldGhostty() async {
    let current = AppleScriptTerminal(runner: FakeRunner(ghostty: "2", terminal: "3"), processes: FakeProcesses())
    #expect(await current.openWindowCount() == 5)
    let old = AppleScriptTerminal(runner: FakeRunner(version: "1.3.1", ghostty: "2", terminal: "3"), processes: FakeProcesses())
    #expect(await old.openWindowCount() == 3)
}
@Test func cleanupRequiresEveryTabIdleAndKnownTTYsAreProtected() async {
    let snapshot = "4" + row("a", "ttys001", "/a") + row("b", "ttys002", "/b") + row("b", "ttys003", "/b") + row("c", "ttys004", "/c") + row("d", "ttys005", "/d")
    let ps = FakeProcesses(byTTY: ["ttys001": [shell()], "ttys002": [shell()], "ttys003": [shell(), process("claude", pid: 101)], "ttys004": [shell(), process("server", pid: 102)], "ttys005": [shell()]])
    let terminal = AppleScriptTerminal(runner: FakeRunner(ghostty: snapshot), processes: ps)
    let windows = await terminal.closableWindows(knownTTYs: ["/dev/ttys005"])
    #expect(windows.map(\.windowId) == ["a"])
    #expect(windows[0].cwd == "/a")
}
@Test func terminalCleanupUsesShellDirectoryAndRejectsUnknown() async {
    let ps = FakeProcesses(byTTY: ["ttys001": [shell("/shell-dir")]])
    let terminal = AppleScriptTerminal(runner: FakeRunner(terminal: "2" + row("42", "/dev/ttys001") + row("43", "ttys002")), processes: ps)
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(windows.first?.cwd == "/shell-dir")
}
@Test func oldGhosttyHasNoCleanup() async {
    let terminal = AppleScriptTerminal(runner: FakeRunner(version: "1.3.1", ghostty: "1" + row("id", "ttys001", "/a")), processes: FakeProcesses(byTTY: ["ttys001": [shell()]]))
    #expect(await terminal.closableWindows(knownTTYs: []).isEmpty)
}
@Test func closeRequiresFreshIdleEvidence() async throws {
    let runner = FakeRunner(terminal: "1" + row("42", "/dev/ttys001"))
    let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses(byTTY: ["ttys001": [shell()]]))
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(try await terminal.close(windows) == windows)
    let scripts = await runner.recorded()
    #expect(scripts.last?.contains("set w to window id 42") == true)
    #expect(scripts.last?.contains("tty of item 1") == true)
    #expect(scripts.last?.contains("close w saving no") == true)
    #expect(try await terminal.close(windows).isEmpty)
    #expect(await runner.recorded().count == scripts.count)
}
@Test func ghosttyCloseAcceptsFullTTYPath() async throws {
    let runner = FakeRunner(ghostty: "1" + row("id", "/dev/ttys000", "/a"))
    let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses(byTTY: ["ttys000": [shell()]]))
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(try await terminal.close(windows) == windows)
    let script = try #require(await runner.recorded().last)
    #expect(script.contains("is not \"/dev/ttys000\""))
    #expect(script.contains("close window w"))
}
@Test func ghosttyCloseAcceptsBareTTY() async throws {
    let runner = FakeRunner(ghostty: "1" + row("id", "ttys000", "/a"))
    let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses(byTTY: ["ttys000": [shell()]]))
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(try await terminal.close(windows) == windows)
    let script = try #require(await runner.recorded().last)
    #expect(script.contains("is not \"/dev/ttys000\" and (tty of item 1 of itemsToCheck as text) is not \"ttys000\""))
    #expect(script.contains("close window w"))
}
@Test func closeWithoutEvidenceIsSkipped() async throws {
    let runner = FakeRunner(); let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses())
    #expect(try await terminal.close([TerminalWindow(app: .terminal, windowId: "42", cwd: nil, tty: nil)]).isEmpty)
    #expect(await runner.recorded().isEmpty)
}
@Test func shellOutsideForegroundIsNotIdle() async {
    let p = process("zsh", foreground: 101)
    let terminal = AppleScriptTerminal(runner: FakeRunner(terminal: "1" + row("42", "/dev/ttys001")), processes: FakeProcesses(byTTY: ["ttys001": [p]]))
    #expect(await terminal.closableWindows(knownTTYs: []).isEmpty)
}
@Test func loginAndForegroundZshAreClosable() async throws {
    let runner = FakeRunner(ghostty: "1" + row("id", "ttys001"))
    let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses(byTTY: ["ttys001": [login(), loginShell()]]))
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(windows.first?.cwd == "/project")
    #expect(try await terminal.close(windows) == windows)
}
@Test func loginShellWithVimIsBusy() async {
    let ps = [login(), loginShell(), process("vim", pid: 101, parent: 100, session: 90, group: 101, foreground: 101)]
    let terminal = AppleScriptTerminal(runner: FakeRunner(ghostty: "1" + row("id", "ttys001", "/a")), processes: FakeProcesses(byTTY: ["ttys001": ps]))
    #expect(await terminal.closableWindows(knownTTYs: []).isEmpty)
}
@Test func loginShellWithBackgroundJobIsBusy() async {
    let ps = [login(), loginShell(), process("sleep", pid: 101, parent: 100, session: 90, group: 101)]
    let terminal = AppleScriptTerminal(runner: FakeRunner(ghostty: "1" + row("id", "ttys001", "/a")), processes: FakeProcesses(byTTY: ["ttys001": ps]))
    #expect(await terminal.closableWindows(knownTTYs: []).isEmpty)
}
@Test func foregroundSessionLeaderShellIsClosable() async {
    let terminal = AppleScriptTerminal(runner: FakeRunner(ghostty: "1" + row("id", "ttys001", "/a")), processes: FakeProcesses(byTTY: ["ttys001": [shell()]]))
    #expect(await terminal.closableWindows(knownTTYs: []).count == 1)
}
@Test func loginAndForegroundBashAreClosable() async {
    let terminal = AppleScriptTerminal(runner: FakeRunner(terminal: "1" + row("42", "ttys001")), processes: FakeProcesses(byTTY: ["ttys001": [loginShell("bash"), login()]]))
    #expect(await terminal.closableWindows(knownTTYs: []).count == 1)
}
@Test func invalidLoginRelationshipsAreBusy() async {
    let lists = [[login(), process("zsh", parent: 91, session: 90)],
                 [process("login", pid: 90, session: 91), loginShell()],
                 [process("zsh", session: 90)]]
    for list in lists {
        let terminal = AppleScriptTerminal(runner: FakeRunner(ghostty: "1" + row("id", "ttys001", "/a")), processes: FakeProcesses(byTTY: ["ttys001": list]))
        #expect(await terminal.closableWindows(knownTTYs: []).isEmpty)
    }
}
@Test func newJobPreventsClosingPreviouslyIdleLoginShell() async throws {
    actor ChangingProcesses: TerminalProcessSource {
        var calls = 0
        func processes(tty: String) async -> [TerminalProcess]? {
            calls += 1
            return calls == 1 ? [login(), loginShell()] : [login(), loginShell(), process("vim", pid: 101, parent: 100, session: 90)]
        }
    }
    let runner = FakeRunner(ghostty: "1" + row("id", "ttys001", "/a"))
    let terminal = AppleScriptTerminal(runner: runner, processes: ChangingProcesses())
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(try await terminal.close(windows).isEmpty)
    #expect(!(await runner.recorded()).contains { $0.contains("close window w") })
}
@Test func changedProcessPreventsClose() async throws {
    actor ChangingProcesses: TerminalProcessSource {
        var n = 0
        func processes(tty: String) async -> [TerminalProcess]? {
            n += 1
            return [process("zsh", start: UInt64(n), cwd: "/a")]
        }
    }
    let runner = FakeRunner(terminal: "1" + row("42", "/dev/ttys001"))
    let terminal = AppleScriptTerminal(runner: runner, processes: ChangingProcesses())
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(try await terminal.close(windows).isEmpty)
    #expect(!(await runner.recorded()).contains { $0.contains("close w saving no") })
}
@Test func closeReportsScriptRevalidationSkip() async throws {
    let runner = FakeRunner(terminal: "1" + row("42", "/dev/ttys001"), closeResult: "skipped")
    let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses(byTTY: ["ttys001": [shell()]]))
    let windows = await terminal.closableWindows(knownTTYs: [])
    #expect(windows.count == 1)
    #expect(try await terminal.close(windows).isEmpty)
    let script = try #require(await runner.recorded().last)
    #expect(script.contains("then return \"skipped\""))
    #expect(script.contains("return \"closed\""))
}
@Test func quotingAndAppleScriptEscaping() async throws {
    let runner = FakeRunner(); let terminal = AppleScriptTerminal(runner: runner, processes: FakeProcesses())
    let text = "a'b\"$(test);\nnext\\end"
    #expect(terminal.quoted(text) == "'a'\\''b\"$(test);\nnext\\end'")
    #expect(AppleScriptTerminal.literal(text) == "\"a'b\\\"$(test);\" & linefeed & \"next\\\\end\"")
    try await terminal.open(app: .terminal, cwd: "/tmp", command: "echo " + terminal.quoted(text))
    #expect(await runner.recorded()[0].contains(" & linefeed & "))
}
@Test func errorsPreserveMessageAndMapAutomationDenial() async {
    #expect(OsaScriptRunner.failure("not permitted (-1743)") == .automationDenied("not permitted (-1743)"))
    #expect(OsaScriptRunner.failure("bad script (-1708)") == .script("bad script (-1708)"))
    let terminal = AppleScriptTerminal(runner: FakeRunner(error: .script("bad script")), processes: FakeProcesses())
    await #expect(throws: AppleScriptTerminal.Failure.script("bad script")) { try await terminal.open(app: .terminal, cwd: "/tmp", command: "") }
}
