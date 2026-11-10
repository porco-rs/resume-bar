import Foundation
import Testing
import RBContract
@testable import RBLive

private let id = "01234567-89ab-cdef-0123-456789abcdef"
private let other = "abcdef01-2345-6789-abcd-ef0123456789"
private final class FakeSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [ProcessSnapshot] = []
    private var complete = true
    private var unreadablePIDs: Set<Int32> = []
    private var incompleteCandidates: Set<ProcessIdentity> = []
    func set(_ processes: [ProcessSnapshot]) { lock.lock(); defer { lock.unlock() }; value = processes }
    func setComplete(_ flag: Bool) { lock.lock(); defer { lock.unlock() }; complete = flag }
    func setFailures(pids: Set<Int32> = [], candidates: Set<ProcessIdentity> = []) {
        lock.lock(); defer { lock.unlock() }; unreadablePIDs = pids; incompleteCandidates = candidates
    }
    func processes() -> [ProcessSnapshot] { lock.lock(); defer { lock.unlock() }; return value }
    func probe() -> ProcessProbe {
        lock.lock(); defer { lock.unlock() }
        return ProcessProbe(processes: value, complete: complete, unreadablePIDs: unreadablePIDs,
                            incompleteCandidates: incompleteCandidates)
    }
}
private actor FakeStore: EntryStoring {
    var state = ResumeCountState(counts: [:], historyImportVersion: 0)
    var failSave = false
    func setFailSave(_ value: Bool) { failSave = value }
    func loadResumeCountState() -> ResumeCountState { state }
    func saveResumeCountState(_ value: ResumeCountState) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        state = value
    }
    func loadEntries() -> [Entry] { [] }
    func loadLinks() -> [String: String] { [:] }
    func loadChanges() -> [Change] { [] }
    func loadSettings() -> Settings { .defaults }
    func createStrands(_ seeds: [StrandSeed]) -> [String: String] { [:] }
    func save(_ entry: Entry, undoLabel: String?) {}
    func link(_ sessionIds: [String], to entryId: String, undoLabel: String?) {}
    func delete(entryId: String, undoLabel: String?) {}
    func addChange(_ change: Change) {}
    func removeChanges(_ ids: [String]) {}
    func apply(_ patch: SettingsPatch) -> Settings { .defaults }
    func undo() -> String? { nil }
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) {}
}
private struct Fixture {
    let root: URL
    let source = FakeSource()
    let store = FakeStore()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(_ name: String, _ content: String) throws { try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    func monitor() -> LiveMonitor { LiveMonitor(store: store, source: source, claudeSessions: root, history: root.appendingPathComponent("history"), countsURL: root.appendingPathComponent("counts.json")) }
}
private func codex(_ pid: Int32 = 1, args: [String] = ["codex", "resume", id], files: [String] = [], tty: String? = "ttys001", start: UInt64 = 1) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, parentPID: 10, name: "codex", tty: tty, arguments: args, openFiles: files, startTime: start)
}

@Test func claudeRegisterLeadingObject() async throws {
    let f = try Fixture()
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"\(registryDate(1_700_000_000))\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\",\"extra\":\"}\\\"{\"} trailing garbage")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 2, name: "claude", tty: "ttys003", startTime: 1_700_000_000_000_000), ProcessSnapshot(pid: 2, parentPID: 3, name: "zsh"), ProcessSnapshot(pid: 3, parentPID: 0, name: "ghostty")])
    let state = await f.monitor().current()
    #expect(state.running["cc_" + id]?.terminalApp == .ghostty)
    #expect(state.running["cc_" + id]?.tty == "ttys003")
}

@Test func claudeRegistryUsesUTCDespiteBerlinLocalZone() async throws {
    let localFormatter = DateFormatter()
    localFormatter.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-02T12:05:48Z"))
    let seconds = UInt64(instant.timeIntervalSince1970)
    #expect(LiveMonitor.registryStart("Mon Nov  2 12:05:48 2026", formatter: localFormatter) == seconds)
    let f = try Fixture()
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"Mon Nov  2 12:05:48 2026\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "claude", tty: "ttys001", startTime: seconds * 1_000_000)])
    #expect(await f.monitor().current().running["cc_" + id] != nil)
    try f.write("4.json", "{\"pid\":5,\"procStart\":\"Mon Nov  2 12:05:48 2026\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    #expect(await f.monitor().current().running.isEmpty)
}

@Test func claudeBackgroundIgnored() async throws {
    let f = try Fixture(); try f.write("4.json", "{\"kind\":\"bg\",\"sessionId\":\"\(id)\"}")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "claude", tty: "ttys001")])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test(arguments: ["claude", "/opt/bin/claude"])
func versionNamedClaudeUsesArgvAndRegistry(_ argv0: String) async throws {
    let f = try Fixture()
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"\(registryDate(1_700_000_000))\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "2.1.316", tty: "ttys011",
                                 arguments: [argv0], startTime: 1_700_000_000_123_456), codex()])
    let state = await f.monitor().current()
    #expect(state.running["cc_" + id]?.pid == 4)
    #expect(state.running["cc_" + id]?.tty == "ttys011")
    #expect(state.resumeCounts["cc_" + id] == 1)
    #expect(state.running["cx_" + id]?.tty == "ttys001")
}

@Test(arguments: ["2.1.316", "unrelated"])
func claudeArgvWithoutRegistryIsNotRunning(_ name: String) async throws {
    let f = try Fixture()
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: name, tty: "ttys011",
                                 arguments: ["claude", "resume", id],
                                 openFiles: ["/synthetic/rollout-\(id).jsonl"], startTime: 1_700_000_000_000_000)])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test(arguments: ["pid", "procStart", "kind"])
func claudeArgvRejectsMismatchedRegistry(_ field: String) async throws {
    let f = try Fixture()
    var registry: [String: Any] = ["pid": 4, "procStart": registryDate(1_700_000_000), "kind": "interactive", "sessionId": id]
    let mismatches: [String: Any] = ["pid": 5, "procStart": registryDate(1_700_000_001), "kind": "bg"]
    registry[field] = mismatches[field]
    try JSONSerialization.data(withJSONObject: registry).write(to: f.root.appendingPathComponent("4.json"))
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "unrelated", tty: "ttys011",
                                 arguments: ["claude", "resume", id], startTime: 1_700_000_000_000_000)])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test func claudeExecutablePathRequiresRegistryAndTTY() async throws {
    let f = try Fixture()
    var process = ProcessSnapshot(pid: 4, parentPID: 0, name: "2.1.316", tty: "ttys011",
                                  startTime: 1_700_000_000_000_000,
                                  executablePath: "/opt/claude/versions/2.1.316")
    f.source.set([process])
    #expect(await f.monitor().current().running.isEmpty)
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"\(registryDate(1_700_000_000))\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    #expect(await f.monitor().current().running["cc_" + id]?.tty == "ttys011")
    process.tty = nil; f.source.set([process])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test(arguments: [["runner", "claude"], ["my-claude"]])
func claudeCandidateRequiresExactArgvBasename(_ arguments: [String]) async throws {
    let f = try Fixture()
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"\(registryDate(1_700_000_000))\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "unrelated", tty: "ttys011",
                                 arguments: arguments, startTime: 1_700_000_000_000_000,
                                 executablePath: "/opt/not-claude/versions/2.1.316")])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test func codexResumeArguments() async throws {
    let f = try Fixture(); f.source.set([codex(), ProcessSnapshot(pid: 10, parentPID: 0, name: "Terminal")])
    let state = await f.monitor().current()
    #expect(state.running["cx_" + id]?.terminalApp == .terminal)
    #expect(state.running["cx_" + id]?.windowIndex == nil)
}

@Test func codexOpenRollout() async throws {
    let f = try Fixture(); f.source.set([codex(args: ["codex"], files: ["/tmp/rollout-2026-01-01T00-00-00-\(id)_\(other).jsonl"])])
    #expect(await f.monitor().current().running["cx_" + id] != nil)
}

@Test func excludesAppServerAndMissingTTY() async throws {
    let f = try Fixture(); f.source.set([codex(args: ["codex", "app-server", "resume", id]), codex(2, tty: nil)])
    #expect(await f.monitor().current().running.isEmpty)
}

@Test func endedAndProcessRestarts() async throws {
    let f = try Fixture(); let monitor = f.monitor(); f.source.set([codex()])
    #expect(await monitor.current().resumeCounts["cx_" + id] == 1)
    #expect(await monitor.current().resumeCounts["cx_" + id] == 1)
    f.source.set([])
    #expect(await monitor.current().ended == ["cx_" + id])
    #expect(await monitor.current().ended.isEmpty)
    f.source.set([codex(start: 2)])
    #expect(await monitor.current().resumeCounts["cx_" + id] == 2)
}

private actor Received {
    var states: [LiveState] = []
    func add(_ state: LiveState) { states.append(state) }
    func all() -> [LiveState] { states }
}
@Test func streamEmitsOnlyChanges() async throws {
    let f = try Fixture(); f.source.set([codex()]); let monitor = f.monitor(); let received = Received()
    let task = Task { for await state in monitor.updates(interval: .milliseconds(20)) { await received.add(state) } }
    for _ in 0..<100 where await received.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await received.all().count == 1)
    try await Task.sleep(for: .milliseconds(120))
    #expect(await received.all().count == 1)
    f.source.set([])
    for _ in 0..<100 where await received.all().count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    task.cancel(); await task.value
    let states = await received.all()
    #expect(states.count == 2)
    #expect(states.last?.ended == ["cx_" + id])
}

@Test func importsHistoryOnceAndPersists() async throws {
    let f = try Fixture()
    try f.write("history", "codex resume \(id)\n: 1700000000:0;codex resume \(id)\nclaude --resume \(other)\n: 1700000001:0;claude --resume \(other)\nignore resume \(id)\n")
    let first = await f.monitor().current()
    #expect(first.resumeCounts["cx_" + id] == 2)
    #expect(first.resumeCounts["cc_" + other] == 2)
    let second = await f.monitor().current()
    #expect(second.resumeCounts == first.resumeCounts)
}

@Test func importsHistoryWithInvalidAndMetafiedBytes() async throws {
    let f = try Fixture()
    var data = Data([0xff, 0x83, 0xc3, 0x83, 0x89, 0x20]) // invalid byte and metafied UTF-8 é
    data.append(contentsOf: "codex resume \(id) ".utf8)
    data.append(contentsOf: [0x83, 0xff, 0x0a])
    try data.write(to: f.root.appendingPathComponent("history"))
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 1)
}

@Test func importsResumesAnywhereAndEveryOccurrence() async throws {
    let f = try Fixture()
    try f.write("history", "cd '/x' && codex resume \(id); codex resume \(id)\n: 1700000000:0;claude -r \(other) && claude --resume \(other)\nclaude -r \(other); claude --resume \(other)\n")
    let counts = await f.monitor().current().resumeCounts
    #expect(counts["cx_" + id] == 2)
    #expect(counts["cc_" + other] == 4)
}

@Test func historyRejectsPartialCommandsAndUUIDs() async throws {
    let f = try Fixture()
    try f.write("history", "mycodex resume \(id)\ncodex resume \(id)extra\nclaude resume \(id)\ncodex -r \(id)\nzz resume \(id)\nzz --resume \(other)\n")
    #expect(await f.monitor().current().resumeCounts.isEmpty)
}

@Test func missingHistoryDoesNotMarkImportAndRetries() async throws {
    let f = try Fixture(); let monitor = f.monitor(); f.source.set([codex()])
    #expect(await monitor.current().resumeCounts["cx_" + id] == 1)
    #expect(await f.store.loadResumeCountState().historyImportVersion == 0)
    try f.write("history", "codex resume \(id)\n")
    #expect(await monitor.current().resumeCounts["cx_" + id] == 2)
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 2)
}

@Test(arguments: [false, true])
func migratesOldHistoryImportExactlyOnce(_ explicitVersion: Bool) async throws {
    let f = try Fixture()
    let version = explicitVersion ? ",\"historyImportVersion\":1" : ""
    try f.write("counts.json", "{\"historyImported\":true\(version),\"counts\":{\"cx_\(id)\":7}}")
    try f.write("history", "codex resume \(id)\ncodex resume \(id)\n")
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 9)
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 9)
    #expect(await f.store.loadResumeCountState().historyImportVersion == 2)
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.json").path))
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.v1.json").path))
}

@Test func legacyCountedProcessSurvivesImportAndRestart() async throws {
    let f = try Fixture(); f.source.set([codex()])
    try f.write("counts.json", "{\"historyImported\":true,\"counts\":{\"cx_\(id)\":7},\"counted\":[{\"key\":{\"pid\":1,\"start\":1},\"sessionID\":\"cx_\(id)\"}]}")
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 7)
    let state = await f.store.loadResumeCountState()
    #expect(state.historyImportVersion == 1)
    #expect(state.counted == [CountedProcess(pid: 1, start: 1, sessionId: "cx_" + id)])
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 7)
}

@Test func legacyBackupExpiresAndVersionTwoIsNotReimported() async throws {
    let f = try Fixture()
    try await f.store.saveResumeCountState(.init(counts: ["existing": 9], historyImportVersion: 2))
    try f.write("counts.json", "{\"historyImported\":true,\"counts\":{\"old\":100}}")
    try f.write("counts.v1.json", "backup")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86400)], ofItemAtPath: f.root.appendingPathComponent("counts.v1.json").path)
    #expect(await f.monitor().current().resumeCounts == ["existing": 9])
    #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.v1.json").path))
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.json").path))
}

@Test func failedSaveRetriesWithoutReimportingHistory() async throws {
    let f = try Fixture(); try f.write("history", "codex resume \(id)\n")
    await f.store.setFailSave(true)
    let monitor = f.monitor()
    #expect(await monitor.current().resumeCounts["cx_" + id] == 1)
    await f.store.setFailSave(false)
    #expect(await monitor.current().resumeCounts["cx_" + id] == 1)
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 1)
}

@Test func readOnlyMonitorLeavesStoreAndLegacyFileUntouched() async throws {
    let f = try Fixture(); f.source.set([codex()])
    try f.write("counts.json", "{\"historyImported\":true,\"counts\":{\"old\":3}}")
    let monitor = LiveMonitor(store: f.store, readOnly: true, source: f.source, claudeSessions: f.root, history: f.root.appendingPathComponent("history"), countsURL: f.root.appendingPathComponent("counts.json"))
    #expect(await monitor.current().running.count == 1)
    #expect(await f.store.loadResumeCountState() == ResumeCountState(counts: [:], historyImportVersion: 0))
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.json").path))
}

@Test func diagnosticImportsOnlyTheProvidedCopy() async throws {
    let f = try Fixture(); f.source.set([codex()])
    try f.write("counts.json", "{\"historyImported\":true,\"counts\":{\"old\":136}}")
    let monitor = LiveMonitor(store: f.store, readOnly: true, importLegacy: true, source: f.source, claudeSessions: f.root, history: f.root.appendingPathComponent("history"), countsURL: f.root.appendingPathComponent("counts.json"))
    #expect(await monitor.current().resumeCounts == ["old": 136])
    #expect(await f.store.loadResumeCountState().historyImportVersion == 1)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("counts.v1.json").path))
}

@Test func parsesProcArgsBuffer() {
    var count: Int32 = 3
    var data = withUnsafeBytes(of: &count) { Array($0) }
    data += Array("/opt/codex\0\0\0codex\0resume\0\(id)\0ENV=ignore\0".utf8)
    #expect(SystemProcessSource.parseArguments(data) == ["codex", "resume", id])
    #expect(SystemProcessSource.parseArguments(Array(data.dropLast(50))).isEmpty)
}

private func registryDate(_ seconds: TimeInterval) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")!
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return f.string(from: Date(timeIntervalSince1970: seconds))
}
@Test func staleClaudeIdentityRejected() async throws {
    let f = try Fixture()
    try f.write("4.json", "{\"pid\":4,\"procStart\":\"\(registryDate(1_700_000_000))\",\"kind\":\"interactive\",\"sessionId\":\"\(id)\"}")
    f.source.set([ProcessSnapshot(pid: 4, parentPID: 0, name: "claude", tty: "ttys001", startTime: 1_700_000_001_000_000)])
    #expect(await f.monitor().current().running.isEmpty)
}
@Test func restartDoesNotRecountSameProcess() async throws {
    let f = try Fixture(); f.source.set([codex()])
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 1)
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 1)
    f.source.set([codex(start: 2)])
    #expect(await f.monitor().current().resumeCounts["cx_" + id] == 2)
}
@Test func unrelatedProcessFailureDoesNotBlockEnd() async throws {
    let f = try Fixture(); f.source.set([codex()]); let monitor = f.monitor()
    _ = await monitor.current(); f.source.set([]); f.source.setFailures(pids: [99])
    #expect(await monitor.current().ended == ["cx_" + id])
}
@Test func failingCandidateExpiresAfterThreePolls() async throws {
    let f = try Fixture(); let monitor = f.monitor()
    f.source.set([codex(), codex(2, args: ["codex", "resume", other])]); _ = await monitor.current()
    f.source.set([]); f.source.setFailures(pids: [1])
    for poll in 1...3 {
        let state = await monitor.current()
        #expect(state.running["cx_" + id] != nil)
        #expect(state.ended == (poll == 1 ? ["cx_" + other] : []))
    }
    let expired = await monitor.current()
    #expect(expired.running.isEmpty); #expect(expired.ended == ["cx_" + id])
    #expect(await monitor.current().ended.isEmpty)
}
@Test func incompleteCandidateFDAndRecovery() async throws {
    let f = try Fixture(); let monitor = f.monitor(); f.source.set([codex()]); _ = await monitor.current()
    f.source.set([codex(args: ["codex"])])
    f.source.setFailures(candidates: [ProcessIdentity(pid: 1, startTime: 1)])
    #expect(await monitor.current().running["cx_" + id] != nil)
    #expect(await monitor.current().running["cx_" + id] != nil)
    f.source.set([codex()]); _ = await monitor.current()
    f.source.set([codex(args: ["codex"])])
    for _ in 1...3 { #expect(await monitor.current().running["cx_" + id] != nil) }
    #expect(await monitor.current().ended == ["cx_" + id])
}
@Test func completeProbeEndsImmediatelyAndPIDReuseDoesNotHold() async throws {
    let f = try Fixture(); let monitor = f.monitor(); f.source.set([codex()]); _ = await monitor.current()
    f.source.set([]); f.source.setFailures(pids: [1])
    #expect(await monitor.current().running["cx_" + id] != nil)
    f.source.setFailures()
    #expect(await monitor.current().ended == ["cx_" + id])
    f.source.set([codex()]); _ = await monitor.current()
    f.source.set([codex(args: ["codex"], start: 2)])
    f.source.setFailures(candidates: [ProcessIdentity(pid: 1, startTime: 2)])
    #expect(await monitor.current().ended == ["cx_" + id])
}
@Test func failedProcessListExpiresAfterThreePolls() async throws {
    let f = try Fixture(); let monitor = f.monitor(); f.source.set([codex()]); _ = await monitor.current()
    f.source.set([]); f.source.setComplete(false)
    for _ in 1...3 { #expect(await monitor.current().running["cx_" + id] != nil) }
    #expect(await monitor.current().ended == ["cx_" + id])
}
@Test func saturatedBuffersGrowAndReportFailure() {
    var calls = 0
    let result: [Int32]? = SystemProcessSource.growingBuffer(initial: 1, make: { 0 }, read: { buffer in
        calls += 1; return calls == 1 ? buffer.count : 0
    })
    #expect(result == []); #expect(calls == 2)
    let failed: [Int32]? = SystemProcessSource.growingBuffer(initial: 1, make: { 0 }, read: { $0.count })
    #expect(failed == nil)
}

@Test func entryHintReadsOnlyExactEnvironmentVariableAndMapsSession() async throws {
    var argc: Int32 = 2
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/bin/codex\0\0codex\0argument\0OTHER_RB_ENTRY=wrong\0SECRET=private\0RB_ENTRY=e_task\0".utf8)
    #expect(SystemProcessSource.parseEntryHint(bytes) == "e_task")
    #expect(SystemProcessSource.parseEntryHint(Array(bytes.dropLast())) == nil)
    var missing = withUnsafeBytes(of: &argc) { Array($0) }
    missing += Array("/bin/codex\0\0codex\0RB_ENTRY=argument\0OTHER=private\0".utf8)
    #expect(SystemProcessSource.parseEntryHint(missing) == nil)
    let f = try Fixture()
    var process = codex(); process.entryHint = "e_task"
    f.source.set([process])
    #expect(await f.monitor().current().entryHints == ["cx_" + id: "e_task"])
}

@Test func streamEmitsWhenOnlyEntryHintChanges() async throws {
    let f = try Fixture(); f.source.set([codex()]); let monitor = f.monitor(); let received = Received()
    let task = Task { for await state in monitor.updates(interval: .milliseconds(20)) { await received.add(state) } }
    for _ in 0..<100 where await received.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    var process = codex(); process.entryHint = "e_task"; f.source.set([process])
    for _ in 0..<100 where await received.all().count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    task.cancel(); await task.value
    #expect(await received.all().last?.entryHints["cx_" + id] == "e_task")
}

@Test func ttyLookupCallsResolverOncePerDevice() {
    var calls: [UInt32: Int] = [:]
    let cache = TTYNameCache { device in
        calls[device, default: 0] += 1
        return device == 3 ? nil : "tty\(device)"
    }
    var missing = Set<UInt32>()
    for device: UInt32 in [1, 1, 2, 2, 3, 3, UInt32.max] {
        _ = cache.lookup(device, missing: &missing)
    }
    #expect(calls == [1: 1, 2: 1, 3: 1])
    missing = []
    #expect(cache.lookup(1, missing: &missing) == "tty1")
    #expect(cache.lookup(2, missing: &missing) == "tty2")
    #expect(cache.lookup(3, missing: &missing) == nil)
    #expect(calls == [1: 1, 2: 1, 3: 2])
}

@Test func foreignSnapshotReadsRootProcess() throws {
    let process = try #require(SystemProcessSource.foreignSnapshot(1))
    #expect(process.pid == 1 && process.name == "launchd" && process.startTime > 0)
}

@Test func foreignSnapshotRefusesOwnProcess() {
    #expect(SystemProcessSource.foreignSnapshot(getpid()) == nil)
}
