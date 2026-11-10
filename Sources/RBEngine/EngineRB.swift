import Foundation
import RBContract
import RBServer
import RBUI

private func rbCreationOrder(_ a: Entry, _ b: Entry) -> Bool {
    a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
}

/// Returns every matching open entry in the selected project, preferring an exact ID.
func findRBEntries(_ query: String, entries: [Entry], projectId: String?, sessions: [Session], changes: [Change], title: (Entry) -> String) -> [Entry] {
    let eligible = entries.filter { entry in entry.projectId == projectId && entry.archivedAt == nil && entry.status != .erledigt && !Logic.saysNothing(entry, hasSession: sessions.contains { $0.entryId == entry.id }, hasChange: changes.contains { $0.entryId == entry.id }) }
    let exact = eligible.filter { $0.id == query }
    return (exact.isEmpty ? eligible.filter { title($0).localizedCaseInsensitiveContains(query) } : exact).sorted(by: rbCreationOrder)
}

extension Engine {
    public func handle(_ request: RBRequest, from caller: RBCallerInfo) async -> RBResponse {
        guard !Task.isCancelled, (trainerSaved?.0 ?? snapshot).settings.ai.enabled else { return .failed(.accessOff, matches: []) }
        let real = trainerSaved?.0 ?? snapshot
        let ownId = ContextProject.resolve(Context(projectId: nil, source: nil, cwd: caller.cwd, windowIndex: nil), in: real)?.projectId
        let ownName = real.project(ownId)?.name
        if let error = rights(request, caller: caller.caller, ownProject: ownName) { return .failed(error, matches: []) }
        let name: String?
        switch request {
        case .list(_, let project), .add(_, _, let project), .start(_, _, let project),
             .done(_, let project), .setDeadline(_, _, let project): name = project
        case .export: name = nil
        }
        var projectId = ownId
        if let name {
            let matching = real.projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard matching.count <= 1 else { return .failed(.ambiguous, matches: []) }
            guard let project = matching.first else { return .failed(.notFound, matches: []) }
            projectId = project.id
            if caller.caller != .person && project.id != ownId { return .failed(.foreignProject, matches: []) }
        }
        func line(_ entry: Entry, changes: [Change]) -> RBEntryLine {
            let title = Logic.titleOf(real, entry)
            return RBEntryLine(id: entry.id, title: title.isEmpty ? t("m01.row.untitled") : title,
                        status: entry.status, projectName: real.project(entry.projectId)?.name,
                        deadline: entry.deadline, sessionCount: real.sessions(of: entry.id).count,
                        awaitsConfirmation: changes.contains { $0.entryId == entry.id })
        }
        switch request {
        case .list(let all, _):
            do {
                let entries = try await services.store.loadEntries()
                let changes = try await services.store.loadChanges()
                guard !Task.isCancelled, (trainerSaved?.0 ?? snapshot).settings.ai.enabled else { return .failed(.accessOff, matches: []) }
                return .entries(entries.filter { entry in !Logic.isArchived(real, entry) && entry.status != .erledigt && (all || entry.projectId == projectId) && !Logic.saysNothing(entry, hasSession: real.sessions.contains { $0.entryId == entry.id }, hasChange: changes.contains { $0.entryId == entry.id }) }.sorted(by: rbCreationOrder).map { line($0, changes: changes) })
            } catch { return .failed(.storeFailed, matches: []) }
        case .add(let text, let word, _):
            let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : $0
            }))
            let title = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard (1...200).contains(title.count), title.utf8.count <= 800 else { return .failed(.badRequest, matches: []) }
            var dated = real; dated.now = clock()
            let deadline = word.flatMap { Logic.parseDeadline(dated, $0) }
            if word != nil && deadline == nil { return .failed(.invalidDeadline, matches: []) }
            let now = clock()
            let actor: Actor = caller.caller == .person ? .user : (caller.caller == .claude ? .claude : .codex)
            let entry = Entry(id: "e_" + UUID().uuidString.lowercased(), projectId: projectId, title: title,
                              status: .offen, deadline: deadline, createdBy: actor, createdAt: now, updatedAt: now)
            do {
                guard !Task.isCancelled, (trainerSaved?.0 ?? snapshot).settings.ai.enabled else { return .failed(.accessOff, matches: []) }
                var changes: [Change] = []
                if actor == .user {
                    try await services.store.save(entry, undoLabel: t("undo.add"))
                } else {
                    let change = Change(id: "c_" + UUID().uuidString.lowercased(), kind: .add, entryId: entry.id, by: actor, at: now)
                    try await services.store.save(entry, change: change, undoLabel: t("undo.add"))
                    changes = [change]
                }
                await rebuildAndPush()
                return .entry(line(entry, changes: changes))
            } catch { return .failed(.storeFailed, matches: []) }
        case .export:
            do {
                struct Counts: Encodable { let counts: [String: Int]; let historyImportVersion: Int; let counted: [CountedProcess] }
                struct Export: Encodable {
                    let entries: [Entry]; let links: [String: String]; let changes: [Change]
                    let settings: Settings; let resumeCounts: Counts
                }
                let state = try await services.store.loadResumeCountState()
                let value = try await Export(entries: services.store.loadEntries(), links: services.store.loadLinks(),
                                             changes: services.store.loadChanges(), settings: services.store.loadSettings(),
                                             resumeCounts: Counts(counts: state.counts, historyImportVersion: state.historyImportVersion, counted: state.counted))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                return .exported(json: String(decoding: try encoder.encode(value), as: UTF8.self))
            } catch { return .failed(.storeFailed, matches: []) }
        case .start, .done, .setDeadline:
            do {
                let entries = try await services.store.loadEntries()
                let changes = try await services.store.loadChanges()
                let eligible = entries.filter { entry in entry.projectId == projectId && entry.archivedAt == nil && entry.status != .erledigt && !Logic.saysNothing(entry, hasSession: real.sessions.contains { $0.entryId == entry.id }, hasChange: changes.contains { $0.entryId == entry.id }) }
                let query: String?
                switch request {
                case .start(let q, _, _), .setDeadline(let q, _, _): query = q
                case .done(let q, _): query = q
                default: query = nil
                }
                let matches: [Entry]
                if let query {
                    matches = findRBEntries(query, entries: entries, projectId: projectId, sessions: real.sessions, changes: changes) { line($0, changes: changes).title }
                } else {
                    let session = caller.processChain.lazy.compactMap { pid in
                        real.sessions.first { $0.live.running && $0.live.pid == Int(pid) }
                    }.first
                    matches = eligible.filter { $0.id == session?.entryId }
                }
                guard !matches.isEmpty else { return .failed(.notFound, matches: []) }
                guard matches.count == 1 else { return .failed(.ambiguous, matches: matches.map { line($0, changes: changes) }) }
                var entry = matches[0]
                guard !Task.isCancelled, (trainerSaved?.0 ?? snapshot).settings.ai.enabled else { return .failed(.accessOff, matches: []) }
                switch request {
                case .done:
                    let now = clock()
                    let actor: Actor = caller.caller == .person ? .user : (caller.caller == .claude ? .claude : .codex)
                    entry.status = .erledigt; entry.statusChangedAt = now; entry.updatedAt = now; entry.archivedAt = now; entry.doneBy = actor
                    var pending = changes
                    if actor == .user { try await services.store.save(entry, undoLabel: t("undo.archive")) }
                    else {
                        let change = Change(id: "c_" + UUID().uuidString.lowercased(), kind: .done, entryId: entry.id, by: actor, at: now)
                        try await services.store.save(entry, change: change, undoLabel: t("undo.archive")); pending.append(change)
                    }
                    await rebuildAndPush(); return .entry(line(entry, changes: pending))
                case .start(_, let tool, _):
                    var current = real; current.entries = entries
                    let result = await run(.startEntry(entryId: entry.id, tool: tool ?? real.settings.defaultTool, terminal: nil), services, current)
                    guard case .opened = result else { return .failed(.startFailed, matches: []) }
                    return .entry(line(entry, changes: changes))
                case .setDeadline(_, let word, _):
                    var dated = real; dated.now = clock()
                    let deadline = word.flatMap { Logic.parseDeadline(dated, $0) }
                    if word != nil && deadline == nil { return .failed(.invalidDeadline, matches: []) }
                    entry.deadline = deadline; entry.updatedAt = clock()
                    try await services.store.save(entry, undoLabel: t("undo.deadline"))
                    await rebuildAndPush(); return .entry(line(entry, changes: changes))
                default: return .failed(.badRequest, matches: [])
                }
            } catch { return .failed(.storeFailed, matches: []) }
        }
    }
}
