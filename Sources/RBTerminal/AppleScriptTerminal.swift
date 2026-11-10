import Foundation
import RBContract

protocol ScriptRunning: Sendable {
    func run(_ script: String) async throws -> String
}

struct OsaScriptRunner: ScriptRunning {
    func run(_ script: String) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { throw AppleScriptTerminal.Failure.script(error.localizedDescription) }
            async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            let (output, errors) = await (stdout, stderr)
            let message = String(decoding: errors, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw Self.failure(message)
            }
            var text = String(decoding: output, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }.value
    }
    static func failure(_ message: String) -> AppleScriptTerminal.Failure {
        message.contains("-1743") ? .automationDenied(message) : .script(message)
    }
}

struct TerminalProcess: Sendable, Equatable {
    let name: String
    let cwd: String?
    let pid: Int32
    let start: UInt64
    let parentPID: Int32
    let sessionID: Int32
    let processGroupID: Int32
    let foregroundGroupID: Int32
}

protocol TerminalProcessSource: Sendable {
    /// nil means that the TTY could not be inspected reliably.
    func processes(tty: String) async -> [TerminalProcess]?
}

private struct IdleEvidence: Sendable {
    let ttys: [String]
    let processes: [[TerminalProcess]]
}
private actor EvidenceStore {
    private var values: [String: IdleEvidence] = [:]
    func set(_ key: String, _ value: IdleEvidence) { values[key] = value }
    func take(_ key: String) -> IdleEvidence? { values.removeValue(forKey: key) }
    func clear() { values.removeAll() }
}

public struct AppleScriptTerminal: TerminalControlling {
    public enum Failure: Error, Equatable {
        case missingDirectory(String)
        case script(String)
        case automationDenied(String)
        case unsupported
    }

    private let runner: any ScriptRunning
    private let processes: any TerminalProcessSource
    private let evidence = EvidenceStore()
    public init() { self.init(runner: OsaScriptRunner(), processes: LibprocSource()) }
    init(runner: any ScriptRunning, processes: any TerminalProcessSource) {
        self.runner = runner
        self.processes = processes
    }

    public func open(app: TerminalApp, cwd: String, command: String) async throws {
        let exists = await Task.detached {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: cwd, isDirectory: &directory) && directory.boolValue
        }.value
        guard exists else { throw Failure.missingDirectory(cwd) }
        let script: String
        switch app {
        case .ghostty:
            script = """
            tell application "Ghostty"
              set cfg to new surface configuration
              set initial working directory of cfg to \(Self.literal(cwd))
              \(command.isEmpty ? "" : "set initial input of cfg to \(Self.literal("cd " + quoted(cwd) + " && " + command)) & linefeed")
              new window with configuration cfg
              activate
            end tell
            """
        case .terminal:
            let line = "cd " + quoted(cwd) + (command.isEmpty ? "" : " && " + command)
            script = """
            tell application "Terminal"
              do script \(Self.literal(line))
              activate
            end tell
            """
        }
        _ = try await runner.run(script)
    }

    public func focus(app: TerminalApp, tty: String) async throws {
        let tty = Self.normalizedTTY(tty)
        let script: String
        switch app {
        case .ghostty:
            guard try await ghosttySupported() else { throw Failure.unsupported }
            script = """
            tell application "Ghostty"
              focus (first terminal whose tty is \(Self.literal("/dev/" + tty)))
              activate
            end tell
            """
        case .terminal:
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is \(Self.literal("/dev/" + tty)) then
                    set selected of t to true
                    set index of w to 1
                    set frontmost of w to true
                    activate
                    return
                  end if
                end repeat
              end repeat
              error "Terminal tab not found"
            end tell
            """
        }
        _ = try await runner.run(script)
    }

    public func openWindowCount() async -> Int {
        var total = 0
        for app in [TerminalApp.ghostty, .terminal] {
            if app == .ghostty {
                guard (try? await ghosttySupported()) == true else { continue }
            }
            if let snapshot = try? await snapshot(app) { total += snapshot.count }
        }
        return total
    }

    public func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] {
        await evidence.clear()
        let known = Set(knownTTYs.map(Self.normalizedTTY))
        var result: [TerminalWindow] = []
        for app in [TerminalApp.ghostty, .terminal] {
            if app == .ghostty {
                guard (try? await ghosttySupported()) == true else { continue }
            }
            guard let snapshot = try? await snapshot(app) else { continue }
            for window in snapshot.windows {
                guard !window.tabs.isEmpty else { continue }
                var cwd: String?
                var idle = true
                var identities: [[TerminalProcess]] = []
                var ttys: [String] = []
                for tab in window.tabs {
                    let tty = Self.normalizedTTY(tab.tty)
                    guard !tty.isEmpty, !known.contains(tty), let list = await processes.processes(tty: tty),
                          let shell = Self.idleShell(list) else { idle = false; break }
                    identities.append(list.sorted { $0.pid < $1.pid }); ttys.append(tty)
                    if cwd == nil { cwd = tab.cwd.isEmpty ? shell.cwd : tab.cwd }
                }
                // Undo must be able to reopen the window in its original directory.
                if idle, let cwd, !cwd.isEmpty {
                    await evidence.set(Self.key(app, window.id), IdleEvidence(ttys: ttys, processes: identities))
                    result.append(TerminalWindow(app: app, windowId: window.id, cwd: cwd, tty: window.tabs.first?.tty))
                }
            }
        }
        return result
    }

    public func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] {
        var closed: [TerminalWindow] = []
        for window in windows {
            guard let old = await evidence.take(Self.key(window.app, window.windowId)),
                  let snapshot = try? await snapshot(window.app),
                  let current = snapshot.windows.first(where: { $0.id == window.windowId }),
                  current.tabs.map({ Self.normalizedTTY($0.tty) }) == old.ttys else { continue }
            var valid = true
            for (tty, identity) in zip(old.ttys, old.processes) {
                guard let list = await processes.processes(tty: tty), Self.idleShell(list) != nil,
                      list.sorted(by: { $0.pid < $1.pid }) == identity else { valid = false; break }
            }
            guard valid else { continue }
            let target = window.app == .ghostty ? "Ghostty" : "Terminal"
            let elements = window.app == .ghostty ? "terminals" : "tabs"
            let reference: String
            if window.app == .ghostty { reference = "first window whose id is \(Self.literal(window.windowId))" }
            else {
                guard let id = Int(window.windowId), id > 0 else { continue }
                reference = "window id \(id)"
            }
            let ttyChecks = old.ttys.enumerated().map { index, tty in
                let actual = "(tty of item \(index + 1) of itemsToCheck as text)"
                let pathCheck = "\(actual) is not \(Self.literal("/dev/" + tty))"
                let mismatch = window.app == .ghostty ? "\(pathCheck) and \(actual) is not \(Self.literal(tty))" : pathCheck
                return "if \(mismatch) then return \"skipped\""
            }.joined(separator: "\n  ")
            let closeCommand = window.app == .ghostty ? "close window w" : "close w saving no"
            let script = """
            tell application "\(target)"
              set w to \(reference)
              set itemsToCheck to \(elements) of w
              if (count itemsToCheck) is not \(old.ttys.count) then return "skipped"
              \(ttyChecks)
              \(closeCommand)
              return "closed"
            end tell
            """
            if try await runner.run(script) == "closed" { closed.append(window) }
        }
        return closed
    }

    private static func key(_ app: TerminalApp, _ id: String) -> String { "\(app):\(id)" }

    public func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // AppleScript source literals cannot contain raw line breaks reliably.
    static func literal(_ text: String) -> String {
        text.components(separatedBy: "\n").map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " & linefeed & ")
    }
    static func normalizedTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh"]

    private static func idleShell(_ processes: [TerminalProcess]) -> TerminalProcess? {
        guard (1...2).contains(processes.count),
              let shell = processes.first(where: { shells.contains($0.name) }),
              shell.processGroupID > 0, shell.processGroupID == shell.foregroundGroupID else { return nil }
        if processes.count == 1 {
            return shell.sessionID == shell.pid ? shell : nil
        }
        guard let login = processes.first(where: { $0.name == "login" }),
              login.pid != shell.pid, login.sessionID == login.pid,
              shell.sessionID == login.pid, shell.parentPID == login.pid else { return nil }
        return shell
    }

    private func ghosttySupported() async throws -> Bool {
        let version = try await runner.run("if application \"Ghostty\" is running then\n tell application \"Ghostty\" to return version\nelse\n return \"0\"\nend if")
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        return parts.count == 2 && (parts[0] > 1 || (parts[0] == 1 && parts[1] >= 4))
    }

    private struct Tab { let tty: String; let cwd: String }
    private struct Window { let id: String; var tabs: [Tab] }
    private struct Snapshot { let count: Int; let windows: [Window] }

    // ASCII record and field separators avoid ambiguity with ordinary tabs and newlines in paths.
    private func snapshot(_ app: TerminalApp) async throws -> Snapshot {
        let target = app == .ghostty ? "Ghostty" : "Terminal"
        let elements = app == .ghostty ? "terminals" : "tabs"
        let directory = app == .ghostty ? "working directory of t" : "\"\""
        let script = """
        if application "\(target)" is not running then return "0"
        tell application "\(target)"
          set rows to (count windows) as text
          set recordSep to ASCII character 30
          set fieldSep to ASCII character 31
          repeat with w in windows
            set wid to id of w as text
            repeat with t in \(elements) of w
              set ttyValue to tty of t
              set dirValue to \(directory)
              if ttyValue is missing value then set ttyValue to ""
              if dirValue is missing value then set dirValue to ""
              set ttyValue to ttyValue as text
              set dirValue to dirValue as text
              if wid contains recordSep or wid contains fieldSep or ttyValue contains recordSep or ttyValue contains fieldSep or dirValue contains recordSep or dirValue contains fieldSep then error "Invalid window data"
              set rows to rows & recordSep & wid & fieldSep & ttyValue & fieldSep & dirValue
            end repeat
          end repeat
          return rows
        end tell
        """
        let output = try await runner.run(script)
        let rows = output.components(separatedBy: "\u{1e}")
        guard let first = rows.first, let count = Int(first), count >= 0 else { throw Failure.script("Invalid window snapshot") }
        var windows: [Window] = []
        for row in rows.dropFirst() {
            let fields = row.components(separatedBy: "\u{1f}")
            guard fields.count == 3, !fields[0].isEmpty else { throw Failure.script("Invalid window snapshot") }
            if let index = windows.firstIndex(where: { $0.id == fields[0] }) {
                windows[index].tabs.append(Tab(tty: fields[1], cwd: fields[2]))
            } else {
                windows.append(Window(id: fields[0], tabs: [Tab(tty: fields[1], cwd: fields[2])]))
            }
        }
        return Snapshot(count: count, windows: windows)
    }
}
