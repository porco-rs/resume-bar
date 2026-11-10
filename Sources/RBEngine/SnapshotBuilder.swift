// Merges index, user fields and live data into the Snapshot the UI renders.
// Assigns strands and persists recovered project associations.

import Foundation
import OSLog
import RBContract
import RBUI

/// Serializes assignment across overlapping index and live updates.
public actor SessionAssignment {
    public init() {}
    private struct Pending {
        let id: UUID
        let entryID: String
        let folder: String
        let started: Date
        let known: Set<String>
    }
    private var pending: [Pending] = []
    private var automatic: [String: Entry] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    public func started(entryID: String, folder: String, at: Date, known: Set<String>) async -> UUID {
        await acquire(); defer { release() }
        let id = UUID()
        pending.append(Pending(id: id, entryID: entryID, folder: folder, started: at, known: known))
        return id
    }
    public func cancel(_ id: UUID) async {
        await acquire(); defer { release() }
        pending.removeAll { $0.id == id }
    }
    func assign(index: IndexResult, store: any EntryStoring, live: LiveState, now: Date) async throws -> [String: String] {
        await acquire(); defer { release() }
        var links = try await store.loadLinks()
        var entries = Dictionary(uniqueKeysWithValues: try await store.loadEntries().map { ($0.id, $0) })
        let changes = try await store.loadChanges()
        pending.removeAll { now.timeIntervalSince($0.started) > 10 }
        for session in index.sessions.sorted(by: { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }) {
            let hint = live.entryHints[session.id]
            var target: String?
            if let hint {
                if let entry = entries[hint], entry.archivedAt == nil { target = hint }
            } else if links[session.id] == nil,
                      let i = pending.firstIndex(where: { $0.folder == session.cwd && !$0.known.contains(session.id) && now >= $0.started && now.timeIntervalSince($0.started) <= 10 && entries[$0.entryID]?.archivedAt == nil && entries[$0.entryID] != nil }) {
                target = pending.remove(at: i).entryID
            }
            if let target, links[session.id] != target {
                if let old = links[session.id] {
                    guard let generated = automatic[session.id], generated.id == old, entries[old] == generated,
                          links.values.filter({ $0 == old }).count == 1,
                          !changes.contains(where: { $0.entryId == old }) else { continue }
                    try await store.link([session.id], to: target, undoLabel: nil)
                    links[session.id] = target
                    try await store.delete(entryId: old, undoLabel: nil)
                    entries[old] = nil; automatic[session.id] = nil
                } else {
                    try await store.link([session.id], to: target, undoLabel: nil)
                    links[session.id] = target
                }
                // A hint also consumes the corresponding fallback reservation.
                if hint != nil, let i = pending.firstIndex(where: { $0.entryID == target && !$0.known.contains(session.id) }) { pending.remove(at: i) }
            }
            if links[session.id] == nil {
                let entry = Entry(id: "e_" + UUID().uuidString.lowercased(), projectId: session.projectId,
                                  title: nil, status: .offen, createdBy: .user,
                                  createdAt: session.startedAt, updatedAt: session.startedAt)
                let result = try await store.createStrands([StrandSeed(sessionId: session.id, entry: entry)])
                if let actual = result[session.id] {
                    links[session.id] = actual
                    if actual == entry.id { automatic[session.id] = entry; entries[entry.id] = entry }
                }
            }
        }
        return links
    }
}

public enum SnapshotBuilder {
    /// Construct the entry-based snapshot, assigning each newly indexed session exactly once.
    public static func build(index: IndexResult, store: any EntryStoring, live: LiveState,
                               settings: Settings, context: Context?, windows: Windows, ended: [String],
                               permissions: Permissions, now: Date,
                               assignment: SessionAssignment = SessionAssignment()) async throws -> Snapshot {
        let folder = Logic.startFolder(settings: settings, projects: index.projects, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let droppedIDs = Set(index.projects.filter { $0.rootPath == folder }.map(\.id))
        var normalizedIndex = index
        for i in normalizedIndex.sessions.indices where normalizedIndex.sessions[i].projectId.map(droppedIDs.contains) == true {
            normalizedIndex.sessions[i].projectId = nil
        }
        let links = try await assignment.assign(index: normalizedIndex, store: store, live: live, now: now)
        var entries = try await store.loadEntries()
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var sessions = try index.sessions.map { s -> Session in
            guard let entryID = links[s.id], entriesByID[entryID] != nil else {
                throw SnapshotError.missingStrand(s.id)
            }
            return Session(id: s.id, tool: s.tool, nativeId: s.nativeId, entryId: entryID,
                             projectId: s.projectId, cwd: s.cwd, transcriptPath: s.transcriptPath,
                             startedAt: s.startedAt, lastActivityAt: s.lastActivityAt, tokens: s.tokens,
                             firstPrompt: s.firstPrompt, threadName: s.threadName, suggestedTitle: s.suggestedTopic,
                             resumable: s.resumable, resumeCount: max(1, live.resumeCounts[s.id] ?? 1),
                             live: live.running[s.id] ?? .notRunning, createdAt: s.startedAt, updatedAt: s.startedAt)
        }
        let projects = index.projects.filter { !droppedIDs.contains($0.id) }
        let droppedEntries = Set(entries.filter { $0.projectId.map(droppedIDs.contains) == true }.map(\.id))
        for i in entries.indices where droppedEntries.contains(entries[i].id) { entries[i].projectId = nil }
        for i in sessions.indices where sessions[i].projectId.map(droppedIDs.contains) == true { sessions[i].projectId = nil }
        var context = context
        if context?.projectId.map(droppedIDs.contains) == true { context?.projectId = nil }
        sessions.removeAll { session in
            session.suggestedTitle.isEmpty && !session.live.running && (entriesByID[session.entryId]?.title ?? "").isEmpty
        }
        let grouped = Dictionary(grouping: sessions, by: \.entryId)
        for i in entries.indices where entries[i].projectId == nil && !droppedEntries.contains(entries[i].id) {
            guard let latest = grouped[entries[i].id]?.filter({ $0.projectId != nil }).max(by: {
                $0.lastActivityAt == $1.lastActivityAt ? $0.id < $1.id : $0.lastActivityAt < $1.lastActivityAt
            }) else { continue }
            entries[i].projectId = latest.projectId
            do {
                try await store.save(entries[i], undoLabel: nil)
            } catch {
                Logger(subsystem: "ResumeBar", category: "SnapshotBuilder")
                    .error("Could not persist recovered entry project")
            }
        }
        let changes = try await store.loadChanges()
        let changedEntries = Set(changes.map(\.entryId))
        entries.removeAll { Logic.saysNothing($0, hasSession: grouped[$0.id] != nil, hasChange: changedEntries.contains($0.id)) }
        let endedIDs = Set(ended)
        let justEnded = entries.compactMap { entry -> String? in
            guard entry.title == nil, let latest = grouped[entry.id]?.max(by: { $0.lastActivityAt < $1.lastActivityAt }),
                  endedIDs.contains(latest.id) else { return nil }
            return entry.id
        }
        return Snapshot(now: now, context: context, settings: settings, projects: projects,
                          entries: entries, sessions: sessions, windows: windows, justEnded: justEnded,
                          changes: changes, permissions: permissions)
    }

    /// Aggregate-only diagnostics for a disposable store copy.
    public static func engineCheck(_ snapshot: Snapshot, links: [String: String], counts: ResumeCountState) -> String {
        let groups = Dictionary(grouping: snapshot.sessions, by: \.entryId)
        let strandIDs = Set(links.values)
        let strands = snapshot.entries.filter { strandIDs.contains($0.id) }
        let titled = strands.filter { $0.title != nil }.count
        let missing = snapshot.sessions.filter { snapshot.entry($0.entryId) == nil }.count
        let total = counts.counts.values.reduce(0, +)
        return "sessions: \(snapshot.sessions.count) · strands titled: \(titled) · strands untitled: \(strands.count - titled) · tasks: \(snapshot.entries.count - strands.count) · max sessions per strand: \(groups.values.map(\.count).max() ?? 0) · sessions without strand: \(missing) · resume count total: \(total)"
    }

    public enum SnapshotError: Error { case missingStrand(String) }

    /// Resume command for a session (`{id}` → native id), DATA.md „Befehl“.
    public static func command(for session: Session, settings: Settings) -> String {
        let id = session.nativeId
        // An unsafe id from an old entry is never inserted, whatever quoting a custom template uses; the tool then fails harmlessly.
        let word = SessionID.isSafe(id) ? id : "invalid-session-id"
        return settings.commands[session.tool].replacingOccurrences(of: "{id}", with: word)
    }
}
