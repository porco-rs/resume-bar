import Darwin
import Foundation
import RBContract
import RBLive

private func recognizedTool(_ process: ProcessSnapshot, executablePath: (Int32) -> String?) -> RBCaller? {
    if process.name == "codex" { return .codex }
    if process.name == "claude" || (executablePath(process.pid) ?? process.executablePath)?.contains("/claude/versions/") == true ||
        process.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent == "claude" }) == true { return .claude }
    return nil
}

private func walkCaller(in processes: [ProcessSnapshot], startingAt pid: Int32,
                        executablePath: (Int32) -> String?, unreadable: (Int32) -> ProcessSnapshot?,
                        pathRequired: Bool = false) -> (caller: RBCaller?, chain: [Int32]) {
    let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var chain: [Int32] = [], current = pid, seen = Set<Int32>()
    var childStart: UInt64 = 0
    while current > 1 {
        guard seen.insert(current).inserted else { return (nil, chain) }
        let process: ProcessSnapshot
        let observedPath: String?
        let requireKnownPath = pathRequired && table[current] != nil
        if let known = table[current] {
            process = known
            observedPath = requireKnownPath ? executablePath(current) : nil
            guard !requireKnownPath || observedPath != nil || known.executablePath != nil else { return (nil, chain) }
        } else {
            guard let foreign = unreadable(current), foreign.pid == current else { return (nil, chain) }
            process = foreign
            observedPath = nil
        }
        guard childStart == 0 || process.startTime <= childStart else { return (nil, chain) }
        chain.append(current)
        if let tool = recognizedTool(process, executablePath: { pid in
            requireKnownPath ? observedPath : executablePath(pid)
        }) { return (tool, chain) }
        childStart = process.startTime
        current = process.parentPID
    }
    return (.person, chain)
}

/// Walk once so attribution and the chain share the same observation.
public func identifyCaller(in processes: [ProcessSnapshot], startingAt pid: Int32,
                           executablePath: (Int32) -> String? = { _ in nil },
                           unreadable: (Int32) -> ProcessSnapshot? = { _ in nil },
                           pathRequired: Bool = false) -> (caller: RBCaller, chain: [Int32])? {
    let result = walkCaller(in: processes, startingAt: pid, executablePath: executablePath, unreadable: unreadable, pathRequired: pathRequired)
    guard let caller = result.caller else { return nil }
    return (caller, result.chain)
}

public func caller(in processes: [ProcessSnapshot], startingAt pid: Int32,
                   executablePath: (Int32) -> String? = { _ in nil },
                   unreadable: (Int32) -> ProcessSnapshot? = { _ in nil }) -> RBCaller? {
    identifyCaller(in: processes, startingAt: pid, executablePath: executablePath, unreadable: unreadable)?.caller
}

public func processChain(in processes: [ProcessSnapshot], startingAt pid: Int32,
                         executablePath: (Int32) -> String? = { _ in nil },
                         unreadable: (Int32) -> ProcessSnapshot? = { _ in nil }) -> [Int32] {
    walkCaller(in: processes, startingAt: pid, executablePath: executablePath, unreadable: unreadable).chain
}

/// Authorization is independent of whether an operation is implemented yet.
public func rights(_ request: RBRequest, caller: RBCaller, ownProject: String?) -> RBErrorCode? {
    guard caller != .person else { return nil }
    let project: String?
    switch request {
    case .list(let all, let name):
        guard ownProject != nil else { return .foreignProject }
        if all { return .notAllowed }; project = name
    case .add(_, _, let name), .done(_, let name): project = name
    case .start, .setDeadline, .export: return .notAllowed
    }
    guard ownProject != nil else { return .foreignProject }
    if let project, ownProject.map({ $0.caseInsensitiveCompare(project) == .orderedSame }) != true { return .foreignProject }
    return nil
}

public final class RBServer: @unchecked Sendable {
    private let configuredPath: String?
    private var path: String { configuredPath ?? Self.defaultPath }
    private let service: any RBServing
    private let queue = DispatchQueue(label: "rb.server.lifecycle")
    private var listener: Int32 = -1
    private var identity: (dev_t, ino_t)?
    private var lockFD: Int32 = -1
    private var generation = UUID()
    private var clients: [Int32: UUID] = [:]
    private var expired = Set<UUID>()
    private var requests: [UUID: Task<Void, Never>] = [:]

    public init(path: String? = nil, service: any RBServing) { self.configuredPath = path; self.service = service }
    public static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResumeBar", isDirectory: true).appendingPathComponent(RBSocket.fileName).path
    }
    public func start() throws {
        try queue.sync {
            guard listener < 0 else { return }
            signal(SIGPIPE, SIG_IGN)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var address = try Self.address(path)
            let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw POSIXError(.EACCES) }
            var lockInfo = stat()
            guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                close(lock); throw POSIXError(.EADDRINUSE)
            }
            var success = false
            defer { if !success { flock(lock, LOCK_UN); close(lock) } }
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), unlink(path) == 0 else { throw POSIXError(.EEXIST) }
            } else if errno != ENOENT { throw POSIXError(.EACCES) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var noSigPipe: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0 else {
                close(fd); throw POSIXError(.EIO)
            }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
            var info = stat()
            guard lstat(path, &info) == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
                close(fd); unlink(path); throw POSIXError(.EIO)
            }
            identity = (info.st_dev, info.st_ino); listener = fd; lockFD = lock; generation = UUID(); success = true
            let run = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd, run: run) }
        }
    }
    public func stop() {
        queue.sync {
            guard listener >= 0 else { return }
            generation = UUID()
            shutdown(listener, SHUT_RDWR); close(listener); listener = -1
            for task in requests.values { task.cancel() }
            for fd in clients.keys { shutdown(fd, SHUT_RDWR) }
            var info = stat()
            if let identity, lstat(path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(path) }
            identity = nil
            flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1
        }
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes + [0]) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    private func acceptLoop(_ fd: Int32, run: UUID) {
        while queue.sync(execute: { generation == run && listener == fd }) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }
                else if errno != EINTR { usleep(10_000) }
                continue
            }
            let token = UUID()
            let accepted = queue.sync { () -> Bool in
                guard generation == run, listener == fd, clients.count < 16 else { return false }
                clients[client] = token; return true
            }
            guard accepted else { close(client); continue }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.queue.sync {
                    if self?.clients[client] == token { self?.expired.insert(token); self?.requests[token]?.cancel(); shutdown(client, SHUT_RDWR) }
                }
            }
            DispatchQueue.global(qos: .utility).async { [self] in serve(client, token: token, run: run) }
        }
    }
    private func finish(_ fd: Int32, token: UUID) {
        queue.sync {
            guard clients[fd] == token else { return }
            clients.removeValue(forKey: fd); expired.remove(token); requests.removeValue(forKey: token); close(fd)
        }
    }
    private func active(_ fd: Int32, token: UUID, run: UUID) -> Bool {
        queue.sync { generation == run && clients[fd] == token && !expired.contains(token) }
    }
    private func serve(_ fd: Int32, token: UUID, run: UUID) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var len = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getpeereid(fd, &uid, &gid) == 0 else {
            Self.sendResponse(.failed(.callerUnknown, matches: []), fd); finish(fd, token: token); return
        }
        guard uid == getuid() else {
            Self.sendResponse(.failed(.notAllowed, matches: []), fd); finish(fd, token: token); return
        }
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else {
            Self.sendResponse(.failed(.callerUnknown, matches: []), fd); finish(fd, token: token); return
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= RBSocket.maxMessageBytes {
            let count = recv(fd, &buffer, min(buffer.count, RBSocket.maxMessageBytes + 1 - data.count), 0)
            if count <= 0 { finish(fd, token: token); return }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline <= RBSocket.maxMessageBytes,
                      let request = try? JSONDecoder().decode(RBRequest.self, from: data.prefix(upTo: newline)) else {
                    Self.sendResponse(.failed(.badRequest, matches: []), fd); finish(fd, token: token); return
                }
                let probe = SystemProcessSource().probe()
                let executablePath: (Int32) -> String? = { pid in
                    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
                }
                guard probe.complete, let identity = identifyCaller(in: probe.processes, startingAt: pid, executablePath: executablePath, unreadable: SystemProcessSource.foreignSnapshot, pathRequired: true) else {
                    Self.sendResponse(.failed(.callerUnknown, matches: []), fd); finish(fd, token: token); return
                }
                var vnode = proc_vnodepathinfo()
                let count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode)))
                let cwd: String? = count == MemoryLayout<proc_vnodepathinfo>.size ? withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : nil
                let scheduled = queue.sync { () -> Bool in
                    guard generation == run, clients[fd] == token, !expired.contains(token) else { return false }
                    requests[token] = Task { [self] in
                        guard !Task.isCancelled, active(fd, token: token, run: run) else { finish(fd, token: token); return }
                        let response = await service.handle(request, from: RBCallerInfo(caller: identity.caller, cwd: cwd, processChain: identity.chain))
                        if !Task.isCancelled && active(fd, token: token, run: run) { Self.sendResponse(response, fd) }
                        finish(fd, token: token)
                    }
                    return true
                }
                if !scheduled { finish(fd, token: token) }
                return
            }
        }
        Self.sendResponse(.failed(.badRequest, matches: []), fd); finish(fd, token: token)
    }
    private static func sendResponse(_ response: RBResponse, _ fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n <= 0 { break }; offset += n
            }
        }
    }
}
