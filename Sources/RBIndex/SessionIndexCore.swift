import CoreServices
import CZstd
import CryptoKit
import Foundation
import RBContract

/// Reads interactive session metadata without loading entire transcripts.
public struct SessionIndex: SessionIndexing {
    private let claudeRoot: URL?
    private let codexRoot: URL?
    private let threadIndex: URL?
    private let cache: IndexCache

    public init(claudeRoot: URL? = nil, codexRoot: URL? = nil, threadIndex: URL? = nil) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.threadIndex = threadIndex
        self.cache = IndexCache()
    }

    init(claudeRoot: URL, codexRoot: URL, threadIndex: URL, onExtendedRead: @escaping @Sendable () -> Void) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.threadIndex = threadIndex
        self.cache = IndexCache(onExtendedRead: onExtendedRead)
    }

    private func paths(_ settings: Settings) -> Roots {
        let claude = claudeRoot ?? URL(fileURLWithPath: NSString(string: settings.watch.claude).expandingTildeInPath)
        let codex = codexRoot ?? URL(fileURLWithPath: NSString(string: settings.watch.codex).expandingTildeInPath)
        let index = threadIndex ?? codex.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        return Roots(claude: claude, codex: codex, index: index)
    }

    public func scan(_ settings: Settings) async throws -> IndexResult {
        let roots = paths(settings)
        return await Task.detached { await cache.scan(roots) }.value
    }

    /// Counts title sources and first-user-event positions without returning transcript content.
    public func titleStats(_ settings: Settings = .defaults) async -> TitleStats {
        let roots = paths(settings)
        return await Task.detached { collectTitleStats(roots) }.value
    }

    public func whereSession(_ nativeId: String, settings: Settings = .defaults) async -> SessionLocation? {
        let roots = paths(settings)
        return await Task.detached { await cache.location(nativeId, roots: roots) }.value
    }

    public func updates(_ settings: Settings) -> AsyncStream<IndexResult> {
        let roots = paths(settings)
        return AsyncStream { continuation in
            let gate = ScanGate(scanSpacing: .seconds(2)) {
                continuation.yield(await cache.scan(roots))
            }
            let watcher = EventWatcher(roots: roots) {
                Task { await gate.request() }
            }
            continuation.onTermination = { @Sendable _ in
                watcher.stop()
                Task { await gate.stop() }
            }
            watcher.start()
        }
    }
}

public struct SessionLocation: Sendable {
    public let projectName: String
    public let resolvedCwd: String
    public let startCwd: String
    public let startExists: Bool
}

struct Roots: Sendable {
    let claude: URL
    let codex: URL
    let index: URL
}
private struct Stamp: Equatable, Sendable {
    let size: UInt64
    let modified: Date
}
private struct Candidate: Sendable {
    let url: URL
    let tool: Tool
    let stamp: Stamp
}
private struct RawSession: Sendable {
    let tool: Tool
    let id: String
    let cwd: String
    let recentCwds: [String]
    let path: String
    let started: Date
    let modified: Date
    let tokens: Int?
    let prompt: String
    let title: String?
    let promptSource: PromptSource?
    let promptAfterHead: Bool
}
private enum Parsed: Sendable { case session(RawSession), ignored, unreadable }
private struct Cached: Sendable {
    let stamp: Stamp
    let parsed: Parsed
    var compressedTailCwds: [String]? = nil
    var hadName: Bool = false
}

private actor IndexCache {
    private let onExtendedRead: @Sendable () -> Void
    init(onExtendedRead: @escaping @Sendable () -> Void = {}) { self.onExtendedRead = onExtendedRead }
    private var entries: [String: Cached] = [:]

    func scan(_ roots: Roots) async -> IndexResult {
        let candidates = enumerate(roots)
        let names = readNames(roots.index)
        var current: [String: Cached] = [:]
        var pending: [Candidate] = []
        for candidate in candidates {
            if let cached = entries[candidate.url.path], cached.stamp == candidate.stamp,
               { if case .session(let session) = cached.parsed, session.tool == .codex { return cached.hadName == (clean(names[session.id]) != nil) }; return true }() {
                current[candidate.url.path] = cached
            } else {
                pending.append(candidate)
            }
        }
        await withTaskGroup(of: (String, Cached).self) { group in
            var iterator = pending.makeIterator()
            let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let onExtendedRead = self.onExtendedRead
            func submit(_ candidate: Candidate) {
                group.addTask {
                    let parsed = parse(candidate, names: names, onExtendedRead: onExtendedRead)
                    let named: Bool
                    if case .session(let session) = parsed { named = clean(names[session.id]) != nil } else { named = false }
                    return (candidate.url.path, Cached(stamp: candidate.stamp, parsed: parsed, hadName: named))
                }
            }
            for _ in 0..<workers { if let candidate = iterator.next() { submit(candidate) } }
            while let (path, parsed) = await group.next() {
                current[path] = parsed
                if let candidate = iterator.next() { submit(candidate) }
            }
        }
        for candidate in candidates where candidate.url.pathExtension == "zst" {
            guard var cached = current[candidate.url.path], cached.compressedTailCwds == nil,
                  case .session(let session) = cached.parsed, !isDirectory(session.cwd) else { continue }
            cached.compressedTailCwds = (try? codexCwds(lines(compressedSegments(at: candidate.url).1))) ?? []
            current[candidate.url.path] = cached
        }
        entries = current
        let raw = current.values.compactMap { value -> (RawSession, [String])? in
            if case .session(let session) = value.parsed { return (session, value.compressedTailCwds ?? session.recentCwds) }
            return nil
        }
        let skipped = current.values.filter { if case .unreadable = $0.parsed { return true }; return false }.count
        return assemble(raw, names: names, skipped: skipped)
    }
    func location(_ nativeId: String, roots: Roots) async -> SessionLocation? {
        let result = await scan(roots)
        guard let session = result.sessions.first(where: { $0.nativeId == nativeId }),
              let project = result.projects.first(where: { $0.id == session.projectId }),
              let raw = entries[session.transcriptPath], case .session(let source) = raw.parsed else { return nil }
        return SessionLocation(projectName: project.name, resolvedCwd: session.cwd, startCwd: source.cwd,
                               startExists: isDirectory(source.cwd))
    }
}

private func enumerate(_ roots: Roots) -> [Candidate] {
    let fm = FileManager.default
    var result: [Candidate] = []
    let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    func add(_ url: URL, _ tool: Tool) {
        guard let values = try? url.resourceValues(forKeys: fileKeys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0,
              let modified = values.contentModificationDate else { return }
        result.append(Candidate(url: url, tool: tool, stamp: Stamp(size: UInt64(size), modified: modified)))
    }
    if let projects = try? fm.contentsOfDirectory(at: roots.claude, includingPropertiesForKeys: [.isDirectoryKey]) {
        for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: Array(fileKeys)) {
                for file in files where file.pathExtension == "jsonl" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                    add(file, .claude)
                }
            }
        }
    }
    if let files = fm.enumerator(at: roots.codex, includingPropertiesForKeys: Array(fileKeys)) {
        for case let file as URL in files {
            let name = file.lastPathComponent
            if name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")) { add(file, .codex) }
        }
    }
    return result
}

private func segments(_ candidate: Candidate) throws -> (Data, Data) {
    if candidate.url.pathExtension == "zst" {
        return (try Zstd.decompressFile(at: candidate.url, limit: 128 * 1024), Data())
    }
    let handle = try FileHandle(forReadingFrom: candidate.url)
    defer { try? handle.close() }
    let head = try handle.read(upToCount: 128 * 1024) ?? Data()
    let tailStart = candidate.stamp.size > 64 * 1024 ? candidate.stamp.size - 64 * 1024 : 0
    try handle.seek(toOffset: tailStart)
    var tail = try handle.read(upToCount: 64 * 1024) ?? Data()
    if tailStart > 0, let newline = tail.firstIndex(of: 10) { tail = Data(tail[tail.index(after: newline)...]) }
    return (head, tail)
}

private func lines(_ data: Data) -> [[String: Any]] {
    data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
}
private func clean(_ value: String?) -> String? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}
private func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
private func parse(_ candidate: Candidate, names: [String: String], onExtendedRead: () -> Void = {}) -> Parsed {
    do {
        let (head, tail) = try segments(candidate)
        let first = lines(head), last = lines(tail)
        if candidate.tool == .claude {
            guard let entry = first.first(where: { $0["entrypoint"] != nil }), entry["entrypoint"] as? String == "cli",
                  let metadata = first.first(where: { $0["cwd"] != nil }),
                  let cwd = metadata["cwd"] as? String, let id = metadata["sessionId"] as? String, SessionID.isSafe(id),
                  let started = date(metadata["timestamp"] as? String) else { return .ignored }
            let selected = firstPrompt(first + last, tool: .claude)
            let headPrompt = firstPrompt(first, tool: .claude)
            let promptAfterHead = selected != nil && candidate.stamp.size > UInt64(head.count)
                && (selected?.source != headPrompt?.source || selected?.text != headPrompt?.text)
            let title = last.reversed().compactMap { line -> String? in
                switch line["type"] as? String {
                case "ai-title": return clean(line["aiTitle"] as? String)
                case "custom-title": return clean(line["customTitle"] as? String)
                default: return nil
                }
            }.first
            let recentCwds = last.compactMap { usableCwd($0["cwd"] as? String) }
            return .session(RawSession(tool: .claude, id: id, cwd: cwd, recentCwds: recentCwds, path: candidate.url.path, started: started, modified: candidate.stamp.modified, tokens: nil, prompt: String((selected?.text ?? "").prefix(200)), title: title, promptSource: selected?.source, promptAfterHead: promptAfterHead))
        }
        guard let meta = first.first, meta["type"] as? String == "session_meta", let payload = meta["payload"] as? [String: Any],
              payload["source"] as? String == "cli", let id = payload["id"] as? String, SessionID.isSafe(id),
              let cwd = payload["cwd"] as? String, let started = date(meta["timestamp"] as? String) else { return .ignored }
        var selected = firstPrompt(first, tool: .codex)
        var afterHead = false
        if selected == nil && clean(names[id]) == nil {
            onExtendedRead()
            if let later = try? extendedCodexPrompt(candidate) {
                selected = later.prompt
                afterHead = later.end > 128 * 1024
            }
        }
        let tokenLines = candidate.url.pathExtension == "zst" ? first : last
        let tokens = tokenLines.reversed().compactMap { line -> Int? in
            guard line["type"] as? String == "event_msg", let payload = line["payload"] as? [String: Any], payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any] else { return nil }
            return usage["total_tokens"] as? Int
        }.first
        return .session(RawSession(tool: .codex, id: id, cwd: cwd, recentCwds: codexCwds(last), path: candidate.url.path, started: started, modified: candidate.stamp.modified, tokens: tokens, prompt: String((selected?.text ?? "").prefix(200)), title: nil, promptSource: selected?.source, promptAfterHead: afterHead))
    } catch { return .unreadable }
}

/// All positions refer to decompressed bytes; percentiles use nearest rank and KB means 1024 bytes.
public struct TitleStats: Sendable {
    public struct ToolCounts: Sendable {
        public fileprivate(set) var sessions = 0, titled = 0, headPrompt = 0, fallbackOnly = 0, neither = 0
        public fileprivate(set) var noUserEvent = 0, onlyInjected = 0, beyondHeadTo1MB = 0, beyond1MBTo8MB = 0, beyond8MB = 0
        public fileprivate(set) var emptyUserText = 0, crossingHead = 0, compressedNeither = 0, unreadable = 0
        public fileprivate(set) var wrapperPrompt = 0, userPositionSamples = 0, firstLineSamples = 0
        public fileprivate(set) var promptFromEvent = 0, promptFromResponseItem = 0, promptAfterHead = 0
        public fileprivate(set) var userPositionP50KB = 0, userPositionP90KB = 0, userPositionMaxKB = 0
        public fileprivate(set) var firstLineP50KB = 0, firstLineMaxKB = 0
    }
    public fileprivate(set) var claude = ToolCounts()
    public fileprivate(set) var codex = ToolCounts()

    /// Fixed labels and integers only, suitable for diagnostic output.
    public var plainText: String {
        func format(_ name: String, _ c: ToolCounts) -> String {
            """
            \(name) sessions \(c.sessions) titled \(c.titled) head_prompt \(c.headPrompt) fallback_only \(c.fallbackOnly) neither \(c.neither) unreadable \(c.unreadable)
            \(name) neither_no_user \(c.noUserEvent) neither_only_injected \(c.onlyInjected) beyond_head_to_1mb \(c.beyondHeadTo1MB) beyond_1mb_to_8mb \(c.beyond1MBTo8MB) beyond_8mb \(c.beyond8MB) empty_user_text \(c.emptyUserText) crossing_head \(c.crossingHead) compressed \(c.compressedNeither)
            \(name) prompt_from_event \(c.promptFromEvent) prompt_from_response_item \(c.promptFromResponseItem) prompt_after_head \(c.promptAfterHead)
            \(name) wrapper_prompt \(c.wrapperPrompt) first_user_samples \(c.userPositionSamples) first_user_position_kb_p50 \(c.userPositionP50KB) p90 \(c.userPositionP90KB) max \(c.userPositionMaxKB) first_line_samples \(c.firstLineSamples) first_line_kb_p50 \(c.firstLineP50KB) max \(c.firstLineMaxKB)
            """
        }
        return format("claude", claude) + "\n" + format("codex", codex)
    }
}

private struct LineMeasures {
    var firstLineBytes: Int?
    var firstUserOffset: Int?
    var firstUserEnd: Int?
    var firstUserHasText = false
    var allUserMessagesInjected = true
}

private enum PromptSource: Sendable { case event, response, claudeUser, fallback }
private struct Prompt { let text: String; let source: PromptSource }

// Shared by indexing and statistics: events take precedence over response items.
private func firstPrompt(_ lines: [[String: Any]], tool: Tool) -> Prompt? {
    func usable(_ value: String?, codex: Bool) -> String? {
        guard let text = clean(value), !text.hasPrefix("<"),
              !(codex && text.hasPrefix("# AGENTS.md instructions")) else { return nil }
        return text
    }
    func command(_ text: String) -> Prompt? {
        func tag(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"),
                  let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
            return clean(String(text[start.upperBound..<end.lowerBound]))
        }
        guard let name = tag("command-name") else { return nil }
        return Prompt(text: tag("command-args") ?? name, source: .claudeUser)
    }
    var response: Prompt?, fallback: Prompt?, commandPrompt: Prompt?
    for line in lines {
        if tool == .claude {
            if line["type"] as? String == "user", let message = line["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    if let text = usable(content, codex: false) { return Prompt(text: text, source: .claudeUser) }
                    if commandPrompt == nil { commandPrompt = command(content) }
                }
                if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "text" {
                        if let text = usable(block["text"] as? String, codex: false) { return Prompt(text: text, source: .claudeUser) }
                        if commandPrompt == nil, let text = block["text"] as? String { commandPrompt = command(text) }
                    }
                }
            } else if line["type"] as? String == "last-prompt" {
                if let text = usable(line["lastPrompt"] as? String, codex: false) { fallback = Prompt(text: text, source: .fallback) }
            }
            continue
        }
        guard let payload = line["payload"] as? [String: Any] else { continue }
        if line["type"] as? String == "event_msg", payload["type"] as? String == "user_message",
           let text = usable(payload["message"] as? String, codex: true) { return Prompt(text: text, source: .event) }
        if response == nil, line["type"] as? String == "response_item", payload["type"] as? String == "message",
           payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] {
            for block in blocks {
                if let text = usable(block["text"] as? String, codex: true) { response = Prompt(text: text, source: .response); break }
            }
        }
    }
    return tool == .claude ? fallback ?? commandPrompt : response
}

// Decode at most 8 MiB and examine complete lines incrementally, for both file formats.
private func extendedCodexPrompt(_ candidate: Candidate) throws -> (prompt: Prompt, end: Int)? {
    let handle = try FileHandle(forReadingFrom: candidate.url)
    defer { try? handle.close() }
    let limit = 8 * 1024 * 1024
    var pending = Data(), offset = 0, decoded = 0
    var response: (prompt: Prompt, end: Int)?, event: (prompt: Prompt, end: Int)?
    func consume(_ data: Data) {
        let chunk = data.prefix(max(0, limit - decoded)); decoded += chunk.count
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); let end = offset + line.count + 1
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               let prompt = firstPrompt([object], tool: .codex) {
                if prompt.source == .event { if event == nil { event = (prompt, end) } }
                else if response == nil { response = (prompt, end) }
            }
            pending.removeSubrange(...newline); offset = end
            if event != nil { break }
        }
    }
    if candidate.url.pathExtension == "zst" {
        guard let stream = ZSTD_createDStream() else { throw Zstd.Failure.decoder("create") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        while decoded < limit && event == nil, let data = try handle.read(upToCount: ZSTD_DStreamInSize()), !data.isEmpty {
            try data.withUnsafeBytes { source in
                var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                var count = 0
                repeat {
                    count = try buffer.withUnsafeMutableBytes { destination in
                        var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                        let rc = ZSTD_decompressStream(stream, &output, &input)
                        if ZSTD_isError(rc) != 0 { throw Zstd.Failure.decoder("decode") }
                        return output.pos
                    }
                    consume(Data(buffer.prefix(count)))
                } while (input.pos < input.size || count == buffer.count) && decoded < limit && event == nil
            }
        }
    } else {
        while decoded < limit && event == nil, let data = try handle.read(upToCount: min(64 * 1024, limit - decoded)), !data.isEmpty { consume(data) }
    }
    // A final line without a newline is valid only when the input ended before the limit.
    if decoded < limit && event == nil && !pending.isEmpty,
       let object = (try? JSONSerialization.jsonObject(with: pending)) as? [String: Any], let prompt = firstPrompt([object], tool: .codex) {
        if prompt.source == .event { event = (prompt, decoded) }
        else if response == nil { response = (prompt, decoded) }
    }
    return event ?? response
}

private func userText(_ line: [String: Any], tool: Tool) -> String? {
    firstPrompt([line], tool: tool)?.text
}

private func isUserEvent(_ line: [String: Any], tool: Tool) -> Bool {
    if tool == .claude { return line["type"] as? String == "user" }
    guard let payload = line["payload"] as? [String: Any] else { return false }
    return (line["type"] as? String == "event_msg" && payload["type"] as? String == "user_message")
        || (line["type"] as? String == "response_item" && payload["type"] as? String == "message" && payload["role"] as? String == "user")
}

private func isInjectedUserEvent(_ line: [String: Any], tool: Tool) -> Bool {
    let texts: [String]
    if tool == .claude, let message = line["message"] as? [String: Any] {
        if let text = message["content"] as? String { texts = [text] }
        else { texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
    } else if tool == .codex, let payload = line["payload"] as? [String: Any] {
        if line["type"] as? String == "event_msg" { texts = (payload["message"] as? String).map { [$0] } ?? [] }
        else { texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
    } else { texts = [] }
    let nonempty = texts.compactMap { clean($0) }
    return !nonempty.isEmpty && nonempty.allSatisfy { $0.hasPrefix("<") || (tool == .codex && $0.hasPrefix("# AGENTS.md instructions")) }
}

// Read chunks, retaining only the current line, including for compressed transcripts.
private func measureLines(_ candidate: Candidate) throws -> LineMeasures {
    let handle = try FileHandle(forReadingFrom: candidate.url)
    defer { try? handle.close() }
    var measures = LineMeasures(), pending = Data(), offset = 0
    func consumeLine(_ line: Data) {
        if measures.firstLineBytes == nil { measures.firstLineBytes = line.count }
        if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], isUserEvent(object, tool: candidate.tool) {
            measures.allUserMessagesInjected = measures.allUserMessagesInjected && isInjectedUserEvent(object, tool: candidate.tool)
            if measures.firstUserOffset == nil {
                measures.firstUserOffset = offset
                measures.firstUserEnd = offset + line.count
                measures.firstUserHasText = userText(object, tool: candidate.tool) != nil
            }
        }
        offset += line.count + 1
    }
    func consume(_ chunk: Data) {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 10) {
            pending.append(chunk[start..<newline])
            consumeLine(pending)
            pending.removeAll(keepingCapacity: true)
            start = chunk.index(after: newline)
        }
        pending.append(chunk[start...])
    }
    if candidate.url.pathExtension == "zst" {
        guard let stream = ZSTD_createDStream() else { throw Zstd.Failure.decoder("create") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize()), remaining = 1
        while let data = try handle.read(upToCount: ZSTD_DStreamInSize()), !data.isEmpty {
            try data.withUnsafeBytes { source in
                var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                var produced = 0
                repeat {
                    produced = try buffer.withUnsafeMutableBytes { destination in
                        var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                        remaining = ZSTD_decompressStream(stream, &output, &input)
                        if ZSTD_isError(remaining) != 0 { throw Zstd.Failure.decoder("decode") }
                        return output.pos
                    }
                    consume(Data(buffer.prefix(produced)))
                } while input.pos < input.size || (produced == buffer.count && remaining != 0)
            }
        }
        guard remaining == 0 else { throw Zstd.Failure.decoder("truncated") }
    } else {
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { consume(data) }
    }
    if !pending.isEmpty { consumeLine(pending) }
    return measures
}

private func collectTitleStats(_ roots: Roots) -> TitleStats {
    let names = readNames(roots.index)
    var stats = TitleStats()
    let candidates = enumerate(roots)
    for tool in [Tool.claude, .codex] {
        var counts = TitleStats.ToolCounts(), positions: [Int] = [], firstLines: [Int] = []
        for candidate in candidates where candidate.tool == tool {
            switch parse(candidate, names: names) {
            case .ignored: continue
            case .unreadable: counts.unreadable += 1; continue
            case .session(let session):
                counts.sessions += 1
                let titled = clean(names[session.id]) != nil || session.title != nil
                if titled { counts.titled += 1 }
                let head: Data
                do { head = try segments(candidate).0 } catch { counts.unreadable += 1; continue }
                let headSelection = firstPrompt(lines(head), tool: tool)
                let hasHeadPrompt = headSelection != nil && headSelection?.source != .fallback
                if session.promptSource == .event { counts.promptFromEvent += 1 }
                if session.promptSource == .response { counts.promptFromResponseItem += 1 }
                if session.promptAfterHead { counts.promptAfterHead += 1 }
                if hasHeadPrompt { counts.headPrompt += 1 }
                if session.promptSource == .fallback { counts.fallbackOnly += 1 }
                if session.prompt.hasPrefix("<") { counts.wrapperPrompt += 1 }
                let neither = !titled && session.prompt.isEmpty
                if neither {
                    counts.neither += 1
                    if candidate.url.pathExtension == "zst" { counts.compressedNeither += 1 }
                }
                do {
                    let m = try measureLines(candidate)
                    if let firstLine = m.firstLineBytes { firstLines.append(firstLine) }
                    if let position = m.firstUserOffset { positions.append(position) }
                    if neither {
                        if let position = m.firstUserOffset {
                            if m.allUserMessagesInjected { counts.onlyInjected += 1 }
                            if position >= 128 * 1024 {
                                if position <= 1024 * 1024 { counts.beyondHeadTo1MB += 1 }
                                else if position <= 8 * 1024 * 1024 { counts.beyond1MBTo8MB += 1 }
                                else { counts.beyond8MB += 1 }
                            } else if (m.firstUserEnd ?? 0) > 128 * 1024 { counts.crossingHead += 1 }
                            else if !m.firstUserHasText { counts.emptyUserText += 1 }
                        } else { counts.noUserEvent += 1 }
                    }
                } catch { counts.unreadable += 1 }
            }
        }
        func percentile(_ values: [Int], _ percent: Int) -> Int {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[(sorted.count * percent + 99) / 100 - 1] / 1024
        }
        counts.userPositionSamples = positions.count
        counts.firstLineSamples = firstLines.count
        counts.userPositionP50KB = percentile(positions, 50)
        counts.userPositionP90KB = percentile(positions, 90)
        counts.userPositionMaxKB = percentile(positions, 100)
        counts.firstLineP50KB = percentile(firstLines, 50)
        counts.firstLineMaxKB = percentile(firstLines, 100)
        if tool == .claude { stats.claude = counts } else { stats.codex = counts }
    }
    return stats
}

private func codexCwds(_ lines: [[String: Any]]) -> [String] {
    lines.compactMap { line in
        guard let type = line["type"] as? String, type == "turn_context" || type == "session_meta",
              let payload = line["payload"] as? [String: Any] else { return nil }
        return usableCwd(payload["cwd"] as? String)
    }
}

private func usableCwd(_ value: String?) -> String? {
    guard let value = clean(value), value.hasPrefix("/") else { return nil }
    let path = URL(fileURLWithPath: value).standardizedFileURL.path
    return isTemporaryFolder(path) ? nil : value
}
func isTemporaryFolder(_ path: String) -> Bool {
    let temporary = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    return temporary.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
}
private func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
}

private func readNames(_ url: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    var result: [String: String] = [:]
    for line in lines(data) {
        if let id = line["id"] as? String, SessionID.isSafe(id) { result[id] = clean(line["thread_name"] as? String) ?? "" }
    }
    return result
}
private func projectRoot(_ cwd: String, mainCheckout: Bool = false) -> String? {
    let original = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
    var cursor = original
    while true {
        let dotGit = cursor.appendingPathComponent(".git")
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &directory) {
            guard mainCheckout && !directory.boolValue else { return cursor.resolvingSymlinksInPath().path }
            guard let contents = try? String(contentsOf: dotGit, encoding: .utf8), contents.hasPrefix("gitdir: ") else { return nil }
            let gitdir = URL(fileURLWithPath: String(contents.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: cursor).standardizedFileURL
            guard let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) else { return nil }
            let commonDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitdir).standardizedFileURL.resolvingSymlinksInPath()
            guard commonDir.lastPathComponent == ".git", isDirectory(commonDir.path) else { return nil }
            return commonDir.deletingLastPathComponent().path
        }
        let parent = cursor.deletingLastPathComponent()
        if parent.path == cursor.path { return original.path }
        cursor = parent
    }
}
private func assemble(_ raw: [(RawSession, [String])], names: [String: String], skipped: Int) -> IndexResult {
    var existence: [String: Bool] = [:]
    var rootCache: [String: String] = [:]
    func exists(_ path: String) -> Bool {
        if let cached = existence[path] { return cached }
        let result = isDirectory(path); existence[path] = result; return result
    }
    func root(_ path: String) -> String {
        if let cached = rootCache[path] { return cached }
        let result = projectRoot(path) ?? path; rootCache[path] = result; return result
    }
    var mainRoots: [String: String] = [:]
    let resolved: [(RawSession, String, String)] = raw.map { session, recentCwds in
        let cwd: String
        if exists(session.cwd) { cwd = session.cwd }
        else {
            var counts: [String: (count: Int, last: Int)] = [:]
            for (index, recent) in recentCwds.enumerated() where exists(recent) {
                let project = mainRoots[recent] ?? projectRoot(recent, mainCheckout: true)
                guard let project else { continue }
                mainRoots[recent] = project
                counts[project] = ((counts[project]?.count ?? 0) + 1, index)
            }
            cwd = counts.max { a, b in
                a.value.count == b.value.count ? a.value.last < b.value.last : a.value.count < b.value.count
            }?.key ?? session.cwd
        }
        return (session, cwd, root(cwd))
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
    let roots = Set(resolved.map { $0.2 }.filter { $0 != home })
    let groups = Dictionary(grouping: roots, by: { URL(fileURLWithPath: $0).lastPathComponent })
    var ids: [String: String] = [:]
    for (name, paths) in groups {
        for path in paths {
            let digest = SHA256.hash(data: Data(path.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
            ids[path] = "prj_" + name + (paths.count > 1 ? "_" + digest : "")
        }
    }
    var activities: [String: Date] = [:]
    var sessions: [IndexedSession] = []
    for (session, cwd, root) in resolved {
        if root != home { activities[root] = max(activities[root] ?? .distantPast, session.modified) }
        let name = clean(names[session.id])
        let topic: String
        if let name { topic = name }
        else if let title = session.title { topic = title }
        else {
            let sentence = session.prompt.firstIndex(where: { ".!?\n".contains($0) }).map { String(session.prompt[...$0]) } ?? session.prompt
            topic = String(sentence.prefix(60))
        }
        let item = IndexedSession(id: session.tool.idPrefix + session.id, tool: session.tool, nativeId: session.id,
            projectId: ids[root], cwd: cwd, transcriptPath: session.path, startedAt: session.started,
            lastActivityAt: session.modified, tokens: session.tokens, firstPrompt: session.prompt, threadName: name,
            suggestedTopic: topic, resumable: FileManager.default.fileExists(atPath: session.path))
        sessions.append(item)
    }
    sessions.sort { $0.lastActivityAt == $1.lastActivityAt ? $0.id < $1.id : $0.lastActivityAt > $1.lastActivityAt }
    let projects = activities.map { root, activity in Project(id: ids[root]!, name: URL(fileURLWithPath: root).lastPathComponent, rootPath: root, lastActivityAt: activity) }.sorted { $0.id < $1.id }
    return IndexResult(projects: projects, sessions: sessions, skippedFiles: skipped)
}

// Coalesce requests while preserving a final scan after every burst.
actor ScanGate {
    private let scanSpacing: Duration
    private let scan: @Sendable () async -> Void
    private let clock = ContinuousClock()
    private var lastStart: ContinuousClock.Instant?
    private var pending = false
    private var stopped = false
    private var worker: Task<Void, Never>?

    init(scanSpacing: Duration = .seconds(2), scan: @escaping @Sendable () async -> Void) {
        self.scanSpacing = scanSpacing
        self.scan = scan
    }
    func request() {
        guard !stopped else { return }
        pending = true
        if worker == nil { worker = Task { await run() } }
    }
    func stop() {
        stopped = true
        pending = false
        worker?.cancel()
        worker = nil
    }
    private func run() async {
        while pending && !stopped {
            if let lastStart {
                let deadline = lastStart.advanced(by: scanSpacing)
                if clock.now < deadline {
                    do { try await clock.sleep(until: deadline) } catch { break }
                }
            }
            guard !stopped else { break }
            pending = false
            lastStart = clock.now
            await scan()
        }
        worker = nil
    }
}

