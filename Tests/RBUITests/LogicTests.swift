import Foundation
import Testing
import RBContract
@testable import RBUI

private let v2Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private struct V2Oracle: Decodable {
    struct Result: Decodable { let id: String; let dueState: String?; let dueShort: String?; let titleOf: String }
    struct Strand: Decodable { let id: String; let isArchived: Bool; let tier: Int }
    struct Deadline: Decodable { let word: String; let date: String?; let input: String? }
    let fixture: String
    let ui: Logic.UI
    let viewSnapshot: Snapshot
    let sortStrands: [String], sortTasks: [String], projectList: [String?], urgentTasks: [String]
    let entries: [Result], strands: [Strand], views: [String: [Logic.Row]], deadlines: [Deadline]
}
private let oracleFiles: [String] = (try? FileManager.default.contentsOfDirectory(atPath: v2Root.appendingPathComponent("Tests/Fixtures/v2-oracle").path).filter { $0.hasSuffix(".json") }.sorted()) ?? []

private func compare<T: Equatable>(_ actual: [T], _ expected: [T], _ name: String, _ fixture: String) {
    let first = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
    #expect(actual == expected, "\(fixture): \(name), first difference \(first.map { String(describing: $0.element) } ?? "length \(actual.count)/\(expected.count)")")
}
@Test(arguments: oracleFiles)
private func v2Oracle(file: String) throws {
    let oracleURL = v2Root.appendingPathComponent("Tests/Fixtures/v2-oracle/" + file)
    let o = try RBJSON.decoder().decode(V2Oracle.self, from: Data(contentsOf: oracleURL))
    let s = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/" + o.fixture)))
    let here = o.ui.contextDismissed ? nil : s.context?.projectId
    let strands = s.entries.filter { Logic.isStrang(s, $0) }, tasks = s.entries.filter { !Logic.isStrang(s, $0) }
    compare(Logic.sortStrands(s, strands, here).map(\.id), o.sortStrands, "sortStrands", file)
    compare(Logic.sortTasks(s, tasks).map(\.id), o.sortTasks, "sortTasks", file)
    compare(Logic.projectList(s, here), o.projectList, "projectList", file)
    compare(Logic.urgentTasks(s).map(\.id), o.urgentTasks, "urgentTasks", file)
    for expected in o.entries {
        let e = try #require(s.entry(expected.id))
        #expect(Logic.dueState(s, e) == expected.dueState, "\(file): dueState \(e.id)")
        #expect(e.deadline.map { Logic.dueShort(s, $0, translate: { $0 }) } == expected.dueShort, "\(file): dueShort \(e.id)")
        #expect(Logic.titleOf(s, e) == expected.titleOf, "\(file): titleOf \(e.id)")
    }
    for expected in o.strands {
        let e = try #require(s.entry(expected.id))
        #expect(Logic.isArchived(s, e) == expected.isArchived, "\(file): isArchived \(e.id)")
        #expect(Logic.tier(s, e) == expected.tier, "\(file): tier \(e.id)")
    }
    // Both modes use the same project tree when no text is entered.
    var resume = o.ui; resume.mode = "resume"; resume.query = ""; resume.chips = []
    var goal = resume; goal.mode = "ziel"
    #expect(Logic.buildView(o.viewSnapshot, resume).rows == Logic.buildView(o.viewSnapshot, goal).rows)
    for d in o.deadlines {
        let actual = Logic.parseDeadline(s, d.word)
        #expect(actual == d.date, "\(file): parseDeadline \(d.word)")
        #expect(actual.map(Logic.dueInput) == d.input, "\(file): dueInput \(d.word)")
    }
}
@Test private func v2OracleCoverage() { #expect(oracleFiles.count == 36) }

@Test func localizedDateLabels() throws {
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    for (index, month) in months.enumerated() {
        #expect(Logic.dayLabel(day: 6, month: index + 1, language: .en) == "\(month) 6")
    }
    #expect(Logic.dayLabel(day: 6, month: 11, language: .de) == "06.11")
    #expect(Logic.dayLabel(day: 26, month: 10, language: .de) == "26.10")

    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    var snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    snapshot.now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 16))!
    let weekday: (String) -> String = { _ in "Fr" }
    #expect(Logic.dueShort(snapshot, "2026-11-06", language: .de) == "06.11")
    #expect(Logic.dueLong(snapshot, "2026-11-06", translate: weekday, language: .de) == "Fr 06.11.")
    #expect(Logic.dueShort(snapshot, "2026-11-06", language: .en) == "Nov 6")
    #expect(Logic.dueLong(snapshot, "2026-11-06", translate: { _ in "Fri" }, language: .en) == "Fri Nov 6")
    #expect(Logic.dueInput("2026-11-06", language: .de) == "06.11")
    #expect(Logic.dueInput("2026-11-06", language: .en) == "2026-11-06")
    #expect(Logic.parseDeadline(snapshot, Logic.dueInput("2026-11-06", language: .en)) == "2026-11-06")
    let old = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 16))!
    #expect(Logic.agoShort(snapshot, old, language: .de) == "26.10")
    #expect(Logic.agoLong(snapshot, old, language: .de) == "26.10. 16:00")
    #expect(Logic.agoShort(snapshot, old, language: .en) == "Oct 26")
    #expect(Logic.agoLong(snapshot, old, language: .en) == "Oct 26 16:00")
}

@Test func menuBarIconPrefersOverdue() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.deadline.json")
    var snap = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    snap.entries = []; snap.justEnded = []; snap.changes = []
    #expect(Logic.menuBarIcon(snap) == .plain)
    let entry = Entry(id: "goal", projectId: nil, title: "Goal", status: .offen, deadline: "2000-01-01",
                      createdBy: .user, createdAt: snap.now, updatedAt: snap.now)
    snap.justEnded = [entry.id]
    #expect(Logic.menuBarIcon(snap) == .news)
    snap.entries = [entry]
    #expect(Logic.menuBarIcon(snap) == .overdue)
    snap.entries[0].archivedAt = snap.now
    #expect(Logic.menuBarIcon(snap) == .news)
    snap.entries[0].archivedAt = nil; snap.entries[0].status = .erledigt
    #expect(Logic.menuBarIcon(snap) == .news)
    snap.justEnded = []
    snap.changes = [Change(id: "change", kind: .done, entryId: entry.id, by: .codex, at: snap.now)]
    #expect(Logic.menuBarIcon(snap) == .news)
    snap.changes = []
    #expect(Logic.menuBarIcon(snap) == .plain)
}

@Test func parseDeadlineTwoDigitYear() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    #expect(Logic.parseDeadline(snapshot, "10.12.26") == "2026-12-10")
    #expect(Logic.parseDeadline(snapshot, "31.02.26") == nil)
    #expect(Logic.parseDeadline(snapshot, "14.11") == "2026-11-14")
    #expect(Logic.parseDeadline(snapshot, "29.02.00") == "2000-02-29")
    #expect(Logic.parseDeadline(snapshot, "29.02.01") == nil)
    #expect(Logic.parseDeadline(snapshot, "10.12.2026") == "2026-12-10")
}

@Test func parseDeadlineEnglishWords() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    #expect(Logic.parseDeadline(snapshot, " TODAY ") == Logic.parseDeadline(snapshot, "heute"))
    #expect(Logic.parseDeadline(snapshot, "Tomorrow") == Logic.parseDeadline(snapshot, "morgen"))
    for (english, full, german) in zip(zip(["sun", "mon", "tue", "wed", "thu", "fri", "sat"], ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]), ["so", "mo", "di", "mi", "do", "fr", "sa"]).map({ ($0.0.0, $0.0.1, $0.1) }) {
        #expect(Logic.parseDeadline(snapshot, english) == Logic.parseDeadline(snapshot, german))
        #expect(Logic.parseDeadline(snapshot, full) == Logic.parseDeadline(snapshot, german))
    }
}

@Test func parseDeadlineIsoDate() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    #expect(Logic.parseDeadline(snapshot, "2024-02-29") == "2024-02-29")
    for invalid in ["2025-02-29", "2026-13-01", "2026-00-01", "2026-01-00", "2026-1-01", "0000-01-01"] {
        #expect(Logic.parseDeadline(snapshot, invalid) == nil)
    }
}

@Test func parseDeadlineGermanUnchanged() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    #expect(Logic.parseDeadline(snapshot, "übermorgen") != nil)
    for (short, full) in zip(["so", "mo", "di", "mi", "do", "fr", "sa"], ["sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag"]) {
        #expect(Logic.parseDeadline(snapshot, short) == Logic.parseDeadline(snapshot, full))
        #expect(Logic.parseDeadline(snapshot, short) != nil)
    }
    #expect(Logic.parseDeadline(snapshot, "10.12.26") == "2026-12-10")
    #expect(Logic.parseDeadline(snapshot, "31.02.26") == nil)
}

@Test func deadlinePrefixBindsItsWords() throws {
    let url = v2Root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.aufgabe.json")
    let snapshot = try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: url))
    for (prefix, accepted, rejected) in [("bis", "so", "sun"), ("by", "sun", "so")] {
        #expect(Logic.deadlineAfter(prefix: prefix, word: accepted, snapshot) == Logic.parseDeadline(snapshot, accepted))
        #expect(Logic.deadlineAfter(prefix: prefix, word: rejected, snapshot) == nil)
        #expect(Logic.hasTrailingDeadline(snapshot, "Stop \(prefix) \(accepted)"))
        #expect(!Logic.hasTrailingDeadline(snapshot, "Stop \(prefix) \(rejected)"))
        for number in ["14.11", "2026-11-14"] {
            #expect(Logic.deadlineAfter(prefix: prefix.uppercased(), word: number, snapshot) == "2026-11-14")
        }
    }
    #expect(Logic.deadlineAfter(prefix: "before", word: "sun", snapshot) == nil)
}
