import Foundation
import SQLite3
import Testing
import RBContract
@testable import RBStore

private func location() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/resume-bar-test-STORE-B-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("store.sqlite")
}
private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
private enum SessionStatus: String { case offen, wartet, erledigt }
private struct UserFields: Equatable {
    var topic: String?; var pinned: Bool; var status: SessionStatus
    var statusChangedAt: Date?; var archivedAt: Date?; var updatedAt: Date
}
private func fields(_ topic: String, at date: Date = Date(timeIntervalSince1970: 1000)) -> UserFields {
    UserFields(topic: topic, pinned: true, status: .wartet, statusChangedAt: date, archivedAt: date, updatedAt: date)
}
private func migratedFields(_ store: SQLiteStore) async throws -> [String: UserFields] {
    let entries = Dictionary(uniqueKeysWithValues: try await store.loadEntries().map { ($0.id, $0) })
    return try await store.loadLinks().reduce(into: [:]) { result, pair in
        guard let e = entries[pair.value], let status = SessionStatus(rawValue: e.status.rawValue) else { throw StoreError.database("Invalid link") }
        result[pair.key] = UserFields(topic: e.title, pinned: e.title != nil, status: status, statusChangedAt: e.statusChangedAt, archivedAt: e.archivedAt, updatedAt: e.updatedAt)
    }
}
private func entryFromFields(_ id: String, _ f: UserFields) -> Entry {
    Entry(id: id, projectId: nil, title: f.topic, status: EntryStatus(rawValue: f.status.rawValue)!, statusChangedAt: f.statusChangedAt, createdBy: .user, createdAt: f.updatedAt, updatedAt: f.updatedAt, archivedAt: f.archivedAt)
}
private func sql(_ url: URL, _ statement: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.database("open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw StoreError.database("SQL failed") }
}
private actor Flag {
    var value = false
    func set() { value = true }
}

@Test func roundTripAcrossReopen() async throws {
    let url = try location(); defer { cleanup(url) }
    let first = SQLiteStore(databaseURL: url)
    let expected = fields("Project")
    try await first.save(entryFromFields("e", expected), undoLabel: "Save")
    try await first.link(["cx_1"], to: "e", undoLabel: nil)
    _ = try await first.apply(.archiveDays(9))
    let second = SQLiteStore(databaseURL: url)
    #expect(try await migratedFields(second)["cx_1"] == expected)
    #expect(try await second.loadSettings().archiveDays == 9)
}

@Test func migratesVersionZeroWithExistingFields() async throws {
    let url = try location(); defer { cleanup(url) }
    try sql(url, "CREATE TABLE session_user (id TEXT PRIMARY KEY, topic TEXT, pinned INTEGER NOT NULL, status TEXT NOT NULL, statusChangedAt REAL, archivedAt REAL, updatedAt REAL NOT NULL); INSERT INTO session_user VALUES ('old', 'Old', 1, 'wartet', NULL, NULL, 1000)")
    let store = SQLiteStore(databaseURL: url)
    #expect(try await migratedFields(store)["old"]?.topic == "Old")
    try await store.prune(knownIds: [], now: Date(timeIntervalSince1970: 2000))
    #expect(try await migratedFields(store)["old"] != nil)
}

@Test func corruptFileRemainsUntouched() async throws {
    let url = try location(); defer { cleanup(url) }
    let original = Data("not sqlite".utf8); try original.write(to: url)
    let store = SQLiteStore(databaseURL: url)
    await #expect(throws: (any Error).self) { try await migratedFields(store) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func undoRestoresPreviousValuesAndAbsence() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    try await store.save(entryFromFields("id", fields("one")), undoLabel: "first")
    try await store.save(entryFromFields("id", fields("two")), undoLabel: "second")
    #expect(try await store.undo() == "second")
    #expect(try await store.loadEntries().first?.title == "one")
    #expect(try await store.undo() == "first")
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.undo() == nil)
}

@Test func undoRetainsOnlyTwentySteps() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    for i in 0..<21 { try await store.save(entryFromFields("id", fields("\(i)")), undoLabel: "\(i)") }
    for i in (1...20).reversed() { #expect(try await store.undo() == "\(i)") }
    #expect(try await store.undo() == nil)
    #expect(try await store.loadEntries().first?.title == "0")
}

@Test func externalUndoRunsInOrder() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let flag = Flag()
    try await store.save(entryFromFields("id", fields("one")), undoLabel: "fields")
    await store.pushUndo(label: "external") { await flag.set() }
    #expect(try await store.undo() == "external")
    #expect(await flag.value)
    #expect(try await store.undo() == "fields")
}

@Test func settingsDefaultWhenMissing() async throws {
    let url = try location(); defer { cleanup(url) }
    #expect(try await SQLiteStore(databaseURL: url).loadSettings() == .defaults)
}

@Test func archiveDaysDefaultAndStoredValueSurviveReopening() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    #expect(try await store.loadSettings().archiveDays == 14)
    _ = try await store.apply(.archiveDays(3))
    #expect(try await SQLiteStore(databaseURL: url).loadSettings().archiveDays == 3)
}

@Test func terminalPairPersistsExactly() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let terminals = Settings.Terminals(default: .terminal, alternate: .terminal)
    _ = try await store.apply(.terminals(terminals))
    #expect(try await SQLiteStore(databaseURL: url).loadSettings().terminal == terminals)
}

@Test func commandValidationPreservesSettings() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    _ = try await store.apply(.command(.codex, "resume {id}"))
    let expected = try await store.loadSettings()
    for tool in [Tool.codex, .claude] {
        await #expect(throws: StoreError.self) { try await store.apply(.command(tool, "resume")) }
        #expect(try await store.loadSettings() == expected)
    }
}

@Test func archiveValidationPreservesSettings() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    for value in [0, 31] { await #expect(throws: StoreError.self) { try await store.apply(.archiveDays(value)) } }
    #expect(try await store.loadSettings() == .defaults)
    #expect(try await store.apply(.archiveDays(1)).archiveDays == 1)
    #expect(try await store.apply(.archiveDays(30)).archiveDays == 30)
}

@Test func cleanupValidationPreservesSettings() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    for value in [0, 51] { await #expect(throws: StoreError.self) { try await store.apply(.cleanupThreshold(value)) } }
    #expect(try await store.loadSettings() == .defaults)
    #expect(try await store.apply(.cleanupThreshold(1)).cleanupThreshold == 1)
    #expect(try await store.apply(.cleanupThreshold(50)).cleanupThreshold == 50)
}

@Test func hotkeyValidationPreservesSettings() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    for slot in [HotkeySlot.popover, .pin] { await #expect(throws: StoreError.self) { try await store.apply(.hotkey(slot, "  ")) } }
    #expect(try await store.loadSettings() == .defaults)
    #expect(try await store.apply(.hotkey(.pin, "⌘P")).hotkeys.pin == "⌘P")
}

@Test func pruneTracksContinuousAbsence() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86400
    _ = try await store.createStrands([StrandSeed(sessionId: "gone", entry: entryFromFields("gone", fields("gone")))])
    _ = try await store.createStrands([StrandSeed(sessionId: "returned", entry: entryFromFields("returned", fields("returned")))])
    try await store.prune(knownIds: [], now: now)
    try await store.prune(knownIds: ["returned"], now: now.addingTimeInterval(29 * day))
    #expect(try await migratedFields(store).count == 2)
    try await store.prune(knownIds: [], now: now.addingTimeInterval(30 * day))
    #expect(try await migratedFields(store)["gone"] == nil)
    #expect(try await migratedFields(store)["returned"] != nil)
    try await store.prune(knownIds: [], now: now.addingTimeInterval(60 * day))
    #expect(try await migratedFields(store).isEmpty)
}

private func entry(_ id: String, title: String? = nil) -> Entry {
    Entry(id: id, projectId: "project", title: title, status: .offen, createdBy: .user,
          createdAt: Date(timeIntervalSince1970: 1000.123456), updatedAt: Date(timeIntervalSince1970: 1000.123456))
}

@Test func v1MigrationPreservesIdentityAndBackupLifecycle() async throws {
    let url = try location(); defer { cleanup(url) }
    try sql(url, "CREATE TABLE session_user (id TEXT PRIMARY KEY, topic TEXT, pinned INTEGER NOT NULL, status TEXT NOT NULL, statusChangedAt REAL, archivedAt REAL, updatedAt REAL NOT NULL); CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO session_user VALUES ('pinned','Title',1,'wartet',101,102,103),('unpinned','Still named',0,'erledigt',201,NULL,203),('archived',NULL,0,'offen',NULL,302,303); PRAGMA user_version=1")
    var old = Settings.defaults; old.hotkeys.popover = "⌥⌘Space"
    let json = String(data: try RBJSON.encoder().encode(old), encoding: .utf8)!
    var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    object.removeValue(forKey: "ai")
    var hotkeys = object["hotkeys"] as! [String: Any]; hotkeys.removeValue(forKey: "task"); object["hotkeys"] = hotkeys
    let legacyJSON = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
    try sql(url, "INSERT INTO settings VALUES ('settings','\(legacyJSON)')")
    let store = SQLiteStore(databaseURL: url)
    let fields = try await migratedFields(store); let links = try await store.loadLinks()
    #expect(fields["pinned"] == UserFields(topic: "Title", pinned: true, status: .wartet, statusChangedAt: Date(timeIntervalSince1970: 101), archivedAt: Date(timeIntervalSince1970: 102), updatedAt: Date(timeIntervalSince1970: 103)))
    #expect(fields["unpinned"]?.topic == "Still named")
    #expect(fields["unpinned"]?.status == .erledigt)
    #expect(fields["archived"]?.archivedAt == Date(timeIntervalSince1970: 302))
    #expect(Set(links.keys) == Set(["pinned", "unpinned", "archived"]))
    #expect(Set(links.values).count == 3)
    let settings = try await store.loadSettings()
    #expect(settings.hotkeys.popover == "⇧⌘Space")
    #expect(settings.hotkeys.task == Settings.defaults.hotkeys.task)
    #expect(settings.ai == Settings.defaults.ai)
    let backup = url.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite")
    let original = try Data(contentsOf: backup)
    _ = try await SQLiteStore(databaseURL: url).loadEntries()
    #expect(try Data(contentsOf: backup) == original)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86400)], ofItemAtPath: backup.path)
    _ = try await SQLiteStore(databaseURL: url).loadEntries()
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

@Test func migrationFailureRollsBackOriginalBytes() async throws {
    let url = try location(); defer { cleanup(url) }
    try sql(url, "CREATE TABLE session_user (id TEXT PRIMARY KEY, topic TEXT, pinned INTEGER NOT NULL, status TEXT NOT NULL, statusChangedAt REAL, archivedAt REAL, updatedAt REAL NOT NULL); INSERT INTO session_user VALUES ('id','title',1,'invalid',NULL,NULL,123); PRAGMA user_version=1")
    let original = try Data(contentsOf: url)
    await #expect(throws: (any Error).self) { try await SQLiteStore(databaseURL: url).loadEntries() }
    #expect(try Data(contentsOf: url) == original)
    let backup = url.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite")
    #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test func strandsAreAtomicIdempotentAndConcurrent() async throws {
    let url = try location(); defer { cleanup(url) }
    let first = SQLiteStore(databaseURL: url); let second = SQLiteStore(databaseURL: url)
    _ = try await first.loadEntries(); _ = try await second.loadEntries()
    let seeds = (0..<8).map { StrandSeed(sessionId: "s\($0)", entry: entry("e\($0)")) }
    async let a = first.createStrands(seeds)
    async let b = second.createStrands(seeds)
    let (one, two) = try await (a, b)
    #expect(one == two)
    #expect(try await first.createStrands(seeds) == one)
    #expect(try await first.loadEntries().count == 8)
    #expect(try await first.loadLinks() == one)
    let bad = [StrandSeed(sessionId: "new", entry: entry("e_new")), StrandSeed(sessionId: "other", entry: entry("e0"))]
    await #expect(throws: (any Error).self) { try await first.createStrands(bad) }
    #expect(try await first.loadLinks()["new"] == nil)
    #expect(try await first.loadEntries().count == 8)
}

@Test func entryLinkUndoAndCountState() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let initial = entry("first", title: "old")
    try await store.save(initial, undoLabel: nil)
    var changed = initial; changed.title = "new"
    try await store.save(changed, undoLabel: "title")
    try await store.link(["s"], to: initial.id, undoLabel: "link")
    _ = try await store.createStrands([StrandSeed(sessionId: "independent", entry: entry("independent"))])
    #expect(try await store.undo() == "link")
    #expect(try await store.loadLinks() == ["independent": "independent"])
    #expect(try await store.undo() == "title")
    #expect(try await store.loadEntries().first { $0.id == "first" } == initial)
    let state = ResumeCountState(counts: ["s": 5, "other": 2], historyImportVersion: 3, counted: [CountedProcess(pid: 42, start: UInt64.max, sessionId: "s")])
    try await store.saveResumeCountState(state)
    #expect(try await SQLiteStore(databaseURL: url).loadResumeCountState() == state)
    _ = try await store.apply(.aiEnabled(false))
    #expect(try await store.apply(.hotkey(.task, "⌘T")).hotkeys.task == "⌘T")
    #expect(try await store.loadSettings().ai.enabled == false)
}

@Test func countStateRollsBackTogetherOnFailure() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let before = ResumeCountState(counts: ["old": 4], historyImportVersion: 1,
                                  counted: [CountedProcess(pid: 9, start: 42, sessionId: "old")])
    try await store.saveResumeCountState(before)
    try sql(url, "CREATE TRIGGER fail_count_marker BEFORE UPDATE ON meta WHEN NEW.key='countedProcesses' BEGIN SELECT RAISE(ABORT, 'failure'); END")
    let after = ResumeCountState(counts: ["new": 7], historyImportVersion: 2, counted: [])
    await #expect(throws: (any Error).self) { try await store.saveResumeCountState(after) }
    #expect(try await store.loadResumeCountState() == before)
}

@Test func migrationBackupIncludesLiveWALAndDiagnostics() async throws {
    let url = try location(); defer { cleanup(url) }
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw StoreError.database("open") }
    defer { sqlite3_close(handle) }
    let statements = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE session_user (id TEXT PRIMARY KEY, topic TEXT, pinned INTEGER NOT NULL, status TEXT NOT NULL, statusChangedAt REAL, archivedAt REAL, updatedAt REAL NOT NULL); CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); PRAGMA user_version=1; INSERT INTO session_user VALUES ('wal','WAL title',1,'offen',NULL,NULL,1000)"
    guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else { throw StoreError.database("fixture") }
    let store = SQLiteStore(databaseURL: url)
    let report = try await store.migrationCheck()
    #expect(report.contains("v1 rows: 1"))
    #expect(report.contains("entry titles: 1"))
    #expect(report.contains("backup present: 1"))
    #expect(try await migratedFields(store)["wal"]?.topic == "WAL title")
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(!names.contains { $0.contains(".tmp-") })
    let backup = url.deletingLastPathComponent().appendingPathComponent("store.v1.sqlite")
    var backupHandle: OpaquePointer?
    guard sqlite3_open_v2(backup.path, &backupHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let backupHandle else { throw StoreError.database("backup open") }
    defer { sqlite3_close(backupHandle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(backupHandle, "SELECT topic FROM session_user WHERE id='wal'", -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.database("backup query: " + String(cString: sqlite3_errmsg(backupHandle))) }
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(statement, 0)) == "WAL title")
}

@Test func migrationFromColdWALCreatesStandaloneBackup() async throws {
    for permissions in [0o600, 0o640] {
        let url = try location(); defer { cleanup(url) }
        try sql(url, "PRAGMA journal_mode=WAL; CREATE TABLE session_user (id TEXT PRIMARY KEY, topic TEXT, pinned INTEGER NOT NULL, status TEXT NOT NULL, statusChangedAt REAL, archivedAt REAL, updatedAt REAL NOT NULL); INSERT INTO session_user VALUES ('one','First',1,'offen',NULL,NULL,1000),('two','Second',0,'wartet',NULL,NULL,2000); PRAGMA user_version=1; PRAGMA wal_checkpoint(TRUNCATE)")
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        // SQLite on this host can retain empty WAL sidecars after the last close.
        // The checkpoint above makes removing them equivalent to a clean close.
        if FileManager.default.fileExists(atPath: url.path + "-wal") {
            try #require(FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? UInt64 == 0)
        }
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let header = try Data(contentsOf: url).prefix(20)
        #expect(header[18] == 2 && header[19] == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == permissions)
        for suffix in ["-wal", "-shm"] {
            try #require(!FileManager.default.fileExists(atPath: url.path + suffix))
        }

        let store = SQLiteStore(databaseURL: url)
        let fields = try await migratedFields(store)
        #expect(fields["one"]?.topic == "First")
        #expect(fields["two"]?.topic == "Second")
        #expect(Set(try await store.loadLinks().keys) == Set(["one", "two"]))

        let directory = url.deletingLastPathComponent()
        let backup = directory.appendingPathComponent("store.v1.sqlite")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".tmp-") })
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: backup.path + suffix))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { throw StoreError.database("backup open") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, topic FROM session_user ORDER BY id", -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.database("backup query") }
        defer { sqlite3_finalize(statement) }
        for (id, title) in [("one", "First"), ("two", "Second")] {
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            #expect(String(cString: sqlite3_column_text(statement, 0)) == id)
            #expect(String(cString: sqlite3_column_text(statement, 1)) == title)
        }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }
}

private final class InterleavedWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false
    func markSucceeded() { lock.lock(); succeeded = true; lock.unlock() }
    func didSucceed() -> Bool { lock.lock(); defer { lock.unlock() }; return succeeded }
}

@Test func undoSnapshotsExcludeWriterImmediatelyAfterCommit() async throws {
    for operation in ["save", "link", "delete"] {
        let url = try location(); defer { cleanup(url) }
        let setup = SQLiteStore(databaseURL: url)
        try await setup.save(entry("base"), undoLabel: nil)
        let second = SQLiteStore(databaseURL: url)
        _ = try await second.loadEntries()
        let writer = InterleavedWriter()
        let store = SQLiteStore(databaseURL: url, afterUndoableCommit: {
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                defer { finished.signal() }
                if (try? await second.createStrands([StrandSeed(sessionId: "other-session", entry: entry("other"))])) != nil {
                    writer.markSucceeded()
                }
            }
            _ = finished.wait(timeout: .now() + 10)
        })
        switch operation {
        case "save": try await store.save(entry("new"), undoLabel: operation)
        case "link": try await store.link(["session"], to: "base", undoLabel: operation)
        case "delete": try await store.delete(entryId: "base", undoLabel: operation)
        default: break
        }
        #expect(writer.didSucceed(), "Second store must commit at the interleaving point for \(operation)")
        #expect(try await store.undo() == operation)
        #expect(try await store.loadEntries().contains { $0.id == "other" })
        #expect(try await store.loadLinks()["other-session"] == "other")
    }
}

@Test func undoNewEntryRemovesLaterDependencies() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let item = entry("new")
    try await store.save(item, undoLabel: "add")
    try await store.link(["s"], to: item.id, undoLabel: nil)
    try await store.addChange(Change(id: "later", kind: .done, entryId: item.id, by: .user, at: item.updatedAt))
    #expect(try await store.undo() == "add")
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.loadLinks().isEmpty)
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await migratedFields(store).isEmpty)
}

@Test func undoRelinkAndDeleteRestoreMissingSince() async throws {
    for operation in ["relink", "delete"] {
        let url = try location(); defer { cleanup(url) }
        let store = SQLiteStore(databaseURL: url)
        let absent = Date(timeIntervalSince1970: 1_000_000)
        try await store.save(entry("original"), undoLabel: nil)
        try await store.save(entry("other"), undoLabel: nil)
        try await store.link(["s"], to: "original", undoLabel: nil)
        try await store.prune(knownIds: [], now: absent)
        if operation == "relink" { try await store.link(["s"], to: "other", undoLabel: operation) }
        else { try await store.delete(entryId: "original", undoLabel: operation) }
        #expect(try await store.undo() == operation)
        #expect(try await store.loadLinks()["s"] == "original")
        try await store.prune(knownIds: [], now: absent.addingTimeInterval(29 * 86400))
        #expect(try await store.loadLinks()["s"] == "original")
        try await store.prune(knownIds: [], now: absent.addingTimeInterval(30 * 86400))
        #expect(try await store.loadLinks()["s"] == nil)
    }
}

@Test func changesAndDeleteUndo() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let item = entry("task", title: "Task")
    let change = Change(id: "c", kind: .done, entryId: item.id, by: .claude, at: item.updatedAt)
    try await store.save(item, undoLabel: nil)
    try await store.link(["s"], to: item.id, undoLabel: nil)
    try await store.addChange(change)
    #expect(try await store.loadChanges() == [change])
    try await store.delete(entryId: item.id, undoLabel: "delete")
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.loadLinks().isEmpty)
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await store.undo() == "delete")
    #expect(try await store.loadEntries() == [item])
    #expect(try await store.loadLinks() == ["s": "task"])
    #expect(try await store.loadChanges() == [change])
    try await store.removeChanges(["c"])
    #expect(try await store.loadChanges().isEmpty)
}

@Test func saveEntryWithChangeIsAtomic() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    _ = try await store.loadEntries()
    try sql(url, "CREATE TRIGGER reject_change BEFORE INSERT ON change BEGIN SELECT RAISE(ABORT, 'rejected'); END")
    let entry = entryFromFields("atomic", fields("Atomic"))
    let change = Change(id: "c", kind: .add, entryId: entry.id, by: .claude, at: Date())
    await #expect(throws: (any Error).self) { try await store.save(entry, change: change, undoLabel: "Add") }
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await store.undo() == nil)
}
@Test func undoRemovesEntryAndItsChange() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let entry = entryFromFields("atomic", fields("Atomic"))
    let change = Change(id: "c", kind: .add, entryId: entry.id, by: .codex, at: Date(timeIntervalSince1970: 1000))
    try await store.save(entry, change: change, undoLabel: "Add")
    #expect(try await store.loadEntries().count == 1)
    #expect(try await store.loadChanges() == [change])
    #expect(try await store.undo() == "Add")
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.loadChanges().isEmpty)
}

@Test func revertAddedChangeRemovesEntryAndChange() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let item = entryFromFields("added", fields("Added"))
    let change = Change(id: "add", kind: .add, entryId: item.id, by: .codex, at: item.updatedAt)
    try await store.save(item, change: change, undoLabel: "Add")
    try await store.revertAddedChange(id: change.id, seeds: [], undoLabel: "Revert")
    #expect(try await store.loadEntries().isEmpty)
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await store.undo() == "Revert")
    #expect(try await store.loadEntries() == [item])
    #expect(try await store.loadChanges() == [change])
}

@Test func silentAcceptAddsNoUndo() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let item = entryFromFields("silent", fields("before"))
    try await store.save(item, undoLabel: nil)
    let change = Change(id: "silent-change", kind: .add, entryId: item.id, by: .codex, at: item.updatedAt)
    try await store.addChange(change)
    var edited = item; edited.title = "after"
    try await store.save(edited, undoLabel: "Edit")
    try await store.acceptSeenChanges(["silent-change"])
    #expect(try await store.loadChanges().isEmpty)
    #expect(try await store.undo() == "Edit")
    #expect(try await store.loadEntries().first?.title == "before")
    #expect(try await store.loadChanges().isEmpty)
}

@Test func silentAcceptOnlyRemovesSeenIds() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    let item = entryFromFields("two", fields("before"))
    try await store.save(item, undoLabel: nil)
    let seen = Change(id: "seen", kind: .add, entryId: item.id, by: .codex, at: item.updatedAt)
    let unseen = Change(id: "unseen", kind: .done, entryId: item.id, by: .claude, at: item.updatedAt)
    try await store.addChange(seen); try await store.addChange(unseen)
    var edited = item; edited.title = "after"
    try await store.save(edited, undoLabel: "Edit")
    try await store.acceptSeenChanges([seen.id])
    #expect(try await store.loadChanges() == [unseen])
    #expect(try await store.undo() == "Edit")
    #expect(try await store.loadChanges() == [unseen])
    #expect(try await store.undo() == nil)
}

@Test func settingsDefaultsAndStoredCommandSurvive() async throws {
    let url = try location(); defer { cleanup(url) }
    let store = SQLiteStore(databaseURL: url)
    #expect(try await !store.hasStoredSettings())
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try await store.loadSettings() == Settings.defaults)
    #expect(try await !store.hasStoredSettings())
    _ = try await store.apply(.command(.codex, "zz resume {id}"))
    #expect(try await store.hasStoredSettings())
    _ = try await store.apply(.archiveDays(7))
    let reopened = SQLiteStore(databaseURL: url)
    #expect(try await reopened.loadSettings().commands.codex == "zz resume {id}")
    #expect(try await reopened.readOnlySettings()?.commands.codex == "zz resume {id}")
}

@Test func missingCommandsSourceDecodes() throws {
    let data = try RBJSON.encoder().encode(Settings.defaults)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "commandsSource")
    let decoded = try RBJSON.decoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.commandsSource.isEmpty)
}
