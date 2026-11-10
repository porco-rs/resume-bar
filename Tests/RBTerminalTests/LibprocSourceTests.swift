import Darwin
import Testing
@testable import RBTerminal

private func record(_ name: String, pid: pid_t, parent: pid_t = 90, group: pid_t = 100,
                    foreground: pid_t = 100, seconds: Int = 123, microseconds: Int32 = 456) -> kinfo_proc {
    var info = kinfo_proc()
    info.kp_proc.p_pid = pid
    info.kp_proc.p_un.__p_starttime = timeval(tv_sec: seconds, tv_usec: microseconds)
    info.kp_eproc.e_ppid = parent
    info.kp_eproc.e_pgid = group
    info.kp_eproc.e_tpgid = foreground
    withUnsafeMutableBytes(of: &info.kp_proc.p_comm) { bytes in
        bytes.copyBytes(from: name.utf8.prefix(bytes.count))
    }
    return info
}

@Test func kinfoParsingPreservesLoginShellAndJobIdentities() throws {
    let records = [record("login", pid: 90, parent: 1, group: 90), record("zsh", pid: 100),
                   record("sleep", pid: 101, parent: 100, group: 101, seconds: 124, microseconds: 789)]
    let processes = try #require(LibprocSource.parse(records, sessions: [90: 90, 100: 90, 101: 90],
                                                   directories: [100: "/synthetic/project"]))
    #expect(processes == [
        TerminalProcess(name: "login", cwd: nil, pid: 90, start: 123_000_456,
                        parentPID: 1, sessionID: 90, processGroupID: 90, foregroundGroupID: 100),
        TerminalProcess(name: "zsh", cwd: "/synthetic/project", pid: 100, start: 123_000_456,
                        parentPID: 90, sessionID: 90, processGroupID: 100, foregroundGroupID: 100),
        TerminalProcess(name: "sleep", cwd: nil, pid: 101, start: 124_000_789,
                        parentPID: 100, sessionID: 90, processGroupID: 101, foregroundGroupID: 100)
    ])
}

@Test func kinfoParsingRejectsUnreadableTTYProcess() {
    let records = [record("zsh", pid: 100), record("sleep", pid: 101)]
    #expect(LibprocSource.parse(records, sessions: [100: 100]) == nil)
    #expect(LibprocSource.parse(records, sessions: [100: 100, 101: -1]) == nil)
    // Failures for processes outside the TTY snapshot do not affect the result.
    #expect(LibprocSource.parse([records[0]], sessions: [100: 100, 999: -1])?.count == 1)
}

@Test func kinfoCommandParsingIsBoundedByFieldSize() throws {
    let name = String(repeating: "x", count: MemoryLayout.size(ofValue: kinfo_proc().kp_proc.p_comm))
    let processes = try #require(LibprocSource.parse([record(name, pid: 100)], sessions: [100: 100]))
    #expect(processes.first?.name == name)
}

@Test func sysctlBufferRetriesOnceAfterGrowthAndUsesReturnedCount() throws {
    let stride = MemoryLayout<kinfo_proc>.stride
    var calls = 0
    let records = try #require(LibprocSource.readRecords { buffer, size in
        calls += 1
        if buffer == nil {
            size = (calls == 1 ? 1 : 3) * stride
            return 0
        }
        if calls == 2 { errno = ENOMEM; return -1 }
        let output = buffer!.assumingMemoryBound(to: kinfo_proc.self)
        output[0] = record("zsh", pid: 100)
        output[1] = record("sleep", pid: 101)
        size = 2 * stride
        return 0
    })
    #expect(calls == 4)
    #expect(records.map { $0.kp_proc.p_pid } == [100, 101])
}

@Test func sysctlBufferFailsWithoutReturningPartialSnapshot() {
    let stride = MemoryLayout<kinfo_proc>.stride
    var calls = 0
    #expect(LibprocSource.readRecords { buffer, size in
        calls += 1
        if buffer == nil { size = stride; return 0 }
        errno = ENOMEM
        return -1
    } == nil)
    #expect(calls == 4)

    calls = 0
    #expect(LibprocSource.readRecords { buffer, size in
        calls += 1
        if buffer == nil { size = stride; return 0 }
        errno = EPERM
        return -1
    } == nil)
    #expect(calls == 2)

    #expect(LibprocSource.readRecords { buffer, size in
        size = buffer == nil ? stride : stride - 1
        return 0
    } == nil)
}

@Test func sysctlBufferAcceptsEmptySnapshotAndRejectsSizingFailure() throws {
    let records = try #require(LibprocSource.readRecords { _, size in size = 0; return 0 })
    #expect(records.isEmpty)
    #expect(LibprocSource.parse(records, sessions: [:]) == [])
    #expect(LibprocSource.readRecords { _, _ in errno = EPERM; return -1 } == nil)
}
