import Darwin
import Foundation

struct LibprocSource: TerminalProcessSource {
    func processes(tty: String) async -> [TerminalProcess]? {
        await Task.detached { inspect(tty: tty) }.value
    }

    private func inspect(tty: String) -> [TerminalProcess]? {
        guard !tty.isEmpty, !tty.contains("/"), tty.hasPrefix("tty") else { return nil }
        var device = stat()
        guard stat("/dev/" + tty, &device) == 0,
              let records = Self.ttyRecords(device: device.st_rdev) else { return nil }
        var sessions: [pid_t: pid_t] = [:]
        var directories: [pid_t: String] = [:]
        for record in records {
            let pid = record.kp_proc.p_pid
            let sessionID = getsid(pid)
            guard sessionID > 0 else { return nil }
            sessions[pid] = sessionID
            // Only the shell's directory is needed to reopen an idle window.
            if Self.shells.contains(Self.command(record)) {
                directories[pid] = Self.workingDirectory(pid)
            }
        }
        return Self.parse(records, sessions: sessions, directories: directories)
    }

    static func ttyRecords(device: dev_t) -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, device]
        return readRecords { buffer, size in
            sysctl(&mib, 4, buffer, &size, nil, 0)
        }
    }

    static func readRecords(_ query: (UnsafeMutableRawPointer?, inout Int) -> Int32) -> [kinfo_proc]? {
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<2 {
            var size = 0
            guard query(nil, &size) == 0, size >= 0, size % stride == 0 else { return nil }
            guard size > 0 else { return [] }
            var records = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let capacity = size
            let status = records.withUnsafeMutableBytes {
                query($0.baseAddress, &size)
            }
            if status == 0 {
                guard size >= 0, size <= capacity, size % stride == 0 else { return nil }
                return Array(records.prefix(size / stride))
            }
            // A new process may have joined this TTY since the sizing call.
            guard errno == ENOMEM, attempt == 0 else { return nil }
        }
        return nil
    }

    /// Pure conversion; session IDs and optional directories are collected separately.
    static func parse(_ records: [kinfo_proc], sessions: [pid_t: pid_t],
                      directories: [pid_t: String] = [:]) -> [TerminalProcess]? {
        var found: [TerminalProcess] = []
        for record in records {
            let pid = record.kp_proc.p_pid
            let name = command(record)
            guard pid > 0, let sessionID = sessions[pid], sessionID > 0, !name.isEmpty else { return nil }
            let start = record.kp_proc.p_un.__p_starttime
            found.append(TerminalProcess(name: name, cwd: directories[pid], pid: pid,
                         start: UInt64(start.tv_sec) &* 1_000_000 &+ UInt64(start.tv_usec),
                         parentPID: record.kp_eproc.e_ppid, sessionID: sessionID,
                         processGroupID: record.kp_eproc.e_pgid,
                         foregroundGroupID: record.kp_eproc.e_tpgid))
        }
        return found
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh"]

    private static func command(_ record: kinfo_proc) -> String {
        withUnsafeBytes(of: record.kp_proc.p_comm) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var paths = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(size)) == size else { return nil }
        return withUnsafeBytes(of: paths.pvi_cdir.vip_path) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
