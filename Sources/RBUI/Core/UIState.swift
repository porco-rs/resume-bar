// UI state and events. Port of the prototype model.
// Event names equal the prototype action names so the fixtures' `_ui.replay` sequences apply 1:1.

import Foundation
import RBContract

public enum Screen: String, Sendable, CaseIterable {
    case m00 = "M00", m01 = "M01", m01s1 = "M01-S1", m02 = "M02"
}

public struct Chip: Sendable, Equatable {
    public enum Kind: String, Sendable { case project, tool, status, archive, deadline }
    public var kind: Kind
    public var value: String
    public var label: String

    public init(kind: Kind, value: String, label: String) {
        self.kind = kind
        self.value = value
        self.label = label
    }
}

/// Toast and row-note kinds; the raw value is the CSS class from the prototype.
public enum NoteKind: String, Sendable { case ok, warn, error }

public struct Note: Sendable, Equatable {
    public var kind: NoteKind
    public var text: String

    public init(kind: NoteKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct PanelState: Sendable, Equatable {
    public enum Source: String, Sendable { case selection, window }
    public let instanceID = UUID()
    public var sessionId: String?
    public var source: Source
    public var selectionText: String
    /// Current field text; `initialText` is what the field was opened with (renders the `value`).
    public var text: String
    public var initialText: String
    public var done: Bool
    public var saving = false

    public init(sessionId: String?, source: Source, selectionText: String, text: String, done: Bool) {
        self.sessionId = sessionId
        self.source = source
        self.selectionText = selectionText
        self.text = text
        self.initialText = text
        self.done = done
    }
}

public struct UIState: Sendable, Equatable {
    public enum Mode: String, Sendable { case list, edit }
    public enum EditKind: String, Sendable { case title, deadline, project }
    public enum ListMode: String, Sendable { case resume, ziel }
    public enum Focus: String, Sendable { case list, banner, strip }
    public enum OnboardingStep: String, Sendable { case berechtigung, eingerichtet }

    public enum RBLinkState: Sendable { case linked, taken, failed, unreachable, notRemoved }
    public var rbLink: RBLinkState = .linked
    public var rbOtherCommands: [String] = []
    public var trainer: TrainerState?
    public var screen: Screen = .m01
    public var onboarding: OnboardingStep = .berechtigung
    public var chips: [Chip] = []
    public var query = ""
    public var selectedId: String?
    public var mode: Mode = .list
    public var listMode: ListMode = .resume
    /// Search semantics are captured when text changes, so a mode switch preserves the displayed rows.
    public var filterMode: ListMode = .resume
    public var editKind: EditKind = .title
    public var editEntryId: String?
    public var goalMode = false
    public var editText = ""
    /// Field value when edit mode started; the edit input renders this, never `editText`.
    public var editInitial = ""
    public var toast: Note?
    public var notes: [String: Note] = [:]
    public var focus: Focus = .list
    public var bannerText = ""
    public var contextDismissed = false
    /// Project of the last marked row; nil also represents a row without a project.
    public var markedProjectId: String?
    public var markedProjectInitialized = false
    public var hasMarkedProject = false
    public var help = false
    public var undoHint = false
    public var panel: PanelState?
    public var openEntries: [String] = []
    public var openProjects: [String] = []
    public var closedSearchProjects: [String] = []
    public var stripIdx = 0
    public var selectAll = false
    public var recording: HotkeySlot?

    public init() {}
}

/// UI events. Names and arguments follow prototype/app.js act(m, type, arg).
public enum UIEvent: Sendable, Equatable {
    case select(String)
    case doubleSelect(String)
    case startWith(Tool), toggleGoal
    case stripAccept, stripRevert, stripSelect(Int), bannerFocus
    case move(Int)
    case modeNext, modePrev, toggleMode, showDue
    case type(String)            // appends characters (fixture replay)
    case setQuery(String)        // full field value (live input)
    case complete
    case backspaceEmpty
    case enter, shiftEnter, altEnter, cmdEnter
    case copy
    case edit
    case editDeadline
    case setEdit(String)
    case saveEdit
    case cycle
    case archive
    case openEntry, closeEntry
    case undo
    case cleanup
    case help, trainer
    case setBanner(String)
    case cancel
    case openSettings
    case panelSet(String)
    case panelSave
    case panelUndo
    case panelCancel
    case allowAx
    case onboardingNext
    case onboardingSkip
    case record(HotkeySlot?)
    case recordCombo(String)
    case setTerminal(TerminalApp)
    case setSetting(path: String, value: String)
    /// Popover was opened: context and justEnded may have changed.
    case opened
    /// Engine feedback for an intent (toasts, row notes).
    case result(IntentResult)

    /// Builds an event from a fixture replay step such as ["select", "cc_…"] or ["type", "pc blog"].
    public static func replay(_ step: [String]) -> UIEvent? {
        guard let name = step.first else { return nil }
        let arg = step.count > 1 ? step[1] : ""
        switch name {
        case "select": return .select(arg)
        case "move": return .move(Int(arg) ?? 1)
        case "toggleGoal": return .toggleGoal
        case "startWith": return Tool(rawValue: arg).map { .startWith($0) }
        case "modeNext": return .modeNext
        case "modePrev": return .modePrev
        case "showDue": return .showDue
        case "type": return .type(arg)
        case "setQuery": return .setQuery(arg)
        case "complete": return .complete
        case "backspaceEmpty": return .backspaceEmpty
        case "enter": return .enter
        case "shiftEnter": return .shiftEnter
        case "cmdEnter": return .cmdEnter
        case "altEnter": return .altEnter
        case "copy": return .copy
        case "edit": return .edit
        case "editDeadline": return .editDeadline
        case "setEdit": return .setEdit(arg)
        case "saveEdit": return .saveEdit
        case "cycle": return .cycle
        case "archive": return .archive
        case "openEntry": return .openEntry
        case "closeEntry": return .closeEntry
        case "undo": return .undo
        case "cleanup": return .cleanup
        case "help": return .help
        case "setBanner": return .setBanner(arg)
        case "cancel": return .cancel
        case "panelSet": return .panelSet(arg)
        case "panelSave": return .panelSave
        case "panelUndo": return .panelUndo
        case "panelCancel": return .panelCancel
        case "allowAx": return .allowAx
        default: return nil
        }
    }
}
