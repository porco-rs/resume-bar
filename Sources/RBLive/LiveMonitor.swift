import Foundation
import RBContract

public actor LiveMonitor: LiveMonitoring {
    private let source: any ProcessSource
    private let claudeSessions: URL
    private let history: URL
    private let countsURL: URL
    private let store: any EntryStoring
    private let readOnly: Bool
    private let importLegacy: Bool
    private var counts: [String: Int] = [:]
    private var loaded = false
    private var dirty = false
    private var polling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var historyImportVersion = 0
    private var previous: [String: Live] = [:]
    private var previousProcesses: [String: ProcessIdentity] = [:]
    private var incompletePolls: [String: Int] = [:]
    private var seen: [ProcessKey: String] = [:]

    private struct ProcessKey: Hashable, Codable { let pid: Int32; let start: UInt64 }
    private struct LegacyCountedProcess: Codable { var key: ProcessKey; var sessionID: String }
    private struct StoredCounts: Codable {
        var historyImported: Bool
        var historyImportVersion: Int?
        var counts: [String: Int]
        var counted: [LegacyCountedProcess]?
    }

    public init(store: any EntryStoring, readOnly: Bool = false, importLegacy: Bool = false, source: any ProcessSource = SystemProcessSource(),
                claudeSessions: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
                history: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history"),
                countsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ResumeBar/resume-counts.json")) {
        self.store = store; self.readOnly = readOnly; self.importLegacy = importLegacy
        self.source = source; self.claudeSessions = claudeSessions; self.history = history; self.countsURL = countsURL
    }

    public func current() async -> LiveState {
        if polling { await withCheckedContinuation { waiters.append($0) } } else { polling = true }
        defer {
            if waiters.isEmpty { polling = false } else { waiters.removeFirst().resume() }
        }
        await loadCounts()
        let probe = source.probe()
        let processes = probe.processes
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var running: [String: Live] = [:]
        var runningProcesses: [String: ProcessIdentity] = [:]
        var entryHints: [String: String] = [:]
        var changedCounts = false
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            guard let tty = process.tty, !tty.isEmpty,
                  (process.isClaudeCandidate || process.name == "codex"),
                  !process.arguments.contains(where: { $0.contains("app-server") }),
                  let id = sessionID(process) else { continue }
            let key = ProcessKey(pid: process.pid, start: process.startTime)
            if loaded && !readOnly && seen[key] != id { counts[id, default: 0] += 1; seen[key] = id; changedCounts = true }
            running[id] = Live(running: true, pid: Int(process.pid), tty: tty,
                               terminalApp: terminalApp(process.parentPID, in: byPID), windowIndex: nil)
            runningProcesses[id] = ProcessIdentity(pid: process.pid, startTime: process.startTime)
            entryHints[id] = process.entryHint
        }
        var nextIncompletePolls: [String: Int] = [:]
        for (id, live) in previous where running[id] == nil {
            guard let identity = previousProcesses[id],
                  !probe.complete || probe.unreadablePIDs.contains(identity.pid) || probe.incompleteCandidates.contains(identity)
            else { continue }
            let polls = incompletePolls[id, default: 0] + 1
            guard polls <= 3 else { continue }
            running[id] = live
            runningProcesses[id] = identity
            nextIncompletePolls[id] = polls
        }
        let ended = previous.keys.filter { running[$0] == nil }.sorted()
        previous = running
        previousProcesses = runningProcesses
        incompletePolls = nextIncompletePolls
        if changedCounts { dirty = true }
        if dirty && loaded && !readOnly { await saveCounts() }
        return LiveState(running: running, ended: ended, resumeCounts: counts, entryHints: entryHints)
    }

    public nonisolated func updates(interval: Duration = .seconds(2)) -> AsyncStream<LiveState> {
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                var last: LiveState?
                while !Task.isCancelled {
                    let state = await current()
                    if last == nil || last?.running != state.running || last?.entryHints != state.entryHints {
                        continuation.yield(state)
                        last = state
                    }
                    do { try await Task.sleep(for: interval) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sessionID(_ process: ProcessSnapshot) -> String? {
        if process.isClaudeCandidate {
            let url = claudeSessions.appendingPathComponent("\(process.pid).json")
            guard let data = try? Data(contentsOf: url), let object = Self.leadingObject(data),
                  let pid = object["pid"] as? Int, pid == Int(process.pid), process.startTime > 0,
                  let start = object["procStart"] as? String, Self.registryStart(start) == process.startTime / 1_000_000,
                  object["kind"] as? String == "interactive", let id = object["sessionId"] as? String,
                  let uuid = UUID(uuidString: id) else { return nil }
            return "cc_" + uuid.uuidString.lowercased()
        }
        for index in process.arguments.indices where process.arguments[index] == "resume" {
            let next = process.arguments.index(after: index)
            if next < process.arguments.endIndex, let uuid = UUID(uuidString: process.arguments[next]) {
                return "cx_" + uuid.uuidString.lowercased()
            }
        }
        for file in process.openFiles {
            let name = URL(fileURLWithPath: file).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let stem = String(name.dropLast(6))
            let thread = stem.components(separatedBy: "_")[0]
            guard thread.count >= 36, let uuid = UUID(uuidString: String(thread.suffix(36))) else { continue }
            return "cx_" + uuid.uuidString.lowercased()
        }
        return nil
    }

    static func registryStart(_ value: String, formatter: DateFormatter = DateFormatter()) -> UInt64? {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let date = formatter.date(from: normalized), date.timeIntervalSince1970 > 0 else { return nil }
        return UInt64(date.timeIntervalSince1970)
    }

    private func terminalApp(_ parent: Int32, in processes: [Int32: ProcessSnapshot]) -> TerminalApp? {
        var pid = parent
        var visited = Set<Int32>()
        while pid > 0, visited.insert(pid).inserted, let process = processes[pid] {
            let name = process.name.lowercased()
            if name == "ghostty" { return .ghostty }
            if name == "terminal" || name == "terminal.app" { return .terminal }
            pid = process.parentPID
        }
        return nil
    }

    private static func leadingObject(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        var start: Int?; var depth = 0; var quoted = false; var escaped = false
        for (i, byte) in bytes.enumerated() {
            if start == nil {
                if byte == 123 { start = i; depth = 1 }
                else if ![9, 10, 13, 32].contains(byte) { return nil }
                continue
            }
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0, let start { return (try? JSONSerialization.jsonObject(with: Data(bytes[start...i]))) as? [String: Any] }
            }
        }
        return nil
    }

    private func loadCounts() async {
        if !loaded {
            guard let state = try? await store.loadResumeCountState() else { return }
            counts = state.counts
            seen = Dictionary(state.counted.map { (ProcessKey(pid: $0.pid, start: $0.start), $0.sessionId) }, uniquingKeysWith: { _, last in last })
            historyImportVersion = state.historyImportVersion
            if !readOnly || importLegacy {
                let backup = countsURL.deletingPathExtension().appendingPathExtension("v1.json")
                if let modified = try? FileManager.default.attributesOfItem(atPath: backup.path)[.modificationDate] as? Date,
                   modified < Date().addingTimeInterval(-30 * 86400) { try? FileManager.default.removeItem(at: backup) }
                if historyImportVersion == 0, let data = try? Data(contentsOf: countsURL),
                   let legacy = try? JSONDecoder().decode(StoredCounts.self, from: data) {
                    let version = legacy.historyImportVersion ?? (legacy.historyImported ? 1 : 0)
                    let imported = ResumeCountState(counts: legacy.counts, historyImportVersion: version,
                        counted: (legacy.counted ?? []).map { RBContract.CountedProcess(pid: $0.key.pid, start: $0.key.start, sessionId: $0.sessionID) })
                    do {
                        try await store.saveResumeCountState(imported)
                        counts = imported.counts; historyImportVersion = version
                        seen = Dictionary(imported.counted.map { (ProcessKey(pid: $0.pid, start: $0.start), $0.sessionId) }, uniquingKeysWith: { _, last in last })
                        try FileManager.default.moveItem(at: countsURL, to: backup)
                    } catch { return }
                }
            }
            loaded = true
        }
        guard !readOnly, historyImportVersion < 2, let data = try? Data(contentsOf: history) else { return }
        let bytes = [UInt8](data)
        var decoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x83, index + 1 < bytes.count {
                decoded.append(bytes[index + 1] ^ 0x20)
                index += 2
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        let content = String(decoding: decoded, as: UTF8.self)
        let pattern = #"(?<![A-Za-z0-9_/-])(codex|claude)[^\S\r\n]+(resume|--resume|-r)[^\S\r\n]+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?![A-Za-z0-9_-])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            guard let toolRange = Range(match.range(at: 1), in: content),
                  let flagRange = Range(match.range(at: 2), in: content),
                  let uuidRange = Range(match.range(at: 3), in: content),
                  let uuid = UUID(uuidString: String(content[uuidRange])) else { continue }
            let prefix: String
            switch (content[toolRange], content[flagRange]) {
            case ("codex", "resume"): prefix = "cx_"
            case ("claude", "--resume"), ("claude", "-r"): prefix = "cc_"
            default: continue
            }
            counts[prefix + uuid.uuidString.lowercased(), default: 0] += 1
        }
        historyImportVersion = 2
        dirty = true
        await saveCounts()
    }

    private func saveCounts() async {
        let state = ResumeCountState(counts: counts, historyImportVersion: historyImportVersion,
            counted: seen.map { RBContract.CountedProcess(pid: $0.key.pid, start: $0.key.start, sessionId: $0.value) })
        do { try await store.saveResumeCountState(state); dirty = false } catch { dirty = true }
    }
}
