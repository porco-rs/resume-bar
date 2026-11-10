import Foundation
import Testing
import RBContract
import RBUI
@testable import RBEngine

private struct Scenario: Decodable, Sendable, CustomStringConvertible {
    struct Followup: Decodable, Sendable { let schritte: [String]; let erwartet: JSONValue }
    let danach: Followup?
    let id: String
    let start: String
    let schritte: [String]
    let erwartet: JSONValue
    var description: String { id }
}
private struct ScenarioFile: Decodable { let szenarien: [Scenario] }
private enum JSONValue: Decodable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}
private let scenarioRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scenarioKeys: Set<String> = ["↓", "↑", "←", "→", "↵", "⇧↵", "⌥↵", "⌘↵", "⇥", "esc", "⌫", "⌘⌫", "⌘C", "⌘P", "⌘D", "⌘G", "⌘S", "⌘Z", "⌘⇧W", "⌘/", "⌘↓", "⌘↑"]
private let scenarios: [Scenario] = {
    let url = scenarioRoot.appendingPathComponent("Tests/Fixtures/scenarios/szenarien.json")
    return (try? JSONDecoder().decode(ScenarioFile.self, from: Data(contentsOf: url)).szenarien) ?? []
}()

private func expand(_ steps: [String]) -> [String] {
    steps.flatMap { step -> [String] in
        let parts = step.components(separatedBy: "×")
        guard parts.count == 2, scenarioKeys.contains(parts[0]), let count = Int(parts[1]), count >= 0 else { return [step] }
        return Array(repeating: parts[0], count: count)
    }
}

private func input(_ step: String, state: UIState) -> RawInput {
    if step == "⇧⌘Space" { return .action("toggleMode", arg: nil) }
    let mapping: [String: String] = ["↓": "ArrowDown", "↑": "ArrowUp", "←": "ArrowLeft", "→": "ArrowRight", "↵": "Enter", "⇥": "Tab", "esc": "Escape", "⌫": "Backspace", "C": "c", "P": "p", "D": "d", "G": "g", "S": "s", "Z": "z", "W": "w", "/": "/"]
    if scenarioKeys.contains(step) {
        if step == "⌫" && state.mode == .edit { return .text(field: "e", value: String(state.editText.dropLast())) }
        if step == "⌫" && !state.query.isEmpty { return .text(field: "q", value: String(state.query.dropLast())) }
        let base = step == "esc" ? step : String(step.last!)
        let field = state.screen == .m01s1 ? "p" : state.mode == .edit ? "e" : "q"
        return .key(KeyPress(key: mapping[base] ?? base, meta: step.contains("⌘"), alt: step.contains("⌥"), shift: step.contains("⇧"), field: field, fieldEmpty: state.query.isEmpty))
    }
    if state.screen == .m01s1 { return .text(field: "p", value: (state.selectAll ? "" : state.panel?.text ?? "") + step) }
    if state.mode == .edit { return .text(field: "e", value: (state.selectAll ? "" : state.editText) + step) }
    if state.focus == .banner { return .text(field: "b", value: state.bannerText + step) }
    return .text(field: "q", value: state.query + step)
}

@Test private func scenarioCatalogueIsComplete() {
    #expect(scenarios.count >= 63)
    #expect(Set(scenarios.map(\.id)).count == scenarios.count)
    #expect(Set(scenarioPending.keys).isSubset(of: Set(scenarios.map(\.id))))
}

@MainActor
@Test(arguments: scenarios) private func designScenario(_ scenario: Scenario) async throws {
    let url = scenario.start == "Trainer.uebung" ? scenarioRoot.appendingPathComponent("ui/trainer/uebung.json") : scenario.start == "M01.mehrdeutig" ? scenarioRoot.appendingPathComponent("Tests/Fixtures/scenarios/mehrdeutig.json") : scenarioRoot.appendingPathComponent("Tests/Fixtures/design/fixtures/\(scenario.start.lowercased()).json")
    let fixture = try FixtureServices(fixture: url)
    let engine = Engine(services: fixture.services, clock: { fixture.snapshot.now })
    await engine.start()
    _ = engine.popoverWillOpen(context: fixture.snapshot.context)
    _ = try engine.replayFixture(data: Data(contentsOf: url), snapshot: fixture.snapshot)
    let before = engine.snapshot
    engine.beginScenarioTrace()
    for step in expand(scenario.schritte) {
        _ = engine.handle(input(step, state: engine.state))
        await engine.waitForScenarioEffects()
    }
    var differences = scenarioDifferences(engine: engine, before: before, expected: scenario.erwartet)
    if differences.isEmpty {
        let dead = deadHints(engine)
        if !dead.isEmpty { differences.append("tote Hinweise: \(dead)") }
    }
    if let followup = scenario.danach {
        for step in expand(followup.schritte) {
            _ = engine.handle(input(step, state: engine.state))
            await engine.waitForScenarioEffects()
        }
        differences += scenarioDifferences(engine: engine, before: before, expected: followup.erwartet)
    }
    if let pending = scenarioPending[scenario.id] {
        #expect(!differences.isEmpty, "\(scenario.id) is pending but now passes: \(pending)")
        let parts = pending.components(separatedBy: " · ")
        #expect(parts.count == 2 && differences.contains { $0.hasPrefix(parts[1] + ":") }, "\(scenario.id): pending field no longer differs: \(pending); differences: \(differences)")
    } else {
        #expect(differences.isEmpty, "\(scenario.id): \(differences.joined(separator: ", "))")
    }
}

private func value(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
private func number(_ n: Int) -> JSONValue { .number(Double(n)) }
private func date(_ d: Date?) -> JSONValue {
    guard let d else { return .null }
    return .string(ISO8601DateFormatter().string(from: d))
}
private func entryDiff(_ before: Snapshot, _ after: Snapshot) -> JSONValue {
    var out: [JSONValue] = []
    for e in after.entries {
        let count = after.sessions.filter { $0.entryId == e.id }.count
        guard let old = before.entries.first(where: { $0.id == e.id }) else {
            out.append(.object(["neu": .string("new"), "title": value(e.title), "projectId": value(e.projectId), "deadline": value(e.deadline), "sessions": number(count)])); continue
        }
        var fields: [String: JSONValue] = [:]
        func changed(_ key: String, _ a: JSONValue, _ b: JSONValue) { if a != b { fields[key] = .array([a, b]) } }
        changed("title", value(old.title), value(e.title))
        changed("status", .string(old.status.rawValue), .string(e.status.rawValue))
        changed("projectId", value(old.projectId), value(e.projectId))
        changed("deadline", value(old.deadline), value(e.deadline))
        changed("archivedAt", date(old.archivedAt), date(e.archivedAt))
        changed("sessions", number(before.sessions.filter { $0.entryId == e.id }.count), number(count))
        if !fields.isEmpty {
            fields["id"] = .string(e.id)
            if fields["title"] == nil { fields["title"] = .string(Logic.titleOf(after, e)) }
            out.append(.object(fields))
        }
    }
    for e in before.entries where !after.entries.contains(where: { $0.id == e.id }) {
        out.append(.object(["entfernt": .string(e.id), "title": value(e.title)]))
    }
    if before.windows != after.windows {
        out.append(.object(["fenster": .array([.string("\(before.windows.open)/\(before.windows.closable)"), .string("\(after.windows.open)/\(after.windows.closable)")])]))
    }
    if before.changes.count != after.changes.count {
        out.append(.object(["seitZuletzt": .array([number(before.changes.count), number(after.changes.count)])]))
    }
    return .array(out)
}
private func bridge(_ trace: [(Intent, IntentResult?)], snapshot: Snapshot, screen: Screen) -> JSONValue {
    .array(trace.map { intent, result in
        var x: [String: JSONValue] = [:]
        func set(_ msg: String) { x["msg"] = .string(msg) }
        switch intent {
        case let .addTask(title, project, deadline, start):
            set("entry.add"); x["title"] = value(title); x["projectId"] = value(project); x["deadline"] = value(deadline); x["start"] = value(start?.rawValue)
        case let .setProject(id, project): set("entry.setProject"); x["entryId"] = value(id); x["projectId"] = value(project)
        case let .setDeadline(id, deadline): set("entry.setDeadline"); x["entryId"] = value(id); x["deadline"] = value(deadline)
        case let .archiveEntry(id): set("entry.archive"); x["entryId"] = value(id)
        case let .startEntry(id, tool, _): set("entry.start"); x["entryId"] = value(id); x["tool"] = value(tool.rawValue)
        case let .startGoal(id, tool, _): set("entry.startGoal"); x["entryId"] = value(id); x["tool"] = value(tool.rawValue)
        case let .setTitle(id, title): set("entry.setTitle"); x["entryId"] = value(id); x["title"] = value(title)
        case let .resumeEntry(id, session, terminal):
            set("entry.resume"); x["entryId"] = value(id)
            switch result {
            case let .opened(app, sid): x["sessionId"] = value(sid ?? session); x["terminal"] = value(app.rawValue); x["result"] = value("opened")
            case let .focused(_, sid): x["sessionId"] = value(sid); x["result"] = value("focused")
            case let .notResumable(sid, _): x["sessionId"] = value(sid); x["result"] = value("not_resumable")
            default: x["sessionId"] = value(session); x["terminal"] = value(terminal?.rawValue)
            }
        case let .newStrang(title, project, tool, _): set("entry.newStrang"); x["title"] = value(title); x["projectId"] = value(project); x["tool"] = value(tool.rawValue)
        case let .cycleStatus(id):
            set("entry.cycleStatus"); x["entryId"] = value(id)
            if case let .entryStatusSet(_, from, to) = result { x["from"] = value(from.rawValue); x["to"] = value(to.rawValue) }
        case let .nameJustEnded(id, title): set("justEnded.name"); x["entryId"] = value(id); x["title"] = value(title)
        case .dismissJustEnded: set("justEnded.dismiss")
        case .acceptChanges: set("changes.accept")
        case let .revertChange(id): set("changes.revert"); x["changeId"] = value(id); x["entryId"] = value(snapshot.changes.first { $0.id == id }?.entryId)
        case let .copyCommand(id): set("clipboard.copyCommand"); x["sessionId"] = value(id)
        case .undo:
            set("undo"); if screen != .m01s1, case let .undone(label) = result { x["label"] = value(label) }
        case let .panelName(id, title): set("panel.name"); x["sessionId"] = value(id); x["title"] = value(title)
        case .cleanupWindows: set("windows.cleanup")
        case .closePopover: set(screen == .m01s1 ? "panel.close" : "popover.close")
        default: set("unmapped: \(intent)")
        }
        return .object(x)
    })
}
@MainActor private func hints(_ engine: Engine) -> [String] {
    let html = Renderer.render(engine.state, engine.snapshot).fullHTML
    let pattern = #"<button type="button" data-act="[^"]*" aria-label="[^"]*"><b>([^<]*)</b> ([^<]*)</button>"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(html.startIndex..., in: html)
    return regex.matches(in: html, range: range).compactMap { m in
        guard let a = Range(m.range(at: 1), in: html), let b = Range(m.range(at: 2), in: html) else { return nil }
        return String(html[a]) + " " + String(html[b])
    }
}
@MainActor private func deadHints(_ engine: Engine) -> [String] {
    hints(engine).filter { hint in
        let first = String(hint.split(separator: " ").first ?? "")
        let keys = first == "←" ? ["←", "→"] : [first]
        return !keys.contains { key in
            guard scenarioKeys.contains(key) else { return true }
            var state = engine.state
            state.toast = nil
            let before = state
            let events = KeyMap.events(for: input(key, state: state), state: state)
            let intents = events.flatMap { Reducer.reduce(&state, $0, engine.snapshot) }
            return state != before || !intents.isEmpty
        }
    }
}
private func normalize(_ v: JSONValue, key: String = "") -> JSONValue {
    switch v {
    case let .object(o): return .object(o.mapValues { normalize($0) }.merging(o["neu"].map { _ in ["neu": .string("new")] } ?? [:]) { _, b in b })
    case let .array(a): return .array(a.map { normalize($0) })
    case let .string(s):
        if s.contains("T"), let d = ISO8601DateFormatter().date(from: s) { return date(d) }
        return v
    default: return v
    }
}
@MainActor private func scenarioDifferences(engine: Engine, before: Snapshot, expected: JSONValue) -> [String] {
    guard case let .object(exp) = expected else { return ["erwartet"] }
    let s = engine.state, snap = engine.snapshot
    let ui = Logic.UI(mode: s.filterMode.rawValue, chips: s.chips.map { .init(kind: $0.kind.rawValue, value: $0.value, label: $0.label) }, query: s.query, openEntries: s.openEntries, openProjects: s.openProjects, contextDismissed: s.contextDismissed, closedSearchProjects: s.closedSearchProjects)
    let rows = Logic.buildView(snap, ui).rows
    let row = rows.first { $0.key == s.selectedId }
    let entry = row?.id.flatMap { snap.entry($0) } ?? s.selectedId.flatMap { id in
        snap.session(id).flatMap { snap.entry($0.entryId) }
    }
    let label: String?
    if row?.type == "proj" { label = "projekt: " + (row?.id.flatMap { snap.project($0)?.name } ?? "ohne Projekt") }
    else if row?.type == "session" { label = row?.id.flatMap { snap.session($0) }.map { "session: " + ($0.suggestedTitle.isEmpty ? $0.firstPrompt : $0.suggestedTitle) } }
    else { label = entry.map { (Logic.isStrang(snap, $0) ? "strang: " : "ziel: ") + Logic.titleOf(snap, $0) } }
    var actual: [String: JSONValue] = ["screen": value(s.screen.rawValue), "modus": value(s.listMode.rawValue), "fokus": value(s.focus.rawValue), "eingabe": value(s.query), "chips": .array(s.chips.map { value($0.label) }), "markiert": value(label), "bearbeitung": s.mode == .edit ? .object(["art": value(s.editKind.rawValue), "text": value(s.editText)]) : .null, "hilfe": .bool(s.help), "meldung": value(s.toast?.text), "daten": entryDiff(before, snap), "hinweise": .array(hints(engine).map(JSONValue.string)), "bridge": bridge(engine.scenarioTrace, snapshot: before, screen: s.screen)]
    let html = Renderer.render(s, snap).fullHTML
    let contextPattern = #"<span class="chip soft"[^>]*>@([^<]*)</span>"#
    let contextMatch = try! NSRegularExpression(pattern: contextPattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
    actual["kontext"] = value(contextMatch.flatMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } })
    let buttonPattern = #"<button type="button" data-act="(?:startWith|toggleGoal)"[^>]*>([^<]*)</button>"#
    let buttonRegex = try! NSRegularExpression(pattern: buttonPattern)
    actual["startknoepfe"] = .array(buttonRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in Range(match.range(at: 1), in: html).map { .string(String(html[$0])) } })
    let duePattern = #"<div class="winhint (?:soon|overdue)"><span>([^<]*)</span><button type="button" data-act="showDue">"#
    let dueMatch = try! NSRegularExpression(pattern: duePattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
    actual["faelligkeitshinweis"] = value(dueMatch.flatMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } })
    actual["zeilen"] = .array(rows.compactMap { row in
        if row.type == "proj" { return .string("projekt: " + (row.id.flatMap { snap.project($0)?.name } ?? "ohne Projekt")) }
        if row.type == "entry", let id = row.id, let e = snap.entry(id) { return .string((Logic.isStrang(snap, e) ? "strang: " : "ziel: ") + Logic.titleOf(snap, e)) }
        if row.type == "session", let id = row.id, let session = snap.session(id) { return .string("session: " + (session.suggestedTitle.isEmpty ? session.firstPrompt : session.suggestedTitle)) }
        return nil
    })
    if s.screen == .m01s1 { actual["panel"] = .object(["text": value(s.panel?.text), "gespeichert": .bool(s.panel?.done ?? false)]) }
    return exp.keys.sorted().compactMap { key in
        guard let a = actual[key], let e = exp[key], normalize(a) == normalize(e) else { return "\(key): got \(String(describing: actual[key])), expected \(String(describing: exp[key]))" }
        return nil
    }
}
