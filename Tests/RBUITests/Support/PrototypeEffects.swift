// Prototype effects for fixture replay; no real services or terminal calls.

import Foundation
import RBContract
import RBUI

struct PrototypeEffects {
    var missingDirectories: Set<String> = []
    private var undoV2: [(String, Snapshot)] = []
    mutating func apply(_ intent: Intent, to snap: inout Snapshot) -> IntentResult? {
        let now = snap.now
        func entryIndex(_ id: String) -> Int? { snap.entries.firstIndex { $0.id == id } }
        func push(_ label: String) {
            undoV2.append((label, snap))
            if undoV2.count > 20 { undoV2.removeFirst() }
        }
        switch intent {
        case let .resumeEntry(id, sessionId, terminal):
            let sessions = snap.sessions(of: id)
            guard let session = sessionId.map({ sid in sessions.first { $0.id == sid } }) ?? sessions.first else { return nil }
            guard session.resumable else { return .notResumable(sessionId: session.id, path: session.transcriptPath) }
            if session.live.running { return .focused(app: session.live.terminalApp ?? snap.settings.terminal.default, sessionId: session.id) }
            if missingDirectories.contains(session.cwd) { return .folderMissing(path: session.cwd) }
            let app = terminal ?? snap.settings.terminal.default
            if let i = snap.sessions.firstIndex(where: { $0.id == session.id }) {
                snap.windows.open += 1
                snap.sessions[i].live = Live(running: true, pid: nil, tty: "ttys0\(10 + i)", terminalApp: app, windowIndex: snap.windows.open)
                snap.sessions[i].resumeCount += 1; snap.sessions[i].lastActivityAt = now; snap.sessions[i].updatedAt = now
            }
            return .opened(app: app, sessionId: session.id)
        case let .startEntry(id, tool, terminal), let .startGoal(id, tool, terminal):
            guard let entry = snap.entry(id), entry.title != nil else { return .entrySaveFailed(entryId: id) }
            let folder = snap.project(entry.projectId)?.rootPath ?? Logic.startFolder(settings: snap.settings, projects: snap.projects, home: FileManager.default.homeDirectoryForCurrentUser.path)
            if missingDirectories.contains(folder) { return .folderMissing(path: folder) }
            push(t("undo.start"))
            let app = terminal ?? snap.settings.terminal.default, n = snap.sessions.count + 1
            snap.windows.open += 1
            snap.sessions.append(Session(id: "new_\(n)", tool: tool, nativeId: t("m01.session.pending"), entryId: id,
                projectId: entry.projectId, cwd: folder, transcriptPath: "", startedAt: now,
                lastActivityAt: now, tokens: nil, firstPrompt: entry.title ?? "", threadName: nil,
                suggestedTitle: entry.title ?? "", resumable: true, resumeCount: 1,
                live: Live(running: true, pid: nil, tty: "ttys0\(20 + n)", terminalApp: app, windowIndex: snap.windows.open),
                createdAt: now, updatedAt: now))
            return .opened(app: app, sessionId: nil)
        case let .addTask(title, project, deadline, start):
            let id = "e_new\(snap.entries.count + 1)"
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...200).contains(title.count) else { return .entrySaveFailed(entryId: id) }
            push("Ziel")
            snap.entries.append(Entry(id: id, projectId: project, title: title, status: .offen, deadline: deadline, createdBy: .user, createdAt: now, updatedAt: now))
            if let start, let result = apply(.startEntry(entryId: id, tool: start, terminal: nil), to: &snap) {
                if case .opened = result {} else { return result }
                undoV2.removeLast()
            }
            return .taskAdded(entryId: id)
        case let .newStrang(title, project, tool, terminal):
            let id = "e_new\(snap.entries.count + 1)"
            push("Starten")
            snap.entries.append(Entry(id: id, projectId: project, title: title, status: .offen, createdBy: .user, createdAt: now, updatedAt: now))
            let result = apply(.startEntry(entryId: id, tool: tool, terminal: terminal), to: &snap)
            if case .opened = result { undoV2.removeLast(); return .taskAdded(entryId: id) }
            return result
        case let .setTitle(id, title):
            guard let i = entryIndex(id) else { return .entrySaveFailed(entryId: id) }
            push("Titel"); snap.entries[i].title = title; snap.entries[i].updatedAt = now
            return .entryTitleSet(entryId: id)
        case let .setDeadline(id, deadline):
            guard let i = entryIndex(id) else { return .entrySaveFailed(entryId: id) }
            push("Deadline"); snap.entries[i].deadline = deadline; snap.entries[i].updatedAt = now
            return .deadlineSet(entryId: id, deadline: deadline)
        case let .setProject(id, project):
            guard let i = entryIndex(id), snap.sessions(of: id).isEmpty, snap.project(project) != nil else { return .entrySaveFailed(entryId: id) }
            push("Projekt"); snap.entries[i].projectId = project; snap.entries[i].updatedAt = now
            return .projectSet(entryId: id)
        case let .cycleStatus(id):
            guard let i = entryIndex(id), let newest = snap.sessions(of: id).first else { return .entrySaveFailed(entryId: id) }
            push(t("undo.status"))
            let from = snap.entries[i].status
            if snap.entries[i].title == nil { snap.entries[i].title = newest.suggestedTitle }
            snap.entries[i].status = from.next; snap.entries[i].statusChangedAt = now; snap.entries[i].updatedAt = now
            return .entryStatusSet(entryId: id, from: from, to: from.next)
        case let .archiveEntry(id):
            guard let i = entryIndex(id) else { return .entrySaveFailed(entryId: id) }
            push(t("undo.archive")); snap.entries[i].status = .erledigt; snap.entries[i].statusChangedAt = now
            snap.entries[i].archivedAt = now; snap.entries[i].updatedAt = now
            return .entryArchived(entryId: id)
        case let .nameJustEnded(id, title):
            guard let i = entryIndex(id), let suggestion = snap.sessions(of: id).first?.suggestedTitle else { return .entrySaveFailed(entryId: id) }
            push("Benennen"); snap.entries[i].title = title ?? suggestion; snap.entries[i].updatedAt = now
            snap.justEnded.removeAll { $0 == id }
            return .entryTitleSet(entryId: id)
        case .acceptChanges:
            if !snap.changes.isEmpty { push("Änderungen bestätigen"); snap.changes.removeAll() }
            return .changesAccepted
        case let .revertChange(id):
            guard let change = snap.changes.first(where: { $0.id == id }), let i = entryIndex(change.entryId) else { return nil }
            let title = snap.entries[i].title ?? snap.sessions(of: change.entryId).first?.suggestedTitle ?? ""
            push("Änderung zurücknehmen")
            switch change.kind {
            case .add:
                snap.entries.remove(at: i)
                for sessionIndex in snap.sessions.indices where snap.sessions[sessionIndex].entryId == change.entryId {
                    let session = snap.sessions[sessionIndex]
                    let id = "e_" + UUID().uuidString.lowercased()
                    snap.entries.append(Entry(id: id, projectId: session.projectId, title: nil, status: .offen,
                                              createdBy: .user, createdAt: session.startedAt, updatedAt: session.startedAt))
                    snap.sessions[sessionIndex].entryId = id
                }
                snap.changes.removeAll { $0.entryId == change.entryId }; snap.justEnded.removeAll { $0 == change.entryId }
            case .done:
                snap.entries[i].status = .offen; snap.entries[i].archivedAt = nil; snap.entries[i].doneBy = nil
                snap.entries[i].statusChangedAt = now; snap.entries[i].updatedAt = now; snap.changes.removeAll { $0.id == id }
            }
            return .changeReverted(title: title)
        case let .panelName(sessionId, title):
            guard let id = snap.session(sessionId)?.entryId else { return nil }
            return apply(.setTitle(entryId: id, title: title), to: &snap)
        case .undo:
            guard let (label, previous) = undoV2.popLast() else { return .undoEmpty }
            snap = previous; return .undone(label: label)
        case .cleanupWindows:
            let n = snap.windows.closable
            guard n > 0 else { return nil }
            push(t("undo.cleanup")); snap.windows.open -= n; snap.windows.closable = 0
            return .windowsClosed(count: n)
        case let .copyCommand(id):
            guard let session = snap.session(id) else { return nil }
            return .copied(command: Logic.command(session, snap))
        default: return nil
        }
    }

}
