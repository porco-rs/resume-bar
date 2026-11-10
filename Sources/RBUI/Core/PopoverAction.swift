public enum PopoverTrigger {
    case click, hotkey
}

public enum PopoverAction {
    case open, close, toggleMode

    public static func decide(trigger: PopoverTrigger, isShown: Bool) -> Self {
        guard isShown else { return .open }
        return trigger == .hotkey ? .toggleMode : .close
    }
}
