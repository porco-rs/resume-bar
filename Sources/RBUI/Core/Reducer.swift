import RBContract

public enum Reducer {
    public static func reduce(_ s: inout UIState, _ e: UIEvent, _ snap: Snapshot) -> [Intent] {
        if s.screen == .m01 {
            if case .openSettings = e { s.screen = .m02; return [.openSettings, .closePopover] }
            return TaskArea.reduce(&s, e, snap)
        }
        switch e {
        case .select, .move, .setQuery, .setEdit, .setBanner, .setTerminal, .setSetting, .result, .opened: break
        default: s.toast = nil; s.notes = [:]; s.undoHint = false
        }
        if case .openSettings = e { s.screen = .m02; return [.openSettings, .closePopover] }
        return EdgesArea.reduce(&s, e, snap)
    }

    public static func replay(_ steps: [[String]], on s: inout UIState, _ snap: Snapshot) {
        for step in steps {
            if let e = UIEvent.replay(step) { _ = reduce(&s, e, snap) }
        }
    }
}
