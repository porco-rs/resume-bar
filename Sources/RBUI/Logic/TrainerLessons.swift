import Foundation
import RBContract

public struct TrainerFacts: Sendable {
    public let hotkeyPressed: Bool
    public let listMode: UIState.ListMode
    public let query: String
    public let hasDeadline: Bool
    public let markedEntryId: String?
    public let markedProjectId: String?
    public let expandedProjects: [String]

    public init(state: UIState, snapshot: Snapshot) {
        hotkeyPressed = state.trainer?.hotkeyPressed ?? false
        listMode = state.listMode
        query = state.query
        hasDeadline = state.chips.contains { $0.kind == .deadline } || Logic.hasTrailingDeadline(snapshot, state.query)
        let row = TaskArea.view(state, snapshot).rows.first { $0.key == state.selectedId }
        markedEntryId = row?.type == "session" ? row?.entryId : (row?.type == "entry" ? row?.id : nil)
        markedProjectId = row?.type == "proj" ? row?.id : nil
        expandedProjects = state.openProjects
    }
}

public struct TrainerStep: Sendable {
    public let label: String
    public let textKey: String
    public let isDone: @Sendable (TrainerFacts) -> Bool
}

public struct TrainerLesson: Sendable {
    public let id: String
    public let titleKey: String
    public let steps: [TrainerStep]
    public let wayKey: String
    public let blind: Bool
    public let matches: @Sendable (Intent) -> Bool
    public func currentStep(_ facts: TrainerFacts) -> Int? { steps.firstIndex { !$0.isDone(facts) } }
}

public enum TrainerLessons {
    private static func step(_ label: String, _ key: String, _ done: @escaping @Sendable (TrainerFacts) -> Bool) -> TrainerStep {
        .init(label: label, textKey: key, isDone: done)
    }
    private static func lesson(_ id: String, _ base: String, _ labels: [(String, @Sendable (TrainerFacts) -> Bool)], blind: Bool = false, matches: @escaping @Sendable (Intent) -> Bool) -> TrainerLesson {
        .init(id: id, titleKey: "trainer." + id, steps: labels.enumerated().map { step($0.element.0, "trainer.\(base).\($0.offset + 1)", $0.element.1) }, wayKey: "trainer.\(base).way", blind: blind, matches: matches)
    }
    private static let never: @Sendable (TrainerFacts) -> Bool = { _ in false }
    private static let find: [(String, @Sendable (TrainerFacts) -> Bool)] = [(t("trainer.input.find"), { $0.markedEntryId == "suchen" }), ("↵", never)]
    private static let deadline: [(String, @Sendable (TrainerFacts) -> Bool)] = [("{task}", { $0.listMode == .ziel }), (t("trainer.input.text"), { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), (t("trainer.input.due"), { $0.hasDeadline }), ("↵", never)]
    private static let start: [(String, @Sendable (TrainerFacts) -> Bool)] = [("↓", { $0.markedEntryId == "offen" }), ("↵", never)]
    public static let all: [TrainerLesson] = [
        lesson("weitermachen", "weitermachen", [("{popover}", { $0.hotkeyPressed }), ("↵", never)], matches: { if case .resumeEntry = $0 { true } else { false } }),
        lesson("finden", "finden", find, matches: { if case .resumeEntry("suchen", _, _) = $0 { true } else { false } }),
        lesson("merken", "merken", [("{task}", { $0.listMode == .ziel }), ("Text", { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), ("↵", never)], matches: { if case .addTask(_, _, nil, nil) = $0 { true } else { false } }),
        lesson("deadline", "deadline", deadline, matches: { if case .addTask(_, _, .some, nil) = $0 { true } else { false } }),
        lesson("anfangen", "anfangen", start, matches: { if case .startEntry = $0 { true } else { false } }),
        lesson("ueberblicken", "ueberblicken", [("↓", { $0.markedProjectId == "prj_karte" }), ("↵", never)], matches: { _ in false }),
        lesson("erledigen", "erledigen", [("⌘⌫", never)], matches: { if case .archiveEntry = $0 { true } else { false } }),
        lesson("abschluss_finden", "finden", [("Text", { $0.markedEntryId == "suchen" }), ("↵", never)], blind: true, matches: { if case .resumeEntry("suchen", _, _) = $0 { true } else { false } }),
        lesson("abschluss_deadline", "deadline", deadline, blind: true, matches: { if case .addTask(_, _, .some, nil) = $0 { true } else { false } }),
        lesson("abschluss_anfangen", "anfangen", start, blind: true, matches: { if case .startEntry("offen", _, _) = $0 { true } else { false } })
    ]
}

public struct TrainerState: Sendable, Equatable {
    public var lesson: Int
    public var success = false
    public var hotkeyPressed = false
    public var wrongKey: String?
    public var tipped = false
    public var finalWithoutTip = 0
    public var passed = 0
    public init(lesson: Int = 0) { self.lesson = lesson }
}
