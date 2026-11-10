// Shared data model for the design fixtures.
import Foundation

public enum Tool: String, Codable, Sendable, CaseIterable {
    case codex, claude

    public var short: String { self == .codex ? "CX" : "CC" }
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
    public var idPrefix: String { self == .codex ? "cx_" : "cc_" }
}

/// Status of a strand or task.
public enum EntryStatus: String, Codable, Sendable, CaseIterable {
    case offen, wartet, erledigt

    public var next: EntryStatus {
        switch self { case .offen: .wartet; case .wartet: .erledigt; case .erledigt: .offen }
    }

    public var glyph: String {
        switch self { case .offen: "●"; case .wartet: "◐"; case .erledigt: "○" }
    }
}

/// Who created or finished an entry.
public enum Actor: String, Codable, Sendable { case user, claude, codex }

/// What the user works on: a task or a strand, derived from its session links.
public struct Entry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectId: String?
    public var title: String?
    public var status: EntryStatus
    public var statusChangedAt: Date?
    public var deadline: String?
    public var createdBy: Actor
    public var doneBy: Actor?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var schemaVersion: Int

    public init(id: String, projectId: String?, title: String?, status: EntryStatus,
                statusChangedAt: Date? = nil, deadline: String? = nil, createdBy: Actor,
                doneBy: Actor? = nil, createdAt: Date, updatedAt: Date, archivedAt: Date? = nil,
                schemaVersion: Int = 2) {
        self.id = id; self.projectId = projectId; self.title = title; self.status = status
        self.statusChangedAt = statusChangedAt; self.deadline = deadline; self.createdBy = createdBy
        self.doneBy = doneBy; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.archivedAt = archivedAt; self.schemaVersion = schemaVersion
    }
}

public enum ChangeKind: String, Codable, Sendable { case add, done }

/// An AI write shown until accepted or reverted.
public struct Change: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ChangeKind
    public var entryId: String
    public var by: Actor
    public var at: Date

    public init(id: String, kind: ChangeKind, entryId: String, by: Actor, at: Date) {
        self.id = id; self.kind = kind; self.entryId = entryId; self.by = by; self.at = at
    }
}

public enum TerminalApp: String, Codable, Sendable, CaseIterable {
    case ghostty, terminal

    public var displayName: String { self == .ghostty ? "Ghostty" : "Terminal.app" }
}

public enum PermissionState: String, Codable, Sendable {
    case granted, denied, unknown
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    /// `prj_<folder name>`; on name collision `prj_<name>_<hash4>`
    public var id: String
    public var name: String
    public var rootPath: String
    public var lastActivityAt: Date

    public init(id: String, name: String, rootPath: String, lastActivityAt: Date) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.lastActivityAt = lastActivityAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, rootPath, lastActivityAt }

    /// v2 fixtures carry no `lastActivityAt` (derived from sessions, DATA.md v2 „Project“); default `.distantPast`.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        lastActivityAt = try values.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? .distantPast
    }
}

public struct Live: Codable, Sendable, Equatable {
    public var running: Bool
    public var pid: Int?
    public var tty: String?
    public var terminalApp: TerminalApp?
    public var windowIndex: Int?

    public static let notRunning = Live(running: false, pid: nil, tty: nil, terminalApp: nil, windowIndex: nil)

    public init(running: Bool, pid: Int?, tty: String?, terminalApp: TerminalApp?, windowIndex: Int?) {
        self.running = running
        self.pid = pid
        self.tty = tty
        self.terminalApp = terminalApp
        self.windowIndex = windowIndex
    }
}

public struct Context: Codable, Sendable, Equatable {
    public var projectId: String?
    public var source: TerminalApp?
    public var cwd: String?
    public var windowIndex: Int?
    /// tty of the focused terminal (Terminal.app; Ghostty ≥ 1.4), e.g. "ttys004". Not in the design data;
    /// identifies the session for ⇧⌘R without a marking when several sessions share a folder.
    public var tty: String?

    public init(projectId: String?, source: TerminalApp?, cwd: String?, windowIndex: Int?, tty: String? = nil) {
        self.projectId = projectId
        self.source = source
        self.cwd = cwd
        self.windowIndex = windowIndex
        self.tty = tty
    }
}

public struct ToolStrings: Codable, Sendable, Equatable {
    public var codex: String
    public var claude: String

    public init(codex: String, claude: String) {
        self.codex = codex
        self.claude = claude
    }

    public subscript(tool: Tool) -> String {
        get { tool == .codex ? codex : claude }
        set { if tool == .codex { codex = newValue } else { claude = newValue } }
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public struct Terminals: Codable, Sendable, Equatable {
        public var `default`: TerminalApp
        public var alternate: TerminalApp

        public init(default defaultApp: TerminalApp, alternate: TerminalApp) {
            self.default = defaultApp
            self.alternate = alternate
        }
    }

    public struct Hotkeys: Codable, Sendable, Equatable {
        public var popover: String
        public var pin: String
        public var task: String

        public init(popover: String, pin: String, task: String = "⌥⌘N") {
            self.popover = popover
            self.pin = pin
            self.task = task
        }

        private enum CodingKeys: String, CodingKey { case popover, pin, task }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            popover = try values.decode(String.self, forKey: .popover)
            pin = try values.decode(String.self, forKey: .pin)
            task = try values.decodeIfPresent(String.self, forKey: .task) ?? Settings.defaults.hotkeys.task
        }
    }

    /// AI access via the CLI `rb` only.
    public struct AI: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var cliPath: String

        public init(enabled: Bool = true, cliPath: String = "~/.local/bin/rb") {
            self.enabled = enabled
            self.cliPath = cliPath
        }

        private enum CodingKeys: String, CodingKey { case enabled, cliPath }

        /// Tolerates the design fixtures' `{mcp, cliPath, clients}` and stored v1 settings.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            cliPath = try values.decodeIfPresent(String.self, forKey: .cliPath) ?? "~/.local/bin/rb"
        }
    }

    public struct Watch: Codable, Sendable, Equatable {
        public var claude: String
        public var codex: String

        public init(claude: String, codex: String) {
            self.claude = claude
            self.codex = codex
        }
    }

    /// Resume commands with `{id}` placeholder
    public var commands: ToolStrings
    /// Commands for a new session (prompt appended)
    public var newCommands: ToolStrings
    public var commandsSource: String
    public var terminal: Terminals
    public var hotkeys: Hotkeys
    public var ai: AI
    /// Tool that Enter starts for an open goal; Shift-Enter takes the other one.
    public var defaultTool: Tool
    /// Folder where a goal without project starts. Nil: the parent folder holding most projects, else home.
    public var startFolder: String?
    /// Trainer lessons done. Private progress, no points.
    public var trainerDone: [String]
    public var archiveDays: Int           // 1–30
    public var cleanupThreshold: Int      // 1–50
    public var importDays: Int
    public var watch: Watch

    public init(commands: ToolStrings, newCommands: ToolStrings, commandsSource: String,
                terminal: Terminals, hotkeys: Hotkeys, archiveDays: Int, cleanupThreshold: Int,
                importDays: Int, watch: Watch, ai: AI = AI(), defaultTool: Tool = .codex, startFolder: String? = nil, trainerDone: [String] = []) {
        self.commands = commands
        self.newCommands = newCommands
        self.commandsSource = commandsSource
        self.terminal = terminal
        self.hotkeys = hotkeys
        self.ai = ai
        self.defaultTool = defaultTool
        self.startFolder = startFolder
        self.trainerDone = trainerDone
        self.archiveDays = archiveDays
        self.cleanupThreshold = cleanupThreshold
        self.importDays = importDays
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey {
        case commands, newCommands, commandsSource, terminal, hotkeys, ai, defaultTool, startFolder, trainerDone, archiveDays, cleanupThreshold, importDays, watch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commands = try values.decode(ToolStrings.self, forKey: .commands)
        newCommands = try values.decode(ToolStrings.self, forKey: .newCommands)
        commandsSource = try values.decodeIfPresent(String.self, forKey: .commandsSource) ?? ""
        terminal = try values.decode(Terminals.self, forKey: .terminal)
        hotkeys = try values.decode(Hotkeys.self, forKey: .hotkeys)
        ai = try values.decodeIfPresent(AI.self, forKey: .ai) ?? Settings.defaults.ai
        defaultTool = try values.decodeIfPresent(Tool.self, forKey: .defaultTool) ?? .codex
        startFolder = try values.decodeIfPresent(String.self, forKey: .startFolder)
        trainerDone = try values.decodeIfPresent([String].self, forKey: .trainerDone) ?? []
        archiveDays = try values.decode(Int.self, forKey: .archiveDays)
        cleanupThreshold = try values.decode(Int.self, forKey: .cleanupThreshold)
        importDays = try values.decode(Int.self, forKey: .importDays)
        watch = try values.decode(Watch.self, forKey: .watch)
    }

    /// Defaults per DATA.md, with the popover hotkey decided on 2026-11-02.
    public static let defaults = Settings(
        commands: ToolStrings(codex: "codex resume {id}", claude: "claude --resume {id}"),
        newCommands: ToolStrings(codex: "codex", claude: "claude"),
        commandsSource: "",
        terminal: Terminals(default: .ghostty, alternate: .terminal),
        hotkeys: Hotkeys(popover: "⇧⌘Space", pin: "⇧⌘R"),
        archiveDays: 14, cleanupThreshold: 3, importDays: 14,
        watch: Watch(claude: "~/.claude/projects", codex: "~/.codex/sessions"))
}

public struct Windows: Codable, Sendable, Equatable {
    public var open: Int
    public var closable: Int

    public init(open: Int, closable: Int) {
        self.open = open
        self.closable = closable
    }
}

public struct Permissions: Codable, Sendable, Equatable {
    public struct Automation: Codable, Sendable, Equatable {
        public var ghostty: PermissionState
        public var terminal: PermissionState

        public init(ghostty: PermissionState, terminal: PermissionState) {
            self.ghostty = ghostty
            self.terminal = terminal
        }
    }

    public var accessibility: Bool
    public var automation: Automation

    public init(accessibility: Bool, automation: Automation) {
        self.accessibility = accessibility
        self.automation = automation
    }
}

public struct ImportSummary: Codable, Sendable, Equatable {
    public var sessions: Int
    public var days: Int
    public var byProject: [String: Int]

    public init(sessions: Int, days: Int, byProject: [String: Int]) {
        self.sessions = sessions
        self.days = days
        self.byProject = byProject
    }
}

/// v2 session: index + live data + its strand. User fields live on `Entry` (DATA.md „Session · geändert“).
public struct Session: Codable, Sendable, Equatable, Identifiable {
    public var id: String                 // cx_<uuid> | cc_<uuid>
    public var tool: Tool
    public var nativeId: String
    public var entryId: String            // always set: the strand this session belongs to
    public var projectId: String?         // nil when cwd is ~ („ohne Projekt“)
    public var cwd: String
    public var transcriptPath: String
    public var startedAt: Date
    public var lastActivityAt: Date
    public var tokens: Int?
    public var firstPrompt: String        // max 200
    public var threadName: String?
    public var suggestedTitle: String     // threadName, else first prompt to first sentence end, max 60
    public var resumable: Bool
    public var resumeCount: Int
    public var live: Live
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int         // 2

    public init(id: String, tool: Tool, nativeId: String, entryId: String, projectId: String?, cwd: String,
                transcriptPath: String, startedAt: Date, lastActivityAt: Date, tokens: Int?, firstPrompt: String,
                threadName: String?, suggestedTitle: String, resumable: Bool, resumeCount: Int, live: Live,
                createdAt: Date, updatedAt: Date, schemaVersion: Int = 2) {
        self.id = id
        self.tool = tool
        self.nativeId = nativeId
        self.entryId = entryId
        self.projectId = projectId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.tokens = tokens
        self.firstPrompt = firstPrompt
        self.threadName = threadName
        self.suggestedTitle = suggestedTitle
        self.resumable = resumable
        self.resumeCount = resumeCount
        self.live = live
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

/// Everything one v2 render needs; exactly the fixture JSON format without `_` fields.
public struct Snapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int         // 2
    public var now: Date
    public var context: Context?
    public var settings: Settings
    public var projects: [Project]
    public var entries: [Entry]
    public var sessions: [Session]
    public var windows: Windows
    public var justEnded: [String]        // entry ids: untitled strands whose last session just ended
    public var changes: [Change]
    public var permissions: Permissions
    public var `import`: ImportSummary?

    public init(schemaVersion: Int = 2, now: Date, context: Context?, settings: Settings, projects: [Project],
                entries: [Entry], sessions: [Session], windows: Windows, justEnded: [String], changes: [Change],
                permissions: Permissions, import importSummary: ImportSummary? = nil) {
        self.schemaVersion = schemaVersion
        self.now = now
        self.context = context
        self.settings = settings
        self.projects = projects
        self.entries = entries
        self.sessions = sessions
        self.windows = windows
        self.justEnded = justEnded
        self.changes = changes
        self.permissions = permissions
        self.import = importSummary
    }

    public func project(_ id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }
    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    public func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
    /// Sessions of one strand, newest activity first (logic.js `sessionsOf`).
    public func sessions(of entryId: String) -> [Session] {
        sessions.filter { $0.entryId == entryId }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
