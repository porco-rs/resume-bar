import Foundation
import RBContract

/// The v2 task list and task creation flow.
enum TaskArea {
    static func view(_ s: UIState, _ snap: Snapshot) -> Logic.View {
        Logic.buildView(snap, .init(mode: s.filterMode.rawValue, chips: s.chips.map { .init(kind: $0.kind.rawValue, value: $0.value, label: $0.label) }, query: s.query, openEntries: s.openEntries, openProjects: s.openProjects, contextDismissed: s.contextDismissed, closedSearchProjects: s.closedSearchProjects))
    }
    static func stripAvailable(_ s: UIState, _ snap: Snapshot) -> Bool {
        s.listMode == .resume && !snap.changes.isEmpty && !s.help && !view(s, snap).searching
    }
    static func bannerAvailable(_ s: UIState, _ snap: Snapshot) -> Bool {
        guard s.listMode == .resume, s.mode == .list, !s.help,
              let id = snap.justEnded.first, let entry = snap.entry(id) else { return false }
        return Logic.latest(snap, entry) != nil
    }
    static func normalize(_ s: inout UIState, _ snap: Snapshot) {
        let keys = view(s, snap).keys
        if !keys.contains(s.selectedId ?? "") {
            s.selectedId = s.listMode == .ziel && !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (view(s, snap).rows.first { $0.type == "entry" }?.key ?? keys.first)
        }
    }
    private static func contextProject(_ s: UIState, _ snap: Snapshot) -> String? {
        guard !s.contextDismissed else { return nil }
        return s.markedProjectInitialized ? s.markedProjectId : snap.context?.projectId
    }
    private static func creationProject(_ s: UIState, _ snap: Snapshot) -> String? {
        s.chips.first { $0.kind == .project }?.value ?? contextProject(s, snap)
    }
    static func reduce(_ s: inout UIState, _ event: UIEvent, _ snap: Snapshot) -> [Intent] {
        if !s.markedProjectInitialized {
            s.markedProjectId = snap.context?.projectId
            s.markedProjectInitialized = true
        }
        let oldSelection = s.selectedId
        defer {
            if s.selectedId != oldSelection { s.goalMode = false }
            let selectedExplicitly: Bool
            switch event {
            case .select(let id), .doubleSelect(let id): selectedExplicitly = !id.isEmpty
            default: selectedExplicitly = false
            }
            if s.selectedId != oldSelection || selectedExplicitly {
                if event != .opened, let key = s.selectedId,
                   let row = view(s, snap).rows.first(where: { $0.key == key }) {
                    if row.type == "proj" { s.markedProjectId = row.id }
                    else { s.markedProjectId = (row.type == "session" ? row.entryId : row.id).flatMap { snap.entry($0)?.projectId } }
                    s.hasMarkedProject = true
                }
            }
        }
        switch event {
        case .select, .move, .setQuery, .setEdit, .setBanner, .result, .opened: break
        default: s.toast = nil; s.notes = [:]; s.undoHint = false
        }
        switch event {
        case .stripSelect, .stripAccept, .stripRevert:
            if stripAvailable(s, snap), s.mode == .edit { s.mode = .list; s.editEntryId = nil; s.selectAll = false }
        default: break
        }
        switch event {
        case .select(let id):
            openSelection(id, &s, snap); s.selectedId = id; s.focus = .list
        case .doubleSelect(let id):
            openSelection(id, &s, snap); s.selectedId = id; s.focus = .list
            if let entry = selectedEntry(s, snap), !Logic.isStrang(snap, entry) { break }
            return reduce(&s, .enter, snap)
        case .stripSelect(let index):
            if stripAvailable(s, snap), snap.changes.indices.contains(index) { s.stripIdx = index; s.focus = .strip }
        case .stripAccept:
            if stripAvailable(s, snap) { s.focus = .list; s.toast = Note(kind: .ok, text: t("m01.toast.changes_ok")); return [.acceptChanges] }
        case .stripRevert:
            if stripAvailable(s, snap), snap.changes.indices.contains(s.stripIdx) { return [.revertChange(changeId: snap.changes[s.stripIdx].id)] }
        case .bannerFocus:
            if bannerAvailable(s, snap) { s.focus = .banner }
        case .toggleGoal:
            if s.mode == .list, let entry = selectedEntry(s, snap), !Logic.isStrang(snap, entry), Logic.isOpen(entry) {
                s.goalMode.toggle()
            }
        case .startWith(let tool):
            guard s.mode == .list, let entry = selectedEntry(s, snap), !Logic.isStrang(snap, entry), Logic.isOpen(entry) else { break }
            return start(&s, entry: entry, tool: tool)
        case .move(let n):
            guard s.mode != .edit, !s.help else { break }
            if s.focus == .strip && stripAvailable(s, snap) {
                let index = s.stripIdx + n
                if index >= snap.changes.count { s.focus = bannerAvailable(s, snap) ? .banner : .list } else if index >= 0 { s.stripIdx = index }
                break
            }
            if s.focus == .banner && bannerAvailable(s, snap) {
                if n > 0 { s.focus = .list }
                else if n < 0 && stripAvailable(s, snap) { s.focus = .strip; s.stripIdx = snap.changes.count - 1 }
                break
            }
            s.focus = .list
            let keys = view(s, snap).keys
            let i = keys.firstIndex(of: s.selectedId ?? "") ?? -1
            if keys.indices.contains(i + n) { s.selectedId = keys[i + n] }
            else if n < 0 && i == 0 {
                if s.listMode == .ziel && !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.selectedId = nil }
                else if bannerAvailable(s, snap) { s.focus = .banner }
                else if stripAvailable(s, snap) { s.focus = .strip; s.stripIdx = snap.changes.count - 1 }
            }
        case .type(let text): s.closedSearchProjects = []; s.filterMode = s.listMode; for ch in text { s.query.append(ch); chipify(&s, snap) }; s.selectedId = nil; if view(s, snap).searching { s.focus = .list }
        case .setQuery(let text): s.closedSearchProjects = []; s.filterMode = s.listMode; s.query = text; chipify(&s, snap); s.selectedId = nil; if view(s, snap).searching { s.focus = .list }
        case .modeNext, .modePrev, .toggleMode:
            guard (event == .toggleMode || s.query.isEmpty), s.mode == .list, !s.help else { break }
            s.listMode = s.listMode == .resume ? .ziel : .resume
            s.focus = .list
        case .showDue:
            if let urgent = Logic.urgentTasks(snap).first {
                let project = urgent.projectId ?? "_none"
                if !s.openProjects.contains(project) { s.openProjects.append(project) }
                s.selectedId = "e:" + urgent.id
                s.focus = .list
                s.mode = .list; s.editEntryId = nil; s.selectAll = false
            }
        case .complete:
            if s.mode == .edit && s.editKind == .project {
                let fragment = s.editText.hasPrefix("@") ? String(s.editText.dropFirst()) : s.editText
                s.editText += Logic.ghostProject(snap, fragment)
                return []
            }
            if s.focus == .banner, s.listMode == .resume, let id = snap.justEnded.first, let entry = snap.entry(id) {
                s.bannerText = Logic.titleOf(snap, entry); break
            }
            if s.query.last?.isWhitespace == true, let word = s.query.split(whereSeparator: \.isWhitespace).last, word.hasPrefix("@"),
               let match = Logic.resolveProject(snap, String(word.dropFirst())), !match.unique {
                let fragment = String(word.dropFirst())
                s.query = s.query.trimmingCharacters(in: .whitespacesAndNewlines) + Logic.ghostProject(snap, fragment) + " "
                chipify(&s, snap); s.selectedId = nil; break
            }
            let ghost = Logic.ghostFor(snap, s.query)
            if !ghost.isEmpty { s.query += ghost + " "; chipify(&s, snap); s.selectedId = nil }
            else if let entry = selectedEntry(s, snap), !Logic.isStrang(snap, entry) { let id = entry.id; beginEdit(&s, id: id, kind: .project, text: "") }
        case .edit, .editDeadline:
            if let entry = selectedEntry(s, snap) {
                let kind: UIState.EditKind = event == .edit ? .title : .deadline
                beginEdit(&s, id: entry.id, kind: kind, text: kind == .title ? Logic.titleOf(snap, entry) : entry.deadline.map(Logic.dueInput) ?? "")
                s.selectAll = kind == .deadline
            }
        case .setEdit(let text): s.editText = text; s.selectAll = false
        case .backspaceEmpty:
            if !s.chips.isEmpty { s.chips.removeLast() } else { s.contextDismissed = true }
            s.selectedId = nil
        case .enter, .shiftEnter, .altEnter, .cmdEnter, .saveEdit:
            if s.mode == .edit { return saveEdit(&s, snap) }
            if let fragment = ambiguousQuery(s.query, snap) {
                s.toast = ambiguousMessage(fragment, snap); return []
            }
            if s.help { s.help = false; break }
            if s.focus == .strip && stripAvailable(s, snap) { s.focus = .list; s.toast = Note(kind: .ok, text: t("m01.toast.changes_ok")); return [.acceptChanges] }
            if s.focus == .banner && s.listMode == .resume, let id = snap.justEnded.first, let entry = snap.entry(id) {
                let name = s.bannerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let chosen = name.isEmpty ? Logic.titleOf(snap, entry) : name
                s.focus = snap.justEnded.count > 1 ? .banner : .list; s.bannerText = ""; s.undoHint = true
                s.toast = Note(kind: .ok, text: t("m01.toast.named", ["project": entry.projectId.flatMap { snap.project($0)?.name } ?? t("project.none"), "title": chosen]))
                return [.nameJustEnded(entryId: id, title: chosen)]
            }
            if s.listMode == .ziel && !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if s.query.last?.isWhitespace != true {
                    let original = s.query
                    s.query.append(" ")
                    chipify(&s, snap)
                    if s.query == original + " " { s.query = original }
                }
                let title = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return [] }
                let project = creationProject(s, snap)
                let deadline = s.chips.first { $0.kind == .deadline }?.value
                return [.addTask(title: title, projectId: project, deadline: deadline, start: event == .cmdEnter ? snap.settings.defaultTool : nil)]
            }
            let title = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = view(s, snap)
            if let key = s.selectedId, let row = v.rows.first(where: { $0.key == key }) {
                if row.type == "proj" {
                    let project = row.id ?? "_none"
                    if v.searching {
                        if row.open == true { s.closedSearchProjects.append(project) }
                        else { s.closedSearchProjects.removeAll { $0 == project } }
                    } else if row.open == true { s.openProjects.removeAll { $0 == project } }
                    else if !s.openProjects.contains(project) { s.openProjects.append(project) }
                    break
                }
                guard let id = row.type == "session" ? row.entryId : row.id, let entry = snap.entry(id) else { break }
                if Logic.isStrang(snap, entry) {
                    let session = row.type == "session" ? row.id.flatMap { snap.session($0) } : Logic.latest(snap, entry)
                    if let session {
                        let key = row.key ?? "e:" + id
                        if !session.resumable {
                            s.notes[key] = Note(kind: .error, text: t("m01.row.not_resumable"))
                            s.toast = Note(kind: .error, text: t("m01.toast.not_resumable", ["path": session.transcriptPath]))
                        } else if session.live.running {
                            let app = (session.live.terminalApp ?? snap.settings.terminal.default).displayName
                            s.notes[key] = Note(kind: .ok, text: t("m01.row.focus", ["app": app, "window": session.live.windowIndex.map(String.init) ?? ""]))
                            s.toast = Note(kind: .ok, text: t("m01.toast.focus", ["app": app, "window": session.live.windowIndex.map(String.init) ?? "", "tty": session.live.tty ?? ""]))
                        } else {
                            let app = (event == .altEnter ? snap.settings.terminal.alternate : snap.settings.terminal.default).displayName
                            let cwd = session.cwd.replacingOccurrences(of: "^/Users/[^/]+", with: "~", options: .regularExpression)
                            s.notes[key] = Note(kind: .ok, text: t("m01.row.open", ["app": app]))
                            s.toast = Note(kind: .ok, text: t("m01.toast.open", ["app": app, "cwd": cwd, "cmd": Logic.command(session, snap)]))
                        }
                    }
                    return [.resumeEntry(entryId: id, sessionId: row.type == "session" ? row.id : nil, terminal: event == .altEnter ? snap.settings.terminal.alternate : nil)]
                }
                return start(&s, entry: entry, tool: chosenTool(event, snap))
            } else if s.listMode == .resume && v.searching && !title.isEmpty {
                return [.newStrang(title: title, projectId: creationProject(s, snap), tool: chosenTool(event, snap), terminal: nil)]
            }
        case .copy:
            if let row = view(s, snap).rows.first(where: { $0.key == s.selectedId }), let entry = selectedEntry(s, snap), Logic.isStrang(snap, entry), let session = row.type == "session" ? row.id.flatMap({ snap.session($0) }) : Logic.latest(snap, entry) { return [.copyCommand(sessionId: session.id)] }
        case .openEntry:
            if let entry = selectedEntry(s, snap), Logic.isStrang(snap, entry) {
                if Logic.sessionsOf(snap, entry).count < 2 { s.toast = Note(kind: .warn, text: t("m01.toast.one_session")) }
                else if !s.openEntries.contains(entry.id) { s.openEntries.append(entry.id) }
            }
        case .closeEntry:
            if let entry = selectedEntry(s, snap) { s.openEntries.removeAll { $0 == entry.id }; s.selectedId = "e:" + entry.id }
        case .help: s.help.toggle()
        case .setBanner(let text): s.bannerText = text
        case .result(let result):
            if case let .changeReverted(title) = result {
                s.toast = Note(kind: .ok, text: t("m01.toast.change_reverted", ["title": title]))
                s.stripIdx = max(0, min(s.stripIdx, snap.changes.count - 1))
            } else if case let .taskAdded(id) = result, let entry = snap.entry(id) {
                s.query = ""; s.chips = []; s.selectedId = "e:" + id
                let projectKey = entry.projectId ?? "_none"
                if !s.openProjects.contains(projectKey) { s.openProjects.append(projectKey) }
                s.undoHint = true
                s.notes[s.selectedId!] = Note(kind: .ok, text: t("m01.row.added"))
                let project = entry.projectId.flatMap { snap.project($0)?.name } ?? t("project.none")
                let date = entry.deadline.map { Logic.dueLong(snap, $0) } ?? ""
                s.toast = Note(kind: .ok, text: t(entry.deadline == nil ? "m01.toast.task_added" : "m01.toast.task_added_due", ["project": project, "date": date]))
            } else if case let .projectSet(id) = result, let entry = snap.entry(id) {
                let project = entry.projectId ?? "_none"
                if !s.openProjects.contains(project) { s.openProjects.append(project) }
                s.selectedId = "e:" + id
                s.markedProjectId = entry.projectId; s.hasMarkedProject = true
            } else if case let .copied(command) = result {
                s.toast = Note(kind: .ok, text: t("m01.toast.copied", ["cmd": command]))
            } else if case let .entryStatusSet(id, from, to) = result {
                s.undoHint = true; s.selectedId = "e:" + id
                s.notes[s.selectedId!] = Note(kind: .warn, text: t("m01.row.status", ["from": t("status." + from.rawValue), "to": t("status." + to.rawValue)]))
                s.toast = Note(kind: .ok, text: t("m01.toast.status", ["status": t("status." + to.rawValue)]))
            } else if case let .folderMissing(path) = result {
                s.toast = Note(kind: .error, text: t("m01.toast.folder_missing", ["path": path]))
            } else if case let .terminalFailed(app, reason) = result {
                s.toast = Note(kind: .error, text: t("m01.toast.terminal_failed", ["app": app.displayName, "reason": reason]))
            } else if case let .automationDenied(app) = result {
                s.toast = Note(kind: .error, text: t("m01.toast.automation_denied", ["app": app.displayName]))
            } else if case .entrySaveFailed = result {
                s.toast = Note(kind: .error, text: t("m01.toast.entry_save_failed"))
            } else if case let .undone(label) = result {
                s.toast = Note(kind: .ok, text: t("m01.toast.undo", ["label": t(label)]))
                normalize(&s, snap)
            } else if case .undoEmpty = result {
                s.toast = Note(kind: .warn, text: t("m01.toast.nothing_undo"))
            } else if case let .windowsClosed(count) = result {
                s.toast = Note(kind: .ok, text: t("m01.toast.cleanup", ["n": count]))
                s.undoHint = count > 0
            }
        case .archive:
            if s.focus == .strip && stripAvailable(s, snap) && snap.changes.indices.contains(s.stripIdx) {
                return [.revertChange(changeId: snap.changes[s.stripIdx].id)]
            }
            if let entry = selectedEntry(s, snap) {
                let keys = view(s, snap).keys
                let index = keys.firstIndex(of: s.selectedId ?? "") ?? 0
                let remaining = keys.filter { $0 != s.selectedId }
                s.selectedId = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
                s.undoHint = true
                s.toast = Note(kind: .ok, text: t(Logic.isStrang(snap, entry) ? "m01.toast.archived" : "m01.toast.task_done", ["title": Logic.titleOf(snap, entry)]))
                return [.archiveEntry(entryId: entry.id)]
            }
        case .cycle:
            if let entry = selectedEntry(s, snap) {
                if Logic.isStrang(snap, entry) { s.selectedId = "e:" + entry.id; return [.cycleStatus(entryId: entry.id)] }
                s.toast = Note(kind: .warn, text: t("m01.toast.cycle_task"))
            }
        case .undo:
            return [.undo]
        case .cleanup:
            if snap.windows.closable > 0 { return [.cleanupWindows] }
        case .cancel:
            if s.help { s.help = false }
            else if s.mode == .edit { s.mode = .list; s.editEntryId = nil; s.selectAll = false }
            else if s.focus == .strip && stripAvailable(s, snap) { return reduce(&s, .stripAccept, snap) }
            else if s.focus == .banner && s.listMode == .resume && !snap.justEnded.isEmpty { s.focus = .list; return [.dismissJustEnded] }
            else if !s.query.isEmpty || !s.chips.isEmpty { s.query = ""; s.chips = []; s.selectedId = nil }
            else { s.toast = Note(kind: .ok, text: t("m01.toast.close")); return [.closePopover] }
        case .opened:
            s.stripIdx = 0
            s.query = ""; s.chips = []; s.selectedId = nil; s.closedSearchProjects = []; s.filterMode = s.listMode; s.contextDismissed = false; s.focus = .list
            s.markedProjectId = snap.context?.projectId; s.markedProjectInitialized = true; s.hasMarkedProject = false
            s.toast = nil; s.notes = [:]; s.help = false; s.mode = .list; s.focus = stripAvailable(s, snap) ? .strip : s.listMode == .resume && !snap.justEnded.isEmpty ? .banner : .list; s.openProjects = snap.context?.projectId.map { [$0] } ?? []
        case .openSettings: s.screen = .m02; return [.openSettings, .closePopover]
        default: break
        }
        normalize(&s, snap)
        return []
    }
    private static func chosenTool(_ event: UIEvent, _ snap: Snapshot) -> Tool {
        let tool = snap.settings.defaultTool
        return event == .shiftEnter ? (tool == .codex ? .claude : .codex) : tool
    }
    private static func start(_ s: inout UIState, entry: Entry, tool: Tool) -> [Intent] {
        return [s.goalMode ? .startGoal(entryId: entry.id, tool: tool, terminal: nil) : .startEntry(entryId: entry.id, tool: tool, terminal: nil)]
    }
    private static func ambiguousQuery(_ query: String, _ snap: Snapshot) -> String? {
        for word in query.split(whereSeparator: \.isWhitespace) where word.hasPrefix("@") && word.count > 1 {
            let fragment = String(word.dropFirst())
            if let match = Logic.resolveProject(snap, fragment), !match.unique { return fragment }
        }
        return nil
    }
    private static func ambiguousMessage(_ fragment: String, _ snap: Snapshot) -> Note {
        let names = snap.projects.filter { $0.name.lowercased().hasPrefix(fragment.lowercased()) }.map(\.name).joined(separator: " · ")
        return Note(kind: .warn, text: t("m01.toast.project_ambiguous", ["projects": names]))
    }
    private static func openSelection(_ id: String, _ s: inout UIState, _ snap: Snapshot) {
        let entry: Entry?
        if id.hasPrefix("e:") { entry = snap.entry(String(id.dropFirst(2))) }
        else if id.hasPrefix("s:"), let session = snap.session(String(id.dropFirst(2))) {
            entry = snap.entry(session.entryId)
            if let entry, !s.openEntries.contains(entry.id) { s.openEntries.append(entry.id) }
        } else { entry = nil }
        guard let entry else { return }
        let project = entry.projectId ?? "_none"
        if !s.openProjects.contains(project) { s.openProjects.append(project) }
        s.closedSearchProjects.removeAll { $0 == project }
    }
    private static func selectedEntry(_ s: UIState, _ snap: Snapshot) -> Entry? {
        guard let row = view(s, snap).rows.first(where: { $0.key == s.selectedId }), let id = row.type == "session" ? row.entryId : row.id else { return nil }
        return snap.entry(id)
    }
    private static func beginEdit(_ s: inout UIState, id: String, kind: UIState.EditKind, text: String) {
        s.mode = .edit; s.editKind = kind; s.editEntryId = id
        s.editText = text; s.editInitial = text; s.selectedId = "e:" + id
    }
    private static func saveEdit(_ s: inout UIState, _ snap: Snapshot) -> [Intent] {
        guard let id = s.editEntryId, let entry = snap.entry(id) else { return [] }
        let text = s.editText.trimmingCharacters(in: .whitespacesAndNewlines)
        var intents: [Intent] = []
        switch s.editKind {
        case .title:
            if !text.isEmpty { intents = [.setTitle(entryId: id, title: text)]; s.toast = Note(kind: .ok, text: t("m01.toast.title")) }
        case .deadline:
            if text.isEmpty {
                if entry.deadline != nil { intents = [.setDeadline(entryId: id, deadline: nil)]; s.toast = Note(kind: .ok, text: t("m01.toast.deadline_removed")) }
            } else {
                let value = text.replacingOccurrences(of: "^bis\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                guard let date = Logic.parseDeadline(snap, value) else { s.toast = Note(kind: .error, text: t("m01.toast.deadline_invalid", ["text": text])); return [] }
                intents = [.setDeadline(entryId: id, deadline: date)]
                s.toast = Note(kind: .ok, text: t("m01.toast.deadline", ["date": Logic.dueLong(snap, date)]))
            }
        case .project:
            if text.isEmpty { break }
            let fragment = text.hasPrefix("@") ? String(text.dropFirst()) : text
            guard let match = Logic.resolveProject(snap, fragment) else { s.toast = Note(kind: .error, text: t("m01.toast.project_unknown", ["text": text])); return [] }
            guard match.unique else { s.toast = ambiguousMessage(fragment, snap); return [] }
            intents = [.setProject(entryId: id, projectId: match.project.id)]
            s.toast = Note(kind: .ok, text: t("m01.toast.moved", ["project": match.project.name]))
        }
        s.mode = .list; s.editEntryId = nil; s.selectAll = false
        s.undoHint = !intents.isEmpty
        return intents
    }
    private static func chipify(_ s: inout UIState, _ snap: Snapshot) {
        while s.query.last?.isWhitespace == true {
            var words = s.query.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let word = words.popLast() else { break }
            if s.listMode == .ziel, let prefix = words.last, let date = Logic.deadlineAfter(prefix: prefix, word: word, snap) {
                words.removeLast()
                s.chips.removeAll { $0.kind == .deadline }
                s.chips.append(Chip(kind: .deadline, value: date, label: t("chip.deadline", ["date": Logic.dueLong(snap, date)])))
                s.query = words.isEmpty ? "" : words.joined(separator: " ") + " "
                continue
            }
            guard let chip = Logic.chipFor(snap, word, s.listMode.rawValue), let kind = Chip.Kind(rawValue: chip.kind) else { break }
            s.chips.removeAll { $0.kind == kind }
            s.chips.append(Chip(kind: kind, value: chip.value, label: chip.label))
            s.query = words.isEmpty ? "" : words.joined(separator: " ") + " "
        }
    }
    private static func help(_ snap: Snapshot) -> String {
            let items = [(snap.settings.hotkeys.popover + " ← →", "mode"), ("↵", "resume"), ("⇧↵", "claude"), ("⌥↵", "terminal"), ("⌘↵", "keep_start"), ("⌘G", "goal"), ("⌘C", "copy"), ("⌘P", "edit_title"), ("⌘D", "deadline"), ("⇥", "complete"), ("⌫", "chip"), ("⌘S", "status"), ("⌘↓ ⌘↑", "sessions"), ("⌘⌫", "done"), ("⌘Z", "undo"), ("⌘⇧W", "cleanup"), ("@ cc cx ? ! /a", "prefix"), (t("m01o1.due_keys"), "due"), ("↑ ↓", "move")]
            let title = h(t("m01o1.title"))
            return "<div class=\"help\" data-screen=\"M01-O1\" data-state=\"hilfe\" role=\"region\" aria-label=\"\(title)\"><h2 class=\"sr\">\(title)</h2>" + items.map { "<b>\(h($0.0))</b><span>\(h(t("m01o1." + $0.1)))</span>" }.joined() + "</div>"
    }

    static func render(_ s: UIState, _ snap: Snapshot) -> RenderedScreen {
        let v = view(s, snap)
        let selectedRow = v.rows.first { $0.key == s.selectedId }
        let current = selectedRow.flatMap { $0.type == "session" ? $0.entryId : $0.id }.flatMap { snap.entry($0) }
        let bannerFocus = s.listMode == .resume && s.focus == .banner && !snap.justEnded.isEmpty && s.mode == .list && !s.help
        let stripFocus = stripAvailable(s, snap) && s.focus == .strip && !s.help
        let listFocus = s.mode == .list && !bannerFocus && !stripFocus && !s.help
        let emptySearch = s.listMode == .resume && v.searching && v.keys.isEmpty
        let newTask = s.listMode == .ziel && !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let warn = s.listMode == .resume && !v.searching && !s.help && snap.windows.closable >= snap.settings.cleanupThreshold
        func pname(_ id: String?) -> String { id.map { snap.project($0)?.name ?? "?" } ?? t("project.none") }
        var chips = ""
        if let project = contextProject(s, snap), (s.listMode == .ziel || !v.searching), !s.chips.contains(where: { $0.kind == .project }) {
            chips += "<span class=\"chip soft\" title=\"\(h(t("a11y.context")))\" aria-label=\"\(h("@" + pname(project) + ", " + t("a11y.context")))\">@\(h(pname(project)))</span>"
        }
        chips += s.chips.map { "<span class=\"chip\($0.kind == .deadline ? " due" : "")\">\(h($0.label))</span>" }.joined()
        let ghost = listFocus ? Logic.ghostFor(snap, s.query) : ""
        let ph = s.query.isEmpty && s.chips.isEmpty ? "<span class=\"ph\">\(h(t("m01.search.placeholder." + s.listMode.rawValue)))</span>" : ""
        let mirror = h(s.query) + "<span class=\"ghost\">\(h(ghost))</span>" + ph
        let editFragment = s.editText.hasPrefix("@") ? String(s.editText.dropFirst()) : s.editText
        let editGhost = s.editKind == .project ? Logic.ghostProject(snap, editFragment) : ""
        let editPlaceholder = s.editText.isEmpty ? "<span class=\"ph\">\(h(t("m01.edit.\(s.editKind.rawValue)_ph")))</span>" : ""
        let editMirror = h(s.editText) + "<span class=\"ghost\">\(h(editGhost))</span>" + editPlaceholder
        var body = ""
        if stripAvailable(s, snap) && !v.searching && !s.help {
            body += "<div class=\"strip\" role=\"group\" aria-label=\"\(h(t("a11y.strip")))\"><div class=\"strip-head\">\(h(t("m01.strip.head")))</div>"
            for (i, change) in snap.changes.enumerated() {
                let e = snap.entry(change.entryId), done = change.kind.rawValue == "done"
                let title = e.map { Logic.titleOf(snap, $0) } ?? ""
                body += "<div class=\"chg\(stripFocus && i == s.stripIdx ? " sel" : "")\" data-act=\"stripSelect\" data-arg=\"\(i)\"><span class=\"g\">\(done ? "○" : "◇")</span><span class=\"ct\(done ? " done" : "")\">\(h(title))</span><span class=\"cp\">\(h(pname(e?.projectId)))</span><span class=\"tool \(change.by.rawValue)\">\(change.by.rawValue == "claude" ? "CC" : "CX")</span></div>"
            }
            let actions = [("stripAccept", "m01.strip.ok"), ("", "m01.strip.pick"), ("stripRevert", "m01.strip.revert")]
            let hint = actions.map { action, key in
                action.isEmpty ? h(t(key)) : "<button type=\"button\" class=\"strip-act\" data-act=\"\(action)\">\(h(t(key)))</button>"
            }.joined(separator: " · ")
            body += "<div class=\"strip-hint\">\(hint)</div></div>"
        }
        var bannerMirror = ""
        if s.listMode == .resume && s.mode == .list && !s.help, let id = snap.justEnded.first, let entry = snap.entry(id), let session = Logic.latest(snap, entry) {
            let head = t("m01.banner.head", ["tool": session.tool.short, "project": pname(entry.projectId), "ago": Logic.agoLong(snap, session.lastActivityAt)])
            let actions = [("bannerAccept", "m01.banner.accept"), ("", "m01.banner.type"), ("bannerName", "m01.banner.name"), ("bannerLater", "m01.banner.later")]
            let hint = actions.map { action, key in
                action.isEmpty ? h(t(key)) : "<button type=\"button\" class=\"banner-act\" data-act=\"\(action)\">\(h(t(key)))</button>"
            }.joined(separator: " · ")
            body += "<div class=\"banner\" role=\"group\" aria-label=\"\(h(t("a11y.banner")))\"><div class=\"banner-head\">\(h(head))</div><div class=\"banner-field\"><span class=\"lbl\">\(h(t("m01.banner.label")))</span><div class=\"field\"><input class=\"b\" data-act=\"bannerFocus\" value=\"\" aria-label=\"\(h(t("a11y.banner_input")))\" spellcheck=\"false\"><span class=\"mirror\" aria-hidden=\"true\" data-region=\"bmirror\"></span></div></div><div class=\"banner-hint\">\(hint)</div></div>"
            bannerMirror = h(s.bannerText) + (s.bannerText.isEmpty ? "<span class=\"ph it\">\(h(Logic.titleOf(snap, entry)))</span>" : "")
        }
        if !v.searching && !s.help, let urgent = Logic.urgentTasks(snap).first, let date = urgent.deadline {
            let count = Logic.urgentTasks(snap).count
            let message = t(count == 1 ? "m01.duehint.one" : "m01.duehint.many", ["n": String(count), "title": Logic.titleOf(snap, urgent), "date": Logic.dueShort(snap, date)])
            body += "<div class=\"winhint \(Logic.dueState(snap, urgent) ?? "")\"><span>\(h(message))</span><button type=\"button\" data-act=\"showDue\">\(h(t("m01.duehint.action")))</button></div>"
        }
        if warn { body += "<div class=\"winhint\"><span>\(h(t("m01.warn.text", ["open": snap.windows.open, "closable": snap.windows.closable])))</span><button type=\"button\" data-act=\"cleanup\">\(h(t("m01.warn.action")))</button></div>" }
        if !v.rows.isEmpty {
            let active = s.selectedId.map { " aria-activedescendant=\"opt-\(h($0))\"" } ?? ""
            body += "<div class=\"list\" id=\"rb-list\" role=\"listbox\" aria-label=\"\(h(t("a11y.list." + s.listMode.rawValue)))\"\(active)>"
            for row in v.rows {
                if row.type == "head" {
                    body += "<div class=\"ghead\" role=\"presentation\"><span>\(h(t("m01.group." + (row.id ?? ""))))</span><span>\(row.count ?? 0)</span></div>"
                    continue
                }
                if row.type == "proj", let key = row.key {
                    let summary = Logic.projectSummary(snap, row.id), name = pname(row.id), selected = key == s.selectedId
                    let label = t("a11y.project", ["project": name, "strands": String(summary.strands), "tasks": String(summary.tasks), "state": t(row.open == true ? "a11y.open" : "a11y.closed")])
                    let due = summary.due.flatMap(\.deadline).map { "<span class=\"due \(summary.dueState ?? "")\">\(h(Logic.dueShort(snap, $0)))</span>" } ?? ""
                    body += "<div class=\"prow\(row.open == true ? " open" : "")\(row.id == nil ? " none" : "")\(selected ? " sel" : "")\" role=\"option\" id=\"opt-\(h(key))\" aria-selected=\"\(selected)\" aria-label=\"\(h(label))\" data-sel=\"\(h(key))\" aria-expanded=\"\(row.open == true)\"><span class=\"arr\" aria-hidden=\"true\">\(row.open == true ? "▾" : "▸")</span><span class=\"pname\">\(h(name))</span><span class=\"psum\" aria-hidden=\"true\"><span>\(summary.strands) ● · \(summary.tasks) ◇</span>\(summary.wait ? "<span class=\"glyph wartet\">◐</span>" : "")\(due)</span></div>"
                    continue
                }
                if row.type == "session", let id = row.id, let session = snap.session(id), let key = row.key {
                    let selected = key == s.selectedId, running = session.live.running
                    let label = t("a11y.session", ["tool": session.tool.displayName, "title": session.suggestedTitle, "ago": running ? t("m01.row.running") : Logic.agoLong(snap, session.lastActivityAt)])
                    let note = s.notes[key].map { "<span class=\"note \($0.kind.rawValue)\">\(h($0.text))</span>" } ?? ""
                    body += "<div class=\"row child\(row.flat == true ? "" : " tree")\(selected ? " sel" : "")\" role=\"option\" id=\"opt-\(h(key))\" aria-selected=\"\(selected)\" aria-label=\"\(h(label))\" data-sel=\"\(h(key))\"><span class=\"tool \(session.tool.rawValue)\">└ \(session.tool.short)</span><div class=\"tcell\"><span class=\"title\">\(h(session.suggestedTitle.isEmpty ? session.firstPrompt : session.suggestedTitle))</span>\(note)</div><span class=\"ago\(running ? " run" : "")\">\(h(running ? t("m01.row.running") : Logic.agoShort(snap, session.lastActivityAt)))</span><span class=\"glyph\"></span></div>"
                    continue
                }
                guard row.type == "entry", let id = row.id, let e = snap.entry(id), let key = row.key else { continue }
                let selected = key == s.selectedId, pn = pname(e.projectId)
                let ds = Logic.dueState(snap, e)
                let due = e.deadline.map { Logic.dueShort(snap, $0) } ?? ""
                let dueA = e.deadline.map { t("a11y.due", ["date": Logic.dueLong(snap, $0)]) + (ds == "overdue" ? ", " + t("a11y.overdue") : "") } ?? t("a11y.nodue")
                let rowTitle = Logic.titleOf(snap, e).isEmpty ? t("m01.row.untitled") : Logic.titleOf(snap, e)
                let label = Logic.latest(snap, e).map { t("a11y.strang", ["tool": $0.tool.displayName, "project": pn, "title": rowTitle, "status": t("status." + e.status.rawValue), "ago": Logic.entryRunning(snap, e) ? t("m01.row.running") : Logic.agoLong(snap, Logic.lastActivity(snap, e)), "due": dueA]) } ?? t("a11y.task", ["project": pn, "title": rowTitle, "due": dueA])
                let str = Logic.isStrang(snap, e)
                let noteText: String? = Logic.isArchived(snap, e) ? t("m01.row.archived") : str ? (Logic.sessionsOf(snap, e).count > 1 ? t("m01.row.sessions", ["count": Logic.sessionsOf(snap, e).count]) : nil) : (e.createdBy == .user ? nil : t("m01.row.by_ai", ["tool": e.createdBy == .claude ? "CC" : "CX"]))
                let note = s.notes[key].map { "<span class=\"note \($0.kind.rawValue)\">\(h($0.text))</span>" } ?? noteText.map { "<span class=\"note muted\">\(h($0))</span>" } ?? ""
                let latest = Logic.latest(snap, e)
                let running = Logic.entryRunning(snap, e)
                let dueClass = ds.map { " due " + $0 } ?? ""
                let toolClass = latest?.tool.rawValue ?? "task"
                let toolLabel = latest.map { $0.tool == .codex ? "● CX" : "● CC" } ?? "◇"
                let showDue = ds != nil
                let right = running ? t("m01.row.running") : showDue ? due : str ? Logic.agoShort(snap, Logic.lastActivity(snap, e)) : ""
                let editing = selected && s.mode == .edit && s.editEntryId == id
                let editLabel = s.editKind == .title ? nil : t("m01.edit.\(s.editKind.rawValue)_label")
                let labelHTML = editLabel.map { "<span class=\"lbl\">\(h($0))</span>" } ?? ""
                let input = "<span class=\"eline\">\(labelHTML)<span class=\"field\"><input class=\"e\" value=\"\(h(s.editInitial))\" aria-label=\"\(h(editLabel ?? t("a11y.edit_input")))\" spellcheck=\"false\" autocomplete=\"off\"><span class=\"mirror\" aria-hidden=\"true\" data-region=\"emirror\"></span></span></span>"
                let title = editing && s.editKind == .title ? input : "<span class=\"title\(str && (e.title ?? "").isEmpty ? " unpinned" : "")\(e.status == .erledigt ? " done" : "")\">\(h(rowTitle))</span>"
                let buttons: String
                if selected && !str && s.mode == .list && Logic.isOpen(e) && !(s.trainer.map { $0.success || $0.lesson >= TrainerLessons.all.count } ?? false) {
                    let tools: [Tool] = snap.settings.defaultTool == .codex ? [.codex, .claude] : [.claude, .codex]
                    buttons = "<span class=\"start-buttons\">" + tools.enumerated().map { index, tool in
                        "<button type=\"button\" data-act=\"startWith\" data-arg=\"\(tool.rawValue)\">\(h(t("m01.start." + tool.rawValue))) \(index == 0 ? "↵" : "⇧↵")</button>"
                    }.joined() + "<button type=\"button\" data-act=\"toggleGoal\" aria-pressed=\"\(s.goalMode)\" class=\"\(s.goalMode ? "on" : "")\">\(h(t("m01.start.goal"))) ⌘G</button></span>"
                } else { buttons = "" }
                let sub = editing && s.editKind != .title ? input : note + buttons
                body += "<div class=\"row\(row.flat == true ? "" : " tree")\(selected ? " sel" : "")\" role=\"option\" id=\"opt-\(h(key))\" aria-selected=\"\(selected)\" aria-label=\"\(h(label))\" data-sel=\"\(h(key))\"><span class=\"tool \(toolClass)\" aria-hidden=\"true\">\(toolLabel)</span>\(row.flat == true ? "<span class=\"proj\(e.projectId == nil ? " none" : "")\">\(h(pn))</span>" : "")<div class=\"tcell\">\(title)\(sub)</div><span class=\"ago\(running ? " run" : showDue ? dueClass : "")\">\(h(right))</span><span class=\"glyph \(str ? e.status.rawValue : "")\" aria-hidden=\"true\">\(str ? e.status.glyph : "")</span></div>"
            }
            body += "</div>"
        }
        if snap.entries.isEmpty && s.listMode != .ziel && !emptySearch {
            body += "<div class=\"empty\"><div class=\"msg strong\">\(h(t("m01.empty.none")))</div><div class=\"msg\">\(h(t("m01.empty.none_detail", ["claude": snap.settings.watch.claude, "codex": snap.settings.watch.codex])))</div></div>"
        } else if emptySearch {
            let project = creationProject(s, snap)
            let q = (s.chips.map(\.label) + (s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [s.query.trimmingCharacters(in: .whitespacesAndNewlines)])).joined(separator: " ")
            body += "<div class=\"empty\"><div class=\"msg\">\(h(t("m01.empty.search", ["query": q])))</div>"
            if !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body += "<button type=\"button\" class=\"new primary\" data-act=\"enter\"><span>\(h(t("m01.empty.new_codex", ["project": project.map(pname) ?? t("m01.empty.start_folder")])))</span><span class=\"tool codex\">CX</span></button><button type=\"button\" class=\"new\" data-act=\"shiftEnter\"><span>\(h(t("m01.empty.new_claude", ["project": project.map(pname) ?? t("m01.empty.start_folder")])))</span><span class=\"tool claude\">CC</span></button>"
            } else { body += "<div class=\"msg\">\(h(t("m01.empty.no_context")))</div>" }
            body += "</div>"
        } else if s.listMode == .ziel && v.keys.isEmpty && !newTask { body += "<div class=\"empty\"><div class=\"msg\">\(h(t("m01.empty.tasks")))</div></div>" }
        body += Renderer.toastRegion
        var detail = ""
        if current == nil && !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !s.help {
            let project = creationProject(s, snap)
            let deadline = s.chips.first { $0.kind == .deadline }?.value
            let text = t(deadline == nil ? "m01.detail.new_task" : "m01.detail.new_task_due", ["project": pname(project), "date": deadline.map { Logic.dueLong(snap, $0) } ?? ""])
            detail = "<div class=\"d-path\">\(h(text))</div><div class=\"d-cmd\">\(h(t("m01.detail.quoted", ["text": s.query.trimmingCharacters(in: .whitespacesAndNewlines)])))</div>"
        } else if let e = current, let latest = Logic.latest(snap, e), !s.help && !bannerFocus && !stripFocus && !emptySearch {
            let session = selectedRow?.type == "session" ? selectedRow?.id.flatMap { snap.session($0) } ?? latest : latest
            let home = session.cwd.replacingOccurrences(of: "^/Users/[^/]+", with: "~", options: .regularExpression)
            let count = Logic.sessionsOf(snap, e).count
            var parts = [home, count > 1 ? t("m01.detail.sessions", ["count": count]) : session.resumeCount > 1 ? t("m01.detail.resumes", ["count": session.resumeCount]) : t("m01.detail.new")]
            if session.live.running { parts.append(t("m01.detail.tty", ["tty": session.live.tty ?? ""])) }
            if let tokens = session.tokens, tokens != 0 { parts.append(t("m01.detail.tokens", ["n": Logic.tokensM(tokens)])) }
            if let deadline = e.deadline { parts.append(t("chip.deadline", ["date": Logic.dueLong(snap, deadline)])) }
            detail = "<div class=\"d-path\">\(h(parts.joined(separator: " · ")))</div><div class=\"d-cmd\">\(h("$ " + Logic.command(session, snap)))</div>"
        } else if let e = current, Logic.latest(snap, e) == nil, !s.help && !bannerFocus && !stripFocus && !emptySearch {
            let path = t("m01.detail.task", ["project": pname(e.projectId), "by": t("by." + e.createdBy.rawValue), "date": Logic.agoLong(snap, e.createdAt)])
            let due = e.deadline.map { t("m01.detail.task_due", ["date": Logic.dueLong(snap, $0)]) } ?? t("m01.detail.task_nodue")
            detail = "<div class=\"d-path\">\(h(path))</div><div class=\"d-cmd\">\(h(due))</div>"
        }
        if s.help { body = help(snap) }
        if let trainer = s.trainer {
            let keys = ["popover": snap.settings.hotkeys.popover, "task": snap.settings.hotkeys.task, "pin": snap.settings.hotkeys.pin]
            func resolve(_ text: String) -> String {
                keys.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
            }
            let final = trainer.lesson >= 7
            let progress = t(final ? "trainer.final_progress" : "trainer.progress", ["n": String(final ? min(trainer.lesson - 6, 3) : trainer.lesson + 1), "total": final ? "3" : "7"])
            let content: String
            if trainer.lesson >= TrainerLessons.all.count {
                let resultKey = trainer.passed == TrainerLessons.all.count ? "trainer.end_result" : "trainer.end_partial"
                content = "<div>\(h(t(resultKey, ["done": String(trainer.passed), "n": String(trainer.finalWithoutTip)])))</div><div>\(h(resolve(t("trainer.end_more"))))</div><div>\(h(t("trainer.finish")))</div>"
            } else {
                let lesson = TrainerLessons.all[trainer.lesson]
                var lines = "<div class=\"trainer-title\"><strong>\(h(t(lesson.titleKey)))</strong>"
                if !trainer.success { lines += "<span>\(h(t("trainer.skip")))</span>" }
                lines += "</div>"
                if let wrong = trainer.wrongKey { lines += "<div class=\"trainer-wrong\">\(h(t(wrong)))</div>" }
                if trainer.success {
                    let message = lesson.blind ? t(trainer.tipped ? "trainer.success_tipped" : "trainer.success_free") : t("trainer.success_way", ["way": resolve(t(lesson.wayKey))])
                    let next = trainer.lesson == 6 ? "trainer.to_final" : (lesson.blind ? "trainer.next_task" : "trainer.next_lesson")
                    lines += "<div>\(h(message))</div><div>\(h(t(next)))</div>"
                } else {
                    if lesson.blind && !trainer.tipped { lines += "<div class=\"trainer-hint\">\(h(t("trainer.final_hint")))</div>" }
                    if !lesson.blind || trainer.tipped {
                        let facts = TrainerFacts(state: s, snapshot: snap), current = lesson.currentStep(facts)
                        lines += "<ol class=\"trainer-steps\">"
                        for (index, step) in lesson.steps.enumerated() {
                            let done = current.map { index < $0 } ?? true
                            let marker = done ? "✓" : (current == index ? "▸" : " ")
                            lines += "<li class=\"\(current == index ? "current" : "dim")\"><span>\(marker)</span><kbd>\(h(resolve(step.label)))</kbd><span>\(h(t(step.textKey)))</span></li>"
                        }
                        lines += "</ol>"
                    }
                }
                content = lines
            }
            let exitKey = !s.query.isEmpty || s.mode == .edit ? "trainer.exit_back" : "trainer.exit"
            body = "<div class=\"trainer\" role=\"status\"><div class=\"trainer-head\"><span>\(h(progress))</span><span>\(h(t(exitKey)))</span></div>\(content)</div>" + body
        }
        var hints: [(String, String, String)]
        if s.help { hints = [("⌘T", "practice", "trainer"), ("esc", "close", "cancel")] }
        else if s.mode == .edit { hints = s.editKind == .project ? [("⇥", "complete", "complete"), ("↵", "save", "enter"), ("esc", "cancel", "cancel")] : [("↵", "save", "enter"), ("esc", "cancel", "cancel")] }
        else if stripFocus { hints = [("↵", "ok", "enter"), ("⌘⌫", "discard", "stripRevert")] }
        else if bannerFocus { hints = [("⇥", "suggest", "complete"), ("↵", "name", "enter"), ("esc", "later", "cancel")] }
        else if newTask { hints = [("↵", "keep", "enter"), ("⌘↵", "keep_start", "cmdEnter"), ("esc", "clear", "cancel")] }
        else if emptySearch { hints = !s.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [("↵", "new_codex", "enter"), ("⇧↵", "new_claude", "shiftEnter"), ("esc", "back", "cancel")] : [("esc", "back", "cancel")] }
        else if snap.entries.isEmpty { hints = [("⌘/", "help", "help")] }
        else if !ghost.isEmpty { hints = [("⇥", "complete", "complete"), ("↵", "resume", "enter")] }

        else if selectedRow == nil { hints = [("⌘/", "help", "help")] }
        else if selectedRow?.type == "proj" { hints = [("↵", "toggle", "enter")] }
        else if selectedRow?.type == "session", let session = selectedRow?.id.flatMap({ snap.session($0) }) {
            hints = session.live.running || session.resumable ? [("↵", session.live.running ? "focus" : "resume", "enter"), ("⌘C", "copy", "copy")] : [("⌘C", "copy", "copy")]
        }
        else if let e = current, let latest = Logic.latest(snap, e) {
            hints = [latest.live.running || latest.resumable ? ("↵", latest.live.running ? "focus" : "resume", "enter") : ("⌘⌫", "done", "archive"), ("⌘D", "deadline", "editDeadline"), ("⌘P", "title", "edit")]
        } else { hints = [("↵", "start", "enter"), ("⌘D", "deadline", "editDeadline"), ("⇥", "project", "complete")] }
        if listFocus && s.query.isEmpty && !hints.contains(where: { $0.1 == "help" || $0.1 == "back" }) { hints.append(warn && current.flatMap({ Logic.latest(snap, $0) }) == nil ? ("⌘⇧W", "cleanup", "cleanup") : ("← →", "mode", "modeNext")) }
        if s.undoHint && s.toast != nil { hints = Array(([("⌘Z", "undo", "undo")] + hints.filter { $0.1 != "undo" }).prefix(4)) }
        if s.trainer != nil { hints = [] }
        let buttons = hints.map { glyph, key, action in
            let label = t("m01.hint." + key)
            return "<button type=\"button\" data-act=\"\(action)\" aria-label=\"\(h(t("a11y.hint", ["label": label, "key": glyph])))\"><b>\(h(glyph))</b> \(h(label))</button>"
        }.joined()
        let skeleton = Renderer.m01Skeleton.replacingOccurrences(of: h(t("m01.mode.resume")), with: h(t("m01.mode." + s.listMode.rawValue))).replacingOccurrences(of: h(t("m01.search.label")), with: h(t("m01.search.label." + s.listMode.rawValue)))
        var regions = [("chips", chips), ("mirror", mirror), ("key", ghost.isEmpty ? "" : "<span class=\"key\" aria-hidden=\"true\">⇥</span>"), ("legend", s.listMode == .resume && !s.chips.isEmpty && !s.help ? "<div class=\"legend\" aria-hidden=\"true\">" + ["project", "tool", "wartet", "erledigt", "archive"].map { "<span>\(h(t("m01.legend." + $0)))</span>" }.joined() + "</div>" : ""), ("body", body)]
        if body.contains("data-region=\"bmirror\"") { regions.append(("bmirror", bannerMirror)) }
        if body.contains("data-region=\"emirror\"") { regions.append(("emirror", editMirror)) }
        if body.contains("data-region=\"toast\"") { regions.append(("toast", Renderer.toast(s.toast))) }
        let symbols = !snap.entries.isEmpty ? "<div class=\"symbols\" aria-hidden=\"true\">\(h(t("m01.legend.symbols")))</div>" : ""
        regions.append(("footer", detail + "<div class=\"hints\">" + buttons + "</div>" + symbols))
        return RenderedScreen(screen: .m01, skeleton: skeleton, regions: regions, focus: s.mode == .edit ? "e" : bannerFocus ? "b" : "q", selectAll: s.mode == .edit && s.selectAll, fieldValues: s.mode == .edit ? ["q": s.query, "e": s.editText] : bannerFocus ? ["q": s.query, "b": s.bannerText] : ["q": s.query])
    }
}
