// The core of curtain: holds the single UI state and snapshot, turns raw input into events,
// executes intents through the services and sends only changed regions to the web view.
// Main actor for state; every service call is awaited off the main thread.

import Foundation
import RBContract
import RBStore
import RBPlatform
import RBTerminal
import RBUI

/// What the web view applies (ui/bridge.js `apply`).
public struct ViewUpdate: Sendable, Equatable, Encodable {
    public var screen: String
    public var skeleton: String?
    public var regions: [[String]]
    public var focus: String?
    public var selectAll: Bool
    public var values: [String: String]

    public var isEmpty: Bool { skeleton == nil && regions.isEmpty && values.isEmpty }
}

/// Things only the AppKit shell can do.
@MainActor
public protocol EngineHost: AnyObject {
    func push(_ update: ViewUpdate)
    func closePopover()
    func openSettings()
    func copyToPasteboard(_ text: String)
    func startHotkeyRecording(_ slot: HotkeySlot)
    func endHotkeyRecording()
    func screenChanged(_ screen: Screen)
    /// Bring a terminal app to the front (no Apple Event; NSRunningApplication).
    func activate(_ app: TerminalApp)
    /// Settings loaded or changed (hotkeys are registered by the shell).
    func settingsChanged(_ settings: Settings)
    func prepareHotkey(_ slot: HotkeySlot, combo: String) -> Bool
    /// Number of sessions that just ended without a pin.
    func justEndedChanged(_ count: Int)
    func menuBarIconChanged(_ icon: Logic.MenuBarIcon)
}

public extension EngineHost {
    func prepareHotkey(_ slot: HotkeySlot, combo: String) -> Bool { true }
    func endHotkeyRecording() {}
    func menuBarIconChanged(_ icon: Logic.MenuBarIcon) {}
}

public struct Services: Sendable {
    public var index: any SessionIndexing
    public var live: any LiveMonitoring
    public var store: any EntryStoring
    public var terminal: any TerminalControlling
    public var platform: any PlatformProviding

    public init(index: any SessionIndexing, live: any LiveMonitoring, store: any EntryStoring,
                terminal: any TerminalControlling, platform: any PlatformProviding) {
        self.index = index
        self.live = live
        self.store = store
        self.terminal = terminal
        self.platform = platform
    }
}

@MainActor
public final class Engine: RBServing {
    public private(set) var state = UIState()
    public weak var host: EngineHost?

    let services: Services
    private var indexResult = IndexResult(projects: [], sessions: [], skippedFiles: 0)
    public private(set) var snapshot: Snapshot
    private var rebuildGeneration = 0
    private var popoverOpen = false
    private var stripSeen: Set<String> = []
    private var bannerSeen: Set<String> = []
    private let assignment = SessionAssignment()
    private var liveState = LiveState(running: [:], ended: [], resumeCounts: [:])
    private var rawContext: Context?
    private var justEnded: [String] = []
    private var sentScreen: Screen?
    private var sentSkeleton: String?
    private var sentRegions: [String: String] = [:]
    private var sentEditing = false
    private var tasks: [Task<Void, Never>] = []
    // Opt-in tracing for design scenarios; normal application input does not retain intents.
    private var scenarioTracing = false
    private var scenarioEffects = 0
    private var fixtureEffects = ReplayEffects()
    private var trainerData: Data?
    private var activeRealWork = 0
    private var pendingTrainer: (Int, Bool)?

    private func startPendingTrainerIfReady() {
        guard activeRealWork == 0, let pending = pendingTrainer else { return }
        pendingTrainer = nil
        _ = beginTrainer(lesson: pending.0, success: pending.1)
        push()
    }
    var trainerSaved: (Snapshot, UIState)?
    private var trainerPractice: Snapshot?
    private var trainerDone: [String] = []
    private var trainerWrite: Task<Void, Never>?

    public func configureTrainer(data: Data?) { trainerData = data }

    @discardableResult public func beginTrainer(lesson: Int = 0, success: Bool = false) -> ViewUpdate {
        guard trainerSaved == nil, let data = trainerData,
              var practice = try? RBJSON.decoder().decode(Snapshot.self, from: data) else { return render(force: false) }
        if activeRealWork > 0 {
            pendingTrainer = (lesson, success)
            return render(force: false)
        }
        rebuildGeneration += 1
        trainerSaved = (snapshot, state)
        trainerDone = snapshot.settings.trainerDone
        practice.settings.hotkeys = snapshot.settings.hotkeys
        trainerPractice = practice
        resetTrainer(lesson: max(0, min(lesson, TrainerLessons.all.count)), success: success)
        return render(force: true)
    }

    private func resetTrainer(lesson: Int, success: Bool = false) {
        guard let practice = trainerPractice else { return }
        let finalWithoutTip = state.trainer?.finalWithoutTip ?? 0
        let passed = state.trainer?.passed ?? 0
        snapshot = practice
        state = UIState()
        state.trainer = TrainerState(lesson: lesson)
        state.trainer?.success = success
        state.trainer?.finalWithoutTip = finalWithoutTip
        state.trainer?.passed = passed
        _ = Reducer.reduce(&state, .opened, snapshot)
        fixtureEffects = ReplayEffects()
    }

    public func endTrainer() {
        pendingTrainer = nil
        guard let saved = trainerSaved else { return }
        snapshot = saved.0; state = saved.1
        if state.screen == .m00 && state.onboarding == .eingerichtet {
            state.screen = .m01
            _ = Reducer.reduce(&state, .opened, snapshot)
        }
        snapshot.settings.trainerDone = trainerDone
        trainerSaved = nil; trainerPractice = nil
        Task { [weak self] in await self?.rebuildAndPush() }
    }

    private func trainerInput(_ input: RawInput) -> Bool {
        guard var trainer = state.trainer else { return false }
        trainer.wrongKey = nil
        state.trainer = trainer
        if case let .key(k) = input {
            if (k.meta || k.ctrl) && k.key.lowercased() == "t" { return false }
            if k.key == "Escape", state.query.isEmpty, state.mode != .edit { endTrainer(); return true }
            if k.key == "Enter", trainer.success || trainer.lesson >= TrainerLessons.all.count {
                if trainer.lesson >= TrainerLessons.all.count { endTrainer() }
                else { resetTrainer(lesson: trainer.lesson + 1) }
                return true
            }
        }
        return trainer.success || trainer.lesson >= TrainerLessons.all.count
    }

    private func trainerWrong(_ key: String) {
        state.trainer?.wrongKey = key
        if let trainer = state.trainer, trainer.lesson < TrainerLessons.all.count, TrainerLessons.all[trainer.lesson].blind {
            state.trainer?.tipped = true
        }
    }

    @discardableResult public func trainerHotkey() -> ViewUpdate {
        guard let trainer = state.trainer, trainer.lesson < TrainerLessons.all.count, !trainer.success else { return render(force: false) }
        let lesson = TrainerLessons.all[trainer.lesson]
        let facts = TrainerFacts(state: state, snapshot: snapshot)
        if let step = lesson.currentStep(facts), lesson.steps[step].label == "{popover}" {
            state.trainer?.hotkeyPressed = true; state.trainer?.wrongKey = nil
        } else { trainerWrong("trainer.wrong.open") }
        return render(force: false)
    }

    @discardableResult public func trainerOtherHotkey() -> ViewUpdate {
        if state.trainer != nil { trainerWrong("trainer.wrong.other") }
        return render(force: false)
    }

    private func trainerPassed() {
        guard var trainer = state.trainer, trainer.lesson < TrainerLessons.all.count else { return }
        let lesson = TrainerLessons.all[trainer.lesson]
        trainer.success = true
        trainer.passed += 1
        if lesson.blind && !trainer.tipped { trainer.finalWithoutTip += 1 }
        if !trainerDone.contains(lesson.id) {
            trainerDone.append(lesson.id)
            let done = trainerDone, store = services.store, previous = trainerWrite
            trainerWrite = Task { await previous?.value; _ = try? await store.apply(.trainerDone(done)) }
        }
        state.trainer = trainer
        state.toast = nil; state.undoHint = false
    }

    private func trainerExecute(_ intents: [Intent], before: UIState, events: [UIEvent]) {
        guard let trainer = before.trainer, trainer.lesson < TrainerLessons.all.count else { return }
        let lesson = TrainerLessons.all[trainer.lesson]
        let facts = TrainerFacts(state: before, snapshot: snapshot)
        let ready = lesson.blind || lesson.steps.dropLast().allSatisfy { $0.isDone(facts) }
        let projectOpened = lesson.id == "ueberblicken" && facts.markedProjectId == "prj_karte" && !before.openProjects.contains("prj_karte") && state.openProjects.contains("prj_karte")
        if projectOpened && ready { trainerPassed(); return }
        if !intents.isEmpty {
            guard intents.count == 1, let intent = intents.first, lesson.matches(intent), ready else {
                let intent = intents[0]
                state = before
                if lesson.matches(intent) && !ready { trainerWrong("trainer.wrong.first") }
                else {
                    switch intent {
                    case .resumeEntry: trainerWrong("trainer.wrong.resume")
                    case .startEntry: trainerWrong("trainer.wrong.start")
                    case .addTask: trainerWrong("trainer.wrong.add")
                    case .archiveEntry: trainerWrong("trainer.wrong.archive")
                    default: trainerWrong("trainer.wrong.other")
                    }
                }
                return
            }
            if let result = fixtureEffects.apply(intent, to: &snapshot) {
                if case .taskAdded = result { _ = Reducer.reduce(&state, .result(result), snapshot) }
                trainerPassed()
            } else { state = before; trainerWrong("trainer.wrong.other") }
        } else if events.contains(.enter) || events.contains(.archive) {
            state = before; trainerWrong(events.contains(.archive) ? "trainer.wrong.archive" : "trainer.wrong.other")
        }
    }
    var scenarioTrace: [(Intent, IntentResult?)] = []

    func beginScenarioTrace() { scenarioTrace = []; scenarioTracing = true }
    func waitForScenarioEffects() async {
        while scenarioEffects > 0 { await Task.yield() }
    }

    /// Time source for the snapshot (relative ages); fixture runs pass the fixture's `now`.
    let clock: @Sendable () -> Date
    private var deadlineClock: DeadlineClock?
    var deadlineClockFactory: ((@escaping @MainActor () -> Void) -> DeadlineClock)?

    public init(services: Services, settings: Settings = .defaults, now: Date = .now,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.clock = clock
        self.snapshot = Snapshot(now: now, context: nil, settings: settings, projects: [], entries: [],
                                     sessions: [], windows: Windows(open: 0, closable: 0), justEnded: [], changes: [],
                                     permissions: Permissions(accessibility: false,
                                                              automation: .init(ghostty: .unknown, terminal: .unknown)))
    }

    // MARK: Lifecycle

    /// Loads everything once, then follows index and live updates.
    public func start() async {
        // Fixtures intentionally freeze time; a real timer would repeatedly schedule in the past.
        if deadlineClock == nil, !(services.index is FixtureServices.FixtureIndex) || deadlineClockFactory != nil {
            let onFire: @MainActor () -> Void = { [weak self] in self?.refreshDeadline() }
            let deadlineClock = deadlineClockFactory?(onFire) ?? DeadlineClock(now: clock, onFire: onFire)
            self.deadlineClock = deadlineClock
            deadlineClock.start()
        }
        let svc = services
        let settings = (try? await svc.store.loadSettings()) ?? snapshot.settings
        async let idx = try? await svc.index.scan(settings)
        async let lv = svc.live.current()
        async let perms = svc.platform.permissions()
        if let r = await idx { indexResult = r }
        liveState = await lv
        justEnded = liveState.ended
        snapshot.permissions = await perms
        snapshot.settings = settings
        await rebuild()
        if let fixture = (services.index as? FixtureServices.FixtureIndex)?.owner,
           let store = services.store as? FixtureServices.FixtureStore, store.owner === fixture {
            snapshot = fixture.snapshot
            state.listMode = fixture.fixtureMode == "aufgabe" ? .ziel : (UIState.ListMode(rawValue: fixture.fixtureMode ?? "resume") ?? .resume)
        }
        host?.menuBarIconChanged(Logic.menuBarIcon(snapshot))
        host?.settingsChanged(settings)
        tasks.append(Task { [weak self] in
            for await r in svc.index.updates(settings) { self?.indexResult = r; await self?.rebuildAndPush() }
        })
        tasks.append(Task { [weak self] in
            for await l in svc.live.updates(interval: .seconds(2)) { await self?.liveChanged(l) }
        })
    }

    /// Popover is about to show: refresh context, render from memory (no I/O on this path).
    /// `onboarding` shows the first start M00 instead of the list.
    public func popoverWillOpen(context: Context?, onboarding: Bool = false, mode: UIState.ListMode = .resume) -> ViewUpdate {
        popoverOpen = true
        if trainerSaved != nil {
            if mode == .ziel, state.trainer?.success == false, state.trainer!.lesson < TrainerLessons.all.count {
                state.trainer?.wrongKey = nil
                if state.listMode != .ziel { _ = Reducer.reduce(&state, .toggleMode, snapshot) }
            }
            return render(force: true)
        }
        rawContext = context
        snapshot.context = ContextProject.resolve(rawContext, in: snapshot)
        snapshot.now = clock()
        state.screen = onboarding ? .m00 : .m01
        state.listMode = mode
        _ = Reducer.reduce(&state, .opened, snapshot)
        return render(force: true)
    }

    /// Accept changes that were actually shown, without creating an undo step.
    public func popoverDidClose() {
        popoverOpen = false
        if trainerSaved == nil && !bannerSeen.isEmpty {
            let seenBanner = bannerSeen
            bannerSeen = []
            justEnded.removeAll { seenBanner.contains($0) }
            let shownEntries = Set(snapshot.justEnded.filter { id in
                snapshot.sessions(of: id).first.map { seenBanner.contains($0.id) } ?? false
            })
            snapshot.justEnded.removeAll { shownEntries.contains($0) }
            host?.justEndedChanged(snapshot.justEnded.count)
            Task { [weak self] in await self?.rebuildAndPush() }
        }
        let seen = stripSeen
        stripSeen = []
        guard !seen.isEmpty, trainerSaved == nil, let store = services.store as? any EntryChangeStoring else { return }
        activeRealWork += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.activeRealWork -= 1; self.startPendingTrainerIfReady() }
            do { try await store.acceptSeenChanges(seen); await self.rebuildAndPush() }
            catch { /* Keep the changes so they appear again. */ }
        }
    }

    /// Frontmost context arrived after the popover opened (platform probe runs off the main thread).
    public func contextChanged(_ context: Context) {
        guard trainerSaved == nil else { return }
        rawContext = context
        let resolved = ContextProject.resolve(rawContext, in: snapshot)
        guard resolved != snapshot.context else { return }
        let previousProject = snapshot.context?.projectId
        snapshot.context = resolved
        if state.screen == .m01 && !state.hasMarkedProject {
            state.markedProjectId = resolved?.projectId
            state.markedProjectInitialized = true
        }
        if previousProject == nil, let project = resolved?.projectId,
           state.screen == .m01, !state.hasMarkedProject, state.mode == .list, state.query.isEmpty, state.openProjects.isEmpty {
            state.openProjects = [project]
            state.selectedId = nil
            _ = Reducer.reduce(&state, .select(""), snapshot)
        }
        push()
    }

    public var platform: any PlatformProviding { services.platform }

    public func showPanel(_ panel: PanelState) -> ViewUpdate {
        state.screen = .m01s1
        state.panel = panel
        state.selectAll = true
        return render(force: true)
    }

    public func show(_ screen: Screen) -> ViewUpdate {
        state.screen = screen
        return render(force: true)
    }

    /// ⇧⌘R: the session comes from the marked text (session id or resume line) or, without a
    /// marking, from the running session in the frontmost terminal's folder (FLOWS: Merken im Terminal).
    public func openPinPanel(selection: String?, context: Context?) -> ViewUpdate {
        let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snap = snapshot
        var id: String?
        var source = PanelState.Source.selection
        if !text.isEmpty {
            if let (tool, uuid) = SessionIdParser.parse(text, commands: snap.settings.commands, known: { snap.session($0) != nil }) {
                id = snap.session(tool.idPrefix + uuid.lowercased())?.id
            }
        } else {
            source = .window
            let running = snap.sessions.filter { $0.live.running }
            if let tty = context?.tty {
                let matches = running.filter { $0.live.tty == tty }
                if matches.count == 1 { id = matches[0].id }
            } else if let cwd = context?.cwd {
                let matches = running.filter { $0.cwd == cwd }
                if matches.count == 1 { id = matches[0].id }
            }
        }
        let topic = id.flatMap(snapshot.session).flatMap { snapshot.entry($0.entryId) }.map { Logic.titleOf(snapshot, $0) }
            ?? ""
        state.toast = nil
        state.undoHint = false
        return showPanel(PanelState(sessionId: id, source: source, selectionText: text, text: topic, done: false))
    }

    /// Open and closable terminal windows (Apple Events, off the main thread); pushes only on change.
    public func refreshWindows() async {
        guard trainerSaved == nil else { return }
        activeRealWork += 1
        defer { activeRealWork -= 1; startPendingTrainerIfReady() }
        let terminal = services.terminal
        let known = Set(liveState.running.values.compactMap(\.tty))
        async let open = terminal.openWindowCount()
        async let closable = terminal.closableWindows(knownTTYs: known)
        let w = Windows(open: await open, closable: await closable.count)
        guard trainerSaved == nil else { return }
        guard w != snapshot.windows else { return }
        snapshot.windows = w
        await rebuildAndPush()
    }

    // MARK: Input

    public func handle(_ input: RawInput) -> ViewUpdate {
        if state.trainer != nil && trainerInput(input) { return render(force: false) }
        let events = KeyMap.events(for: input, state: state)
        if state.trainer != nil && events.contains(.openSettings) { trainerWrong("trainer.wrong.other"); return render(force: false) }
        if events.contains(.trainer) {
            if state.trainer == nil { return beginTrainer() }
            if let trainer = state.trainer, trainer.lesson < TrainerLessons.all.count { resetTrainer(lesson: trainer.lesson + 1) }
            return render(force: false)
        }
        let beforeTrainer = state
        var intents: [Intent] = []
        let wasRecording = state.recording != nil
        for event in events {
            intents += Reducer.reduce(&state, event, snapshot)
        }
        if wasRecording && state.recording == nil { host?.endHotkeyRecording() }
        if state.trainer != nil { trainerExecute(intents, before: beforeTrainer, events: events); return render(force: false) }
        var update = render(force: false)
        if case .setting = input, intents.isEmpty { update.values.merge(settingValues()) { _, new in new } }
        if !intents.isEmpty { execute(intents) }
        return update
    }

    /// Apply the design fixture after its surface is shown, including prototype effects.
    public func replayFixture(data: Data, snapshot fixture: Snapshot) throws -> ViewUpdate {
        struct Meta: Decodable {
            struct UI: Decodable {
                struct Panel: Decodable { let sessionId: String?; let source: String; let selectionText: String; let text: String; let done: Bool }
                struct ReplayStep: Decodable {
                    let values: [String]
                    init(from decoder: Decoder) throws {
                        var container = try decoder.unkeyedContainer()
                        var values: [String] = []
                        while !container.isAtEnd {
                            if let string = try? container.decode(String.self) { values.append(string) }
                            else { values.append(String(try container.decode(Int.self))) }
                        }
                        self.values = values
                    }
                }
                let panel: Panel?; let selectAll: Bool?; let replay: [ReplayStep]?; let mode: String?
            }
            let _screen: String; let _state: String; let _ui: UI?
        }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        snapshot = fixture
        state = UIState()
        state.listMode = meta._ui?.mode == "aufgabe" ? .ziel : (UIState.ListMode(rawValue: meta._ui?.mode ?? "resume") ?? .resume)
        state.screen = Screen(rawValue: meta._screen) ?? .m01
        if state.screen == .m00 { state.onboarding = UIState.OnboardingStep(rawValue: meta._state) ?? .berechtigung }
        if let p = meta._ui?.panel {
            var text = p.text
            if let id = p.sessionId, text.isEmpty, let session = snapshot.session(id), let entry = snapshot.entry(session.entryId) {
                text = Logic.titleOf(snapshot, entry)
            }
            state.panel = PanelState(sessionId: p.sessionId, source: PanelState.Source(rawValue: p.source) ?? .selection,
                                     selectionText: p.selectionText, text: text, done: p.done)
        }
        state.selectAll = meta._ui?.selectAll ?? false
        if state.screen == .m01 && !snapshot.justEnded.isEmpty { state.focus = .banner }
        if state.screen == .m01 { _ = Reducer.reduce(&state, .opened, snapshot) }
        fixtureEffects = ReplayEffects()
        for step in meta._ui?.replay ?? [] {
            guard let event = UIEvent.replay(step.values) else { continue }
            var queue = Reducer.reduce(&state, event, snapshot)
            while !queue.isEmpty {
                let intent = queue.removeFirst()
                let result = fixtureEffects.apply(intent, to: &snapshot)
                applyStartState(intent, result: result)
                if let result {
                    if !fixtureStart(intent, result: result) { queue += Reducer.reduce(&state, .result(panelResult(intent, result)), snapshot) }
                }
            }
        }
        return render(force: true)
    }

    /// Initial render after the web view loaded.
    public func ready() -> ViewUpdate { render(force: true) }

    // MARK: Intents

    private func execute(_ intents: [Intent]) {
        let svc = services
        let snap = snapshot
        let panelID = state.screen == .m01s1 ? state.panel?.instanceID : nil
        if scenarioTracing { scenarioEffects += 1 }
        activeRealWork += 1
        Task { [weak self] in
            defer {
                if let self {
                    if self.scenarioTracing { self.scenarioEffects -= 1 }
                    self.activeRealWork -= 1
                    self.startPendingTrainerIfReady()
                }
            }
            for intent in intents {
                guard let self else { return }
                let outcome: IntentResult?
                if self.scenarioTracing {
                    outcome = self.fixtureEffects.apply(intent, to: &self.snapshot)
                    self.scenarioTrace.append((intent, outcome))
                    if case let .taskAdded(id) = outcome {
                        switch intent {
                        case let .addTask(_, _, _, .some(tool)), let .newStrang(_, _, tool, _):
                            self.scenarioTrace.append((.startEntry(entryId: id, tool: tool, terminal: nil), .opened(app: self.snapshot.settings.terminal.default, sessionId: nil)))
                        default: break
                        }
                    }
                    self.applyStartState(intent, result: outcome)
                } else {
                    outcome = await self.run(intent, svc, snap)
                    if self.scenarioTracing { self.scenarioTrace.append((intent, outcome)) }
                    self.applyStartState(intent, result: outcome)
                }
                if let result = outcome {
                    if self.fixtureStart(intent, result: result) { self.push(); continue }
                    switch intent {
                    case .panelName:
                        if let panelID {
                            guard self.state.screen == .m01s1, self.state.panel?.instanceID == panelID,
                                  self.state.panel?.saving == true else { continue }
                        } else if self.state.screen == .m01s1 { continue }
                    default:
                        if self.state.screen == .m01s1 {
                            switch result {
                            case .topicSet, .saveFailed: continue
                            default: break
                            }
                        }
                    }
                    self.feed(.result(self.panelResult(intent, result)))
                }
            }
        }
    }

    private func panelResult(_ intent: Intent, _ result: IntentResult) -> IntentResult {
        guard case let .panelName(sessionID, _) = intent else { return result }
        switch result {
        case .entryTitleSet: return .topicSet(sessionId: sessionID)
        case .entrySaveFailed: return .saveFailed(sessionId: sessionID)
        default: return result
        }
    }

    private func applyStartState(_ intent: Intent, result: IntentResult?) {
        let id: String, tool: Tool
        switch (intent, result) {
        case let (.startEntry(entryId, startTool, _), .opened), let (.startGoal(entryId, startTool, _), .opened): id = entryId; tool = startTool
        case let (.addTask(_, _, _, .some(startTool)), .taskAdded(entryId)),
             let (.newStrang(_, _, startTool, _), .taskAdded(entryId)): id = entryId; tool = startTool
        default: return
        }
        guard let entry = snapshot.entry(id) else { return }
        let folder = snapshot.project(entry.projectId)?.rootPath ?? Logic.startFolder(settings: snapshot.settings, projects: snapshot.projects, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let app: TerminalApp
        switch (intent, result) {
        case let (_, .opened(openedApp, _)): app = openedApp
        case let (.newStrang(_, _, _, terminal), _): app = terminal ?? snapshot.settings.terminal.default
        default: app = snapshot.settings.terminal.default
        }
        let cwd = folder.replacingOccurrences(of: "^/Users/[^/]+", with: "~", options: .regularExpression)
        state.listMode = .resume; state.query = ""; state.chips = []; state.selectedId = "e:" + id
        let projectKey = entry.projectId ?? "_none"
        if !state.openProjects.contains(projectKey) { state.openProjects.append(projectKey) }
        state.focus = .list; state.undoHint = true
        state.notes["e:" + id] = Note(kind: .ok, text: t("m01.row.started"))
        let prompt: String
        if case .startGoal = intent { prompt = "/goal " + (entry.title ?? "") } else { prompt = entry.title ?? "" }
        state.toast = Note(kind: .ok, text: t("m01.toast.new", ["app": app.displayName, "cwd": cwd, "cmd": Logic.newCommand(snapshot, tool, prompt)]))
    }

    private func fixtureStart(_ intent: Intent, result: IntentResult) -> Bool {
        switch (intent, result) {
        case (.startEntry, .opened), (.startGoal, .opened), (.addTask(_, _, _, .some), .taskAdded), (.newStrang, .taskAdded): return true
        default: return false
        }
    }

    func run(_ intent: Intent, _ svc: Services, _ snap: Snapshot) async -> IntentResult? {
        switch intent {
        case let .resumeEntry(entryId, sessionId, terminal):
            let sessions = snapshot.sessions(of: entryId)
            guard let session = sessionId.map({ id in sessions.first { $0.id == id } }) ?? sessions.first,
                  let s = snap.session(session.id) else { return nil }
            let id = s.id
            guard s.resumable else { return .notResumable(sessionId: id, path: s.transcriptPath) }
            let app = terminal ?? snap.settings.terminal.default
            do {
                if s.live.running {
                    let runApp = s.live.terminalApp ?? app
                    do {
                        guard let tty = s.live.tty else { throw AppleScriptTerminal.Failure.unsupported }
                        try await svc.terminal.focus(app: runApp, tty: tty)
                    } catch AppleScriptTerminal.Failure.unsupported {
                        // Ghostty < 1.4 cannot address a window by tty. A second client on a running session
                        // would compete for it, so bring the terminal app forward instead of opening again.
                        host?.activate(runApp)
                    }
                    host?.closePopover()
                    return .focused(app: runApp, sessionId: id)
                }
                try await svc.terminal.open(app: app, cwd: s.cwd, command: SnapshotBuilder.command(for: s, settings: snap.settings))
                host?.closePopover()
                return .opened(app: app, sessionId: id)
            } catch AppleScriptTerminal.Failure.missingDirectory(let path) {
                host?.copyToPasteboard(SnapshotBuilder.command(for: s, settings: snap.settings))
                return .folderMissing(path: path)
            } catch {
                return .terminalFailed(app: app, reason: String(describing: error))
            }
        case let .copyCommand(id):
            guard let s = snap.session(id) else { return nil }
            let cmd = SnapshotBuilder.command(for: s, settings: snap.settings)
            host?.copyToPasteboard(cmd)
            return .copied(command: cmd)
        case .dismissJustEnded:
            justEnded.removeAll()
            await rebuildAndPush()
            return nil
        case .undo:
            let label = try? await svc.store.undo()
            await rebuildAndPush()
            await refreshWindows()
            return label.map { .undone(label: $0) } ?? .undoEmpty
        case .cleanupWindows:
            let known = Set(liveState.running.values.compactMap(\.tty))
            let windows = await svc.terminal.closableWindows(knownTTYs: known)
            var closed: [TerminalWindow] = []
            for window in windows {
                closed.append(contentsOf: (try? await svc.terminal.close([window])) ?? [])
            }
            let terminal = svc.terminal
            if !closed.isEmpty {
                let restore = closed
                await svc.store.pushUndo(label: "undo.cleanup") {
                    for w in restore { try? await terminal.open(app: w.app, cwd: w.cwd ?? NSHomeDirectory(), command: "") }
                }
            }
            await refreshWindows()
            return .windowsClosed(count: closed.count)
        case let .updateSettings(patch):
            if case let .hotkey(slot, combo) = patch, host?.prepareHotkey(slot, combo: combo) == false {
                host?.push(ViewUpdate(screen: state.screen.rawValue, skeleton: nil, regions: [], focus: nil,
                                      selectAll: false, values: settingValues()))
                return .settingsRejected(reason: "Shortcut unavailable")
            }
            do {
                snapshot.settings = try await svc.store.apply(patch)
                await rebuildAndPush()
                host?.settingsChanged(snapshot.settings)
                return .settingsSaved
            } catch {
                if case let .hotkey(slot, _) = patch {
                    let old = slot == .popover ? snap.settings.hotkeys.popover : snap.settings.hotkeys.pin
                    _ = host?.prepareHotkey(slot, combo: old)
                }
                host?.push(ViewUpdate(screen: state.screen.rawValue, skeleton: nil, regions: [], focus: nil,
                                      selectAll: false, values: settingValues()))
                return .settingsRejected(reason: String(describing: error))
            }
        case let .recordHotkey(slot):
            host?.startHotkeyRecording(slot)
            return nil
        case .requestAccessibility:
            await svc.platform.requestAccessibility()
            snapshot.permissions = await svc.platform.permissions()
            await rebuildAndPush()
            return nil
        case .closePopover:
            host?.closePopover()
            return nil
        case .openSettings:
            host?.openSettings()
            return nil
        case let .startEntry(entryId, tool, terminal), let .startGoal(entryId, tool, terminal):
            guard let entry = snap.entry(entryId) else { return .entrySaveFailed(entryId: entryId) }
            let title = Logic.titleOf(snap, entry)
            guard !title.isEmpty else { return .entrySaveFailed(entryId: entryId) }
            let folder = snap.project(entry.projectId)?.rootPath ?? Logic.startFolder(settings: snap.settings, projects: snap.projects, home: FileManager.default.homeDirectoryForCurrentUser.path)
            let app = terminal ?? snap.settings.terminal.default
            let prompt: String
            if case .startGoal = intent { prompt = "/goal " + title } else { prompt = title }
            let command = "RB_ENTRY=\(entry.id) " + snap.settings.newCommands[tool] + " " + svc.terminal.quoted(prompt)
            let reservation = await assignment.started(entryID: entryId, folder: folder, at: clock(),
                                                       known: Set(indexResult.sessions.map(\.id)))
            do {
                try await svc.terminal.open(app: app, cwd: folder, command: command)
                host?.closePopover()
                return .opened(app: app, sessionId: nil)
            } catch AppleScriptTerminal.Failure.missingDirectory(let path) {
                await assignment.cancel(reservation)
                host?.copyToPasteboard(command)
                return .folderMissing(path: path)
            } catch { await assignment.cancel(reservation); return .terminalFailed(app: app, reason: String(describing: error)) }
        case let .addTask(title, projectId, deadline, start):
            let id = "e_" + UUID().uuidString.lowercased()
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...200).contains(title.count) else { return .entrySaveFailed(entryId: id) }
            let now = clock()
            let entry = Entry(id: id, projectId: projectId, title: title, status: .offen, deadline: deadline,
                              createdBy: .user, createdAt: now, updatedAt: now)
            do { try await svc.store.save(entry, undoLabel: t("undo.add")); await rebuildAndPush() }
            catch { return .entrySaveFailed(entryId: id) }
            if let start {
                let result = await run(.startEntry(entryId: id, tool: start, terminal: nil), svc, snapshot)
                if case .opened = result {} else { return result ?? .entrySaveFailed(entryId: id) }
            }
            return .taskAdded(entryId: id)
        case let .newStrang(title, projectId, tool, terminal):
            let id = "e_" + UUID().uuidString.lowercased()
            let now = clock()
            let entry = Entry(id: id, projectId: projectId, title: title, status: .offen, createdBy: .user,
                              createdAt: now, updatedAt: now)
            do { try await svc.store.save(entry, undoLabel: t("undo.start")); await rebuildAndPush() }
            catch { return .entrySaveFailed(entryId: id) }
            let result = await run(.startEntry(entryId: id, tool: tool, terminal: terminal), svc, snapshot)
            if case .opened = result { return .taskAdded(entryId: id) }
            return result
        case let .setTitle(id, title):
            return await saveEntry(id, label: "Titel", svc) { $0.title = title }
                ? .entryTitleSet(entryId: id) : .entrySaveFailed(entryId: id)
        case let .setDeadline(id, deadline):
            return await saveEntry(id, label: "Deadline", svc) { $0.deadline = deadline }
                ? .deadlineSet(entryId: id, deadline: deadline) : .entrySaveFailed(entryId: id)
        case let .setProject(id, projectId):
            guard snapshot.sessions(of: id).isEmpty, snapshot.project(projectId) != nil else { return .entrySaveFailed(entryId: id) }
            return await saveEntry(id, label: t("undo.project"), svc) { $0.projectId = projectId }
                ? .projectSet(entryId: id) : .entrySaveFailed(entryId: id)
        case let .cycleStatus(id):
            guard let entry = snapshot.entry(id), let newest = snapshot.sessions(of: id).first else { return .entrySaveFailed(entryId: id) }
            let now = clock()
            let ok = await saveEntry(id, label: "undo.status", svc) {
                if $0.title == nil { $0.title = newest.suggestedTitle }
                $0.status = entry.status.next; $0.statusChangedAt = now
            }
            return ok ? .entryStatusSet(entryId: id, from: entry.status, to: entry.status.next) : .entrySaveFailed(entryId: id)
        case let .archiveEntry(id):
            let now = clock()
            return await saveEntry(id, label: "undo.archive", svc, { $0.status = .erledigt; $0.statusChangedAt = now; $0.archivedAt = now })
                ? .entryArchived(entryId: id) : .entrySaveFailed(entryId: id)
        case let .nameJustEnded(id, title):
            guard let suggestion = snapshot.sessions(of: id).first?.suggestedTitle else { return .entrySaveFailed(entryId: id) }
            return await saveEntry(id, label: "Benennen", svc) { $0.title = title ?? suggestion }
                ? .entryTitleSet(entryId: id) : .entrySaveFailed(entryId: id)
        case .acceptChanges:
            guard let store = svc.store as? any EntryChangeStoring else { return nil }
            do { try await store.acceptChanges(undoLabel: t("undo.acceptChanges")); await rebuildAndPush(); return .changesAccepted }
            catch { return nil }
        case let .revertChange(id):
            guard let change = snapshot.changes.first(where: { $0.id == id }), var entry = snapshot.entry(change.entryId) else { return nil }
            let title = entry.title ?? snapshot.sessions(of: entry.id).first?.suggestedTitle ?? ""
            do {
                switch change.kind {
                case .add:
                    guard let store = svc.store as? any EntryChangeStoring else { return .entrySaveFailed(entryId: entry.id) }
                    let seeds = snapshot.sessions(of: entry.id).map { session in
                        StrandSeed(sessionId: session.id,
                                   entry: Entry(id: "e_" + UUID().uuidString.lowercased(), projectId: session.projectId,
                                                title: nil, status: .offen, createdBy: .user,
                                                createdAt: session.startedAt, updatedAt: session.startedAt))
                    }
                    try await store.revertAddedChange(id: id, seeds: seeds, undoLabel: t("undo.revertChange"))
                case .done:
                    guard let store = svc.store as? any EntryChangeStoring else { return .entrySaveFailed(entryId: entry.id) }
                    entry.status = .offen; entry.archivedAt = nil; entry.statusChangedAt = clock(); entry.updatedAt = clock(); entry.doneBy = nil
                    try await store.revertDoneChange(id: id, entry: entry, undoLabel: t("undo.revertChange"))
                }
                await rebuildAndPush(); return .changeReverted(title: title)
            } catch { return .entrySaveFailed(entryId: entry.id) }
        case let .panelName(sessionId, title):
            guard let entryId = snapshot.session(sessionId)?.entryId else { return nil }
            return await run(.setTitle(entryId: entryId, title: title), svc, snap)
        }
    }

    private func saveEntry(_ id: String, label: String, _ svc: Services,
                             _ change: (inout Entry) -> Void) async -> Bool {
        guard var entry = snapshot.entry(id) else { return false }
        change(&entry); entry.updatedAt = clock()
        do { try await svc.store.save(entry, undoLabel: label); await rebuildAndPush(); return true }
        catch { return false }
    }

    private func settingValues() -> [String: String] {
        let settings = snapshot.settings
        return ["setting:commands.codex": settings.commands.codex, "setting:commands.claude": settings.commands.claude,
                "setting:archiveDays": String(settings.archiveDays), "setting:cleanupThreshold": String(settings.cleanupThreshold)]
    }

    // MARK: Updates

    public func feed(_ event: UIEvent) {
        if state.trainer != nil && event == .openSettings { trainerWrong("trainer.wrong.other"); push(); return }
        if event == .trainer { if let trainer = state.trainer { if trainer.lesson < TrainerLessons.all.count { resetTrainer(lesson: trainer.lesson + 1); push() } } else { _ = beginTrainer(); push() }; return }
        if let trainer = state.trainer {
            if trainer.success || trainer.lesson >= TrainerLessons.all.count {
                if event == .enter {
                    if trainer.lesson >= TrainerLessons.all.count { endTrainer() }
                    else { resetTrainer(lesson: trainer.lesson + 1) }
                    push()
                }
                return
            }
            state.trainer?.wrongKey = nil
            let before = state
            let intents = Reducer.reduce(&state, event, snapshot)
            trainerExecute(intents, before: before, events: [event]); push(); return
        }
        let wasRecording = state.recording != nil
        let intents = Reducer.reduce(&state, event, snapshot)
        if wasRecording && state.recording == nil { host?.endHotkeyRecording() }
        push()
        if !intents.isEmpty { execute(intents) }
    }

    private func liveChanged(_ l: LiveState) async {
        justEnded += l.ended.filter { !justEnded.contains($0) }
        liveState = l
        await rebuildAndPush()
    }

    private func rebuild() async {
        guard trainerSaved == nil else { return }
        activeRealWork += 1
        defer { activeRealWork -= 1; startPendingTrainerIfReady() }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let source = snapshot
        guard var next = try? await SnapshotBuilder.build(index: indexResult, store: services.store, live: liveState,
                                                            settings: source.settings, context: source.context,
                                                            windows: source.windows, ended: justEnded,
                                                            permissions: source.permissions, now: clock(), assignment: assignment),
              generation == rebuildGeneration, trainerSaved == nil else { return }
        let endedBefore = snapshot.justEnded.count
        next.now = clock()
        next.context = ContextProject.resolve(rawContext, in: next); next.settings = snapshot.settings
        next.windows = snapshot.windows; next.permissions = snapshot.permissions
        snapshot = next
        if snapshot.justEnded.count != endedBefore { host?.justEndedChanged(snapshot.justEnded.count) }
        host?.menuBarIconChanged(Logic.menuBarIcon(next))
    }

    private func refreshDeadline() {
        guard trainerSaved == nil else { return }
        snapshot.now = clock()
        host?.menuBarIconChanged(Logic.menuBarIcon(snapshot))
        push()
    }

    func rebuildAndPush() async {
        await rebuild()
        push()
    }

    public func setRBLink(_ link: UIState.RBLinkState, otherCommands: [String]) {
        state.rbLink = link; state.rbOtherCommands = otherCommands
        if host != nil { push() }
    }

    private func push() {
        let u = render(force: false)
        host?.push(u)
    }

    /// Renders the current state and returns only what changed since the last update.
    public func render(force: Bool) -> ViewUpdate {
        let r = Renderer.render(state, snapshot)
        // A new skeleton goes out when the screen changes or its frame differs (M00 berechtigung → eingerichtet).
        let newScreen = force || sentScreen != r.screen || sentSkeleton != r.skeleton
        if newScreen {
            let changed = sentScreen != r.screen
            sentRegions = [:]; sentScreen = r.screen; sentSkeleton = r.skeleton
            if changed || force { host?.screenChanged(r.screen) }
        }
        var regions: [[String]] = []
        var replaced: [String] = []
        for (name, html) in r.regions {
            // Keep the live edit input in place until editing ends, even if context regroups the list.
            if name == "body", !newScreen, sentEditing, state.mode == .edit, !state.help { continue }
            let parentReplaced = replaced.contains { $0.contains("data-region=\"\(name)\"") }
            if sentRegions[name] != html || parentReplaced {
                regions.append([name, html])
                sentRegions[name] = html
                replaced.append(html)
            }
        }
        if popoverOpen && trainerSaved == nil && Renderer.stripAvailable(state, snapshot),
           regions.contains(where: { $0.first == "body" && $0.last?.contains("class=\"strip\"") == true }) {
            stripSeen.formUnion(snapshot.changes.map(\.id))
        }
        if popoverOpen && trainerSaved == nil,
           regions.contains(where: { $0.first == "body" && $0.last?.contains("class=\"banner\"") == true }),
           let entry = snapshot.justEnded.first {
            bannerSeen.formUnion(snapshot.sessions(of: entry).map(\.id).filter { justEnded.contains($0) })
        }
        sentEditing = r.screen == .m01 && state.mode == .edit && !state.help
        return ViewUpdate(screen: r.screen.rawValue, skeleton: newScreen ? r.skeleton : nil, regions: regions,
                          focus: r.focus, selectAll: r.selectAll, values: r.fieldValues)
    }
}
