// Fake services backed by one design fixture. Used for tests and for running the real app
// against design data.
// Terminal and platform calls are recorded, never executed.

import Foundation
import RBContract
import RBStore

public final class FixtureServices: @unchecked Sendable {
    public let snapshot: Snapshot
    let fixtureMode: String?
    private let lock = NSLock()
    private var _calls: [String] = []
    private var entries: [String: Entry]
    private var links: [String: String]
    private var changes: [Change] = []
    private var undoStack: [(String, [String: Entry], [String: String], [Change])] = []

    public init(fixture url: URL) throws {
        let data = try Data(contentsOf: url)
        struct Metadata: Decodable { struct UI: Decodable { let mode: String? }; let schemaVersion: Int; let _ui: UI? }
        let meta = try JSONDecoder().decode(Metadata.self, from: data)
        fixtureMode = meta._ui?.mode
        guard meta.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        snapshot = try RBJSON.decoder().decode(Snapshot.self, from: data)
        entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        links = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0.entryId) })
        changes = snapshot.changes
    }

    public var calls: [String] { lock.withLock { _calls } }
    func record(_ call: String) { lock.withLock { _calls.append(call) } }

    public var services: Services {
        Services(index: FixtureIndex(owner: self), live: FixtureLive(owner: self), store: FixtureStore(owner: self),
                 terminal: FixtureTerminal(owner: self), platform: FixturePlatform(owner: self))
    }

    struct FixtureIndex: SessionIndexing {
        let owner: FixtureServices
        func scan(_ settings: Settings) async throws -> IndexResult {
            IndexResult(projects: owner.snapshot.projects, sessions: owner.snapshot.sessions.map {
                IndexedSession(id: $0.id, tool: $0.tool, nativeId: $0.nativeId, projectId: $0.projectId, cwd: $0.cwd,
                               transcriptPath: $0.transcriptPath, startedAt: $0.startedAt, lastActivityAt: $0.lastActivityAt,
                               tokens: $0.tokens, firstPrompt: $0.firstPrompt, threadName: $0.threadName,
                               suggestedTopic: $0.suggestedTitle, resumable: $0.resumable)
            }, skippedFiles: 0)
        }
        func updates(_ settings: Settings) -> AsyncStream<IndexResult> { AsyncStream { $0.finish() } }
    }

    struct FixtureLive: LiveMonitoring {
        let owner: FixtureServices
        func current() async -> LiveState {
            let s = owner.snapshot.sessions
            return LiveState(running: Dictionary(uniqueKeysWithValues: s.filter(\.live.running).map { ($0.id, $0.live) }),
                             ended: owner.snapshot.justEnded.compactMap { owner.snapshot.sessions(of: $0).first?.id },
                             resumeCounts: Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0.resumeCount) }))
        }
        func updates(interval: Duration) -> AsyncStream<LiveState> { AsyncStream { $0.finish() } }
    }

    struct FixtureStore: EntryChangeStoring {
        let owner: FixtureServices
        func loadEntries() async throws -> [Entry] { owner.lock.withLock { Array(owner.entries.values) } }
        func loadLinks() async throws -> [String: String] { owner.lock.withLock { owner.links } }
        func loadChanges() async throws -> [Change] { owner.lock.withLock { owner.changes } }
        func loadSettings() async throws -> Settings { owner.snapshot.settings }
        func loadResumeCountState() async throws -> ResumeCountState { .init(counts: [:], historyImportVersion: 0) }
        func saveResumeCountState(_ state: ResumeCountState) async throws {}
        func createStrands(_ seeds: [StrandSeed]) async throws -> [String: String] {
            owner.lock.withLock {
                var result: [String: String] = [:]
                for seed in seeds {
                    if owner.links[seed.sessionId] == nil {
                        owner.entries[seed.entry.id] = seed.entry
                        owner.links[seed.sessionId] = seed.entry.id
                    }
                    result[seed.sessionId] = owner.links[seed.sessionId]
                }
                return result
            }
        }
        func save(_ entry: Entry, undoLabel: String?) async throws {
            owner.lock.withLock {
                if let undoLabel { owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes)) }
                owner.entries[entry.id] = entry
            }
            owner.record("save \(entry.id) \(undoLabel ?? "")")
        }
        func link(_ sessionIds: [String], to entryId: String, undoLabel: String?) async throws {
            owner.lock.withLock {
                if let undoLabel { owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes)) }
                for id in sessionIds { owner.links[id] = entryId }
            }
        }
        func delete(entryId: String, undoLabel: String?) async throws {
            owner.lock.withLock {
                if let undoLabel { owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes)) }
                owner.entries[entryId] = nil; owner.links = owner.links.filter { $0.value != entryId }
                owner.changes.removeAll { $0.entryId == entryId }
            }
        }
        func addChange(_ change: Change) async throws { owner.lock.withLock { owner.changes.append(change) } }
        func removeChanges(_ ids: [String]) async throws { owner.lock.withLock { owner.changes.removeAll { ids.contains($0.id) } } }
        func revertAddedChange(id: String, seeds: [StrandSeed], undoLabel: String) async throws {
            owner.lock.withLock {
                guard let change = owner.changes.first(where: { $0.id == id && $0.kind == .add }) else { return }
                owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes))
                owner.entries[change.entryId] = nil; owner.links = owner.links.filter { $0.value != change.entryId }
                owner.changes.removeAll { $0.entryId == change.entryId }
                for seed in seeds { owner.entries[seed.entry.id] = seed.entry; owner.links[seed.sessionId] = seed.entry.id }
            }
        }
        func acceptChanges(undoLabel: String) async throws {
            owner.lock.withLock {
                if !owner.changes.isEmpty {
                    owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes))
                }
                owner.changes.removeAll()
            }
        }
        func acceptSeenChanges(_ ids: Set<String>) async throws {
            owner.lock.withLock {
                owner.undoStack = owner.undoStack.map { label, entries, links, changes in
                    (label, entries, links, changes.filter { !ids.contains($0.id) })
                }
                owner.changes.removeAll { ids.contains($0.id) }
            }
        }
        func revertDoneChange(id: String, entry: Entry, undoLabel: String) async throws {
            owner.lock.withLock {
                owner.undoStack.append((undoLabel, owner.entries, owner.links, owner.changes))
                owner.entries[entry.id] = entry; owner.changes.removeAll { $0.id == id }
            }
        }
        func apply(_ patch: SettingsPatch) async throws -> Settings {
            owner.record("settings \(patch)")
            var settings = owner.snapshot.settings
            switch patch {
            case .terminals(let terminals): settings.terminal = terminals
            case .defaultTerminal(let terminal): settings.terminal = Settings.Terminals(default: terminal, alternate: terminal == .ghostty ? .terminal : .ghostty)
            default: break
            }
            return settings
        }
        func undo() async throws -> String? {
            owner.lock.withLock {
                guard let (label, entries, links, changes) = owner.undoStack.popLast() else { return nil }
                owner.entries = entries; owner.links = links; owner.changes = changes
                return label
            }
        }
        func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async {
            owner.record("pushUndo \(label)")
        }
    }

    struct FixtureTerminal: TerminalControlling {
        let owner: FixtureServices
        func open(app: TerminalApp, cwd: String, command: String) async throws { owner.record("open \(app.rawValue) \(cwd) \(command)") }
        func focus(app: TerminalApp, tty: String) async throws { owner.record("focus \(app.rawValue) \(tty)") }
        func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow] {
            (0..<owner.snapshot.windows.closable).map { TerminalWindow(app: .ghostty, windowId: "fx\($0)", cwd: nil, tty: nil) }
        }
        func openWindowCount() async -> Int { owner.snapshot.windows.open }
        func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow] { owner.record("close \(windows.count)"); return windows }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    }

    struct FixturePlatform: PlatformProviding {
        let owner: FixtureServices
        func frontmostContext() async -> Context { owner.snapshot.context ?? Context(projectId: nil, source: nil, cwd: nil, windowIndex: nil) }
        func selectedText() async -> String? { nil }
        func permissions() async -> Permissions { owner.snapshot.permissions }
        func requestAccessibility() async { owner.record("requestAccessibility") }
    }
}
