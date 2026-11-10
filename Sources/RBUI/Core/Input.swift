// Raw input from the web view and its mapping to UI events.
// The mapping is the keyboard table as implemented in
// prototype/app.js (keydown handler). ui/bridge.js only decides intercept-or-native; meaning lives here.

import RBContract

public struct KeyPress: Sendable, Equatable, Decodable {
    /// DOM `KeyboardEvent.key`
    public var key: String
    public var code: String?
    public var meta: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    /// Class of the focused input: "q" search, "e" topic edit, "b" banner, "p" panel; nil otherwise
    public var field: String?
    public var fieldEmpty: Bool
    public var hasSelection: Bool

    public init(key: String, code: String? = nil, meta: Bool = false, ctrl: Bool = false, alt: Bool = false, shift: Bool = false,
                field: String? = "q", fieldEmpty: Bool = true, hasSelection: Bool = false) {
        self.key = key
        self.code = code
        self.meta = meta
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.field = field
        self.fieldEmpty = fieldEmpty
        self.hasSelection = hasSelection
    }
}

public enum RawInput: Sendable, Equatable {
    case key(KeyPress)
    /// Input event of a field: q/e/b/p
    case text(field: String, value: String)
    /// `change` of a settings field (data-setting path)
    case setting(path: String, value: String)
    /// Click on an element with data-act (and optional data-arg)
    case action(String, arg: String?)
    case select(String)
    case doubleSelect(String)
}

public enum KeyMap {
    /// Translates raw input to UI events (in order). Empty = nothing to do.
    public static func events(for input: RawInput, state: UIState) -> [UIEvent] {
        switch input {
        case let .text(field, value):
            switch field {
            case "q": return [.setQuery(value)]
            case "e": return [.setEdit(value)]
            case "b": return [.setBanner(value)]
            case "p": return [.panelSet(value)]
            default: return []
            }
        case let .setting(path, value):
            return [.setSetting(path: path, value: value)]
        case let .select(id):
            return state.mode == .edit ? [] : [.select(id)]
        case let .doubleSelect(id):
            return [.doubleSelect(id)]
        case let .action(name, arg):
            return action(name, arg: arg)
        case let .key(k):
            return key(k, state: state)
        }
    }

    static func action(_ name: String, arg: String?) -> [UIEvent] {
        switch name {
        case "stripAccept": return [.stripAccept]
        case "stripRevert": return [.stripRevert]
        case "stripSelect": return arg.flatMap(Int.init).map { [.stripSelect($0)] } ?? []
        case "bannerFocus": return [.bannerFocus]
        case "bannerAccept": return [.bannerFocus, .complete]
        case "bannerName": return [.bannerFocus, .enter]
        case "bannerLater": return [.bannerFocus, .cancel]
        case "trainer": return [.trainer]
        case "toggleMode": return [.toggleMode]
        case "record": return [.record(arg.flatMap(HotkeySlot.init(rawValue:)))]
        case "setDefaultTool": return arg.flatMap(Tool.init(rawValue:)).map { [.setSetting(path: "defaultTool", value: $0.rawValue)] } ?? []
        case "setAI": return arg.map { [.setSetting(path: "aiEnabled", value: $0)] } ?? []
        case "setTerminal": return arg.flatMap(TerminalApp.init(rawValue:)).map { [.setTerminal($0)] } ?? []
        default: return UIEvent.replay([name] + (arg.map { [$0] } ?? [])).map { [$0] } ?? []
        }
    }

    static func key(_ k: KeyPress, state: UIState) -> [UIEvent] {
        let mod = k.meta || k.ctrl
        let lk = k.key.lowercased()
        if mod && lk == "t" && (state.screen == .m01 || (state.screen == .m00 && state.onboarding == .eingerichtet)) { return [.trainer] }
        switch state.screen {
        case .m01:
            return keyToAction(k, state: state)
        case .m01s1:
            if k.key == "Enter" { return [.panelSave] }
            if k.key == "Escape" { return [.panelCancel] }
            if mod && lk == "z" { return [.panelUndo] }
            return []
        case .m00:
            if k.key == "Enter" { return [.onboardingNext] }
            if k.key == "Escape" { return [.onboardingSkip] }
            if mod && k.key == "," { return [.openSettings] }
            return []
        case .m02:
            guard state.recording != nil else { return [] }
            if k.key == "Escape" { return [.record(nil)] }
            if ["Meta", "Control", "Alt", "Shift"].contains(k.key) || !(k.meta || k.ctrl || k.alt) { return [] }
            let name = k.key == " " ? "Space" : (k.key.count == 1 ? k.key.uppercased() : k.key)
            let combo = (k.ctrl ? "⌃" : "") + (k.alt ? "⌥" : "") + (k.shift ? "⇧" : "") + (k.meta ? "⌘" : "") + name
            return [.recordCombo(combo)]
        }
    }

    /// M01 mapping of the prototype's keyToAction table.
    static func keyToAction(_ k: KeyPress, state: UIState) -> [UIEvent] {
        let mod = k.meta || k.ctrl
        let lower = k.key.lowercased()
        if mod {
            switch k.key {
            case "ArrowDown": return [.openEntry]
            case "ArrowUp": return [.closeEntry]
            case "Backspace": return [.archive]
            case "Enter": return [.cmdEnter]
            default: break
            }
            switch lower {
            case "c": return k.hasSelection ? [] : [.copy]
            case "p": return [.edit]
            case "d": return [.editDeadline]
            case "g": return [.toggleGoal]
            case "s": return [.cycle]
            case "z": return [.undo]
            case "w" where k.shift: return [.cleanup]
            case "/", "?": return [.help]
            case ",": return [.openSettings]
            default: break
            }
            if k.shift && k.code == "Digit7" { return [.help] }
            return []
        }
        switch k.key {
        case "ArrowDown": return [.move(1)]
        case "ArrowUp": return [.move(-1)]
        case "ArrowLeft", "ArrowRight":
            guard !k.alt, !k.shift, state.query.isEmpty, state.mode == .list, !state.help, state.focus != .banner else { return [] }
            return [k.key == "ArrowRight" ? .modeNext : .modePrev]
        case "Enter": return [k.alt ? .altEnter : k.shift ? .shiftEnter : .enter]
        case "Tab": return [.complete]
        case "Escape": return [.cancel]
        case "Backspace" where k.field == "q" && k.fieldEmpty: return [.backspaceEmpty]
        default: return []
        }
    }
}
