// Intents: what the UI asks the engine to do; in curtain they stay inside Swift.
// Results come back to the UI as UIEvent.result for toasts and row notes.

import Foundation

public enum HotkeySlot: String, Codable, Sendable { case popover, pin, task }

public enum Intent: Sendable, Equatable {
    case dismissJustEnded
    case cleanupWindows
    case undo
    case copyCommand(sessionId: String)
    case updateSettings(SettingsPatch)
    case recordHotkey(HotkeySlot)
    case requestAccessibility
    case closePopover
    case openSettings

    /// ↵ on a strand (newest session) or a session row (`sessionId`). entry.resume
    case resumeEntry(entryId: String, sessionId: String?, terminal: TerminalApp?)
    /// ↵ / ⇧↵ on a task: new session, title as prompt, `RB_ENTRY` set; the task becomes a strand. entry.start
    case startEntry(entryId: String, tool: Tool, terminal: TerminalApp?)
    /// Like startEntry, with `/goal <title>` as the prompt.
    case startGoal(entryId: String, tool: Tool, terminal: TerminalApp?)
    /// aufgabe mode ↵ (start nil) / ⌘↵ (start .codex). entry.add
    case addTask(title: String, projectId: String?, deadline: String?, start: Tool?)
    /// resume mode, no hit: entry + session; without project it starts in the start folder. entry.newStrang
    case newStrang(title: String, projectId: String?, tool: Tool, terminal: TerminalApp?)
    case setTitle(entryId: String, title: String)
    /// Already parsed to YYYY-MM-DD by Logic.parseDeadline; nil removes it.
    case setDeadline(entryId: String, deadline: String?)
    /// Tasks only.
    case setProject(entryId: String, projectId: String)
    /// Strands only: offen → wartet → erledigt → offen; an untitled strand takes its suggestion as title.
    case cycleStatus(entryId: String)
    /// erledigt + archivedAt (⌘⌫), strands and tasks.
    case archiveEntry(entryId: String)
    case nameJustEnded(entryId: String, title: String?)
    case acceptChanges
    case revertChange(changeId: String)
    /// M01-S1: title of the strand of this session.
    case panelName(sessionId: String, title: String)
}

/// One settings change, applied by RBStore and validated there (invalid input keeps the old value).
public enum SettingsPatch: Sendable, Equatable {
    case command(Tool, String)
    case terminals(Settings.Terminals)
    case defaultTerminal(TerminalApp)
    case hotkey(HotkeySlot, String)
    case archiveDays(Int)
    case cleanupThreshold(Int)
    case aiEnabled(Bool)
    case defaultTool(Tool)
    case startFolder(String?)
    case trainerDone([String])
}

public enum IntentResult: Sendable, Equatable {
    case opened(app: TerminalApp, sessionId: String?)
    case focused(app: TerminalApp, sessionId: String)
    case notResumable(sessionId: String, path: String)
    case folderMissing(path: String)
    case terminalFailed(app: TerminalApp, reason: String)
    case automationDenied(app: TerminalApp)
    case copied(command: String)
    case topicSet(sessionId: String)
    /// The store rejected a change to the user fields (topic, pin, status, archive); nothing was saved.
    case saveFailed(sessionId: String)
    case windowsClosed(count: Int)
    case undone(label: String)
    case undoEmpty
    case settingsSaved
    case settingsRejected(reason: String)
    case hotkeyRecorded(HotkeySlot, combo: String)

    case entryTitleSet(entryId: String)
    /// The store rejected an entry change; nothing was saved.
    case entrySaveFailed(entryId: String)
    case entryStatusSet(entryId: String, from: EntryStatus, to: EntryStatus)
    case entryArchived(entryId: String)
    case taskAdded(entryId: String)
    case deadlineSet(entryId: String, deadline: String?)
    case projectSet(entryId: String)
    case changesAccepted
    case changeReverted(title: String)
}
