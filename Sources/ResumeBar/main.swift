// ResumeBar entry point.
//   ResumeBar                      menu bar app
//   ResumeBar --fixture <file>     app on design fixture data (no terminal or store side effects)
//   ResumeBar --title-stats        prints title diagnostic counts and byte positions only and exits
//   ResumeBar --index-stats        prints counts of the real index, live sessions and windows (metadata only) and exits

import AppKit
import RBContract
import RBIndex
import RBLive
import RBTerminal
import RBStore
import RBEngine

if let index = CommandLine.arguments.firstIndex(of: "--engine-check") {
    guard index + 1 < CommandLine.arguments.count else {
        fputs("Usage: ResumeBar --engine-check <folder>\n", stderr); exit(2)
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    let url = folder.appendingPathComponent("store.sqlite")
    guard url.resolvingSymlinksInPath().standardizedFileURL != SQLiteStore.defaultURL.resolvingSymlinksInPath().standardizedFileURL else {
        fputs("Engine check requires a store copy\n", stderr); exit(2)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        fputs("Engine check failed: Store file missing\n", stderr); exit(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let store = SQLiteStore(databaseURL: url)
            let index = try await SessionIndex().scan(.defaults)
            let live = await LiveMonitor(store: store, readOnly: true, importLegacy: true, countsURL: folder.appendingPathComponent("resume-counts.json")).current()
            let snapshot = try await SnapshotBuilder.build(index: index, store: store, live: live,
                settings: store.loadSettings(), context: nil, windows: Windows(open: 0, closable: 0), ended: [],
                permissions: Permissions(accessibility: false, automation: .init(ghostty: .unknown, terminal: .unknown)), now: Date())
            print(try await SnapshotBuilder.engineCheck(snapshot, links: store.loadLinks(), counts: store.loadResumeCountState()))
            semaphore.signal()
        } catch { fputs("Engine check failed: \(error)\n", stderr); exit(1) }
    }
    semaphore.wait(); exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--migrate-check") {
    guard index + 1 < CommandLine.arguments.count else {
        fputs("Usage: ResumeBar --migrate-check <folder>\n", stderr); exit(2)
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true).appendingPathComponent("store.sqlite")
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { print(try await SQLiteStore(databaseURL: url).migrationCheck()); semaphore.signal() }
        catch { fputs("Migration check failed: \(error)\n", stderr); exit(1) }
    }
    semaphore.wait(); exit(0)
}

if let whereIndex = CommandLine.arguments.firstIndex(of: "--where") {
    guard whereIndex + 1 < CommandLine.arguments.count else {
        fputs("Usage: ResumeBar --where <nativeId>\n", stderr)
        exit(2)
    }
    let nativeId = CommandLine.arguments[whereIndex + 1]
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        if let location = await SessionIndex().whereSession(nativeId) {
            print("project: \(location.projectName)\nresolved cwd: \(location.resolvedCwd)\nstart cwd: \(location.startCwd)\nstart exists: \(location.startExists)")
        } else { print("session not found") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if CommandLine.arguments.contains("--title-stats") {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        print(await SessionIndex().titleStats().plainText)
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if CommandLine.arguments.contains("--settings-stats") {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let stored = try await SQLiteStore().readOnlySettings()
            let settings = stored ?? .defaults
            func firstWord(_ command: String) -> String { command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }
            print("settings: \(stored == nil ? "default" : "stored")")
            print("commands: \(firstWord(settings.commands.codex)) · \(firstWord(settings.commands.claude))")
            semaphore.signal()
        } catch { fputs("Settings check failed\n", stderr); exit(1) }
    }
    semaphore.wait(); exit(0)
}

if CommandLine.arguments.contains("--index-stats") {
    let started = Date()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let r = try await SessionIndex().scan(.defaults)
            let byTool = Dictionary(grouping: r.sessions, by: \.tool).mapValues(\.count)
            let days14 = r.sessions.filter { $0.lastActivityAt > Date().addingTimeInterval(-14 * 86400) }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy-MM-dd"
            func oldest(_ tool: Tool) -> String {
                r.sessions.filter { $0.tool == tool }.map(\.startedAt).min().map { date.string(from: $0) } ?? "–"
            }
            print("sessions \(r.sessions.count) · claude \(byTool[.claude] ?? 0) · codex \(byTool[.codex] ?? 0)"
                  + " · last 14 days \(days14.count) · projects \(r.projects.count) · skipped \(r.skippedFiles)"
                  + " · oldest claude \(oldest(.claude)) · oldest codex \(oldest(.codex))"
                  + String(format: " · %.2f s", Date().timeIntervalSince(started)))
            let live = await LiveMonitor(store: SQLiteStore()).current()
            let known = Set(r.sessions.map(\.id))
            print("live running \(live.running.count) · in index \(live.running.keys.filter(known.contains).count)"
                  + " · with tty \(live.running.values.filter { $0.tty != nil }.count) · resume counts \(live.resumeCounts.count)")
            // Which tool on which tty (no ids): compare with `ps -axo tty=,comm=` when counts disagree.
            print("live by tty " + live.running.map { "\($0.key.prefix(2))@\($0.value.tty ?? "-")" }.sorted().joined(separator: " "))
            // Windows as the cleanup sees them (counts and ttys only; nothing is closed).
            let terminal = AppleScriptTerminal()
            let closable = await terminal.closableWindows(knownTTYs: Set(live.running.values.compactMap(\.tty)))
            print("windows open \(await terminal.openWindowCount()) · closable \(closable.count) "
                  + closable.map { "\($0.app.rawValue)@\($0.tty ?? "-")" }.joined(separator: " "))
        } catch {
            print("error \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
