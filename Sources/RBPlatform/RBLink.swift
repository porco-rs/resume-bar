import Darwin
import Foundation

public enum RBLinkDecision: Equatable, Sendable { case create, replace, remove, unchanged, taken }
public enum RBLinkItem: Equatable, Sendable { case missing, link(String), other }

public enum RBLink {
    public static func decide(item: RBLinkItem, target: String, recorded: String?, enabled: Bool) -> RBLinkDecision {
        switch (item, enabled) {
        case (.missing, true): return .create
        case (.missing, false): return .unchanged
        case (.other, _): return .taken
        case (.link(let old), _) where old != target && old != recorded: return .taken
        case (.link, false): return .remove
        case (.link(let old), true): return old == target ? .unchanged : .replace
        }
    }
    public struct Report: Sendable {
        public let taken: Bool
        public let otherCommands: [String]
    }
    private static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func item(_ fd: Int32, _ name: String) throws -> RBLinkItem {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .missing }
            throw error()
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return .other }
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = readlinkat(fd, name, &bytes, bytes.count)
        if count < 0 { throw error() }
        guard count < bytes.count else { throw POSIXError(.ENAMETOOLONG) }
        return .link(String(decoding: bytes.prefix(count), as: UTF8.self))
    }

    public static func reconcile(home: URL, record: URL, target: URL, enabled: Bool, alternatives: [URL],
                                 beforeChange: () -> Void = {}, afterSwap: () -> Void = {}) throws -> Report {
        let fm = FileManager.default
        let others = alternatives.filter { fm.isExecutableFile(atPath: $0.path) }.map(\.path)
        func report(_ taken: Bool) -> Report { Report(taken: taken, otherCommands: others) }
        let homeFD = open(home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard homeFD >= 0 else { throw error() }
        defer { close(homeFD) }
        func directory(_ parent: Int32, _ name: String) throws -> Int32? {
            var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT {
                guard enabled else { return nil }
                if mkdirat(parent, name, 0o755) != 0 && errno != EEXIST { throw error() }
                fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if fd < 0 {
                if errno == ELOOP || errno == ENOTDIR { return -1 }
                throw error()
            }
            return fd
        }
        guard let localFD = try directory(homeFD, ".local") else { return report(false) }
        guard localFD >= 0 else { return report(true) }
        defer { close(localFD) }
        guard let binFD = try directory(localFD, "bin") else { return report(false) }
        guard binFD >= 0 else { return report(true) }
        defer { close(binFD) }
        let observed = try item(binFD, "rb")
        let recorded = try? String(contentsOf: record, encoding: .utf8)
        let decision = decide(item: observed, target: target.path, recorded: recorded, enabled: enabled)
        if decision == .taken { return report(true) }
        func writeRecord() throws {
            try fm.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try target.path.write(to: record, atomically: true, encoding: .utf8)
        }
        if enabled && decision == .unchanged && observed == .link(target.path) && recorded != target.path {
            try writeRecord()
        }
        guard decision != .unchanged else { return report(false) }
        beforeChange()
        let temporary = ".rb." + UUID().uuidString
        switch decision {
        case .create:
            if symlinkat(target.path, binFD, "rb") != 0 {
                if errno == EEXIST { return report(true) }
                throw error()
            }
        case .replace:
            guard symlinkat(target.path, binFD, temporary) == 0 else { throw error() }
            if renameatx_np(binFD, temporary, binFD, "rb", UInt32(RENAME_SWAP)) != 0 {
                let failure = error()
                if (try? item(binFD, temporary)) == .link(target.path) { _ = unlinkat(binFD, temporary, 0) }
                throw failure
            }
            afterSwap()
            let swapped: RBLinkItem
            do { swapped = try item(binFD, temporary) }
            catch {
                let failure = error
                if try swapBack(binFD, temporary, target: target.path) { return report(true) }
                throw failure
            }
            if swapped != observed {
                _ = try swapBack(binFD, temporary, target: target.path)
                return report(true)
            }
            guard unlinkat(binFD, temporary, 0) == 0 else { throw error() }
        case .remove:
            if renameatx_np(binFD, "rb", binFD, temporary, UInt32(RENAME_EXCL)) != 0 {
                if errno == ENOENT { return report(false) }
                throw error()
            }
            let moved: RBLinkItem
            do { moved = try item(binFD, temporary) }
            catch {
                _ = renameatx_np(binFD, temporary, binFD, "rb", UInt32(RENAME_EXCL))
                throw error
            }
            if moved != observed {
                guard renameatx_np(binFD, temporary, binFD, "rb", UInt32(RENAME_EXCL)) == 0 else { throw error() }
                return report(true)
            }
            guard unlinkat(binFD, temporary, 0) == 0 else { throw error() }
            if unlink(record.path) != 0 && errno != ENOENT { throw error() }
        case .unchanged, .taken: break
        }
        if decision == .create || decision == .replace { try writeRecord() }
        return report(false)
    }

    // Restore the displaced item, deleting only the link created by this call.
    private static func swapBack(_ fd: Int32, _ temporary: String, target: String) throws -> Bool {
        if renameatx_np(fd, temporary, fd, "rb", UInt32(RENAME_SWAP)) != 0 {
            guard errno == ENOENT else { throw error() }
            guard renameatx_np(fd, temporary, fd, "rb", UInt32(RENAME_EXCL)) == 0 else { throw error() }
            return true
        }
        guard try item(fd, temporary) == .link(target) else { throw POSIXError(.EEXIST) }
        guard unlinkat(fd, temporary, 0) == 0 else { throw error() }
        return false
    }
}
