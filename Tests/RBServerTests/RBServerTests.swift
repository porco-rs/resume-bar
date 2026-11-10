import Darwin
import Foundation
import Testing
import RBContract
import RBLive
@testable import RBServer

@Test func callerChains() {
    func p(_ id: Int32, _ parent: Int32, _ name: String, _ path: String? = nil) -> ProcessSnapshot {
        ProcessSnapshot(pid: id, parentPID: parent, name: name, executablePath: path)
    }
    #expect(caller(in: [p(10, 9, "rb"), p(9, 1, "zsh")], startingAt: 10) == .person)
    #expect(caller(in: [p(10, 9, "rb"), p(9, 8, "zsh"), p(8, 1, "2.1.316", "/x/claude/versions/2")], startingAt: 10) == .claude)
    #expect(caller(in: [p(10, 9, "rb"), p(9, 8, "codex"), p(8, 1, "claude")], startingAt: 10) == .codex)
    #expect(caller(in: [p(10, 9, "rb")], startingAt: 10) == nil)
    #expect(processChain(in: [p(10, 9, "rb"), p(9, 8, "zsh"), p(8, 1, "codex")], startingAt: 10) == [10, 9, 8])
    #expect(processChain(in: [p(10, 9, "rb"), p(9, 10, "zsh")], startingAt: 10) == [10, 9])
}
@Test func rightsTable() {
    for who in [RBCaller.claude, .codex] {
        #expect(rights(.list(allProjects: false, project: nil), caller: who, ownProject: "garten") == nil)
        #expect(rights(.add(text: "x", deadline: nil, project: "garten"), caller: who, ownProject: "garten") == nil)
        #expect(rights(.done(query: nil, project: "other"), caller: who, ownProject: "garten") == .foreignProject)
        #expect(rights(.list(allProjects: true, project: nil), caller: who, ownProject: "garten") == .notAllowed)
        #expect(rights(.start(query: "x", tool: nil, project: nil), caller: who, ownProject: "garten") == .notAllowed)
        #expect(rights(.setDeadline(query: "x", deadline: nil, project: nil), caller: who, ownProject: "garten") == .notAllowed)
        #expect(rights(.export, caller: who, ownProject: "garten") == .notAllowed)
    }
    #expect(rights(.export, caller: .person, ownProject: nil) == nil)
}
private struct Fake: RBServing {
    func handle(_ request: RBRequest, from caller: RBCallerInfo) async -> RBResponse { .entries([]) }
}
private func socketPath() -> String { "/tmp/rb-" + UUID().uuidString.prefix(8) + ".sock" }
private func connectSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if result != 0 { close(fd); return -1 }; return fd
}
@Test func rbSocketModeRoundTripAndStop() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start(); defer { server.stop() }
    var info = stat(); #expect(lstat(path, &info) == 0); #expect(info.st_mode & 0o777 == 0o600)
    let fd = connectSocket(path); #expect(fd >= 0)
    var request = try JSONEncoder().encode(RBRequest.list(allProjects: false, project: nil)); request.append(10)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var bytes = [UInt8](repeating: 0, count: 1024); let n = recv(fd, &bytes, bytes.count, 0); close(fd)
    #expect(n > 0)
    if n > 0 { #expect(try JSONDecoder().decode(RBResponse.self, from: Data(bytes.prefix(n - 1))) == .entries([])) }
    server.stop(); #expect(lstat(path, &info) != 0)
}
@Test func rbSocketSecondInstanceRefused() throws {
    let path = socketPath(), first = RBServer(path: path, service: Fake()), second = RBServer(path: path, service: Fake())
    try first.start(); defer { first.stop() }
    #expect(throws: (any Error).self) { try second.start() }
}
@Test func rbSocketOversizedRefused() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start(); defer { server.stop() }
    let fd = connectSocket(path); #expect(fd >= 0)
    let data = [UInt8](repeating: 65, count: RBSocket.maxMessageBytes + 1)
    _ = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var bytes = [UInt8](repeating: 0, count: 1024); let n = recv(fd, &bytes, bytes.count, 0); close(fd)
    #expect(n > 0)
    if n > 0 { #expect(try JSONDecoder().decode(RBResponse.self, from: Data(bytes.prefix(n - 1))) == .failed(.badRequest, matches: [])) }
}
@Test func rbSocketStaleReplaced() throws {
    let path = socketPath(), fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    #expect(result == 0); close(fd)
    let server = RBServer(path: path, service: Fake()); try server.start(); defer { server.stop() }
    let client = connectSocket(path); #expect(client >= 0); if client >= 0 { close(client) }
}

@Test func callerRecognisesClaudeWithoutTerminal() {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                     ProcessSnapshot(pid: 9, parentPID: 1, name: "2.1.318")]
    #expect(caller(in: processes, startingAt: 10, executablePath: { $0 == 9 ? "/home/test/claude/versions/2.1.318" : nil }) == .claude)
}

private func roundTrip(_ path: String) throws -> Bool {
    let fd = connectSocket(path); guard fd >= 0 else { return false }; defer { close(fd) }
    var request = try JSONEncoder().encode(RBRequest.list(allProjects: false, project: nil)); request.append(10)
    guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count else { return false }
    var bytes = [UInt8](repeating: 0, count: 1024)
    let n = recv(fd, &bytes, bytes.count, 0)
    return n > 0 && (try? JSONDecoder().decode(RBResponse.self, from: Data(bytes.prefix(n - 1)))) == .entries([])
}
private func waitForRoundTrip(_ path: String, within seconds: Double = 5) throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    var result = try roundTrip(path)
    while !result && ProcessInfo.processInfo.systemUptime < deadline {
        usleep(50_000)
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        result = try roundTrip(path)
    }
    return result
}
@Test func rbSocketClientClosingAtOnceKeepsServerAlive() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start(); defer { server.stop() }
    var connected = 0
    for _ in 0..<200 { let fd = connectSocket(path); if fd >= 0 { connected += 1; close(fd) } }
    #expect(connected > 0)
    // Slots free only after the server reads each closed client, which takes longer on a loaded machine.
    #expect(try waitForRoundTrip(path))
}
@Test func rbSocketLimitsConnections() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start(); defer { server.stop() }
    var clients: [Int32] = []
    defer { for fd in clients { close(fd) } }
    for _ in 0..<16 { let fd = connectSocket(path); #expect(fd >= 0); clients.append(fd) }
    usleep(200_000)
    let extra = connectSocket(path); #expect(extra >= 0); defer { close(extra) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(extra, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var byte: UInt8 = 0; #expect(recv(extra, &byte, 1, 0) == 0)
}
@Test func rbSocketSlowClientIsCutOff() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start(); defer { server.stop() }
    let fd = connectSocket(path); #expect(fd >= 0); defer { close(fd) }
    var byte: UInt8 = 65
    for _ in 0..<6 { _ = send(fd, &byte, 1, 0); sleep(1) }
    #expect(recv(fd, &byte, 1, 0) <= 0)
    #expect(try roundTrip(path))
}
@Test func rbSocketStopEndsOpenClients() throws {
    let path = socketPath(), server = RBServer(path: path, service: Fake())
    try server.start()
    let fd = connectSocket(path); #expect(fd >= 0); defer { close(fd) }
    usleep(200_000); server.stop()
    var byte: UInt8 = 0; #expect(recv(fd, &byte, 1, 0) <= 0)
}

@Test func processChainStopsAtNearestTool() {
    let chain = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                 ProcessSnapshot(pid: 9, parentPID: 8, name: "codex"),
                 ProcessSnapshot(pid: 8, parentPID: 7, name: "zsh"),
                 ProcessSnapshot(pid: 7, parentPID: 1, name: "claude")]
    #expect(processChain(in: chain, startingAt: 10) == [10, 9])
    let nested = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                  ProcessSnapshot(pid: 9, parentPID: 7, name: "claude"),
                  ProcessSnapshot(pid: 7, parentPID: 1, name: "claude")]
    #expect(processChain(in: nested, startingAt: 10) == [10, 9])
    #expect(processChain(in: chain, startingAt: 8) == [8, 7])
    let plain = [ProcessSnapshot(pid: 10, parentPID: 8, name: "rb"), ProcessSnapshot(pid: 8, parentPID: 1, name: "zsh")]
    #expect(processChain(in: plain, startingAt: 10) == [10, 8])
    let versions = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"), ProcessSnapshot(pid: 9, parentPID: 8, name: "1.0"), ProcessSnapshot(pid: 8, parentPID: 1, name: "claude")]
    #expect(processChain(in: versions, startingAt: 10, executablePath: { $0 == 9 ? "/x/claude/versions/1" : nil }) == [10, 9])
}

@Test func identifyCallerAsksEachProcessOnce() throws {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "1.0"),
                     ProcessSnapshot(pid: 8, parentPID: 1, name: "zsh")]
    var calls: [Int32: Int] = [:]
    let result = try #require(identifyCaller(in: processes, startingAt: 10, executablePath: { pid in
        calls[pid, default: 0] += 1
        return pid == 9 && calls[pid] == 1 ? "/x/claude/versions/1" : nil
    }))
    #expect(result.caller == .claude && result.chain == [10, 9])
    #expect(calls == [10: 1, 9: 1])
}

@Test func identifyCallerWalksThroughRootOwnedLogin() throws {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh"),
                     ProcessSnapshot(pid: 7, parentPID: 1, name: "ghostty")]
    var calls: [Int32] = []
    let result = try #require(identifyCaller(in: processes, startingAt: 10, unreadable: { pid in
        calls.append(pid)
        return pid == 8 ? ProcessSnapshot(pid: 8, parentPID: 7, name: "login") : nil
    }))
    #expect(result.caller == .person && result.chain == [10, 9, 8, 7])
    #expect(calls == [8])
}

@Test func identifyCallerFindsToolAboveRootOwnedProcess() throws {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh"),
                     ProcessSnapshot(pid: 7, parentPID: 1, name: "claude")]
    let result = try #require(identifyCaller(in: processes, startingAt: 10, unreadable: {
        $0 == 8 ? ProcessSnapshot(pid: 8, parentPID: 7, name: "login") : nil
    }))
    #expect(result.caller == .claude && result.chain == [10, 9, 8, 7])
    let tool = identifyCaller(in: Array(processes.prefix(2)), startingAt: 10, unreadable: {
        $0 == 8 ? ProcessSnapshot(pid: 8, parentPID: 1, name: "codex") : nil
    })
    #expect(tool?.caller == .codex && tool?.chain == [10, 9, 8])
}

@Test func identifyCallerFailsClosedWithoutParent() {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb")]
    var calls = 0
    #expect(identifyCaller(in: processes, startingAt: 10, unreadable: { _ in calls += 1; return nil }) == nil)
    #expect(calls == 1)
}

@Test func identifyCallerRefusesRecycledParent() {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb", startTime: 300),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh", startTime: 200),
                     ProcessSnapshot(pid: 7, parentPID: 1, name: "claude", startTime: 100)]
    #expect(identifyCaller(in: processes, startingAt: 10, unreadable: { _ in
        ProcessSnapshot(pid: 8, parentPID: 7, name: "login", startTime: 201)
    }) == nil)
    #expect(identifyCaller(in: processes, startingAt: 10, unreadable: { _ in
        ProcessSnapshot(pid: 6, parentPID: 7, name: "login", startTime: 150)
    }) == nil)
}

@Test func identifyCallerRefusesRecycledKnownParent() {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb", startTime: 200),
                     ProcessSnapshot(pid: 9, parentPID: 1, name: "codex", startTime: 201)]
    #expect(identifyCaller(in: processes, startingAt: 10) == nil)
    let unknownChildTime = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb"), processes[1]]
    #expect(identifyCaller(in: unknownChildTime, startingAt: 10)?.caller == .codex)
}

@Test func identifyCallerRefusesEndedProcessWhenPathRequired() {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb", executablePath: "/usr/bin/rb"),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh", executablePath: "/bin/zsh"),
                     ProcessSnapshot(pid: 8, parentPID: 7, name: "2.1.318"),
                     ProcessSnapshot(pid: 7, parentPID: 6, name: "zsh", executablePath: "/bin/zsh")]
    #expect(identifyCaller(in: processes, startingAt: 10, unreadable: {
        $0 == 6 ? ProcessSnapshot(pid: 6, parentPID: 1, name: "login") : nil
    }, pathRequired: true) == nil)
}

@Test func identifyCallerAcceptsReadablePathsWhenRequired() throws {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb", startTime: 400, executablePath: "/usr/bin/rb"),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh", startTime: 300),
                     ProcessSnapshot(pid: 7, parentPID: 1, name: "ghostty", startTime: 100, executablePath: "/Applications/Ghostty")]
    var calls: [Int32: Int] = [:]
    let result = try #require(identifyCaller(in: processes, startingAt: 10, executablePath: { pid in
        calls[pid, default: 0] += 1
        return pid == 9 ? "/bin/zsh" : nil
    }, unreadable: { pid in
        pid == 8 ? ProcessSnapshot(pid: 8, parentPID: 7, name: "login", startTime: 200) : nil
    }, pathRequired: true))
    #expect(result.caller == .person && result.chain == [10, 9, 8, 7])
    #expect(calls == [10: 1, 9: 1, 8: 1, 7: 1])
}

@Test func identifyCallerAcceptsOlderRootParent() throws {
    let processes = [ProcessSnapshot(pid: 10, parentPID: 9, name: "rb", startTime: 400),
                     ProcessSnapshot(pid: 9, parentPID: 8, name: "zsh", startTime: 300),
                     ProcessSnapshot(pid: 7, parentPID: 1, name: "ghostty", startTime: 100)]
    let result = try #require(identifyCaller(in: processes, startingAt: 10, unreadable: { pid in
        pid == 8 ? ProcessSnapshot(pid: 8, parentPID: 7, name: "login", startTime: 200) : nil
    }))
    #expect(result.caller == .person && result.chain == [10, 9, 8, 7])
}
