import Foundation
import RBContract

/// Pure v2 ranking, search and view construction over the shared snapshot.
public enum Logic {
    public static func firstRunTerminals(ghosttyInstalled: Bool) -> Settings.Terminals {
        ghosttyInstalled ? .init(default: .ghostty, alternate: .terminal) : .init(default: .terminal, alternate: .terminal)
    }

    public static func saysNothing(_ entry: Entry, hasSession: Bool, hasChange: Bool) -> Bool {
        (entry.title ?? "").isEmpty && entry.deadline == nil && !hasSession && !hasChange
    }
    public static func startFolder(settings: Settings, projects: [Project], home: String) -> String {
        if let configured = settings.startFolder, !configured.isEmpty {
            if configured == "~" { return home }
            if configured.hasPrefix("~/") { return home + String(configured.dropFirst()) }
            return configured
        }
        let parents = projects.map { URL(fileURLWithPath: $0.rootPath).deletingLastPathComponent().path }
        let counts = Dictionary(grouping: parents, by: { $0 }).mapValues(\.count)
        return counts.filter { $0.value >= 2 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first?.key ?? home
    }
    public struct Filter: Codable, Sendable, Equatable {
        public var kind: String
        public var value: String
        public var label: String
        public init(kind: String, value: String, label: String = "") { self.kind = kind; self.value = value; self.label = label }
        private enum CodingKeys: String, CodingKey { case kind, value, label }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind); label = try c.decode(String.self, forKey: .label)
            if let string = try? c.decode(String.self, forKey: .value) { value = string }
            else { value = try c.decode(Bool.self, forKey: .value) ? "true" : "false" }
        }
    }
    public struct UI: Codable, Sendable, Equatable {
        public var mode: String
        public var chips: [Filter]
        public var query: String
        public var openEntries: [String]
        public var openProjects: [String]
        public var contextDismissed: Bool
        public var closedSearchProjects: [String]?
        public init(mode: String = "resume", chips: [Filter] = [], query: String = "", openEntries: [String] = [], openProjects: [String] = [], contextDismissed: Bool = false, closedSearchProjects: [String]? = nil) {
            self.mode = mode; self.chips = chips; self.query = query; self.openEntries = openEntries; self.openProjects = openProjects; self.contextDismissed = contextDismissed; self.closedSearchProjects = closedSearchProjects
        }
    }
    public struct Row: Codable, Sendable, Equatable {
        public var type: String
        public var id: String?
        public var flat: Bool?
        public var key: String?
        public var entryId: String?
        public var open: Bool?
        public var count: Int?
        public init(_ type: String, _ id: String?, _ flat: Bool? = nil, key: String? = nil, entryId: String? = nil, open: Bool? = nil, count: Int? = nil) {
            self.type = type; self.id = id; self.flat = flat; self.key = key; self.entryId = entryId; self.open = open; self.count = count
        }
    }
    public struct View: Sendable {
        public var rows: [Row]
        public var keys: [String]
        public var searching: Bool
        public var filters: [String: String]
        public var words: [String]
        public var here: String?
    }
    public static func projectOf(_ s: Snapshot, _ id: String?) -> Project? {
        guard let id, !id.isEmpty else { return nil }
        return s.project(id) ?? Project(id: id, name: "?", rootPath: "", lastActivityAt: .distantPast)
    }
    public struct ProjectMatch: Sendable {
        public var project: Project; public var exact: Bool; public var unique: Bool
    }
    public struct ProjectSummary: Sendable {
        public var strands: Int; public var tasks: Int; public var wait: Bool; public var due: Entry?; public var dueState: String?; public var last: Date?; public var empty: Bool
    }
    public static func sessionsOf(_ s: Snapshot, _ e: Entry) -> [Session] { s.sessions(of: e.id) }
    public static func isStrang(_ s: Snapshot, _ e: Entry) -> Bool { s.sessions.contains { $0.entryId == e.id } }
    public static func latest(_ s: Snapshot, _ e: Entry) -> Session? { sessionsOf(s, e).first }
    public static func running(_ s: Session?) -> Bool { s?.live.running ?? false }
    public static func entryRunning(_ s: Snapshot, _ e: Entry) -> Bool { sessionsOf(s, e).contains { running($0) } }
    private static func hasTitle(_ e: Entry) -> Bool { !(e.title ?? "").isEmpty }
    public static func titleOf(_ s: Snapshot, _ e: Entry) -> String { hasTitle(e) ? e.title! : (latest(s, e)?.suggestedTitle ?? "") }
    public static func lastActivity(_ s: Snapshot, _ e: Entry) -> Date { latest(s, e)?.lastActivityAt ?? e.createdAt }
    public static func isOpen(_ e: Entry) -> Bool { e.status != .erledigt }
    private static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private static func day(_ s: Snapshot) -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: s.now)
        return utc.date(from: parts)!
    }
    private static func date(_ value: String) -> Date? {
        let p = value.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    private static func ymd(_ d: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func dayDiff(_ s: Snapshot, _ value: String) -> Int { Int(((date(value) ?? day(s)).timeIntervalSince(day(s)) / 86400).rounded()) }
    public static func dueState(_ s: Snapshot, _ e: Entry) -> String? {
        guard let d = e.deadline, !d.isEmpty, isOpen(e) else { return nil }
        let k = dayDiff(s, d); return k < 0 ? "overdue" : k <= 2 ? "soon" : "later"
    }
    public enum MenuBarIcon: Sendable, Equatable { case overdue, news, plain }
    public static func menuBarIcon(_ snap: Snapshot) -> MenuBarIcon {
        if snap.entries.contains(where: { $0.archivedAt == nil && dueState(snap, $0) == "overdue" }) { return .overdue }
        return !snap.justEnded.isEmpty || !snap.changes.isEmpty ? .news : .plain
    }
    public static func urgent(_ s: Snapshot, _ e: Entry) -> Bool { ["overdue", "soon"].contains(dueState(s, e) ?? "") }
    private static let germanDeadlineWords = ["heute", "morgen", "übermorgen", "so", "mo", "di", "mi", "do", "fr", "sa", "sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag"]
    private static let englishDeadlineWords = ["today", "tomorrow", "sun", "mon", "tue", "wed", "thu", "fri", "sat", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    public static func parseDeadline(_ s: Snapshot, _ word: String) -> String? {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), base = day(s)
        let offsets = ["heute": 0, "morgen": 1, "übermorgen": 2, "today": 0, "tomorrow": 1]
        if let n = offsets[w] { return ymd(base.addingTimeInterval(Double(n) * 86400)) }
        let short = ["so", "mo", "di", "mi", "do", "fr", "sa"], full = ["sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag"]
        let englishShort = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"], englishFull = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let i = short.firstIndex(of: w) ?? full.firstIndex(of: w) ?? englishShort.firstIndex(of: w) ?? englishFull.firstIndex(of: w) {
            let weekday = utc.component(.weekday, from: base) - 1
            return ymd(base.addingTimeInterval(Double((i - weekday + 7) % 7) * 86400))
        }
        if let match = w.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/), let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) {
            guard year > 0, let candidate = utc.date(from: DateComponents(year: year, month: month, day: day)),
                  utc.component(.year, from: candidate) == year, utc.component(.month, from: candidate) == month, utc.component(.day, from: candidate) == day else { return nil }
            return ymd(candidate)
        }
        // Deliberate deviation from logic.js: accept two-digit years as 2000–2099.
        guard let match = w.wholeMatch(of: /([0-9]{1,2})\.([0-9]{1,2})(?:\.([0-9]{2})|\.?([0-9]{4})|\.)?/), let d = Int(match.1), let m = Int(match.2) else { return nil }
        let year = match.3.flatMap { Int($0).map { 2000 + $0 } } ?? match.4.flatMap { Int($0) } ?? utc.component(.year, from: base)
        guard var candidate = utc.date(from: DateComponents(year: year, month: m, day: d)) else { return nil }
        if match.3 == nil && match.4 == nil && candidate < base { candidate = utc.date(from: DateComponents(year: year + 1, month: m, day: d))! }
        guard utc.component(.day, from: candidate) == d && utc.component(.month, from: candidate) == m else { return nil }
        return ymd(candidate)
    }
    public static func deadlineAfter(prefix: String, word: String, _ s: Snapshot) -> String? {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch prefix.lowercased() {
        case "bis": if englishDeadlineWords.contains(w) { return nil }
        case "by": if germanDeadlineWords.contains(w) { return nil }
        default: return nil
        }
        return parseDeadline(s, w)
    }
    public static func hasTrailingDeadline(_ s: Snapshot, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }
        return deadlineAfter(prefix: String(words[words.count - 2]), word: String(words[words.count - 1]), s) != nil
    }
    public static func dayLabel(day: Int, month: Int, language: AppLanguage = .current) -> String {
        if language == .de { return String(format: "%02d.%02d", day, month) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard (1...12).contains(month) else { return "" }
        return "\(months[month - 1]) \(day)"
    }
    public static func dueInput(_ value: String) -> String { dueInput(value, language: .current) }
    public static func dueInput(_ value: String, language: AppLanguage) -> String {
        let p = value.split(separator: "-")
        guard p.count == 3 else { return "" }
        return language == .en ? value : "\(p[2]).\(p[1])"
    }
    public static func dueShort(_ s: Snapshot, _ value: String, translate: (String) -> String = { t($0) }, language: AppLanguage = .current) -> String {
        let k = dayDiff(s, value)
        if k == -1 { return translate("due.yesterday") }; if k == 0 { return translate("due.today") }; if k == 1 { return translate("due.tomorrow") }
        if k > 1 && k < 7, let d = date(value) { return translate("time.weekday.\(utc.component(.weekday, from: d) - 1)") }
        guard let d = date(value) else { return "" }
        return dayLabel(day: utc.component(.day, from: d), month: utc.component(.month, from: d), language: language)
    }
    public static func dueLong(_ s: Snapshot, _ value: String, translate: (String) -> String = { t($0) }, language: AppLanguage = .current) -> String {
        guard let d = date(value) else { return "" }
        let label = dayLabel(day: utc.component(.day, from: d), month: utc.component(.month, from: d), language: language)
        return translate("time.weekday.\(utc.component(.weekday, from: d) - 1)") + " " + label + (language == .de ? "." : "")
    }
    public static func isArchived(_ s: Snapshot, _ e: Entry) -> Bool {
        if e.archivedAt != nil { return true }
        return isStrang(s, e) && !entryRunning(s, e) && s.now.timeIntervalSince(lastActivity(s, e)) > Double(s.settings.archiveDays) * 86400 && (e.status == .erledigt || !hasTitle(e))
    }
    public static func tier(_ s: Snapshot, _ e: Entry) -> Int {
        if urgent(s, e) { return 0 }; if e.status == .erledigt { return 5 }; if hasTitle(e) && e.status == .wartet { return 1 }; if hasTitle(e) { return 2 }; return entryRunning(s, e) ? 3 : 4
    }
    public static func sortStrands(_ s: Snapshot, _ list: [Entry], _ here: String?) -> [Entry] {
        list.enumerated().sorted { a, b in
            let x = a.element, y = b.element, tx = tier(s, x), ty = tier(s, y)
            if (tx == 0) != (ty == 0) { return tx == 0 }
            if let here, (x.projectId == here) != (y.projectId == here) { return x.projectId == here }
            if tx != ty { return tx < ty }
            let dx = lastActivity(s, x), dy = lastActivity(s, y); return dx != dy ? dx > dy : a.offset < b.offset
        }.map(\.element)
    }
    public static func sortTasks(_ s: Snapshot, _ list: [Entry]) -> [Entry] {
        list.enumerated().sorted { a, b in
            let x = a.element, y = b.element, dx = x.deadline.flatMap { $0.isEmpty ? nil : $0 } ?? "9999", dy = y.deadline.flatMap { $0.isEmpty ? nil : $0 } ?? "9999"
            if dx != dy { return dx < dy }; if (x.projectId == nil) != (y.projectId == nil) { return x.projectId != nil }
            return x.createdAt != y.createdAt ? x.createdAt > y.createdAt : a.offset < b.offset
        }.map(\.element)
    }
    public static func urgentTasks(_ s: Snapshot) -> [Entry] { sortTasks(s, s.entries.filter { !isStrang(s, $0) && $0.archivedAt == nil && urgent(s, $0) }) }
    public static func projectSummary(_ s: Snapshot, _ id: String?) -> ProjectSummary {
        let es = s.entries.filter { $0.projectId == id && !isArchived(s, $0) && (isStrang(s, $0) || isOpen($0)) }, strands = es.filter { isStrang(s, $0) }
        let due = es.filter { urgent(s, $0) }.sorted { ($0.deadline ?? "") < ($1.deadline ?? "") }.first
        return ProjectSummary(strands: strands.count, tasks: es.count - strands.count, wait: strands.contains { $0.status == .wartet }, due: due, dueState: due.flatMap { dueState(s, $0) }, last: es.map { lastActivity(s, $0) }.max(), empty: es.isEmpty)
    }
    public static func projectList(_ s: Snapshot, _ here: String?) -> [String?] {
        let ids: [String?] = s.projects.map { $0.id } + [nil]
        func rank(_ x: ProjectSummary) -> Int { x.dueState == "overdue" ? 0 : x.dueState == "soon" ? 1 : x.wait ? 2 : 3 }
        return ids.enumerated().map { (index: $0.offset, id: $0.element, summary: projectSummary(s, $0.element)) }.filter { !$0.summary.empty || ($0.id != nil && $0.id == here) }.sorted { a, b in
            if (a.id == nil) != (b.id == nil) { return a.id != nil }
            if (a.id == here) != (b.id == here) { return a.id == here }
            if rank(a.summary) != rank(b.summary) { return rank(a.summary) < rank(b.summary) }
            let x = a.summary.last ?? .distantPast, y = b.summary.last ?? .distantPast; return x != y ? x > y : a.index < b.index
        }.map(\.id)
    }
    public static func resolveProject(_ s: Snapshot, _ fragment: String) -> ProjectMatch? {
        let f = fragment.lowercased(); guard !f.isEmpty else { return nil }
        if let p = s.projects.first(where: { $0.name.lowercased() == f }) { return ProjectMatch(project: p, exact: true, unique: true) }
        let matches = s.projects.filter { $0.name.lowercased().hasPrefix(f) }; return matches.first.map { ProjectMatch(project: $0, exact: false, unique: matches.count == 1) }
    }
    public static func ghostProject(_ s: Snapshot, _ fragment: String) -> String { guard let m = resolveProject(s, fragment), !m.exact else { return "" }; return String(m.project.name.dropFirst(fragment.count)) }
    public static func ghostFor(_ s: Snapshot, _ query: String) -> String {
        guard query.last?.isWhitespace == false, let word = query.split(whereSeparator: \.isWhitespace).last, word.first == "@", word.count > 1 else { return "" }; return ghostProject(s, String(word.dropFirst()))
    }
    public static func chipFor(_ s: Snapshot, _ word: String, _ mode: String) -> Filter? {
        if mode == "resume" {
            switch word { case "cc": return Filter(kind: "tool", value: "claude", label: "cc"); case "cx": return Filter(kind: "tool", value: "codex", label: "cx"); case "?": return Filter(kind: "status", value: "wartet", label: t("filter.waiting")); case "!": return Filter(kind: "status", value: "erledigt", label: t("filter.done")); case "/a": return Filter(kind: "archive", value: "true", label: t("filter.archive")); default: break }
        }
        guard word.hasPrefix("@"), word.count > 1, let m = resolveProject(s, String(word.dropFirst())), m.unique else { return nil }; return Filter(kind: "project", value: m.project.id, label: "@" + m.project.name)
    }
    private static func subseq(_ name: String, _ word: String) -> Bool {
        var rest = word[...]; for ch in name where !rest.isEmpty { if ch == rest.first { rest = rest.dropFirst() } }; return rest.isEmpty
    }
    public static func matchesWord(_ s: Snapshot, _ e: Entry, _ word: String) -> Bool {
        let w = word.lowercased(), name = e.projectId.map { s.project($0)?.name ?? "?" }?.lowercased() ?? ""
        let hay = ([titleOf(s, e), name] + sessionsOf(s, e).flatMap { [$0.firstPrompt, $0.nativeId, $0.cwd] }).joined(separator: " ").lowercased()
        return hay.contains(w) || (!name.isEmpty && subseq(name, w))
    }
    public static func similar(_ s: Snapshot, _ text: String) -> [Entry] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzäöüß0123456789")
        let words = text.lowercased().components(separatedBy: allowed.inverted).filter { $0.count >= 4 }
        return s.entries.enumerated().map { pair in (index: pair.offset, e: pair.element, n: words.filter { titleOf(s, pair.element).lowercased().contains($0) }.count) }.filter { $0.n > 0 && isOpen($0.e) && !isArchived(s, $0.e) }.sorted { a, b in
            if a.n != b.n { return a.n > b.n }; let x = lastActivity(s, a.e), y = lastActivity(s, b.e); return x != y ? x > y : a.index < b.index
        }.prefix(3).map(\.e)
    }
    public static func buildView(_ s: Snapshot, _ ui: UI) -> View {
        let words = ui.query.split(whereSeparator: \.isWhitespace).map(String.init), filters = Dictionary(ui.chips.map { ($0.kind, $0.value) }, uniquingKeysWith: { _, last in last })
        let here = s.context?.projectId
        var rows: [Row] = []
        func push(_ e: Entry) {
            rows.append(Row("entry", e.id, false, key: "e:" + e.id))
            if ui.openEntries.contains(e.id) && isStrang(s, e) {
                rows += sessionsOf(s, e).map { Row("session", $0.id, false, key: "s:" + $0.id, entryId: e.id) }
            }
        }
        let searching = !words.isEmpty || !ui.chips.filter { $0.kind != "deadline" }.isEmpty
        let similarIDs = Set(similar(s, ui.query).map(\.id))
        func matchingEntries(_ id: String?) -> [Entry] {
            if let project = filters["project"], id != project { return [] }
            return s.entries.filter { e in
                guard e.projectId == id, isStrang(s, e) || isOpen(e) else { return false }
                let archived = isArchived(s, e)
                if filters["archive"] == "true" ? !archived : (archived && (words.isEmpty || ui.mode == "ziel")) { return false }
                if let tool = filters["tool"], !sessionsOf(s, e).contains(where: { $0.tool.rawValue == tool }) { return false }
                if let status = filters["status"], e.status.rawValue != status { return false }
                if words.isEmpty { return true }
                return ui.mode == "ziel" ? similarIDs.contains(e.id) : words.allSatisfy { matchesWord(s, e, $0) }
            }
        }
        var projectIDs = projectList(s, here)
        if searching || filters["archive"] == "true" {
            let known = Set(projectIDs)
            let candidates: [String?] = s.projects.map { $0.id } + [nil]
            let additional = candidates.enumerated().compactMap { index, id -> (Int, String?, Date)? in
                guard !known.contains(id), let last = matchingEntries(id).map({ lastActivity(s, $0) }).max() else { return nil }
                return (index, id, last)
            }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            projectIDs += additional.map { $0.1 }
        }
        for id in projectIDs {
            if let project = filters["project"], id != project { continue }
            let entries = matchingEntries(id)
            if searching && entries.isEmpty { continue }
            let projectKey = id ?? "_none"
            let open = searching ? !(ui.closedSearchProjects ?? []).contains(projectKey) : ui.openProjects.contains(projectKey)
            rows.append(Row("proj", id, key: "p:" + (id ?? "_none"), open: open))
            if open {
                let sorted = sortStrands(s, entries, nil)
                for e in sorted.filter({ !isArchived(s, $0) }) + sorted.filter({ isArchived(s, $0) }) { push(e) }
            }
        }
        let keys = rows.compactMap(\.key)
        return View(rows: rows, keys: keys, searching: searching, filters: filters, words: words, here: here)
    }
    private static func ago(_ s: Snapshot, _ date: Date, long: Bool, language: AppLanguage) -> String {
        let delta = s.now.timeIntervalSince(date), prefix = long ? "time.long." : "time.short."
        if delta < 60 { return t(prefix + "now") }
        if delta < 3600 { return t(prefix + "min", ["n": Int((delta / 60).rounded())]) }
        if delta < 86400 { return t(prefix + "hour", ["n": Int((delta / 3600).rounded())]) }
        let c = Calendar.current.dateComponents([.weekday, .day, .month, .hour, .minute], from: date)
        let day = dayLabel(day: c.day!, month: c.month!, language: language), hm = String(format: "%02d:%02d", c.hour!, c.minute!)
        if delta < 6 * 86400 { return t("time.weekday.\(c.weekday! - 1)") + (long ? " " + hm : "") }
        return day + (long ? (language == .de ? ". " : " ") + hm : "")
    }
    public static func agoShort(_ s: Snapshot, _ date: Date, language: AppLanguage = .current) -> String { ago(s, date, long: false, language: language) }
    public static func agoLong(_ s: Snapshot, _ date: Date, language: AppLanguage = .current) -> String { ago(s, date, long: true, language: language) }
    public static func command(_ session: Session, _ s: Snapshot) -> String { s.settings.commands[session.tool].replacingOccurrences(of: "{id}", with: session.nativeId) }
    public static func newCommand(_ s: Snapshot, _ tool: Tool, _ prompt: String) -> String { s.settings.newCommands[tool] + " \"" + prompt + "\"" }
    public static func tokensM(_ n: Int) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: AppLanguage.current == .de ? "de_DE" : "en_US"); f.maximumFractionDigits = 1; f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: Double(n) / 1_000_000)) ?? "0"
    }
}
