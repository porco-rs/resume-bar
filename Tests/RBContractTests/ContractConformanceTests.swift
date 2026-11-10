import Foundation
import Testing
@testable import RBContract

// Guard: every contract declaration that this suite relies on is used here. If one is missing, this file does not
// compile. Extend it before relying on a new declaration.

/// Compile-time witness for the `rb` protocol; never executed.
func rbServingWitness(_ server: some RBServing) async -> RBResponse {
    await server.handle(.list(allProjects: false, project: nil), from: RBCallerInfo(caller: .codex, cwd: "/x", processChain: [2, 1]))
}

@Test func rbProtocolRoundTripsAsOneJSONLine() throws {
    let line = RBEntryLine(id: "e1", title: "Zeile\nzwei", status: .offen, projectName: nil, deadline: "2026-11-06", sessionCount: 0)
    let requests: [RBRequest] = [
        .list(allProjects: true, project: "garten"), .add(text: "x", deadline: "fr", project: nil),
        .start(query: "x", tool: .claude, project: nil), .done(query: nil, project: nil),
        .setDeadline(query: "x", deadline: nil, project: "garten"), .export,
    ]
    let responses: [RBResponse] = [
        .entries([line]), .entry(line), .exported(json: "{}"), .failed(.ambiguous, matches: [line]),
    ]
    for request in requests {
        let data = try JSONEncoder().encode(request)
        #expect(!data.contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(RBRequest.self, from: data) == request)
    }
    for response in responses {
        let data = try JSONEncoder().encode(response)
        #expect(!data.contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(RBResponse.self, from: data) == response)
    }
    #expect(RBSocket.fileName == "rb.sock")
    #expect(RBSocket.maxMessageBytes > 0)
    #expect(RBSocket.maxResponseBytes > RBSocket.maxMessageBytes)
    #expect(RBEntryLine(id: "e", title: "t", status: .offen, projectName: nil, deadline: nil, sessionCount: 0).awaitsConfirmation == false)
    #expect(Set(RBCaller.allCases) == [.person, .claude, .codex])
    #expect(RBErrorCode(rawValue: "fremdes_projekt") == .foreignProject)
    #expect(RBErrorCode(rawValue: "zugriff_aus") == .accessOff)
    #expect(RBErrorCode(rawValue: "aufrufer_unbekannt") == .callerUnknown)
    #expect(RBErrorCode(rawValue: "speicher_fehler") == .storeFailed)
    #expect(RBErrorCode(rawValue: "start_fehlgeschlagen") == .startFailed)
}

/// Compile-time witness for every `EntryStoring` requirement; never executed.
func entryStoringWitness(_ store: some EntryStoring, _ entry: Entry, _ change: Change) async throws {
    _ = try await store.loadEntries()
    _ = try await store.loadLinks()
    _ = try await store.loadChanges()
    _ = try await store.loadSettings()
    let state: ResumeCountState = try await store.loadResumeCountState()
    try await store.saveResumeCountState(state)
    let links: [String: String] = try await store.createStrands([StrandSeed(sessionId: "cc_x", entry: entry)])
    _ = links
    try await store.save(entry, undoLabel: nil)
    try await store.link(["cc_x"], to: entry.id, undoLabel: "link")
    try await store.delete(entryId: entry.id, undoLabel: nil)
    try await store.addChange(change)
    try await store.removeChanges([change.id])
    try await store.save(entry, change: change, undoLabel: "Ziel")
    _ = try await store.apply(.aiEnabled(false))
    _ = try await store.apply(.defaultTool(.claude))
    _ = try await store.apply(.startFolder("~/projects"))
    _ = try await store.apply(.trainerDone(["weitermachen"]))
    _ = try await store.apply(.terminals(.init(default: .terminal, alternate: .terminal)))
    _ = try await store.apply(.hotkey(.task, "⌥⌘N"))
    _ = try await store.undo()
    await store.pushUndo(label: "x") {}
}

@Test func contractDeclarationsExist() {
    let now = Date(timeIntervalSince1970: 0)
    let entry = Entry(id: "e_1", projectId: nil, title: nil, status: .wartet, statusChangedAt: nil, deadline: "2026-11-06",
                      createdBy: .user, doneBy: Actor.codex, createdAt: now, updatedAt: now, archivedAt: nil,
                      schemaVersion: 2)
    let change = Change(id: "c_1", kind: .done, entryId: entry.id, by: .claude, at: now)
    let session = Session(id: "cc_x", tool: .claude, nativeId: "x", entryId: entry.id, projectId: nil, cwd: "/",
                            transcriptPath: "/x", startedAt: now, lastActivityAt: now, tokens: nil, firstPrompt: "",
                            threadName: nil, suggestedTitle: "", resumable: true, resumeCount: 0, live: .notRunning,
                            createdAt: now, updatedAt: now)
    let snap = Snapshot(now: now, context: nil, settings: .defaults, projects: [], entries: [entry],
                          sessions: [session], windows: Windows(open: 0, closable: 0), justEnded: [entry.id],
                          changes: [change], permissions: Permissions(accessibility: true,
                          automation: .init(ghostty: .granted, terminal: .unknown)))
    #expect(snap.sessions(of: entry.id).map(\.id) == ["cc_x"])
    #expect(snap.project(nil) == nil)
    #expect(Settings.defaults.hotkeys.task == "⌥⌘N")
    #expect(Settings.defaults.ai.enabled)
    #expect(HotkeySlot.task.rawValue == "task")
    #expect(ResumeCountState(counts: [:], historyImportVersion: 2).historyImportVersion == 2)
}

/// Intents and results used by the engine and screens.
@Test func contractIntentsExist() {
    let intents: [Intent] = [
        .resumeEntry(entryId: "e", sessionId: nil, terminal: nil), .startEntry(entryId: "e", tool: .claude, terminal: nil),
        .startGoal(entryId: "e", tool: .codex, terminal: nil), .updateSettings(.defaultTool(.claude)), .updateSettings(.startFolder(nil)), .updateSettings(.trainerDone([])), .updateSettings(.terminals(.init(default: .terminal, alternate: .terminal))),
        .newStrang(title: "t", projectId: nil, tool: .codex, terminal: nil),
        .addTask(title: "t", projectId: nil, deadline: "2026-11-06", start: .codex),
        .newStrang(title: "t", projectId: "p", tool: .codex, terminal: .ghostty), .setTitle(entryId: "e", title: "t"),
        .setDeadline(entryId: "e", deadline: nil), .setProject(entryId: "e", projectId: "p"), .cycleStatus(entryId: "e"),
        .archiveEntry(entryId: "e"), .nameJustEnded(entryId: "e", title: nil), .acceptChanges, .revertChange(changeId: "c"),
        .panelName(sessionId: "cc_x", title: "t"), .updateSettings(.aiEnabled(true)), .recordHotkey(.task),
    ]
    let results: [IntentResult] = [
        .entryTitleSet(entryId: "e"), .entrySaveFailed(entryId: "e"), .entryStatusSet(entryId: "e", from: .offen, to: .wartet),
        .entryArchived(entryId: "e"), .taskAdded(entryId: "e"), .deadlineSet(entryId: "e", deadline: nil),
        .projectSet(entryId: "e"), .changesAccepted, .changeReverted(title: "t"), .folderMissing(path: "/x"),
    ]
    #expect(intents.count == 21 && results.count == 10)
}

/// Live entry hints from RB_ENTRY.
@Test func contractEntryHintsExist() {
    let state = LiveState(running: [:], ended: [], resumeCounts: [:], entryHints: ["cc_x": "e_1"])
    #expect(state.entryHints["cc_x"] == "e_1")
    #expect(LiveState(running: [:], ended: [], resumeCounts: [:]).entryHints.isEmpty)
}

/// Counted processes travel with the counts.
@Test func contractCountedProcessesExist() {
    let state = ResumeCountState(counts: ["cc_x": 2], historyImportVersion: 2, counted: [CountedProcess(pid: 42, start: 7, sessionId: "cc_x")])
    #expect(state.counted.first?.sessionId == "cc_x")
    #expect(ResumeCountState(counts: [:], historyImportVersion: 0).counted.isEmpty)
}

/// A session in the home folder has no project.
@Test func contractIndexedSessionWithoutProject() {
    let s = IndexedSession(id: "cc_x", tool: .claude, nativeId: "x", projectId: nil, cwd: "/Users/x", transcriptPath: "/t",
                           startedAt: .distantPast, lastActivityAt: .distantPast, tokens: nil, firstPrompt: "", threadName: nil,
                           suggestedTopic: "", resumable: true)
    #expect(s.projectId == nil)
}

// Compile-time witness for the language contract.
func appLanguageWitness() -> (AppLanguage, [AppLanguage], AppLanguage) {
    (AppLanguage.current, AppLanguage.allCases, AppLanguage.resolve(override: nil, preferred: [], underTest: false))
}
