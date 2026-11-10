import Carbon.HIToolbox
import Foundation
import RBContract
import Testing
@testable import RBPlatform

private func runners(bundle: String? = nil, output: String? = nil, cwd: String? = nil,
                     trusted: Bool = false, selection: String? = nil,
                     ghostty: PermissionState = .unknown, terminal: PermissionState = .unknown) -> PlatformRunners {
    PlatformRunners(frontmost: { bundle.map { ($0, 42) } }, script: { _ in output }, shellCWD: { _ in cwd },
                    selection: { _ in selection }, accessibility: { trusted },
                    automation: { $0 == .ghostty ? ghostty : terminal }, requestAccessibility: {})
}

@Test func ghosttyContext() async {
    let platform = SystemPlatform(runners: runners(bundle: "com.mitchellh.ghostty", output: "/project\u{1f}ttys002\n"))
    #expect(await platform.frontmostContext() == Context(projectId: nil, source: .ghostty, cwd: "/project", windowIndex: 1, tty: "ttys002"))
}
@Test func terminalContext() async {
    let platform = SystemPlatform(runners: runners(bundle: "com.apple.Terminal", output: "/dev/ttys001", cwd: "/work"))
    #expect(await platform.frontmostContext() == Context(projectId: nil, source: .terminal, cwd: "/work", windowIndex: 1, tty: "ttys001"))
}
@Test func otherAppHasEmptyContext() async {
    let platform = SystemPlatform(runners: runners(bundle: "org.example.editor", output: "/ignored"))
    #expect(await platform.frontmostContext() == Context(projectId: nil, source: nil, cwd: nil, windowIndex: nil))
}
@Test func timeoutHasNoCWD() async {
    let platform = SystemPlatform(runners: runners(bundle: "com.mitchellh.ghostty", output: nil))
    #expect(await platform.frontmostContext() == Context(projectId: nil, source: .ghostty, cwd: nil, windowIndex: nil))
}
@Test func processTimeoutTerminatesRunner() async {
    let start = ContinuousClock.now
    let result = await Task.detached { runCommand(executable: "/bin/sleep", arguments: ["3"], timeout: .milliseconds(300)) }.value
    #expect(result == nil)
    #expect(start.duration(to: .now) < .seconds(2))
}
@Test func selectionRequiresPermissionAndTerminal() async {
    let denied = SystemPlatform(runners: runners(bundle: "com.apple.Terminal", selection: "selected"))
    let allowed = SystemPlatform(runners: runners(bundle: "com.apple.Terminal", trusted: true, selection: "selected"))
    let other = SystemPlatform(runners: runners(bundle: "editor", trusted: true, selection: "selected"))
    #expect(await denied.selectedText() == nil)
    #expect(await allowed.selectedText() == "selected")
    #expect(await other.selectedText() == nil)
}
@Test func permissionStates() async {
    let platform = SystemPlatform(runners: runners(trusted: true, ghostty: .granted, terminal: .denied))
    let permissions = await platform.permissions()
    #expect(permissions.accessibility)
    #expect(permissions.automation.ghostty == .granted)
    #expect(permissions.automation.terminal == .denied)
    #expect(permissionState(noErr) == .granted)
    #expect(permissionState(OSStatus(errAEEventNotPermitted)) == .denied)
    #expect(permissionState(-12345) == .unknown)
}
private let uuid = "12345678-1234-1234-1234-123456789abc"
@Test func explicitSessionCommands() {
    for command in ["codex resume", "codex --resume"] {
        let result = SessionIdParser.parse("\(command) \(uuid)", commands: Settings.defaults.commands, known: { _ in false })
        #expect(result?.0 == .codex); #expect(result?.1 == uuid)
    }
    for command in ["claude --resume", "claude -r"] {
        let result = SessionIdParser.parse("\(command) \(uuid)", commands: Settings.defaults.commands, known: { _ in false })
        #expect(result?.0 == .claude); #expect(result?.1 == uuid)
    }
}
@Test func knownUUIDFallback() {
    let unknown = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let result = SessionIdParser.parse("\(unknown) \(uuid)", commands: Settings.defaults.commands, known: { $0 == "cc_" + uuid })
    #expect(result?.0 == .claude); #expect(result?.1 == uuid)
    #expect(SessionIdParser.parse(unknown, commands: Settings.defaults.commands, known: { _ in false }) == nil)
}
@Test func combosRoundTrip() {
    for text in ["⇧⌘Space", "⌃⌥⇧⌘R", "⌘0", "⌥Return", "⌘←", "⌘→", "⌘↑", "⌘↓"] {
        let combo = HotkeyCombo(text)
        #expect(combo != nil)
        #expect(combo.flatMap { HotkeyCombo($0.description) } == combo)
    }
    #expect(HotkeyCombo("R") == nil)
    #expect(HotkeyCombo("⌘⌘R") == nil)
    #expect(HotkeyCombo("⌘Bogus") == nil)
}
@Test @MainActor func pinOnlyInTerminals() {
    #expect(HotkeyCenter.pinEnabled(bundleID: "com.mitchellh.ghostty"))
    #expect(HotkeyCenter.pinEnabled(bundleID: "com.apple.Terminal"))
    #expect(!HotkeyCenter.pinEnabled(bundleID: "org.example.editor"))
    #expect(!HotkeyCenter.pinEnabled(bundleID: nil))
}

@Test func ghosttyWithoutTTYRetainsDirectory() async {
    let platform = SystemPlatform(runners: runners(bundle: "com.mitchellh.ghostty", output: "/old\u{1f}"))
    let context = await platform.frontmostContext()
    #expect(context.cwd == "/old"); #expect(context.tty == nil)
}
@Test func terminalTTYSurvivesUnknownDirectory() async {
    let platform = SystemPlatform(runners: runners(bundle: "com.apple.Terminal", output: "/dev/ttys004"))
    let context = await platform.frontmostContext()
    #expect(context.tty == "ttys004"); #expect(context.cwd == nil)
}

@Test func configuredCommandsAndLiteralExecutable() {
    let custom = ToolStrings(codex: "zz resume {id}", claude: "x+y --resume {id}")
    #expect(SessionIdParser.parse("zz resume \(uuid)", commands: custom, known: { _ in false })?.0 == .codex)
    let claudeAlias = ToolStrings(codex: "codex resume {id}", claude: "zz resume {id}")
    #expect(SessionIdParser.parse("zz resume \(uuid)", commands: claudeAlias, known: { _ in false })?.0 == .claude)
    #expect(SessionIdParser.parse("zz resume \(uuid)", commands: Settings.defaults.commands, known: { _ in false }) == nil)
    #expect(SessionIdParser.parse("zz resume \(uuid)", commands: Settings.defaults.commands, known: { $0 == "cc_" + uuid })?.0 == .claude)
    #expect(SessionIdParser.parse("x+y --resume \(uuid)", commands: custom, known: { _ in false })?.0 == .claude)
    #expect(SessionIdParser.parse("xy --resume \(uuid)", commands: custom, known: { _ in false }) == nil)
}
