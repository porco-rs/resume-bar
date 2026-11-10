import Foundation
import RBContract

enum EdgesArea {
    static func reduce(_ s: inout UIState, _ e: UIEvent, _ snap: Snapshot) -> [Intent] {
        switch e {
        case .panelSet(let text):
            s.panel?.text = text
            s.selectAll = false
        case .panelSave:
            guard let p = s.panel, !p.done, !p.saving, let id = p.sessionId, let session = snap.session(id) else { return [] }
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            s.panel?.saving = true
            let fallback = snap.entry(session.entryId).map { Logic.titleOf(snap, $0) } ?? session.suggestedTitle
            return [.panelName(sessionId: id, title: text.isEmpty ? fallback : text)]
        case .panelUndo:
            guard s.panel != nil else { return [] }
            s.panel?.done = false
            return [.undo]
        case .panelCancel:
            s.panel?.saving = false
            s.toast = Note(kind: .ok, text: t("m01s1.closed"))
            return [.closePopover]
        case .allowAx:
            return [.requestAccessibility]
        case .onboardingSkip:
            if s.onboarding == .berechtigung { s.onboarding = .eingerichtet }
        case .onboardingNext:
            if s.onboarding == .eingerichtet { s.screen = .m01 }
            else if snap.permissions.accessibility { s.onboarding = .eingerichtet }
            else { return [.requestAccessibility] }
        case .result(let result):
            switch result {
            case .topicSet(let id) where s.panel?.sessionId == id && s.panel?.saving == true:
                s.panel?.saving = false
                s.panel?.done = true
                s.undoHint = true
            case .saveFailed(let id) where s.panel?.sessionId == id && s.panel?.saving == true:
                s.panel?.saving = false
                s.toast = Note(kind: .error, text: "Speichern fehlgeschlagen. Bitte erneut versuchen.")
            default: break
            }
        case .record(let slot):
            s.recording = slot
            return slot.map { [.recordHotkey($0)] } ?? []
        case .recordCombo(let combo):
            guard let slot = s.recording else { return [] }
            s.recording = nil
            return [.updateSettings(.hotkey(slot, combo))]
        case .setTerminal(let app):
            return [.updateSettings(.defaultTerminal(app))]
        case .setSetting(let path, let value):
            switch path {
            case "aiEnabled": return [.updateSettings(.aiEnabled(value == "true"))]
            case "defaultTool": return Tool(rawValue: value).map { [.updateSettings(.defaultTool($0))] } ?? []
            case "startFolder": return [.updateSettings(.startFolder(value.isEmpty ? nil : value))]
            case "commands.codex": return [.updateSettings(.command(.codex, value))]
            case "commands.claude": return [.updateSettings(.command(.claude, value))]
            case "archiveDays": return Int(value).map { [.updateSettings(.archiveDays($0))] } ?? []
            case "cleanupThreshold": return Int(value).map { [.updateSettings(.cleanupThreshold($0))] } ?? []
            default: return []
            }
        default: break
        }
        return []
    }

    static func regions(_ s: UIState, _ snap: Snapshot) -> [String: String] {
        switch s.screen {
        case .m01s1: return panel(s, snap)
        case .m00: return ["page": onboarding(s, snap)]
        case .m02: return ["page": settings(s, snap)]
        case .m01: return [:]
        }
    }

    private static func panel(_ s: UIState, _ snap: Snapshot) -> [String: String] {
        guard let p = s.panel else { return ["panel": ""] }
        let content: String
        if let session = p.sessionId.flatMap(snap.session) {
            let entry = snap.entry(session.entryId)
            let project = snap.project(entry?.projectId)?.name ?? t("project.none")
            if p.done {
                content = "<div class=\"p-done\"><span><span class=\"acc\">✓</span> \(h(t("m01s1.done", ["project": project, "title": entry?.title ?? ""])))</span><button type=\"button\" data-act=\"panelUndo\">\(h(t("m01s1.undo")))</button></div>"
            } else {
                let head = t("m01s1.head", ["tool": session.tool.short, "project": project, "short": String(session.nativeId.prefix(8))])
                let source = p.source == .window ? t("m01s1.source.window") : t("m01s1.source.selection", ["text": p.selectionText])
                content = "<div class=\"p-head\"><span class=\"tool \(session.tool.rawValue)\">\(h(session.tool.short))</span> \(h(head))</div>"
                    + "<div class=\"p-field\"><span class=\"lbl\">\(h(t("m01s1.label")))</span><div class=\"field\"><input class=\"p\" value=\"\(h(p.initialText))\" aria-label=\"\(h(t("a11y.panel_input")))\" spellcheck=\"false\"><span class=\"mirror\" aria-hidden=\"true\" data-region=\"pmirror\"></span></div></div>"
                    + "<div class=\"p-foot\"><span class=\"p-src\">\(h(source))</span><span class=\"hints\"><button type=\"button\" data-act=\"panelSave\"><b>↵</b> \(h(t("m01s1.hint.save")))</button><button type=\"button\" data-act=\"panelCancel\"><b>esc</b></button></span></div>"
            }
        } else {
            content = "<div class=\"p-title\">\(h(t("m01s1.none.title")))</div><div class=\"p-text\">\(h(t("m01s1.none.text")))</div><div class=\"p-src\">\(h(t("m01s1.source.selection", ["text": p.selectionText])))</div><div class=\"p-foot\"><span></span><button type=\"button\" data-act=\"panelCancel\"><b>esc</b> \(h(t("m01.hint.close")))</button></div>"
        }
        let toast = s.toast.map { "<div class=\"toast \($0.kind.rawValue)\" role=\"status\">\(h($0.text))</div>" } ?? ""
        return ["panel": content + toast, "pmirror": h(p.text)]
    }

    private static func onboarding(_ s: UIState, _ snap: Snapshot) -> String {
        func line(_ glyph: String, _ ok: Bool, _ title: String, _ sub: String, _ right: String = "", extra: String = "") -> String {
            "<div class=\"o-line\"><span class=\"g\(ok ? " ok" : "")\" aria-hidden=\"true\">\(glyph)</span><div class=\"o-txt\"><div class=\"o-t\">\(h(title))</div><div class=\"o-s\">\(h(sub))</div>\(extra)</div>\(right)</div>"
        }
        // The frame `.pop.onboard` is the core skeleton (Renderer.pageSkeleton); this returns its children.
        let start = ""
        if s.onboarding == .berechtigung {
            let ax = snap.permissions.accessibility
            let right = ax ? "<span class=\"o-s ok\">\(h(t("m00.perm.granted")))</span>" : "<button type=\"button\" class=\"o-btn\" data-act=\"allowAx\">\(h(t("m00.perm.allow")))</button>"
            return start + "<h1 class=\"o-title\">\(h(t("m00.title.berechtigung")))</h1>"
                + line(ax ? "✓" : "○", ax, t("m00.perm.ax.title"), t("m00.perm.ax.text"), right)
                + line("○", false, t("m00.perm.ae.title"), t("m00.perm.ae.text"), "<span class=\"o-s\">\(h(t("m00.perm.ae.later")))</span>")
                + "<div class=\"o-foot\"><span><b>esc</b> \(h(t("m00.foot.later")))</span><span class=\"acc\">\(h(t(ax ? "m00.foot.next" : "m00.foot.allow")))</span></div>"
        }
        let st = snap.settings
        let aiOK = st.ai.enabled && s.rbLink == .linked
        let aiTitle = !st.ai.enabled ? t("m00.line.ai_off") : (aiOK ? t("m00.line.ai") : t("m00.line.ai_missing"))
        var aiSub = !st.ai.enabled ? t("m00.line.ai_off_sub") :
            t(s.rbLink == .taken ? "m02.ai.taken" : (s.rbLink == .failed ? "m02.ai.failed" : (s.rbLink == .unreachable ? "m02.ai.unreachable" : "m00.line.ai_sub")), ["path": "~/.local/bin/rb"])
        if st.ai.enabled && s.rbLink != .failed && s.rbLink != .unreachable && s.rbLink != .notRemoved && !s.rbOtherCommands.isEmpty {
            aiSub += " · " + t("m02.ai.other", ["paths": s.rbOtherCommands.joined(separator: t("list.joiner"))])
        }
        let summary = snap.import
        let projects = (summary?.byProject ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        return start + "<h1 class=\"o-title\">\(h(t("m00.title.eingerichtet")))</h1>"
            + line("✓", true, t("m00.line.commands"), st.commands.codex + " · " + st.commands.claude)
            + line("✓", true, t("m00.line.import", ["count": summary?.sessions ?? 0, "days": summary?.days ?? st.importDays]), projects)
            + line("✓", true, t("m00.line.terminal", ["app": st.terminal.default.displayName]), t(st.terminal.default == st.terminal.alternate ? "m00.line.terminal_only" : "m00.line.terminal_sub", ["alt": st.terminal.alternate.displayName]))
            + line("✓", true, t("m00.line.folder", ["path": startFolder(snap)]), t("m00.line.folder_sub"))
            + line(aiOK ? "✓" : "○", aiOK, aiTitle, aiSub,
                   "<button type=\"button\" class=\"o-btn\" data-act=\"setAI\" data-arg=\"\(!st.ai.enabled)\">\(h(t(st.ai.enabled ? "m00.line.ai_disable" : "m00.line.ai_enable")))</button>",
                   extra: aiOK ? "<div class=\"o-s\">\(h(t("m00.line.ai_path")))</div>" : "")
            + line("→", true, t("m00.line.hotkey", ["key": st.hotkeys.popover]), t("m00.line.hotkey_sub", ["pin": st.hotkeys.pin, "task": st.hotkeys.task]))
            + "<div class=\"o-foot\"><span><b>⌘,</b> \(h(t("m00.foot.settings"))) · <b>⌘T</b> \(h(t("trainer.practice")))</span><span class=\"acc\">\(h(t("m00.foot.go")))</span></div>"
    }

    private static func settings(_ s: UIState, _ snap: Snapshot) -> String {
        let st = snap.settings
        func row(_ label: String, _ content: String, _ hint: String = "") -> String {
            "<div class=\"s-row\"><div class=\"s-l\">\(h(label))</div><div class=\"s-c\">\(content)\(hint.isEmpty ? "" : "<div class=\"s-h\">\(h(hint))</div>")</div></div>"
        }
        func command(_ tool: Tool) -> String {
            let label = t("m02.cmd." + tool.rawValue)
            return "<input class=\"s-in\" data-setting=\"commands.\(tool.rawValue)\" aria-label=\"\(h(label))\" value=\"\(h(st.commands[tool]))\" spellcheck=\"false\">"
        }
        func key(_ slot: HotkeySlot, _ value: String) -> String {
            if s.recording == slot { return "<span class=\"kc rec\">\(h(t("m02.hk.recording")))</span>" }
            return "<span class=\"kc\">\(h(value))</span><button type=\"button\" class=\"lnk\" data-act=\"record\" data-arg=\"\(slot.rawValue)\">\(h(t("m02.hk.change")))</button>"
        }
        func number(_ name: String, _ value: Int, _ max: Int) -> String {
            "<span class=\"inl\">\(h(t("m02.\(name).after"))) <input class=\"s-num\" type=\"number\" min=\"1\" max=\"\(max)\" data-setting=\"\(name == "archive" ? "archiveDays" : "cleanupThreshold")\" value=\"\(value)\" aria-label=\"\(h(t("m02.\(name).a11y")))\"> \(h(t("m02.\(name).unit")))</span>"
        }
        let buttons = TerminalApp.allCases.map { app in
            let on = st.terminal.default == app
            return "<button type=\"button\" role=\"radio\" aria-checked=\"\(on)\" class=\"\(on ? "on" : "")\" data-act=\"setTerminal\" data-arg=\"\(app.rawValue)\">\(h(app.displayName))</button>"
        }.joined()
        let toolButtons = [Tool.codex, .claude].map { tool in
            let on = st.defaultTool == tool
            return "<button type=\"button\" role=\"radio\" aria-checked=\"\(on)\" class=\"\(on ? "on" : "")\" data-act=\"setDefaultTool\" data-arg=\"\(tool.rawValue)\">\(h(tool.displayName))</button>"
        }.joined()
        let aiButtons = [true, false].map { enabled in
            "<button type=\"button\" role=\"radio\" aria-checked=\"\(st.ai.enabled == enabled)\" class=\"\(st.ai.enabled == enabled ? "on" : "")\" data-act=\"setAI\" data-arg=\"\(enabled)\">\(h(t(enabled ? "m02.ai.on" : "m02.ai.off")))</button>"
        }.joined()
        var aiHint = t(s.rbLink == .taken ? "m02.ai.taken" : (s.rbLink == .failed ? "m02.ai.failed" : (s.rbLink == .unreachable ? "m02.ai.unreachable" : (s.rbLink == .notRemoved ? "m02.ai.not_removed" : "m02.ai.hint"))), ["path": "~/.local/bin/rb"])
        if st.ai.enabled && s.rbLink != .failed && s.rbLink != .unreachable && s.rbLink != .notRemoved && !s.rbOtherCommands.isEmpty {
            aiHint += " · " + t("m02.ai.other", ["paths": s.rbOtherCommands.joined(separator: t("list.joiner"))])
        }
        return "<h1 class=\"s-title\">\(h(t("m02.title")))</h1>"
            + row(t("m02.cmd.codex"), command(.codex))
            + row(t("m02.cmd.claude"), command(.claude), t("m02.cmd.hint"))
            + row(t("m02.default_tool"), "<div class=\"seg\" role=\"radiogroup\" aria-label=\"\(h(t("m02.default_tool")))\">\(toolButtons)</div>")
            + row(t("m02.start_folder"), "<input class=\"s-in\" data-setting=\"startFolder\" aria-label=\"\(h(t("m02.start_folder")))\" value=\"\(h(st.startFolder ?? ""))\" placeholder=\"\(h(startFolder(snap)))\" spellcheck=\"false\">", t("m02.start_folder_hint"))
            + row(t("m02.terminal"), "<div class=\"seg\" role=\"radiogroup\" aria-label=\"\(h(t("m02.terminal")))\">\(buttons)</div>", t("m02.terminal.hint"))
            + row(t("m02.hk.popover"), key(.popover, st.hotkeys.popover))
            + row(t("m02.hk.task"), key(.task, st.hotkeys.task), t("m02.hk.task_hint"))
            + row(t("m02.hk.pin"), key(.pin, st.hotkeys.pin), t("m02.hk.pin_hint"))
            + row(t("m02.archive"), number("archive", st.archiveDays, 30))
            + row(t("m02.cleanup"), number("cleanup", st.cleanupThreshold, 50))
            + row(t("m02.ai"), "<div class=\"seg\" role=\"radiogroup\" aria-label=\"\(h(t("m02.ai")))\">\(aiButtons)</div>", aiHint)
            + row(t("m02.watch"), "<div class=\"s-path\">\(h(st.watch.claude))</div><div class=\"s-path\">\(h(st.watch.codex))</div>")
    }

    private static func startFolder(_ snap: Snapshot) -> String {
        let home = NSHomeDirectory()
        let path = Logic.startFolder(settings: snap.settings, projects: snap.projects, home: home)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
