import CoreServices
import Darwin
import Foundation

struct EventPaths: Sendable {
    struct Variants: Sendable {
        let literal: String
        let real: String

        init(_ url: URL) {
            literal = url.path
            var ancestor = literal
            var remainder: [String] = []
            while true {
                if let resolved = realpath(ancestor, nil) {
                    defer { free(resolved) }
                    let base = String(cString: resolved)
                    real = remainder.reversed().reduce(base) { $0 == "/" ? $0 + $1 : $0 + "/" + $1 }
                    break
                }
                guard ancestor != "/" else { real = literal; break }
                remainder.append((ancestor as NSString).lastPathComponent)
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
    }

    let claude: Variants
    let codex: Variants
    let index: Variants

    init(_ roots: Roots) {
        claude = Variants(roots.claude)
        codex = Variants(roots.codex)
        index = Variants(roots.index)
    }
}

func eventCanChangeResult(path: String, flags: FSEventStreamEventFlags, roots: EventPaths) -> Bool {
    let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
    if flags & rescan != 0 { return true }
    let event = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    func within(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    func matches(claude: String, codex: String, index: String) -> Bool {
        if [claude, codex, index].contains(where: { within($0, event) }) { return true }
        if within(event, claude) {
            let components = event.dropFirst(claude.count).split(separator: "/")
            if isDirectory { return components.count == 1 }
            if components.count == 2 {
                let file = components[1]
                return file.hasSuffix(".jsonl") && UUID(uuidString: String(file.dropLast(6))) != nil
            }
        }
        if within(event, codex) {
            if isDirectory { return true }
            let name = event.split(separator: "/").last ?? ""
            return name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"))
        }
        return false
    }
    return matches(claude: roots.claude.literal, codex: roots.codex.literal, index: roots.index.literal)
        || matches(claude: roots.claude.real, codex: roots.codex.real, index: roots.index.real)
}

final class EventWatcher: @unchecked Sendable {
    private let roots: Roots
    private let changed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "RBIndex.FSEvents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var eventPaths: EventPaths?
    init(roots: Roots, changed: @escaping @Sendable () -> Void) { self.roots = roots; self.changed = changed }
    func start() {
        queue.async { [self] in
            eventPaths = EventPaths(roots)
            // Existing ancestors also observe creation of currently missing roots and atomic index replacement.
            let paths = Set([roots.claude, roots.codex, roots.index.deletingLastPathComponent()].map { url -> String in
                var path = url
                while !FileManager.default.fileExists(atPath: path.path) && path.path != "/" { path.deleteLastPathComponent() }
                return path.path
            })
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<EventWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                guard let eventPaths = watcher.eventPaths else { return }
                for i in 0..<count where eventCanChangeResult(path: String(cString: paths[i]), flags: flags[i], roots: eventPaths) {
                    watcher.changed()
                    break
                }
            }
            guard let stream = FSEventStreamCreate(nil, callback, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }
    func stop() {
        queue.async { [self] in
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
}
