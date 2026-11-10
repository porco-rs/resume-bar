import Foundation
import Testing
import RBContract
@testable import RBUI

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func taskFixture(_ state: String) throws -> Snapshot {
    try RBJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/design/fixtures/m01.\(state).json")))
}
@Test func taskModeOnlySwitchesWithEmptyUneditedField() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    state.chips = [Chip(kind: .project, value: "p", label: "@p"), Chip(kind: .tool, value: "claude", label: "cc")]
    state.query = "text"
    #expect(KeyMap.events(for: .key(KeyPress(key: "ArrowRight", fieldEmpty: false)), state: state).isEmpty)
    _ = Reducer.reduce(&state, .modeNext, v2)
    #expect(state.listMode == .resume)
    state.query = ""; state.mode = .edit
    _ = Reducer.reduce(&state, .modeNext, v2)
    #expect(state.listMode == .resume)
    state.mode = .list
    #expect(KeyMap.events(for: .key(KeyPress(key: "ArrowRight")), state: state) == [.modeNext])
    _ = Reducer.reduce(&state, .modeNext, v2)
    #expect(state.listMode == .ziel)
    #expect(state.chips.map(\.kind) == [.project, .tool])
    _ = Reducer.reduce(&state, .modeNext, v2)
    #expect(state.listMode == .resume)
}

@Test func footerExplainsSymbols() throws {
    let v2 = try taskFixture("aufgabe")
    let symbols = "<div class=\"symbols\" aria-hidden=\"true\">◇ offen · ● begonnen · ◐ wartet · ○ erledigt</div>"
    var state = UIState()
    for mode in [UIState.ListMode.resume, .ziel] {
        state.listMode = mode
        for editing in [false, true] {
            state.mode = editing ? .edit : .list
            let footer = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
            #expect(footer.hasSuffix(symbols))
        }
        state.help = true
        let helpFooter = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
        #expect(helpFooter.hasSuffix(symbols))
        state.help = false
    }
    var empty = v2
    empty.entries = []
    #expect(!Renderer.render(state, empty).fullHTML.contains(symbols))
    state.help = true
    #expect(!Renderer.render(state, empty).fullHTML.contains(symbols))
}

@Test func taskRowsFollowV2OrderAndEmptyState() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    let before = Logic.buildView(v2, .init(openProjects: state.openProjects)).rows
    _ = Reducer.reduce(&state, .modeNext, v2)
    let after = Logic.buildView(v2, .init(mode: "ziel", openProjects: state.openProjects)).rows
    #expect(before == after)
    #expect(before.first?.id == v2.context?.projectId)
    #expect(before.first?.open == true)
    #expect(state.selectedId == before.first { $0.type == "entry" }?.key)
    #expect(Renderer.render(state, v2).fullHTML.contains("ziel ›"))
}

@Test func taskTypingCreatesWithContextAndDeadline() throws {
    let v2 = try taskFixture("aufgabe-neu")
    var state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("Preisliste Scanner bis fr "), v2)
    let date = try #require(Logic.parseDeadline(v2, "fr"))
    #expect(state.query == "Preisliste Scanner ")
    #expect(state.chips.first(where: { $0.kind == .deadline })?.value == date)
    #expect(state.selectedId == nil)
    #expect(Renderer.render(state, v2).fullHTML.contains("data-sel=\"p:prj_parkway-portal\""))
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Preisliste Scanner", projectId: v2.context?.projectId, deadline: date, start: nil)])
    #expect(KeyMap.events(for: .key(KeyPress(key: "Enter", meta: true)), state: state) == [.cmdEnter])
    #expect(Reducer.reduce(&state, .cmdEnter, v2) == [.addTask(title: "Preisliste Scanner", projectId: v2.context?.projectId, deadline: date, start: .codex)])
}

@Test func chipifyAcceptsByWithEnglishWord() throws {
    let snapshot = try taskFixture("aufgabe-neu")
    for suffix in ["by fri ", "by fri"] {
        var state = UIState(); state.listMode = .ziel
        _ = Reducer.reduce(&state, .setQuery("Blumen " + suffix), snapshot)
        let date = try #require(Logic.parseDeadline(snapshot, "fri"))
        #expect(Reducer.reduce(&state, .enter, snapshot) == [.addTask(title: "Blumen", projectId: snapshot.context?.projectId, deadline: date, start: nil)])
    }
}

@Test func chipifyLeavesByWithGermanWord() throws {
    let snapshot = try taskFixture("aufgabe-neu")
    var state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("Stop by so "), snapshot)
    #expect(state.query == "Stop by so ")
    #expect(!state.chips.contains { $0.kind == .deadline })
    #expect(Reducer.reduce(&state, .enter, snapshot) == [.addTask(title: "Stop by so", projectId: snapshot.context?.projectId, deadline: nil, start: nil)])
}

@Test func taskEnterRecognizesTrailingChipsWithoutSpace() throws {
    let v2 = try taskFixture("aufgabe-neu")
    let date = try #require(Logic.parseDeadline(v2, "fr"))
    for event in [UIEvent.enter, .shiftEnter, .altEnter, .cmdEnter, .saveEdit] {
        var state = UIState(); state.listMode = .ziel
        _ = Reducer.reduce(&state, .setQuery("Logs prüfen bis fr"), v2)
        #expect(Reducer.reduce(&state, event, v2) == [.addTask(title: "Logs prüfen", projectId: v2.context?.projectId, deadline: date, start: event == .cmdEnter ? v2.settings.defaultTool : nil)])
        _ = Reducer.reduce(&state, .setQuery("Logs prüfen @par"), v2)
        #expect(Reducer.reduce(&state, event, v2) == [.addTask(title: "Logs prüfen", projectId: "prj_parkway-portal", deadline: date, start: event == .cmdEnter ? v2.settings.defaultTool : nil)])
    }
    var state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("bis fr"), v2)
    state.selectedId = "e:" + (try #require(v2.entries.first?.id))
    #expect(Reducer.reduce(&state, .enter, v2).isEmpty)
    #expect(state.query.isEmpty)
    #expect(state.chips.first { $0.kind == .deadline }?.value == date)
    #expect(state.selectedId != nil)
    _ = Reducer.reduce(&state, .setQuery("Logs prüfen bis xyz"), v2)
    state.chips = []
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Logs prüfen bis xyz", projectId: v2.context?.projectId, deadline: nil, start: nil)])
}

@Test func taskSelectionStartsWithChosenToolWithoutProject() throws {
    let v2 = try taskFixture("aufgabe")
    let entry = try #require(v2.entries.first { $0.projectId != nil && !Logic.isStrang(v2, $0) && Logic.isOpen($0) && $0.archivedAt == nil })
    var state = UIState(); state.listMode = .ziel; state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.startEntry(entryId: entry.id, tool: .codex, terminal: nil)])
    #expect(Reducer.reduce(&state, .shiftEnter, v2) == [.startEntry(entryId: entry.id, tool: .claude, terminal: nil)])
    var noProject = v2
    let i = try #require(noProject.entries.firstIndex { $0.id == entry.id })
    noProject.entries[i].projectId = nil
    state.openProjects.append("_none")
    #expect(Reducer.reduce(&state, .enter, noProject) == [.startEntry(entryId: entry.id, tool: .codex, terminal: nil)])
    #expect(Reducer.reduce(&state, .shiftEnter, noProject) == [.startEntry(entryId: entry.id, tool: .claude, terminal: nil)])
    #expect(Reducer.reduce(&state, .cmdEnter, noProject) == [.startEntry(entryId: entry.id, tool: .codex, terminal: nil)])
    #expect(state.mode == .list)
}

@Test func taskProjectAndDeadlineEditing() throws {
    let v2 = try taskFixture("aufgabe")
    let entry = try #require(v2.entries.first { $0.projectId != nil && !Logic.isStrang(v2, $0) && Logic.isOpen($0) && $0.archivedAt == nil })
    let project = try #require(v2.projects.first { $0.id != entry.projectId })
    var state = UIState(); state.listMode = .ziel; state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    var withoutDeadline = v2
    let entryIndex = try #require(withoutDeadline.entries.firstIndex { $0.id == entry.id })
    withoutDeadline.entries[entryIndex].deadline = nil
    let noDueFooter = try #require(Renderer.render(state, withoutDeadline).regions.first { $0.0 == "footer" }?.1)
    #expect(noDueFooter.contains("keine deadline"))
    #expect(!noDueFooter.contains("↵ Codex"))
    #expect(!noDueFooter.contains("⇧↵ Claude Code"))
    _ = Reducer.reduce(&state, .complete, v2)
    #expect(state.editKind == .project)
    _ = Reducer.reduce(&state, .setEdit(project.name), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.setProject(entryId: entry.id, projectId: project.id)])
    _ = Reducer.reduce(&state, .editDeadline, v2)
    #expect(state.selectAll)
    #expect(Renderer.render(state, v2).focus == "e")
    _ = Reducer.reduce(&state, .setEdit("fr"), v2)
    let date = try #require(Logic.parseDeadline(v2, "fr"))
    #expect(Reducer.reduce(&state, .enter, v2) == [.setDeadline(entryId: entry.id, deadline: date)])
    var withDeadline = v2
    let i = try #require(withDeadline.entries.firstIndex { $0.id == entry.id })
    withDeadline.entries[i].deadline = date
    _ = Reducer.reduce(&state, .editDeadline, withDeadline)
    let dueFooter = try #require(Renderer.render(state, withDeadline).regions.first { $0.0 == "footer" }?.1)
    #expect(dueFooter.contains("bis " + Logic.dueLong(withDeadline, date)))
    #expect(!dueFooter.contains("↵ Codex"))
    #expect(!dueFooter.contains("⇧↵ Claude Code"))
    #expect(state.editText == Logic.dueInput(date))
    _ = Reducer.reduce(&state, .setEdit(""), withDeadline)
    #expect(Reducer.reduce(&state, .enter, withDeadline) == [.setDeadline(entryId: entry.id, deadline: nil)])
}

@Test func taskEditMirrorShowsTextAndGhost() throws {
    let v2 = try taskFixture("aufgabe")
    let entry = try #require(v2.entries.first { !Logic.isStrang(v2, $0) && Logic.isOpen($0) && $0.archivedAt == nil })
    var state = UIState(); state.listMode = .ziel; state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    _ = Reducer.reduce(&state, .editDeadline, v2)
    _ = Reducer.reduce(&state, .setEdit("fr & <"), v2)
    var rendered = Renderer.render(state, v2)
    #expect(rendered.fullHTML.contains("data-region=\"emirror\""))
    #expect(rendered.regions.first { $0.0 == "emirror" }?.1 == "fr &amp; &lt;<span class=\"ghost\"></span>")
    _ = Reducer.reduce(&state, .setEdit(""), v2)
    rendered = Renderer.render(state, v2)
    #expect(rendered.regions.first { $0.0 == "emirror" }?.1.contains(t("m01.edit.deadline_ph")) == true)
    _ = Reducer.reduce(&state, .cancel, v2)
    _ = Reducer.reduce(&state, .complete, v2)
    _ = Reducer.reduce(&state, .setEdit("@par"), v2)
    rendered = Renderer.render(state, v2)
    #expect(rendered.regions.first { $0.0 == "emirror" }?.1 == "@par<span class=\"ghost\">kway-portal</span>")
    _ = Reducer.reduce(&state, .setEdit(""), v2)
    #expect(Renderer.render(state, v2).regions.first { $0.0 == "emirror" }?.1.contains(t("m01.edit.project_ph")) == true)
}

@Test func taskSimilarExcludesArchivedGoals() throws {
    let v2 = try taskFixture("aufgabe-neu")
    var state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("Preisliste Scanner"), v2)
    let html = Renderer.render(state, v2).fullHTML
    #expect(!html.contains("data-sel=\"e:e_s8\""))
    #expect(state.selectedId == nil)
}

@Test func taskDeadlineChipIsDue() throws {
    let v2 = try taskFixture("aufgabe-neu")
    var state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("@par "), v2)
    _ = Reducer.reduce(&state, .setQuery("bis fr "), v2)
    let chips = try #require(Renderer.render(state, v2).regions.first { $0.0 == "chips" }?.1)
    #expect(chips.contains("<span class=\"chip\">@parkway-portal</span>"))
    #expect(chips.contains("<span class=\"chip due\">"))
}

@Test func switchingModeKeepsSearchRowsUntilTextChanges() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    _ = Reducer.reduce(&state, .setQuery("CallKit"), v2)
    let before = TaskArea.view(state, v2).rows
    _ = Reducer.reduce(&state, .toggleMode, v2)
    #expect(state.listMode == .ziel)
    #expect(TaskArea.view(state, v2).rows == before)
    _ = Reducer.reduce(&state, .setQuery("Projektanalyse"), v2)
    #expect(state.selectedId == nil)
    #expect(TaskArea.view(state, v2).rows.contains { $0.id == "e_s2" })
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Projektanalyse", projectId: v2.context?.projectId, deadline: nil, start: nil)])
}

@Test func projectWithSearchHitsCanBeCollapsedAndReopened() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    _ = Reducer.reduce(&state, .setQuery("CallKit"), v2)
    _ = Reducer.reduce(&state, .select("p:prj_vesper_ios"), v2)
    _ = Reducer.reduce(&state, .enter, v2)
    #expect(TaskArea.view(state, v2).rows.first?.open == false)
    #expect(!TaskArea.view(state, v2).rows.contains { $0.type == "entry" })
    _ = Reducer.reduce(&state, .enter, v2)
    #expect(TaskArea.view(state, v2).rows.first?.open == true)
    #expect(TaskArea.view(state, v2).rows.contains { $0.id == "e_s4" })
}

@Test func projectSummaryCountsVisibleStrandsAndWaitingWithoutTitle() throws {
    var snapshot = try taskFixture("aufgabe")
    let project = try #require(snapshot.context?.projectId)
    let index = try #require(snapshot.entries.firstIndex { $0.projectId == project && Logic.isStrang(snapshot, $0) })
    snapshot.entries[index].title = nil
    snapshot.entries[index].status = .wartet
    let visible = snapshot.entries.filter { $0.projectId == project && !Logic.isArchived(snapshot, $0) && (Logic.isStrang(snapshot, $0) || Logic.isOpen($0)) }
    let summary = Logic.projectSummary(snapshot, project)
    #expect(summary.strands == visible.filter { Logic.isStrang(snapshot, $0) }.count)
    #expect(summary.tasks == visible.filter { !Logic.isStrang(snapshot, $0) }.count)
    #expect(summary.wait)
}

@Test func dueHintStaysInBothModesAndShowsUrgentGoal() throws {
    let v2 = try taskFixture("kontext")
    let urgent = try #require(Logic.urgentTasks(v2).first)
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    let before = Renderer.render(state, v2)
    let body = try #require(before.regions.first { $0.0 == "body" }?.1)
    #expect(body.contains("data-act=\"showDue\">zeigen</button>"))
    let rows = TaskArea.view(state, v2).rows
    _ = Reducer.reduce(&state, .modeNext, v2)
    #expect(TaskArea.view(state, v2).rows == rows)
    let zielBody = try #require(Renderer.render(state, v2).regions.first { $0.0 == "body" }?.1)
    #expect(zielBody.replacingOccurrences(of: "aria-label=\"Ziele\"", with: "aria-label=\"Stränge\"") == body)
    #expect(KeyMap.events(for: .action("showDue", arg: nil), state: state) == [.showDue])
    _ = Reducer.reduce(&state, .showDue, v2)
    #expect(state.listMode == .ziel)
    #expect(state.openProjects.contains(urgent.projectId ?? "_none"))
    #expect(state.selectedId == "e:" + urgent.id)
    #expect(TaskArea.view(state, v2).rows.contains { $0.key == state.selectedId })
    _ = Reducer.reduce(&state, .modeNext, v2)
    _ = Reducer.reduce(&state, .showDue, v2)
    #expect(state.listMode == .resume)
    #expect(state.selectedId == "e:" + urgent.id)
    var withoutProject = v2
    let index = try #require(withoutProject.entries.firstIndex { $0.id == urgent.id })
    withoutProject.entries[index].projectId = nil
    state.mode = .edit
    _ = Reducer.reduce(&state, .showDue, withoutProject)
    #expect(state.mode == .list)
    #expect(state.openProjects.contains("_none"))
    #expect(TaskArea.view(state, withoutProject).rows.contains { $0.key == state.selectedId })
}

@Test func strandDeadlineAndCopyRemainAvailable() throws {
    let v2 = try taskFixture("kontext")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    let id = try #require(state.selectedId.flatMap { $0.hasPrefix("e:") ? String($0.dropFirst(2)) : nil })
    let entry = try #require(v2.entry(id))
    #expect(Logic.isStrang(v2, entry))
    let footer = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(footer.contains("<b>⌘D</b> deadline"))
    #expect(footer.contains("<b>⌘P</b> titel"))
    #expect(!footer.contains("<b>⌘C</b>"))
    #expect(!Reducer.reduce(&state, .copy, v2).isEmpty)
    _ = Reducer.reduce(&state, .help, v2)
    #expect(Renderer.render(state, v2).fullHTML.contains("befehl kopieren"))
    _ = Reducer.reduce(&state, .help, v2)
    #expect(KeyMap.events(for: .key(KeyPress(key: "d", meta: true)), state: state) == [.editDeadline])
    _ = Reducer.reduce(&state, .editDeadline, v2)
    #expect(state.editKind == .deadline)
    _ = Reducer.reduce(&state, .setEdit("fr"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.setDeadline(entryId: id, deadline: Logic.parseDeadline(v2, "fr"))])
}

@Test func defaultToolSwapsEnterAndShiftEnter() throws {
    var v2 = try taskFixture("aufgabe")
    v2.settings.defaultTool = .claude
    let entry = try #require(v2.entries.first { $0.projectId != nil && !Logic.isStrang(v2, $0) && Logic.isOpen($0) && $0.archivedAt == nil })
    var state = UIState(); state.openProjects = [entry.projectId!]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.startEntry(entryId: entry.id, tool: .claude, terminal: nil)])
    #expect(Reducer.reduce(&state, .shiftEnter, v2) == [.startEntry(entryId: entry.id, tool: .codex, terminal: nil)])
    let html = Renderer.render(state, v2).fullHTML
    #expect(html.range(of: "Claude ↵")!.lowerBound < html.range(of: "Codex ⇧↵")!.lowerBound)
    _ = Reducer.reduce(&state, .toggleGoal, v2)
    #expect(Renderer.render(state, v2).fullHTML.contains("aria-pressed=\"true\""))
    #expect(Reducer.reduce(&state, .startWith(.codex), v2) == [.startGoal(entryId: entry.id, tool: .codex, terminal: nil)])
    _ = Reducer.reduce(&state, .move(-1), v2)
    #expect(!state.goalMode)
    state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("Neues Ziel"), v2)
    #expect(Reducer.reduce(&state, .cmdEnter, v2) == [.addTask(title: "Neues Ziel", projectId: entry.projectId, deadline: nil, start: .claude)])
    state.listMode = .resume
    _ = Reducer.reduce(&state, .setQuery("Ein völlig neuer Strang"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.newStrang(title: "Ein völlig neuer Strang", projectId: entry.projectId!, tool: .claude, terminal: nil)])
}

@Test func doubleClickOnOpenGoalOnlyMarks() throws {
    let v2 = try taskFixture("kontext")
    let entry = try #require(v2.entries.first { $0.projectId == v2.context?.projectId && !Logic.isStrang(v2, $0) && Logic.isOpen($0) })
    var state = UIState(); _ = Reducer.reduce(&state, .opened, v2)
    let events = KeyMap.events(for: .doubleSelect("e:" + entry.id), state: state)
    #expect(events.flatMap { Reducer.reduce(&state, $0, v2) }.isEmpty)
    #expect(state.selectedId == "e:" + entry.id)
    #expect(Renderer.render(state, v2).fullHTML.contains("als /goal ⌘G"))
    let strand = try #require(v2.entries.first { $0.projectId == entry.projectId && Logic.isStrang(v2, $0) })
    let strandEvents = KeyMap.events(for: .doubleSelect("e:" + strand.id), state: state)
    #expect(strandEvents.flatMap { Reducer.reduce(&state, $0, v2) }.contains { if case .resumeEntry = $0 { true } else { false } })
    let project = try #require(entry.projectId)
    let projectEvents = KeyMap.events(for: .doubleSelect("p:" + project), state: state)
    _ = projectEvents.flatMap { Reducer.reduce(&state, $0, v2) }
    #expect(!state.openProjects.contains(project))
}

@Test func goalStartWithoutProjectAndAmbiguousChip() throws {
    var v2 = try taskFixture("kontext")
    var other = try #require(v2.projects.first { $0.name == "parkway-portal" })
    other.id = "pi"; other.name = "pi-harborlight"; v2.projects.append(other)
    let index = try #require(v2.entries.firstIndex { !Logic.isStrang(v2, $0) && Logic.isOpen($0) })
    v2.entries[index].projectId = nil
    let id = v2.entries[index].id
    var state = UIState(); state.openProjects = ["_none"]
    _ = Reducer.reduce(&state, .select("e:" + id), v2)
    #expect(Reducer.reduce(&state, .toggleGoal, v2).isEmpty)
    #expect(state.goalMode)
    #expect(Reducer.reduce(&state, .enter, v2) == [.startGoal(entryId: id, tool: .codex, terminal: nil)])
    _ = Reducer.reduce(&state, .complete, v2)
    _ = Reducer.reduce(&state, .setEdit("@p"), v2)
    #expect(Reducer.reduce(&state, .enter, v2).isEmpty)
    #expect(state.toast?.text == "mehrere: parkway-portal · pi-harborlight · ⇥ wählt das erste")
    #expect(state.mode == .edit)
    _ = Reducer.reduce(&state, .complete, v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.setProject(entryId: id, projectId: "prj_parkway-portal")])
    state = UIState(); state.listMode = .ziel
    _ = Reducer.reduce(&state, .setQuery("@p "), v2)
    #expect(Reducer.reduce(&state, .enter, v2).isEmpty)
    #expect(state.toast?.text.contains("parkway-portal · pi-harborlight") == true)
    _ = Reducer.reduce(&state, .complete, v2)
    #expect(state.chips.first?.value == "prj_parkway-portal")
}

@Test func markedProjectDrivesCreationAndSurvivesTyping() throws {
    let v2 = try taskFixture("kontext")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    let rows = TaskArea.view(state, v2).rows
    _ = Reducer.reduce(&state, .select("p:prj_devboardkit"), v2)
    #expect(TaskArea.view(state, v2).rows == rows)
    let chips = try #require(Renderer.render(state, v2).regions.first { $0.0 == "chips" }?.1)
    #expect(chips.contains("@devboardkit"))
    #expect(chips.contains("aria-label=\"@devboardkit, Aktuelles Projekt, ⌫ entfernt\""))
    _ = Reducer.reduce(&state, .modeNext, v2)
    _ = Reducer.reduce(&state, .setQuery("Neues Ziel"), v2)
    #expect(state.selectedId == nil)
    #expect(Renderer.render(state, v2).fullHTML.contains("neu · ◇ ziel in devboardkit"))
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Neues Ziel", projectId: "prj_devboardkit", deadline: nil, start: nil)])
    _ = Reducer.reduce(&state, .setQuery("@parkway-portal "), v2)
    _ = Reducer.reduce(&state, .setQuery("Neues Ziel"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Neues Ziel", projectId: "prj_parkway-portal", deadline: nil, start: nil)])
}

@Test func markedRowsAndDismissalControlContext() throws {
    let v2 = try taskFixture("kontext")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    _ = Reducer.reduce(&state, .select("p:prj_devboardkit"), v2)
    _ = Reducer.reduce(&state, .enter, v2)
    let entry = try #require(v2.entries.first { $0.projectId == "prj_devboardkit" && Logic.isStrang(v2, $0) && !Logic.isArchived(v2, $0) })
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    #expect(state.markedProjectId == "prj_devboardkit")
    state.openEntries.append(entry.id)
    let session = try #require(Logic.sessionsOf(v2, entry).first)
    _ = Reducer.reduce(&state, .select("s:" + session.id), v2)
    #expect(state.markedProjectId == "prj_devboardkit")
    _ = Reducer.reduce(&state, .select("p:_none"), v2)
    #expect(state.markedProjectId == nil)
    _ = Reducer.reduce(&state, .enter, v2)
    let goal = try #require(v2.entries.first { $0.projectId == nil && !Logic.isStrang(v2, $0) && Logic.isOpen($0) && !Logic.isArchived(v2, $0) })
    _ = Reducer.reduce(&state, .select("e:" + goal.id), v2)
    #expect(state.markedProjectId == nil)
    _ = Reducer.reduce(&state, .modeNext, v2)
    _ = Reducer.reduce(&state, .setQuery("Ohne Ort"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Ohne Ort", projectId: nil, deadline: nil, start: nil)])
    _ = Reducer.reduce(&state, .opened, v2)
    _ = Reducer.reduce(&state, .backspaceEmpty, v2)
    _ = Reducer.reduce(&state, .select("p:prj_devboardkit"), v2)
    _ = Reducer.reduce(&state, .setQuery("Ohne Ort"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Ohne Ort", projectId: nil, deadline: nil, start: nil)])
    _ = Reducer.reduce(&state, .setQuery("@parkway-portal "), v2)
    _ = Reducer.reduce(&state, .setQuery("Mit Ort"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.addTask(title: "Mit Ort", projectId: "prj_parkway-portal", deadline: nil, start: nil)])
    _ = Reducer.reduce(&state, .opened, v2)
    #expect(state.markedProjectId == v2.context?.projectId)
    #expect(!state.contextDismissed)
}

@Test func newStrandUsesLastMarkedProject() throws {
    let v2 = try taskFixture("kontext")
    var state = UIState()
    _ = Reducer.reduce(&state, .opened, v2)
    _ = Reducer.reduce(&state, .select("p:prj_devboardkit"), v2)
    _ = Reducer.reduce(&state, .setQuery("Unvergleichbarer neuer Strang"), v2)
    #expect(Reducer.reduce(&state, .enter, v2) == [.newStrang(title: "Unvergleichbarer neuer Strang", projectId: "prj_devboardkit", tool: v2.settings.defaultTool, terminal: nil)])
}

@Test func bannerFocusShowsNoRowDetail() throws {
    var v2 = try taskFixture("kontext")
    let strand = try #require(v2.entries.first { Logic.isStrang(v2, $0) && !Logic.isArchived(v2, $0) })
    var state = UIState()
    _ = Reducer.reduce(&state, .select("e:" + strand.id), v2)
    let normal = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(normal.contains("d-path"))
    v2.justEnded = [strand.id]
    state.focus = .banner
    let banner = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(!banner.contains("d-path"))
    #expect(!banner.contains("d-cmd"))
    v2.changes = try taskFixture("seit-zuletzt").changes
    #expect(!v2.changes.isEmpty)
    state.focus = .strip
    let strip = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(!strip.contains("d-path"))
    #expect(!strip.contains("d-cmd"))
    let goal = try #require(v2.entries.first { !Logic.isStrang(v2, $0) && Logic.isOpen($0) && !Logic.isArchived(v2, $0) })
    _ = Reducer.reduce(&state, .select("e:" + goal.id), v2)
    state.focus = .banner
    let goalBanner = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(!goalBanner.contains("d-path"))
}

@Test func selectOpensClosedGroup() throws {
    let v2 = try taskFixture("kontext")
    let entry = try #require(v2.entries.first { Logic.isStrang(v2, $0) && !Logic.isArchived(v2, $0) })
    let session = try #require(Logic.latest(v2, entry))
    let project = entry.projectId ?? "_none"
    var state = UIState()
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    #expect(state.openProjects.contains(project))
    #expect(state.selectedId == "e:" + entry.id)
    state.openProjects.removeAll()
    _ = Reducer.reduce(&state, .select("s:" + session.id), v2)
    #expect(state.openProjects.contains(project))
    #expect(state.openEntries.contains(entry.id))
    #expect(state.selectedId == "s:" + session.id)
    state.openProjects.removeAll()
    let intents = Reducer.reduce(&state, .doubleSelect("s:" + session.id), v2)
    #expect(state.selectedId == "s:" + session.id)
    #expect(TaskArea.view(state, v2).keys.contains("s:" + session.id))
    #expect(!intents.isEmpty || state.toast != nil)
    state.query = Logic.titleOf(v2, entry)
    state.closedSearchProjects = [project]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    #expect(!state.closedSearchProjects.contains(project))
    #expect(state.selectedId == "e:" + entry.id)
}

@Test func unavailableSessionHintsOnlyOfferEffectiveActions() throws {
    var v2 = try taskFixture("fehler")
    let sessionIndex = try #require(v2.sessions.firstIndex { !$0.resumable && !$0.live.running })
    let session = v2.sessions[sessionIndex]
    var state = UIState()
    _ = Reducer.reduce(&state, .select("e:" + session.entryId), v2)
    let footer = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(footer.contains("data-act=\"archive\""))
    #expect(footer.contains("<b>⌘⌫</b> erledigt"))
    #expect(!footer.contains("<b>↵</b>"))
    _ = Reducer.reduce(&state, .select("s:" + session.id), v2)
    let sessionFooter = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(!sessionFooter.contains("<b>↵</b>"))
    #expect(sessionFooter.contains("<b>⌘C</b>"))
    _ = Reducer.reduce(&state, .enter, v2)
    #expect(state.toast != nil)
    v2.sessions[sessionIndex].live.running = true
    let runningFooter = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(runningFooter.contains("<b>↵</b>"))
}

@Test func archiveSearchPreservesOtherFiltersAndModes() throws {
    let snapshot = try taskFixture("kontext")
    let active = try #require(snapshot.entries.first { $0.title == "Blogzugriff Basisversion fixen" })
    let archived = try #require(snapshot.entries.first { $0.title == "Blog-Feed Caching" })
    let project = try #require(active.projectId)
    func ids(_ ui: Logic.UI) -> [String] { Logic.buildView(snapshot, ui).rows.compactMap { $0.type == "entry" ? $0.id : nil } }
    #expect(!ids(.init(openProjects: [project])).contains(archived.id))
    let search = ids(.init(query: "blog"))
    #expect(try #require(search.firstIndex(of: active.id)) < #require(search.firstIndex(of: archived.id)))
    let archive = ids(.init(chips: [.init(kind: "archive", value: "true")], query: "blog"))
    #expect(archive.contains(archived.id))
    #expect(!archive.contains(active.id))
    #expect(!ids(.init(mode: "ziel", query: "blog")).contains(archived.id))
    var state = UIState()
    _ = Reducer.reduce(&state, .setQuery("blog"), snapshot)
    let body = try #require(Renderer.render(state, snapshot).regions.first { $0.0 == "body" }?.1)
    #expect(body.contains("archiv · erledigt"))
}

@Test func searchReachesProjectsWithOnlyArchivedStrands() throws {
    var snapshot = try taskFixture("aufgabe")
    let originalRows = Logic.buildView(snapshot, .init(openProjects: snapshot.projects.map(\.id) + ["_none"])).rows
    var entry = try #require(snapshot.entries.first { $0.id == "e_s13" })
    var session = try #require(snapshot.sessions.first { $0.entryId == entry.id })
    entry.id = "archived-only"; entry.projectId = "archived-project"; entry.title = nil
    session.id = "archived-session"; session.entryId = entry.id; session.projectId = entry.projectId
    session.suggestedTitle = "Orchard maintenance"; session.firstPrompt = ""
    session.live.running = false; session.lastActivityAt = snapshot.now.addingTimeInterval(-5 * 86400)
    snapshot.projects.append(Project(id: "archived-project", name: "orchard-project", rootPath: "/synthetic/orchard", lastActivityAt: session.lastActivityAt))
    snapshot.entries.append(entry); snapshot.sessions.append(session)
    #expect(Logic.isArchived(snapshot, entry))
    #expect(Logic.buildView(snapshot, .init(openProjects: snapshot.projects.map(\.id) + ["_none"])).rows == originalRows)
    for ui in [Logic.UI(query: "maintenance"), .init(query: "orchard-project"), .init(chips: [.init(kind: "archive", value: "true")])] {
        let rows = Logic.buildView(snapshot, ui).rows
        #expect(rows.contains { $0.type == "proj" && $0.id == entry.projectId })
        #expect(rows.contains { $0.type == "entry" && $0.id == entry.id })
    }
    #expect(!Logic.buildView(snapshot, .init(chips: [.init(kind: "archive", value: "true"), .init(kind: "tool", value: "codex")])).rows.contains { $0.id == entry.id })
}

@Test func additionalArchivedProjectsFollowMatchingActivityIncludingNoProject() throws {
    var snapshot = try taskFixture("aufgabe")
    let template = try #require(snapshot.entries.first { $0.id == "e_s13" })
    let sessionTemplate = try #require(snapshot.sessions.first { $0.entryId == template.id })
    snapshot.entries = []; snapshot.sessions = []; snapshot.context = nil
    snapshot.projects = [Project(id: "older", name: "older", rootPath: "/synthetic/older", lastActivityAt: snapshot.now),
                         Project(id: "newer", name: "newer", rootPath: "/synthetic/newer", lastActivityAt: snapshot.now),
                         Project(id: "active", name: "active", rootPath: "/synthetic/active", lastActivityAt: snapshot.now)]
    for (index, project) in ["older", "newer", nil].enumerated() {
        var entry = template; entry.id = "entry-\(index)"; entry.projectId = project; entry.title = nil
        var session = sessionTemplate; session.id = "session-\(index)"; session.entryId = entry.id; session.projectId = project
        session.suggestedTitle = "shared marker"; session.firstPrompt = ""; session.live.running = false
        session.lastActivityAt = snapshot.now.addingTimeInterval(-Double([7, 4, 5][index]) * 86400)
        snapshot.entries.append(entry); snapshot.sessions.append(session)
    }
    var active = template; active.id = "active-entry"; active.projectId = "active"; active.title = "shared active"
    var activeSession = sessionTemplate; activeSession.id = "active-session"; activeSession.entryId = active.id
    activeSession.projectId = active.projectId; activeSession.live.running = true
    activeSession.lastActivityAt = snapshot.now.addingTimeInterval(-10 * 86400)
    snapshot.entries.append(active); snapshot.sessions.append(activeSession)
    var unmatched = template; unmatched.id = "unmatched"; unmatched.projectId = "older"; unmatched.title = nil
    var unmatchedSession = sessionTemplate; unmatchedSession.id = "unmatched-session"; unmatchedSession.entryId = unmatched.id
    unmatchedSession.projectId = unmatched.projectId; unmatchedSession.suggestedTitle = "different"; unmatchedSession.firstPrompt = ""
    unmatchedSession.live.running = false; unmatchedSession.lastActivityAt = snapshot.now.addingTimeInterval(-4 * 86400)
    snapshot.entries.append(unmatched); snapshot.sessions.append(unmatchedSession)
    let rows = Logic.buildView(snapshot, .init(query: "shared")).rows
    #expect(rows.filter { $0.type == "proj" }.map(\.id) == ["active", "newer", nil, "older"])
    #expect(rows.filter { $0.type == "entry" }.compactMap(\.id) == ["active-entry", "entry-1", "entry-2", "entry-0"])
    #expect(Logic.buildView(snapshot, .init(chips: [.init(kind: "archive", value: "true"), .init(kind: "project", value: "older")], query: "shared")).rows.filter { $0.type == "entry" }.compactMap(\.id) == ["entry-0"])
}

@Test func emptyProjectFieldClosesQuietly() throws {
    let v2 = try taskFixture("kontext")
    let entry = try #require(v2.entries.first { !Logic.isStrang(v2, $0) && Logic.isOpen($0) })
    var state = UIState(); state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    _ = Reducer.reduce(&state, .complete, v2)
    #expect(state.mode == .edit)
    #expect(Reducer.reduce(&state, .enter, v2).isEmpty)
    #expect(state.mode == .list && state.toast == nil)
    _ = Reducer.reduce(&state, .complete, v2)
    _ = Reducer.reduce(&state, .setEdit("unknown"), v2)
    #expect(Reducer.reduce(&state, .enter, v2).isEmpty)
    #expect(state.mode == .edit && state.toast?.text.contains("unknown") == true)
}

@Test func startFolderPrefersSettingThenMostProjectsThenHome() {
    let date = Date(timeIntervalSince1970: 0)
    func project(_ path: String) -> Project { Project(id: path, name: path, rootPath: path, lastActivityAt: date) }
    let projects = [project("/z/a"), project("/z/b"), project("/a/a"), project("/a/b")]
    var settings = Settings.defaults
    settings.startFolder = "~/custom"
    #expect(Logic.startFolder(settings: settings, projects: projects, home: "/home/test") == "/home/test/custom")
    settings.startFolder = "/custom"
    #expect(Logic.startFolder(settings: settings, projects: projects, home: "/home/test") == "/custom")
    settings.startFolder = nil
    #expect(Logic.startFolder(settings: settings, projects: projects, home: "/home/test") == "/a")
    #expect(Logic.startFolder(settings: settings, projects: [projects[0]], home: "/home/test") == "/home/test")
}

@Test func emptySearchWithoutProjectOffersBothStarts() throws {
    var v2 = try taskFixture("kontext"); v2.entries = []; v2.sessions = []; v2.context = nil
    var state = UIState()
    _ = Reducer.reduce(&state, .setQuery("Unbekanntes Vorhaben"), v2)
    let html = Renderer.render(state, v2).fullHTML
    #expect(html.contains("neuer strang in dem Startordner"))
    #expect(html.contains("claude code") && html.contains("codex"))
    #expect(Reducer.reduce(&state, .enter, v2) == [.newStrang(title: "Unbekanntes Vorhaben", projectId: nil, tool: .codex, terminal: nil)])
    #expect(Reducer.reduce(&state, .shiftEnter, v2) == [.newStrang(title: "Unbekanntes Vorhaben", projectId: nil, tool: .claude, terminal: nil)])
}

@Test func trainerSuccessShowsTheWay() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    state.trainer = TrainerState(lesson: 0)
    state.trainer?.success = true
    let html = Renderer.render(state, v2).fullHTML
    #expect(html.contains("✓ Geschafft. Dein Weg:"))
    #expect(html.contains(v2.settings.hotkeys.popover))
    #expect(html.contains("↵ nächste Lektion"))
}

@Test func trainerFooterOffersNoActions() throws {
    let v2 = try taskFixture("kontext")
    let entry = try #require(v2.entries.first { !Logic.isStrang(v2, $0) && Logic.isOpen($0) })
    var state = UIState()
    state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    let normal = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
    #expect(normal.contains("d-path") && normal.contains("d-cmd") && normal.contains("symbols"))
    for lesson in 0...TrainerLessons.all.count {
        for success in [false, true] {
            for editing in [false, true] {
                state.trainer = TrainerState(lesson: lesson)
                state.trainer?.success = success
                state.mode = editing ? .edit : .list
                let footer = try #require(Renderer.render(state, v2).regions.first { $0.0 == "footer" }?.1)
                #expect(footer.contains("<div class=\"hints\"></div>"))
                #expect(!footer.contains("<button"))
                #expect(footer.contains("d-path") && footer.contains("d-cmd") && footer.contains("symbols"))
            }
        }
    }
}

@Test func trainerSuccessHidesStartButtons() throws {
    let v2 = try taskFixture("kontext")
    let entry = try #require(v2.entries.first { !Logic.isStrang(v2, $0) && Logic.isOpen($0) })
    var state = UIState()
    state.openProjects = [entry.projectId ?? "_none"]
    _ = Reducer.reduce(&state, .select("e:" + entry.id), v2)
    state.trainer = TrainerState(lesson: 4)
    let before = Renderer.render(state, v2).fullHTML
    #expect(before.contains("class=\"start-buttons\""))
    #expect(before.contains("data-act=\"startWith\"") && before.contains("data-act=\"toggleGoal\""))
    state.trainer?.success = true
    #expect(!Renderer.render(state, v2).fullHTML.contains("class=\"start-buttons\""))
    state.trainer = TrainerState(lesson: TrainerLessons.all.count)
    #expect(!Renderer.render(state, v2).fullHTML.contains("class=\"start-buttons\""))
    state.trainer = nil
    #expect(Renderer.render(state, v2).fullHTML.contains("class=\"start-buttons\""))
}

@Test func trainerHeadTellsWhatEscDoes() throws {
    let v2 = try taskFixture("aufgabe")
    var state = UIState()
    state.trainer = TrainerState(lesson: 1)
    for (query, editing, expected) in [("", false, "esc beendet"), ("zaun", false, "esc zurück"), ("", true, "esc zurück"), ("zaun", true, "esc zurück")] {
        state.query = query
        state.mode = editing ? .edit : .list
        let html = Renderer.render(state, v2).fullHTML
        #expect(html.contains(expected))
    }
}

@Test func helpListsTheKeysOfTheOneWindow() throws {
    var (state, snapshot) = try FixtureHarness.load("M01.kontext")
    state.help = true
    snapshot.settings.hotkeys.popover = "⌃⌘K"
    let help = try #require(Renderer.render(state, snapshot).region("body"))
    let rows = [
        ("⌃⌘K ← →", "modus wechseln (pfeile: feld leer)"),
        ("↵", "fortsetzen · starten · merken"), ("⇧↵", "starten mit dem anderen werkzeug"),
        ("⌥↵", "in Terminal.app öffnen"), ("⌘↵", "ziel merken und gleich starten"),
        ("⌘G", "als /goal an/aus"), ("⌘C", "befehl kopieren"), ("⌘P", "titel bearbeiten"),
        ("⌘D", "deadline setzen · leer = entfernen"), ("⇥", "vervollständigen · projekt zuordnen"),
        ("⌫", "chip entfernen"), ("⌘S", "status: offen → wartet → erledigt"),
        ("⌘↓ ⌘↑", "sessions zeigen / verbergen"), ("⌘⌫", "erledigt + archiv"),
        ("⌘Z", "rückgängig"), ("⌘⇧W", "fenster aufräumen"),
        ("@ cc cx ? ! /a", "präfixe (modus resume)"), ("bis fr · bis 14.11", "deadline beim tippen (modus ziel)"),
        ("↑ ↓", "markieren")
    ]
    let expected = rows.map { "<b>\(h($0.0))</b><span>\(h($0.1))</span>" }.joined()
    #expect(help.contains(expected))
    #expect(help.contains("<h2 class=\"sr\">Tastenkürzel</h2>"))
}

@Test func careEscapeOrder() throws {
    var (s, snap) = try FixtureHarness.load("M01.gerade-beendet")
    s.help = true; s.mode = .edit
    #expect(Reducer.reduce(&s, .cancel, snap).isEmpty)
    #expect(!s.help && s.mode == .edit && s.focus == .banner)
    #expect(Reducer.reduce(&s, .cancel, snap).isEmpty)
    #expect(s.mode == .list && s.focus == .banner)
    #expect(Reducer.reduce(&s, .cancel, snap) == [.dismissJustEnded])
    #expect(s.focus == .list)
}

@Test func careUndoResults() throws {
    var (s, snap) = try FixtureHarness.load("M01.kontext")
    #expect(Reducer.reduce(&s, .undo, snap) == [.undo])
    _ = Reducer.reduce(&s, .result(.undone(label: "undo.status")), snap)
    #expect(s.toast == Note(kind: .ok, text: t("m01.toast.undo", ["label": t("undo.status")])))
    _ = Reducer.reduce(&s, .result(.undoEmpty), snap)
    #expect(s.toast == Note(kind: .warn, text: t("m01.toast.nothing_undo")))
}

@Test func cleanupConfirmationUsesActualResult() throws {
    var (state, snapshot) = try FixtureHarness.load("M01.aufraeumen")
    #expect(Reducer.reduce(&state, .cleanup, snapshot) == [.cleanupWindows])
    #expect(state.toast == nil)
    _ = Reducer.reduce(&state, .result(.windowsClosed(count: 1)), snapshot)
    #expect(state.toast?.text == t("m01.toast.cleanup", ["n": 1]))
    #expect(state.undoHint)
}

@Test func careBannerActionsAndStableInput() throws {
    var (state, snapshot) = try FixtureHarness.load("M01.gerade-beendet")
    let id = try #require(snapshot.justEnded.first)
    let entry = try #require(snapshot.entry(id))
    let before = Renderer.render(state, snapshot)
    _ = Reducer.reduce(&state, .setBanner("  eigenes <Thema>  "), snapshot)
    let after = Renderer.render(state, snapshot)
    #expect(before.region("body") == after.region("body"))
    #expect(after.region("bmirror") == "  eigenes &lt;Thema&gt;  ")
    #expect(Reducer.reduce(&state, .enter, snapshot) == [.nameJustEnded(entryId: id, title: "eigenes <Thema>")])
    #expect(state.focus == .list && state.bannerText.isEmpty && state.undoHint)
    state.focus = .banner
    _ = Reducer.reduce(&state, .complete, snapshot)
    #expect(state.bannerText == Logic.titleOf(snapshot, entry))
    state.bannerText = "   "
    #expect(Reducer.reduce(&state, .enter, snapshot) == [.nameJustEnded(entryId: id, title: Logic.titleOf(snapshot, entry))])
    state.focus = .banner
    #expect(Reducer.reduce(&state, .cancel, snapshot) == [.dismissJustEnded])
}

@Test func relativeTimeAndTokens() throws {
    let snapshot = try taskFixture("kontext")
    #expect(Logic.agoShort(snapshot, snapshot.now.addingTimeInterval(-120)) == t("time.short.min", ["n": 2]))
    #expect(Logic.agoLong(snapshot, snapshot.now.addingTimeInterval(-7200)) == t("time.long.hour", ["n": 2]))
    #expect(Logic.tokensM(3_500_000) == "3,5")
}

@Test func htmlEscapesQuoteWithCombiningMark() throws {
    var v2 = try taskFixture("kontext")
    let index = try #require(v2.entries.firstIndex { !Logic.isStrang(v2, $0) && Logic.isOpen($0) && !Logic.isArchived(v2, $0) })
    v2.entries[index].title = "\"\u{0301} data-act=cleanup x=\"\u{0301}"
    var state = UIState(); state.openProjects = [v2.entries[index].projectId ?? "_none"]
    let html = Renderer.render(state, v2).fullHTML
    let escaped = "&quot;\u{0301} data-act=cleanup x=&quot;\u{0301}"
    #expect(html.contains(escaped))
    let range = try #require(html.range(of: "id=\"opt-e:\(v2.entries[index].id)\""))
    let end = try #require(html[range.lowerBound...].firstIndex(of: ">"))
    #expect(!html[range.lowerBound...end].contains("data-act=\"cleanup\""))
}

private func stripFixture() throws -> Snapshot {
    var snap = try taskFixture("aufgabe")
    let entry = try #require(snap.entries.first)
    snap.changes = [Change(id: "one", kind: .add, entryId: entry.id, by: .codex, at: snap.now),
                    Change(id: "two", kind: .done, entryId: entry.id, by: .claude, at: snap.now)]
    return snap
}
private func click(_ name: String, arg: String? = nil, state: inout UIState, snapshot: Snapshot) -> [Intent] {
    KeyMap.events(for: .action(name, arg: arg), state: state).flatMap { Reducer.reduce(&state, $0, snapshot) }
}
private func press(_ key: String, state: inout UIState, snapshot: Snapshot) -> [Intent] {
    KeyMap.events(for: .key(KeyPress(key: key, meta: true)), state: state)
        .flatMap { Reducer.reduce(&state, $0, snapshot) }
}
@Test func stripCommandDeleteDiscardsChosen() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    _ = Reducer.reduce(&state, .stripSelect(1), snap)
    let html = Renderer.render(state, snap).fullHTML
    #expect(html.contains("⌘⌫ verwerfen"))
    #expect(html.contains("data-act=\"stripRevert\" aria-label=\""))
    #expect(press("Backspace", state: &state, snapshot: snap) == [.revertChange(changeId: "two")])
}
@Test func stripCommandZIsNormalUndo() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    #expect(press("z", state: &state, snapshot: snap) == [.undo])
}
@Test func stripCommandDeleteInListStillArchives() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    let entry = try #require(snap.entries.first)
    _ = Reducer.reduce(&state, .select("e:" + entry.id), snap)
    #expect(state.focus == .list)
    #expect(press("Backspace", state: &state, snapshot: snap) == [.archiveEntry(entryId: entry.id)])
}
@Test func stripDiscardCanBeUndone() throws {
    var snap = try stripFixture(); var state = UIState(); var effects = PrototypeEffects()
    let change = snap.changes[0]
    let entry = try #require(snap.entry(change.entryId))
    _ = Reducer.reduce(&state, .opened, snap)
    let discard = try #require(press("Backspace", state: &state, snapshot: snap).first)
    let result = try #require(effects.apply(discard, to: &snap))
    _ = Reducer.reduce(&state, .result(result), snap)
    #expect(snap.entry(entry.id) == nil && !snap.changes.contains(change))
    #expect(state.toast?.text == "Verworfen: \(entry.title ?? "")")
    let undo = try #require(press("z", state: &state, snapshot: snap).first)
    let undoResult = try #require(effects.apply(undo, to: &snap))
    _ = Reducer.reduce(&state, .result(undoResult), snap)
    #expect(snap.entry(entry.id) == entry && snap.changes.contains(change))
    #expect(Renderer.render(state, snap).fullHTML.contains("data-act=\"stripSelect\""))
}
@Test func stripClickAcceptsAll() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap); state.focus = .list
    let html = Renderer.render(state, snap).fullHTML
    #expect(html.contains("class=\"strip-act\" data-act=\"stripAccept\">↵ ok</button> · ↑↓ wählen · "))
    #expect(!html.contains("esc später"))
    #expect(click("stripAccept", state: &state, snapshot: snap) == [.acceptChanges])
    #expect(state.focus == .list)
}
@Test func stripClickRevertsChosen() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    _ = click("stripSelect", arg: "1", state: &state, snapshot: snap)
    state.focus = .list
    #expect(click("stripRevert", state: &state, snapshot: snap) == [.revertChange(changeId: "two")])
}
@Test func stripClickSelectsRow() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap); state.focus = .list
    #expect(Renderer.render(state, snap).fullHTML.contains("data-act=\"stripSelect\" data-arg=\"1\""))
    #expect(click("stripSelect", arg: "1", state: &state, snapshot: snap).isEmpty)
    #expect(state.focus == .strip && state.stripIdx == 1)
    #expect(Reducer.reduce(&state, .archive, snap) == [.revertChange(changeId: "two")])
    _ = click("stripSelect", arg: "99", state: &state, snapshot: snap)
    #expect(state.stripIdx == 1)
}
@Test func bannerClicksMatchKeys() throws {
    let (initial, snap) = try FixtureHarness.load("M01.gerade-beendet")
    let html = Renderer.render(initial, snap).fullHTML
    for (action, key) in [("bannerAccept", "Tab"), ("bannerName", "Enter"), ("bannerLater", "Escape")] {
        #expect(html.contains("class=\"banner-act\" data-act=\"\(action)\""))
        var clicked = initial; clicked.focus = .list
        var keyed = initial; keyed.focus = .banner
        let actual = click(action, state: &clicked, snapshot: snap)
        let expected = KeyMap.events(for: .key(KeyPress(key: key, field: "b")), state: keyed)
            .flatMap { Reducer.reduce(&keyed, $0, snap) }
        #expect(actual == expected)
        #expect(clicked == keyed)
    }
    #expect(html.contains("</button> · tippen · <button"))
}
@Test func bannerFocusAndNavigationFollowVisualOrder() throws {
    var (state, snap) = try FixtureHarness.load("M01.gerade-beendet")
    let id = try #require(snap.justEnded.first)
    let entry = try #require(snap.entry(id))
    snap.changes = [Change(id: "one", kind: .add, entryId: entry.id, by: .codex, at: snap.now)]
    state.focus = .list
    state.selectedId = try #require(TaskArea.view(state, snap).keys.first)
    _ = Reducer.reduce(&state, .move(-1), snap)
    #expect(state.focus == .banner)
    _ = Reducer.reduce(&state, .move(-1), snap)
    #expect(state.focus == .strip)
    _ = Reducer.reduce(&state, .move(1), snap)
    #expect(state.focus == .banner)
    _ = Reducer.reduce(&state, .move(1), snap)
    #expect(state.focus == .list)
    #expect(Renderer.render(state, snap).fullHTML.contains("class=\"b\" data-act=\"bannerFocus\""))
    #expect(click("bannerFocus", state: &state, snapshot: snap).isEmpty)
    #expect(state.focus == .banner)
}
@Test func stripEscAcceptsLikeEnter() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    #expect(Reducer.reduce(&state, .cancel, snap) == [.acceptChanges])
    #expect(state.focus == .list)
    #expect(state.toast?.text == "Änderungen übernommen")
}
@Test func stripIsInactiveDuringSearch() throws {
    let snap = try stripFixture(); var state = UIState()
    _ = Reducer.reduce(&state, .opened, snap)
    _ = Reducer.reduce(&state, .type("auf"), snap)
    #expect(state.focus == .list)
    #expect(!Renderer.render(state, snap).fullHTML.contains("class=\"strip\""))
    #expect(Reducer.reduce(&state, .undo, snap) == [.undo])
    state.selectedId = TaskArea.view(state, snap).keys.first
    _ = Reducer.reduce(&state, .move(-1), snap)
    #expect(state.focus == .list)
    let entry = try #require(snap.entries.first { $0.title == "Push-Zustellung messen" })
    _ = Reducer.reduce(&state, .setQuery("Push-Zustellung"), snap)
    state.selectedId = "e:" + entry.id
    state.focus = .strip
    #expect(Reducer.reduce(&state, .enter, snap) == [.startEntry(entryId: entry.id, tool: snap.settings.defaultTool, terminal: nil)])
    state.query = ""; state.chips = []; state.help = true; state.focus = .strip
    #expect(Reducer.reduce(&state, .undo, snap) == [.undo])
    #expect(Reducer.reduce(&state, .stripAccept, snap).isEmpty)
    state.help = false
    _ = Reducer.reduce(&state, .setQuery("cc "), snap)
    #expect(state.focus == .list && !Renderer.render(state, snap).fullHTML.contains("class=\"strip\""))
}
@Test func stripOpensOnFirstRowAfterAccept() throws {
    var snap = try stripFixture(); var state = UIState()
    snap.changes.append(Change(id: "three", kind: .add, entryId: snap.changes[0].entryId, by: .codex, at: snap.now))
    _ = Reducer.reduce(&state, .opened, snap)
    _ = Reducer.reduce(&state, .stripSelect(2), snap)
    #expect(Reducer.reduce(&state, .stripAccept, snap) == [.acceptChanges])
    snap.changes = [Change(id: "new", kind: .add, entryId: snap.changes[0].entryId, by: .claude, at: snap.now)]
    _ = Reducer.reduce(&state, .opened, snap)
    #expect(state.focus == .strip && state.stripIdx == 0)
    #expect(Renderer.render(state, snap).fullHTML.contains("class=\"chg sel\""))
    #expect(Reducer.reduce(&state, .archive, snap) == [.revertChange(changeId: "new")])
}
@Test func stripClickEndsEdit() throws {
    let snap = try stripFixture()
    let entry = try #require(snap.entry(snap.changes[0].entryId))
    for event in [UIEvent.stripSelect(0), .stripAccept, .stripRevert] {
        var state = UIState(); _ = Reducer.reduce(&state, .opened, snap)
        _ = Reducer.reduce(&state, .select("e:" + entry.id), snap)
        _ = Reducer.reduce(&state, .edit, snap)
        #expect(state.mode == .edit)
        let intents = Reducer.reduce(&state, event, snap)
        if event == .stripRevert { #expect(intents == [.revertChange(changeId: "one")]) }
        #expect(state.mode == .list && state.editEntryId == nil && !state.selectAll)
        #expect(!Renderer.render(state, snap).fullHTML.contains("class=\"e\""))
    }
}
@Test func rowWithoutTitleShowsPlaceholder() throws {
    var snap = try taskFixture("aufgabe")
    let session = try #require(snap.sessions.first)
    let index = try #require(snap.entries.firstIndex { $0.id == session.entryId })
    snap.entries[index].title = nil
    for i in snap.sessions.indices where snap.sessions[i].entryId == session.entryId { snap.sessions[i].suggestedTitle = "" }
    var state = UIState(); _ = Reducer.reduce(&state, .opened, snap)
    state.openProjects = snap.projects.map(\.id) + ["_none"]
    let html = Renderer.render(state, snap).fullHTML
    #expect(html.contains("class=\"title unpinned\">ohne Titel</span>"))
    #expect(html.range(of: "aria-label=\"[^\"]*ohne Titel[^\"]*\"", options: .regularExpression) != nil)
    state.selectedId = "e:" + session.entryId
    _ = Reducer.reduce(&state, .edit, snap)
    #expect(state.editText.isEmpty)
    _ = Reducer.reduce(&state, .cancel, snap)
    snap.sessions.removeAll { $0.entryId == session.entryId }
    snap.entries[index].deadline = "2026-12-01"
    let taskHTML = Renderer.render(state, snap).fullHTML
    #expect(taskHTML.contains("class=\"title\">ohne Titel</span>"))
    #expect(taskHTML.range(of: "aria-label=\"[^\"]*ohne Titel[^\"]*\"", options: .regularExpression) != nil)
}
