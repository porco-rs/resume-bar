import Foundation
import SQLite3
import CryptoKit
import RBContract

public enum StoreError: Error, Sendable {
    case database(String)
    case invalidSettings(String)
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum SessionStatus: String, Codable, Sendable { case offen, wartet, erledigt }

private struct UserFields: Sendable, Equatable, Codable {
    var topic: String?
    var pinned: Bool
    var status: SessionStatus
    var statusChangedAt: Date?
    var archivedAt: Date?
    var updatedAt: Date

    static func empty(at date: Date) -> UserFields {
        UserFields(topic: nil, pinned: false, status: .offen, statusChangedAt: nil, archivedAt: nil, updatedAt: date)
    }

    init(topic: String?, pinned: Bool, status: SessionStatus, statusChangedAt: Date?,
                archivedAt: Date?, updatedAt: Date) {
        self.topic = topic
        self.pinned = pinned
        self.status = status
        self.statusChangedAt = statusChangedAt
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
    }
}

private enum Value {
    case null, text(String), number(Double)
    static func optional(_ value: String?) -> Value { value.map(Value.text) ?? .null }
    static func time(_ value: Date?) -> Value { value.map { .text(timestamp($0)) } ?? .null }
}
private func timestamp(_ date: Date) -> String {
    let seconds = floor(date.timeIntervalSince1970)
    let nanos = Int(((date.timeIntervalSince1970 - seconds) * 1_000_000_000).rounded())
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    let base = f.string(from: Date(timeIntervalSince1970: seconds))
    if nanos == 1_000_000_000 { return timestamp(Date(timeIntervalSince1970: seconds + 1)) }
    return String(base.dropLast()) + String(format: ".%09dZ", nanos)
}
private func parseTime(_ value: String?) -> Date? {
    guard let value else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    if value.hasSuffix("Z"), let dot = value.lastIndex(of: ".") {
        let whole = String(value[..<dot]) + "Z"
        let digits = String(value[value.index(after: dot)..<value.index(before: value.endIndex)])
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let fraction = Double("0." + digits), let base = f.date(from: whole) else { return nil }
        return base.addingTimeInterval(fraction)
    }
    return f.date(from: value)
}
private func text(_ s: OpaquePointer, _ c: Int32) -> String? {
    guard let p = sqlite3_column_text(s, c) else { return nil }; return String(cString: p)
}
private func oldDate(_ s: OpaquePointer, _ c: Int32) -> Date? {
    sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, c))
}
private func stableID(_ session: String) -> String {
    "e_" + SHA256.hash(data: Data(session.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
}
private final class Database: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let h { sqlite3_close(h) }; throw StoreError.database(message)
        }
        handle = h; sqlite3_busy_timeout(h, 5000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        let s = try prepare(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }
    func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        let s = try prepare(sql, values); defer { sqlite3_finalize(s) }; var rows: [T] = []
        while true { switch sqlite3_step(s) {
        case SQLITE_ROW: rows.append(try row(s))
        case SQLITE_DONE: return rows
        default: throw error()
        } }
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }
        for (i, v) in values.enumerated() {
            let result: Int32
            switch v {
            case .null: result = sqlite3_bind_null(s, Int32(i + 1))
            case .text(let t): result = sqlite3_bind_text(s, Int32(i + 1), t, -1, transient)
            case .number(let n): result = sqlite3_bind_double(s, Int32(i + 1), n)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(s); throw error() }
        }
        return s
    }
    private func error() -> StoreError { .database(String(cString: sqlite3_errmsg(handle))) }
    func backup(to path: String) throws {
        let destination = try Database(path: path)
        let locking = try destination.query("PRAGMA locking_mode=EXCLUSIVE", row: { text($0, 0) })
        guard locking == ["exclusive"] else { throw StoreError.database("Cannot lock backup") }
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw error() }
        let result = sqlite3_backup_step(backup, -1); let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE && finish == SQLITE_OK else { throw StoreError.database("Backup failed") }
        let mode = try destination.query("PRAGMA journal_mode=DELETE", row: { text($0, 0) })
        guard mode == ["delete"] else { throw StoreError.database("Cannot finalize backup") }
    }
}

/// Atomic entry/change operations needed when a single user action touches both tables.
public protocol EntryChangeStoring: EntryStoring {
    func revertAddedChange(id: String, seeds: [StrandSeed], undoLabel: String) async throws
    func acceptChanges(undoLabel: String) async throws
    func acceptSeenChanges(_ ids: Set<String>) async throws
    func revertDoneChange(id: String, entry: Entry, undoLabel: String) async throws
}

/// Persistent user data. File access is isolated to this actor, away from the UI actor.
public actor SQLiteStore: EntryChangeStoring {
    private struct Link: Equatable, Sendable { var entryId: String; var missingSince: String? }
    private struct Snapshot: Sendable { var entries: [Entry]; var links: [String: Link]; var changes: [Change] }
    private enum Undo {
        case snapshot(String, Snapshot, Snapshot)
        case action(String, @Sendable () async -> Void)
    }
    private let databaseURL: URL
    private var opened: Database?
    private var undoStack: [Undo] = []
    private let afterUndoableCommit: (@Sendable () -> Void)?
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ResumeBar/store.sqlite")
    }
    public init(databaseURL: URL = SQLiteStore.defaultURL) { self.databaseURL = databaseURL; self.afterUndoableCommit = nil }
    // Test seam for a second writer between COMMIT and recording the undo step.
    init(databaseURL: URL, afterUndoableCommit: @escaping @Sendable () -> Void) {
        self.databaseURL = databaseURL; self.afterUndoableCommit = afterUndoableCommit
    }
    private func db() throws -> Database {
        if let opened { return opened }
        let fm = FileManager.default
        try fm.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = fm.fileExists(atPath: databaseURL.path)
        let database = try Database(path: databaseURL.path)
        guard try database.query("PRAGMA quick_check", row: { text($0, 0) }) == ["ok"] else { throw StoreError.database("Integrity check failed") }
        let version = try database.query("PRAGMA user_version", row: { Int(sqlite3_column_int($0, 0)) }).first ?? 0
        guard version <= 2 else { throw StoreError.database("Future schema") }
        let backup = databaseURL.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite")
        if version < 2 {
            try database.transaction {
                let current = try database.query("PRAGMA user_version", row: { Int(sqlite3_column_int($0, 0)) }).first ?? 0
                guard current <= 2 else { throw StoreError.database("Future schema") }
                if current < 2 {
                    if existed && !fm.fileExists(atPath: backup.path) {
                        let temporary = backup.appendingPathExtension("tmp-" + UUID().uuidString)
                        do {
                            // A cold WAL database may need its shared-memory file recreated.
                            // Keep the migration's write lock while opening a writable backup source.
                            let source = try Database(path: databaseURL.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
                            try source.backup(to: temporary.path)
                            try fm.moveItem(at: temporary, to: backup)
                        } catch {
                            for suffix in ["", "-journal", "-wal", "-shm"] {
                                try? fm.removeItem(atPath: temporary.path + suffix)
                            }
                            throw error
                        }
                    }
                    try migrate(database)
                }
            }
        } else if let modified = try? fm.attributesOfItem(atPath: backup.path)[.modificationDate] as? Date,
                  modified < Date().addingTimeInterval(-30 * 86400) {
            try fm.removeItem(at: backup)
        }
        opened = database; return database
    }
    private func migrate(_ db: Database) throws {
        let hasOld = try !db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='session_user'", row: { text($0, 0) }).isEmpty
        try db.execute("CREATE TABLE entry (id TEXT PRIMARY KEY, projectId TEXT, title TEXT, status TEXT NOT NULL, statusChangedAt TEXT, deadline TEXT, createdBy TEXT NOT NULL, doneBy TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, archivedAt TEXT, schemaVersion INTEGER NOT NULL)")
        try db.execute("CREATE TABLE session_link (sessionId TEXT PRIMARY KEY, entryId TEXT NOT NULL REFERENCES entry(id), missingSince TEXT)")
        try db.execute("CREATE TABLE change (id TEXT PRIMARY KEY, kind TEXT NOT NULL, entryId TEXT NOT NULL, actor TEXT NOT NULL, at TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("CREATE TABLE resume_count (sessionId TEXT PRIMARY KEY, count INTEGER NOT NULL)")
        if hasOld {
            let columns = try db.query("PRAGMA table_info(session_user)", row: { text($0, 1) ?? "" })
            let missing = columns.contains("missingSince") ? "missingSince" : "NULL"
            let rows = try db.query("SELECT id, topic, status, statusChangedAt, archivedAt, updatedAt, \(missing) FROM session_user") { s -> (String, UserFields, Date?) in
                guard let id = text(s, 0), let raw = text(s, 2), let status = SessionStatus(rawValue: raw), let updated = oldDate(s, 5) else { throw StoreError.database("Invalid v1 row") }
                return (id, UserFields(topic: text(s, 1), pinned: text(s, 1) != nil, status: status, statusChangedAt: oldDate(s, 3), archivedAt: oldDate(s, 4), updatedAt: updated), oldDate(s, 6))
            }
            for (id, fields, missingSince) in rows {
                let entry = makeEntry(fields, id: stableID(id)); try write(entry, db)
                try db.execute("INSERT INTO session_link (sessionId, entryId, missingSince) VALUES (?, ?, ?)", [.text(id), .text(entry.id), .time(missingSince)])
            }
            try db.execute("DROP TABLE session_user")
        }
        if let json = try db.query("SELECT value FROM settings WHERE key='settings'", row: { text($0, 0) }).first ?? nil {
            var settings = try RBJSON.decoder().decode(Settings.self, from: Data(json.utf8))
            if settings.hotkeys.popover == "⌥⌘Space" { settings.hotkeys.popover = "⇧⌘Space" }
            try writeSettings(settings, db)
        }
        try db.execute("PRAGMA user_version = 2")
    }
    private func makeEntry(_ f: UserFields, id: String) -> Entry {
        Entry(id: id, projectId: nil, title: f.topic, status: EntryStatus(rawValue: f.status.rawValue)!, statusChangedAt: f.statusChangedAt, createdBy: .user, createdAt: f.updatedAt, updatedAt: f.updatedAt, archivedAt: f.archivedAt)
    }
    private func write(_ entry: Entry, _ db: Database) throws {
        try db.execute("INSERT INTO entry VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET projectId=excluded.projectId, title=excluded.title, status=excluded.status, statusChangedAt=excluded.statusChangedAt, deadline=excluded.deadline, createdBy=excluded.createdBy, doneBy=excluded.doneBy, createdAt=excluded.createdAt, updatedAt=excluded.updatedAt, archivedAt=excluded.archivedAt, schemaVersion=excluded.schemaVersion", [.text(entry.id), .optional(entry.projectId), .optional(entry.title), .text(entry.status.rawValue), .time(entry.statusChangedAt), .optional(entry.deadline), .text(entry.createdBy.rawValue), .optional(entry.doneBy?.rawValue), .time(entry.createdAt), .time(entry.updatedAt), .time(entry.archivedAt), .number(Double(entry.schemaVersion))])
    }
    public func loadEntries() throws -> [Entry] {
        try db().query("SELECT id, projectId, title, status, statusChangedAt, deadline, createdBy, doneBy, createdAt, updatedAt, archivedAt, schemaVersion FROM entry ORDER BY id") { s in
            guard let id = text(s, 0), let status = text(s, 3).flatMap(EntryStatus.init(rawValue:)), let creator = text(s, 6).flatMap(Actor.init(rawValue:)), let created = parseTime(text(s, 8)), let updated = parseTime(text(s, 9)) else { throw StoreError.database("Invalid entry") }
            let doneRaw = text(s, 7); let done = doneRaw.flatMap(Actor.init(rawValue:))
            guard doneRaw == nil || done != nil else { throw StoreError.database("Invalid actor") }
            return Entry(id: id, projectId: text(s, 1), title: text(s, 2), status: status, statusChangedAt: parseTime(text(s, 4)), deadline: text(s, 5), createdBy: creator, doneBy: done, createdAt: created, updatedAt: updated, archivedAt: parseTime(text(s, 10)), schemaVersion: Int(sqlite3_column_int(s, 11)))
        }
    }
    public func loadLinks() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try db().query("SELECT sessionId, entryId FROM session_link") { (text($0, 0)!, text($0, 1)!) })
    }
    public func loadChanges() throws -> [Change] {
        try db().query("SELECT id, kind, entryId, actor, at FROM change ORDER BY id") { s in
            guard let id = text(s, 0), let kind = text(s, 1).flatMap(ChangeKind.init(rawValue:)), let entry = text(s, 2), let actor = text(s, 3).flatMap(Actor.init(rawValue:)), let at = parseTime(text(s, 4)) else { throw StoreError.database("Invalid change") }
            return Change(id: id, kind: kind, entryId: entry, by: actor, at: at)
        }
    }
    public func loadSettings() throws -> Settings {
        guard let json = try db().query("SELECT value FROM settings WHERE key='settings'", row: { text($0, 0) }).first ?? nil else { return .defaults }
        return try RBJSON.decoder().decode(Settings.self, from: Data(json.utf8))
    }
    /// Reads the settings row without creating, migrating or modifying the store.
    public func readOnlySettings() throws -> Settings? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let database = try Database(path: databaseURL.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        guard !(try database.query("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'", row: { text($0, 0) })).isEmpty else { return nil }
        guard let json = try database.query("SELECT value FROM settings WHERE key='settings'", row: { text($0, 0) }).first ?? nil else { return nil }
        return try RBJSON.decoder().decode(Settings.self, from: Data(json.utf8))
    }
    public func hasStoredSettings() throws -> Bool { try readOnlySettings() != nil }
    private func writeSettings(_ settings: Settings, _ db: Database) throws {
        let data = try RBJSON.encoder().encode(settings)
        guard let json = String(data: data, encoding: .utf8) else { throw StoreError.database("Invalid settings") }
        try db.execute("INSERT INTO settings VALUES ('settings', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(json)])
    }
    public func loadResumeCountState() throws -> ResumeCountState {
        let database = try db()
        let counts = Dictionary(uniqueKeysWithValues: try database.query("SELECT sessionId, count FROM resume_count") { (text($0, 0)!, Int(sqlite3_column_int64($0, 1))) })
        let marker = try database.query("SELECT value FROM meta WHERE key='historyImportVersion'", row: { text($0, 0).flatMap(Int.init) }).first ?? nil
        let json = try database.query("SELECT value FROM meta WHERE key='countedProcesses'", row: { text($0, 0) }).first ?? nil
        let counted = try json.map { try JSONDecoder().decode([CountedProcess].self, from: Data($0.utf8)) } ?? []
        return ResumeCountState(counts: counts, historyImportVersion: marker ?? 0, counted: counted)
    }
    public func saveResumeCountState(_ state: ResumeCountState) throws {
        let database = try db(); try database.transaction {
            try database.execute("DELETE FROM resume_count")
            for (id, count) in state.counts { try database.execute("INSERT INTO resume_count VALUES (?, ?)", [.text(id), .number(Double(count))]) }
            try database.execute("INSERT INTO meta VALUES ('historyImportVersion', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(state.historyImportVersion))])
            let data = try JSONEncoder().encode(state.counted)
            try database.execute("INSERT INTO meta VALUES ('countedProcesses', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(decoding: data, as: UTF8.self))])
        }
    }
    public func createStrands(_ seeds: [StrandSeed]) throws -> [String: String] {
        let database = try db(); var result: [String: String] = [:]
        try database.transaction {
            for seed in seeds {
                if let id = try database.query("SELECT entryId FROM session_link WHERE sessionId=?", [.text(seed.sessionId)], row: { text($0, 0) }).first ?? nil { result[seed.sessionId] = id; continue }
                // A conflicting entry ID must fail rather than attach a different session's data.
                guard try database.query("SELECT id FROM entry WHERE id=?", [.text(seed.entry.id)], row: { text($0, 0) }).isEmpty else { throw StoreError.database("Entry ID already exists") }
                try write(seed.entry, database)
                try database.execute("INSERT INTO session_link (sessionId, entryId) VALUES (?, ?)", [.text(seed.sessionId), .text(seed.entry.id)])
                result[seed.sessionId] = seed.entry.id
            }
        }
        return result
    }
    private func snapshot() throws -> Snapshot {
        let links = try db().query("SELECT sessionId, entryId, missingSince FROM session_link") {
            (text($0, 0)!, Link(entryId: text($0, 1)!, missingSince: text($0, 2)))
        }
        return try Snapshot(entries: loadEntries(), links: Dictionary(uniqueKeysWithValues: links), changes: loadChanges())
    }
    private func append(_ undo: Undo) { undoStack.append(undo); if undoStack.count > 20 { undoStack.removeFirst() } }
    public func save(_ entry: Entry, undoLabel: String?) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction { if undoLabel != nil { before = try snapshot() }; try write(entry, database); if undoLabel != nil { after = try snapshot() } }
        if let label = undoLabel, let before, let after { afterUndoableCommit?(); append(.snapshot(label, before, after)) }
    }
    public func save(_ entry: Entry, change: Change, undoLabel: String?) async throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            if undoLabel != nil { before = try snapshot() }
            try write(entry, database)
            try write(change, database)
            if undoLabel != nil { after = try snapshot() }
        }
        if let label = undoLabel, let before, let after { afterUndoableCommit?(); append(.snapshot(label, before, after)) }
    }
    public func link(_ sessionIds: [String], to entryId: String, undoLabel: String?) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            guard try database.query("SELECT id FROM entry WHERE id=?", [.text(entryId)], row: { text($0, 0) }).first != nil else { throw StoreError.database("Entry does not exist") }
            if undoLabel != nil { before = try snapshot() }
            for id in sessionIds { try database.execute("INSERT INTO session_link (sessionId, entryId) VALUES (?, ?) ON CONFLICT(sessionId) DO UPDATE SET entryId=excluded.entryId, missingSince=NULL", [.text(id), .text(entryId)]) }
            if undoLabel != nil { after = try snapshot() }
        }
        if let label = undoLabel, let before, let after { afterUndoableCommit?(); append(.snapshot(label, before, after)) }
    }
    public func delete(entryId: String, undoLabel: String?) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            if undoLabel != nil { before = try snapshot() }
            try database.execute("DELETE FROM session_link WHERE entryId=?", [.text(entryId)])
            try database.execute("DELETE FROM change WHERE entryId=?", [.text(entryId)])
            try database.execute("DELETE FROM entry WHERE id=?", [.text(entryId)])
            if undoLabel != nil { after = try snapshot() }
        }
        if let label = undoLabel, let before, let after { afterUndoableCommit?(); append(.snapshot(label, before, after)) }
    }
    private func write(_ change: Change, _ database: Database) throws {
        try database.execute("INSERT INTO change VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, entryId=excluded.entryId, actor=excluded.actor, at=excluded.at", [.text(change.id), .text(change.kind.rawValue), .text(change.entryId), .text(change.by.rawValue), .time(change.at)])
    }
    public func addChange(_ change: Change) throws { let database = try db(); try database.transaction { try write(change, database) } }
    public func removeChanges(_ ids: [String]) throws { let database = try db(); try database.transaction { for id in ids { try database.execute("DELETE FROM change WHERE id=?", [.text(id)]) } } }
    public func revertAddedChange(id: String, seeds: [StrandSeed], undoLabel: String) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            before = try snapshot()
            guard let change = before?.changes.first(where: { $0.id == id && $0.kind == .add }) else {
                throw StoreError.database("Change no longer exists")
            }
            let affected = Set(before?.links.filter { $0.value.entryId == change.entryId }.map(\.key) ?? [])
            guard Set(seeds.map(\.sessionId)).isSubset(of: affected) else { throw StoreError.database("Links changed") }
            try database.execute("DELETE FROM session_link WHERE entryId=?", [.text(change.entryId)])
            try database.execute("DELETE FROM change WHERE entryId=?", [.text(change.entryId)])
            try database.execute("DELETE FROM entry WHERE id=?", [.text(change.entryId)])
            for seed in seeds {
                try write(seed.entry, database)
                try database.execute("INSERT INTO session_link (sessionId, entryId) VALUES (?, ?)", [.text(seed.sessionId), .text(seed.entry.id)])
            }
            after = try snapshot()
        }
        if let before, let after { afterUndoableCommit?(); append(.snapshot(undoLabel, before, after)) }
    }
    public func acceptChanges(undoLabel: String) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            before = try snapshot()
            try database.execute("DELETE FROM change")
            after = try snapshot()
        }
        if let before, let after, before.changes != after.changes {
            afterUndoableCommit?(); append(.snapshot(undoLabel, before, after))
        }
    }
    public func acceptSeenChanges(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        let database = try db()
        try database.transaction {
            for id in ids { try database.execute("DELETE FROM change WHERE id=?", [.text(id)]) }
        }
        undoStack = undoStack.map { item in
            guard case .snapshot(let label, var previous, var after) = item else { return item }
            previous.changes.removeAll { ids.contains($0.id) }
            after.changes.removeAll { ids.contains($0.id) }
            return .snapshot(label, previous, after)
        }
    }
    public func revertDoneChange(id: String, entry: Entry, undoLabel: String) throws {
        let database = try db(); var before: Snapshot?; var after: Snapshot?
        try database.transaction {
            before = try snapshot()
            guard before?.changes.contains(where: { $0.id == id && $0.entryId == entry.id && $0.kind == .done }) == true else {
                throw StoreError.database("Change no longer exists")
            }
            try write(entry, database)
            try database.execute("DELETE FROM change WHERE id=?", [.text(id)])
            after = try snapshot()
        }
        if let before, let after { afterUndoableCommit?(); append(.snapshot(undoLabel, before, after)) }
    }
    public func apply(_ patch: SettingsPatch) throws -> Settings {
        let database = try db(); var settings = Settings.defaults
        try database.transaction {
        settings = try loadSettings()
        switch patch {
        case .command(let tool, let command):
            guard command.contains("{id}") else { throw StoreError.invalidSettings("Command must contain {id}") }
            switch tool { case .codex: settings.commands.codex = command; case .claude: settings.commands.claude = command }
        case .terminals(let terminals): settings.terminal = terminals
        case .defaultTerminal(let terminal):
            settings.terminal = Settings.Terminals(default: terminal, alternate: terminal == .ghostty ? .terminal : .ghostty)
        case .hotkey(let slot, let hotkey):
            guard !hotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidSettings("Hotkey must not be empty") }
            switch slot { case .popover: settings.hotkeys.popover = hotkey; case .pin: settings.hotkeys.pin = hotkey; case .task: settings.hotkeys.task = hotkey }
        case .archiveDays(let days): guard (1...30).contains(days) else { throw StoreError.invalidSettings("Archive days must be 1–30") }; settings.archiveDays = days
        case .cleanupThreshold(let value): guard (1...50).contains(value) else { throw StoreError.invalidSettings("Cleanup threshold must be 1–50") }; settings.cleanupThreshold = value
        case .aiEnabled(let value): settings.ai.enabled = value
        case .defaultTool(let value): settings.defaultTool = value
        case .startFolder(let value): settings.startFolder = value
        case .trainerDone(let value): settings.trainerDone = value
        }
        try writeSettings(settings, database)
        }
        return settings
    }
    public func pushUndo(label: String, restore: @escaping @Sendable () async -> Void) { append(.action(label, restore)) }
    public func undo() async throws -> String? {
        guard let undo = undoStack.last else { return nil }
        switch undo {
        case .action(let label, let restore): undoStack.removeLast(); await restore(); return label
        case .snapshot(let label, let previous, let after):
            let database = try db(); try database.transaction {
                let beforeEntries = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
                let afterEntries = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.id, $0) })
                for id in Set(beforeEntries.keys).union(afterEntries.keys) where beforeEntries[id] != afterEntries[id] {
                    if let entry = beforeEntries[id] { try write(entry, database) }
                    else {
                        try database.execute("DELETE FROM session_link WHERE entryId=?", [.text(id)])
                        try database.execute("DELETE FROM change WHERE entryId=?", [.text(id)])
                        try database.execute("DELETE FROM entry WHERE id=?", [.text(id)])
                    }
                }
                for id in Set(previous.links.keys).union(after.links.keys) where previous.links[id] != after.links[id] {
                    if let link = previous.links[id] { try database.execute("INSERT INTO session_link (sessionId, entryId, missingSince) VALUES (?, ?, ?) ON CONFLICT(sessionId) DO UPDATE SET entryId=excluded.entryId, missingSince=excluded.missingSince", [.text(id), .text(link.entryId), .optional(link.missingSince)]) }
                    else { try database.execute("DELETE FROM session_link WHERE sessionId=?", [.text(id)]) }
                }
                let beforeChanges = Dictionary(uniqueKeysWithValues: previous.changes.map { ($0.id, $0) })
                let afterChanges = Dictionary(uniqueKeysWithValues: after.changes.map { ($0.id, $0) })
                for id in Set(beforeChanges.keys).union(afterChanges.keys) where beforeChanges[id] != afterChanges[id] {
                    if let change = beforeChanges[id] { try write(change, database) }
                    else { try database.execute("DELETE FROM change WHERE id=?", [.text(id)]) }
                }
                let orphans = try database.query("SELECT (SELECT count(*) FROM session_link WHERE NOT EXISTS (SELECT 1 FROM entry WHERE entry.id=session_link.entryId)) + (SELECT count(*) FROM change WHERE NOT EXISTS (SELECT 1 FROM entry WHERE entry.id=change.entryId))", row: { sqlite3_column_int64($0, 0) })
                guard orphans == [0] else { throw StoreError.database("Undo would leave orphaned references") }
            }
            undoStack.removeLast(); return label
        }
    }

    /// Counts only; intended for a disposable copy of a store.
    public func migrationCheck() throws -> String {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw StoreError.database("Store file missing") }
        // The app path runs first, on the store exactly as found (a cold WAL store has no -shm); the v1 counts come
        // afterwards from the backup (journal_mode DELETE), so this check never warms the store before migrating.
        let database = try db()
        let backupURL = databaseURL.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite")
        var counts = (0, 0, 0), settings = 0
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let source = try Database(path: backupURL.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            let hasOld = try !source.query("SELECT name FROM sqlite_master WHERE type='table' AND name='session_user'", row: { text($0, 0) }).isEmpty
            if hasOld { counts = try source.query("SELECT count(*), count(topic), count(archivedAt) FROM session_user") { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2))) }.first! }
            let hasSettings = try !source.query("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'", row: { text($0, 0) }).isEmpty
            if hasSettings { settings = try source.query("SELECT count(*) FROM settings WHERE key='settings'", row: { Int(sqlite3_column_int64($0, 0)) }).first! }
        }
        let entries = try database.query("SELECT count(*) FROM entry", row: { Int(sqlite3_column_int64($0, 0)) }).first!
        let titles = try database.query("SELECT count(title) FROM entry", row: { Int(sqlite3_column_int64($0, 0)) }).first!
        let links = try database.query("SELECT count(*) FROM session_link", row: { Int(sqlite3_column_int64($0, 0)) }).first!
        let backup = FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite").path) ? 1 : 0
        return "v1 rows: \(counts.0) · v1 topics: \(counts.1) · v1 archived: \(counts.2) · entries: \(entries) · entry titles: \(titles) · links: \(links) · settings migrated: \(settings) · backup present: \(backup)"
    }
    public func prune(knownIds: Set<String>, now: Date) throws {
        let database = try db(); try database.transaction {
            let links = try loadLinks()
            for (id, _) in links {
                if knownIds.contains(id) { try database.execute("UPDATE session_link SET missingSince=NULL WHERE sessionId=?", [.text(id)]) }
                else { try database.execute("UPDATE session_link SET missingSince=COALESCE(missingSince, ?) WHERE sessionId=?", [.time(now), .text(id)]) }
            }
            let expired = try database.query("SELECT sessionId, entryId FROM session_link WHERE missingSince IS NOT NULL AND missingSince <= ?", [.time(now.addingTimeInterval(-30 * 86400))]) { (text($0, 0)!, text($0, 1)!) }
            for (session, entry) in expired {
                try database.execute("DELETE FROM session_link WHERE sessionId=?", [.text(session)])
                try database.execute("DELETE FROM entry WHERE id=? AND NOT EXISTS (SELECT 1 FROM session_link WHERE entryId=?)", [.text(entry), .text(entry)])
            }
        }
    }
}
