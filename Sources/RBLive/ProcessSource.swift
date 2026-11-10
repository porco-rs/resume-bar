import Darwin
import Foundation

/// A process snapshot contains metadata only, never terminal contents.
public struct ProcessSnapshot: Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var tty: String?
    public var arguments: [String]
    public var openFiles: [String]
    public var executablePath: String?
    public var entryHint: String?
    /// Distinguishes a reused PID from the original process.
    public var startTime: UInt64

    public init(pid: Int32, parentPID: Int32, name: String, tty: String? = nil,
                arguments: [String] = [], openFiles: [String] = [], startTime: UInt64 = 0,
                executablePath: String? = nil, entryHint: String? = nil) {
        self.pid = pid; self.parentPID = parentPID; self.name = name; self.tty = tty
        self.arguments = arguments; self.openFiles = openFiles; self.startTime = startTime
        self.executablePath = executablePath; self.entryHint = entryHint
    }

    /// Candidate metadata only; a matching interactive registry entry is still required.
    var isClaudeCandidate: Bool {
        name == "claude" || executablePath?.contains("/claude/versions/") == true ||
            arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent == "claude" } == true
    }
}

public protocol ProcessSource: Sendable {
    func processes() -> [ProcessSnapshot]
    func probe() -> ProcessProbe
}

public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    public var startTime: UInt64
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

public struct ProcessProbe: Sendable {
    public var processes: [ProcessSnapshot]
    /// False only when the process list itself could not be obtained.
    public var complete: Bool
    public var unreadablePIDs: Set<Int32>
    public var incompleteCandidates: Set<ProcessIdentity>
    public init(processes: [ProcessSnapshot], complete: Bool,
                unreadablePIDs: Set<Int32> = [], incompleteCandidates: Set<ProcessIdentity> = []) {
        self.processes = processes; self.complete = complete
        self.unreadablePIDs = unreadablePIDs; self.incompleteCandidates = incompleteCandidates
    }
}

public extension ProcessSource {
    func probe() -> ProcessProbe { ProcessProbe(processes: processes(), complete: true) }
}

// Successful device names persist across probes; failures are retried by the next probe.
final class TTYNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [UInt32: String] = [:]
    private let resolver: (UInt32) -> String?

    init(resolver: @escaping (UInt32) -> String?) { self.resolver = resolver }

    func lookup(_ device: UInt32, missing: inout Set<UInt32>) -> String? {
        guard device != UInt32.max, !missing.contains(device) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let name = names[device] { return name }
        if let name = resolver(device) { names[device] = name; return name }
        missing.insert(device)
        return nil
    }
}

public struct SystemProcessSource: ProcessSource {
    public init() {}
    private static let ttyNames = TTYNameCache { device in
        devname(dev_t(bitPattern: device), mode_t(S_IFCHR)).map { String(cString: $0) }
    }

    public static func foreignSnapshot(_ pid: Int32) -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != SZOMB, info.kp_proc.p_flag & P_WEXIT == 0,
              info.kp_eproc.e_ucred.cr_uid != getuid() else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec >= 0, start.tv_usec >= 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let startTime = UInt64(start.tv_sec) &* 1_000_000 &+ UInt64(start.tv_usec)
        return ProcessSnapshot(pid: pid, parentPID: info.kp_eproc.e_ppid, name: name, startTime: startTime)
    }

    public func processes() -> [ProcessSnapshot] { probe().processes }

    // A full buffer is ambiguous: libproc may have truncated it.
    static func growingBuffer<Element>(initial: Int, make: () -> Element,
                                       read: (UnsafeMutableRawBufferPointer) -> Int) -> [Element]? {
        var capacity = max(initial, 1)
        for _ in 0..<10 {
            guard capacity <= Int(Int32.max) / MemoryLayout<Element>.stride else { return nil }
            var buffer = [Element](repeating: make(), count: capacity)
            let bytes = buffer.withUnsafeMutableBytes { read($0) }
            guard bytes >= 0, bytes <= capacity * MemoryLayout<Element>.stride,
                  bytes % MemoryLayout<Element>.stride == 0 else { return nil }
            if bytes < capacity * MemoryLayout<Element>.stride {
                return Array(buffer.prefix(bytes / MemoryLayout<Element>.stride))
            }
            capacity *= 2
        }
        return nil
    }

    public func probe() -> ProcessProbe {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0, let pids: [pid_t] = Self.growingBuffer(initial: count + 128, make: { 0 }, read: {
            let n = proc_listallpids($0.baseAddress, Int32($0.count))
            return n > 0 ? Int(n) * MemoryLayout<pid_t>.stride : -1
        }) else { return ProcessProbe(processes: [], complete: false) }
        var unreadablePIDs = Set<Int32>()
        var incompleteCandidates = Set<ProcessIdentity>()
        var snapshots: [ProcessSnapshot] = []
        var missingTTYs = Set<UInt32>()
        for pid in pids where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout<proc_bsdinfo>.size else {
                unreadablePIDs.insert(pid); continue
            }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let tty = Self.ttyNames.lookup(info.e_tdev, missing: &missingTTYs)
            // Claude's accounting name can be its version, so inspect all TTY processes.
            let path = tty != nil ? executablePath(pid) : nil
            let args = tty != nil ? arguments(pid) : []
            let files = tty != nil && name == "codex" ? openFiles(pid) : []
            let startTime = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
            if tty != nil && (files == nil || args == nil) {
                incompleteCandidates.insert(ProcessIdentity(pid: pid, startTime: startTime))
            }
            let candidate = ProcessSnapshot(pid: pid, parentPID: Int32(info.pbi_ppid), name: name, tty: tty,
                                            arguments: args ?? [], executablePath: path)
            let hint = tty != nil && (name == "codex" || candidate.isClaudeCandidate) ? entryHint(pid) : nil
            snapshots.append(ProcessSnapshot(pid: pid, parentPID: Int32(info.pbi_ppid), name: name, tty: tty,
                               arguments: args ?? [], openFiles: files ?? [], startTime: startTime, executablePath: path, entryHint: hint))
        }
        return ProcessProbe(processes: snapshots, complete: true, unreadablePIDs: unreadablePIDs,
                            incompleteCandidates: incompleteCandidates)
    }

    private func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; Swift cannot import that macro.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let parsed = Self.parseArguments(Array(bytes.prefix(size)))
        return parsed.isEmpty ? nil : parsed
    }

    private func entryHint(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return Self.parseEntryHint(Array(bytes.prefix(size)))
    }

    /// Inspect only the named environment value; never decode or retain other variables.
    public static func parseEntryHint(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes.prefix(4)) }
        guard argc > 0, argc <= 65536 else { return nil }
        var pos = 4
        while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
        while pos < bytes.count && bytes[pos] == 0 { pos += 1 }
        for _ in 0..<argc {
            while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
            guard pos < bytes.count else { return nil }
            pos += 1
        }
        let prefix = Array("RB_ENTRY=".utf8)
        while pos < bytes.count {
            let start = pos
            while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
            guard pos < bytes.count else { return nil }
            if bytes[start..<pos].starts(with: prefix) {
                let value = bytes[(start + prefix.count)..<pos]
                return value.isEmpty ? nil : String(validating: value, as: UTF8.self)
            }
            pos += 1
        }
        return nil
    }

    /// KERN_PROCARGS2 starts with argc, then executable path, padding, and argc NUL-terminated arguments.
    public static func parseArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= MemoryLayout<Int32>.size else { return [] }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes.prefix(4)) }
        guard argc > 0, argc <= 65536 else { return [] }
        var pos = 4
        while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
        while pos < bytes.count && bytes[pos] == 0 { pos += 1 }
        var result: [String] = []
        while result.count < Int(argc), pos < bytes.count {
            let start = pos
            while pos < bytes.count && bytes[pos] != 0 { pos += 1 }
            guard pos < bytes.count else { return [] }
            result.append(String(decoding: bytes[start..<pos], as: UTF8.self))
            pos += 1
        }
        return result.count == Int(argc) ? result : []
    }

    private func openFiles(_ pid: pid_t) -> [String]? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0, let fds: [proc_fdinfo] = Self.growingBuffer(
            initial: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16, make: { proc_fdinfo() }, read: {
                let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                return bytes > 0 ? Int(bytes) : -1
            }) else { return nil }
        var paths: [String] = []
        for fd in fds where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var path = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &path, Int32(MemoryLayout.size(ofValue: path))) == MemoryLayout<vnode_fdinfowithpath>.size else { return nil }
            paths.append(withUnsafeBytes(of: path.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        return paths
    }
}
