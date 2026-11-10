// Builds the UI state of a design fixture exactly like prototype/app.js create():
// snapshot from the fixture, `_ui` fields applied, banner focus when justEnded is set,
// then the `_ui.replay` sequence. Used by all UI area tests.

import Foundation
import RBContract
@testable import RBUI

enum FixtureHarness {
    static let designRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/design")

    struct Entry: Decodable { let key: String; let screen: String; let state: String; let file: String }

    struct Meta: Decodable {
        struct UI: Decodable {
            struct Panel: Decodable {
                let sessionId: String?
                let source: String
                let selectionText: String
                let text: String
                let done: Bool
            }
            let panel: Panel?
            let selectAll: Bool?
            struct ReplayStep: Decodable {
                let values: [String]
                init(from decoder: Decoder) throws {
                    var c = try decoder.unkeyedContainer(); var result: [String] = []
                    while !c.isAtEnd {
                        if let value = try? c.decode(String.self) { result.append(value) }
                        else { result.append(String(try c.decode(Int.self))) }
                    }
                    values = result
                }
            }
            let replay: [ReplayStep]?
            let mode: String?
        }
        let _screen: String
        let _state: String
        let _ui: UI?
    }

    static func entries() throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(contentsOf: designRoot.appendingPathComponent("fixtures/index.json")))
    }

    /// State and snapshot for a fixture key such as "M01.kontext".
    static func load(_ key: String) throws -> (UIState, Snapshot) {
        guard let entry = try entries().first(where: { $0.key == key }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSDebugDescriptionErrorKey: key])
        }
        let data = try Data(contentsOf: designRoot.appendingPathComponent("fixtures/\(entry.file)"))
        let snap = try RBJSON.decoder().decode(Snapshot.self, from: data)
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        var s = UIState()
        s.listMode = meta._ui?.mode == "aufgabe" ? .ziel : (UIState.ListMode(rawValue: meta._ui?.mode ?? "resume") ?? .resume)
        s.screen = Screen(rawValue: meta._screen) ?? .m01
        if s.screen == .m00 { s.onboarding = UIState.OnboardingStep(rawValue: meta._state) ?? .berechtigung }
        if let p = meta._ui?.panel {
            var text = p.text
            if let id = p.sessionId, text.isEmpty, let session = snap.session(id) {
                text = snap.entry(session.entryId).map { Logic.titleOf(snap, $0) } ?? session.suggestedTitle
            }
            s.panel = PanelState(sessionId: p.sessionId, source: PanelState.Source(rawValue: p.source) ?? .selection,
                                 selectionText: p.selectionText, text: text, done: p.done)
        }
        s.selectAll = meta._ui?.selectAll ?? false
        if s.screen == .m01 && !snap.justEnded.isEmpty { s.focus = .banner }
        var snapshot = snap
        play(meta._ui?.replay?.map(\.values) ?? [], &s, &snapshot)
        return (s, snapshot)
    }

    /// Replays fixture steps like the real app: reducer → intents → effects on the snapshot
    /// (PrototypeEffects stands in for RBEngine) → results fed back into the reducer.
    static func play(_ steps: [[String]], _ s: inout UIState, _ snap: inout Snapshot) {
        var effects = PrototypeEffects()
        if s.screen == .m01 { _ = Reducer.reduce(&s, .opened, snap) }
        for step in steps {
            guard let event = UIEvent.replay(step) else { continue }
            var queue = Reducer.reduce(&s, event, snap)
            while !queue.isEmpty {
                let intent = queue.removeFirst()
                if var result = effects.apply(intent, to: &snap) {
                    if case let .panelName(id, _) = intent {
                        if case .entryTitleSet = result { result = .topicSet(sessionId: id) }
                        if case .entrySaveFailed = result { result = .saveFailed(sessionId: id) }
                    }
                    queue += Reducer.reduce(&s, .result(result), snap)
                }
            }
        }
    }

    /// Standalone HTML page for a rendered screen (for pair images against the reference).
    static func page(_ r: RenderedScreen) -> String {
        """
        <!doctype html><html lang="de"><head><meta charset="utf-8">
        <link rel="stylesheet" href="../../ui/tokens.css"><link rel="stylesheet" href="../../ui/app.css">
        </head><body class="bare"><div class="stage">\(r.fullHTML)</div></body></html>
        """
    }
}
