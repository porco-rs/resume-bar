// Service protocols. Each module implements exactly one of them;
// RBEngine composes them. All implementations are safe to call off the main thread and never
// block the main thread (rule 4).

import Foundation

// MARK: - RBIndex

/// Index-derived part of a session (no user fields, no live data).
public struct IndexedSession: Sendable, Equatable {
    public var id: String
    public var tool: Tool
    public var nativeId: String
    public var projectId: String?          // nil when the project root is the home folder („ohne Projekt“, v2)
    public var cwd: String
    public var transcriptPath: String
    public var startedAt: Date
    public var lastActivityAt: Date
    public var tokens: Int?
    public var firstPrompt: String
    public var threadName: String?
    public var suggestedTopic: String
    public var resumable: Bool

    public init(id: String, tool: Tool, nativeId: String, projectId: String?, cwd: String,
                transcriptPath: String, startedAt: Date, lastActivityAt: Date, tokens: Int?,
                firstPrompt: String, threadName: String?, suggestedTopic: String, resumable: Bool) {
        self.id = id
        self.tool = tool
        self.nativeId = nativeId
        self.projectId = projectId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.tokens = tokens
        self.firstPrompt = firstPrompt
        self.threadName = threadName
        self.suggestedTopic = suggestedTopic
        self.resumable = resumable
    }
}

public struct IndexResult: Sendable, Equatable {
    public var projects: [Project]
    public var sessions: [IndexedSession]
    /// Files that could not be read (logged, never shown in the list)
    public var skippedFiles: Int

    public init(projects: [Project], sessions: [IndexedSession], skippedFiles: Int) {
        self.projects = projects
        self.sessions = sessions
        self.skippedFiles = skippedFiles
    }
}

public protocol SessionIndexing: Sendable {
    /// Full scan of the watched folders (interactive sessions only), newest first.
    func scan(_ settings: Settings) async throws -> IndexResult
    /// Emits a fresh result whenever a watched file changes (FSEvents), coalesced.
    func updates(_ settings: Settings) -> AsyncStream<IndexResult>
}

// MARK: - RBLive

public struct LiveState: Sendable, Equatable {
    /// Running interactive sessions by session id (cx_/cc_ form).
    public var running: [String: Live]
    /// Session ids whose process ended since the previous state.
    public var ended: [String]
    /// Resume counts by session id (process starts with this id since install, plus history import).
    public var resumeCounts: [String: Int]
    /// Session id → entry id, read from the `RB_ENTRY` variable of the running claude/codex process. Only this one variable is ever read.
    public var entryHints: [String: String]

    public init(running: [String: Live], ended: [String], resumeCounts: [String: Int], entryHints: [String: String] = [:]) {
        self.running = running
        self.ended = ended
        self.resumeCounts = resumeCounts
        self.entryHints = entryHints
    }
}

public protocol LiveMonitoring: Sendable {
    func current() async -> LiveState
    /// Polls processes (default every 2 s) and emits only when something changed.
    func updates(interval: Duration) -> AsyncStream<LiveState>
}

// MARK: - RBStore

/// One automatic untitled strand to create for a session that has no link yet (PRODUKT.md rule 2).
public struct StrandSeed: Sendable, Equatable {
    public var sessionId: String
    public var entry: Entry

    public init(sessionId: String, entry: Entry) { self.sessionId = sessionId; self.entry = entry }
}

/// Resume counts and the zsh-history import marker, always read and written together (one transaction), so an
/// interrupted import is never counted twice. Replaces RBLive's `resume-counts.json`.
public struct ResumeCountState: Sendable, Equatable {
    public var counts: [String: Int]
    /// 0 = never imported; 1 = v1 `historyImported: true`; current RBLive version is 2.
    public var historyImportVersion: Int
    /// Processes already counted, so a restarted monitor never counts the same running process twice
    /// (RBLive `counted` in `resume-counts.json`).
    public var counted: [CountedProcess]

    public init(counts: [String: Int], historyImportVersion: Int, counted: [CountedProcess] = []) {
        self.counts = counts; self.historyImportVersion = historyImportVersion; self.counted = counted
    }
}

/// Identity of one counted process: pid plus process start time (pid reuse safe) and the session it resumed.
public struct CountedProcess: Sendable, Equatable, Hashable, Codable {
    public var pid: Int32
    public var start: UInt64
    public var sessionId: String

    public init(pid: Int32, start: UInt64, sessionId: String) {
        self.pid = pid; self.start = start; self.sessionId = sessionId
    }
}

/// Persistent entries, links, changes, settings, and resume count state.
public protocol EntryStoring: Sendable {
    func loadEntries() async throws -> [Entry]
    func loadLinks() async throws -> [String: String]
    func loadChanges() async throws -> [Change]
    func loadSettings() async throws -> Settings
    func loadResumeCountState() async throws -> ResumeCountState
    /// Replaces counts and marker atomically.
    func saveResumeCountState(_ state: ResumeCountState) async throws
    /// Atomic batch, no undo: for each seed whose session is still unlinked, insert the entry and link the session, all
    /// in one transaction. Seeds for already linked sessions are skipped (idempotent, safe for concurrent callers: no
    /// duplicate entry, no second link). Returns sessionId → entryId for every seed (existing or new link).
    func createStrands(_ seeds: [StrandSeed]) async throws -> [String: String]
    func save(_ entry: Entry, undoLabel: String?) async throws
    func link(_ sessionIds: [String], to entryId: String, undoLabel: String?) async throws
    func delete(entryId: String, undoLabel: String?) async throws
    func addChange(_ change: Change) async throws
    func removeChanges(_ ids: [String]) async throws
    /// Entry and change in one transaction: both are stored or neither. Undo removes both.
    func save(_ entry: Entry, change: Change, undoLabel: String?) async throws
    func apply(_ patch: SettingsPatch) async throws -> Settings
    func undo() async throws -> String?
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async
}

public extension EntryStoring {
    /// Fallback for test stores without transactions; `SQLiteStore` overrides it.
    func save(_ entry: Entry, change: Change, undoLabel: String?) async throws {
        try await save(entry, undoLabel: undoLabel)
        try await addChange(change)
    }
}

public protocol UserStoring: Sendable {
    func loadSettings() async throws -> Settings
    func apply(_ patch: SettingsPatch) async throws -> Settings
    /// Restores the newest undo entry; nil when the stack is empty.
    func undo() async throws -> String?
    /// Registers an undo step whose restore action lives elsewhere (e.g. reopening closed windows).
    func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) async
}

// MARK: - RBTerminal

public struct TerminalWindow: Sendable, Equatable {
    public var app: TerminalApp
    public var windowId: String
    public var cwd: String?
    public var tty: String?

    public init(app: TerminalApp, windowId: String, cwd: String?, tty: String?) {
        self.app = app
        self.windowId = windowId
        self.cwd = cwd
        self.tty = tty
    }
}

public protocol TerminalControlling: Sendable {
    /// New window in `app`, working directory `cwd`, `command` typed into a login shell
    /// (aliases work).
    func open(app: TerminalApp, cwd: String, command: String) async throws
    /// Brings the window that owns `tty` to the front (also from another Space).
    func focus(app: TerminalApp, tty: String) async throws
    /// Windows whose shell sits idle at the prompt: no claude/codex and no other foreground process
    /// (servers, builds). „Fenster aufräumen“.
    func closableWindows(knownTTYs: Set<String>) async -> [TerminalWindow]
    /// Number of open Ghostty and Terminal.app windows (Snapshot.windows.open).
    func openWindowCount() async -> Int
    func close(_ windows: [TerminalWindow]) async throws -> [TerminalWindow]
    /// Shell-quotes a prompt so it can be appended to a command (prevents injection).
    func quoted(_ text: String) -> String
}

// MARK: - RBPlatform

public protocol PlatformProviding: Sendable {
    /// Frontmost app and window → context (only Ghostty/Terminal give a project).
    func frontmostContext() async -> Context
    /// Selected text in the frontmost terminal via Accessibility, nil if none or not permitted.
    func selectedText() async -> String?
    func permissions() async -> Permissions
    func requestAccessibility() async
}
