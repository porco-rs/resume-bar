// AppKit shell: status item, three surfaces, hotkeys, engine wiring.
//   popover   M00 (first start) and M01 (list) · NSPopover from the status item
//   panel     M01-S1 (pin a session) · non-activating NSPanel over the terminal (⇧⌘R)
//   settings  M02 · window (⌘, or right click on the icon)
// One engine with one active screen. Each surface keeps a warm web view and receives only updates for
// its screens; switching surfaces forces a full render into the new one. macOS 26 path (target/action).

import AppKit
import os
import RBContract
import RBEngine
import RBServer
import RBIndex
import RBLive
import RBPlatform
import RBStore
import RBTerminal
import RBUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EngineHost, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var statusItem27: AnyObject?
    private let popover = NSPopover()
    private var panel: PinPanel!
    private var settingsWindow: NSWindow?
    private var snapshotWindow: SnapshotWindow?
    private var engine: Engine!
    private var rbServer: RBServer?
    private var rbServerTask: Task<Void, Never>?
    private var popWeb: WebHost!
    private var panelWeb: WebHost!
    private var settingsWeb: WebHost?
    private var hotkeys = HotkeyCenter()
    private var taskHotkey = HotkeyCenter()
    private var registeredKeys: Settings.Hotkeys?
    private var recordingID: UUID?
    private var popoverRefreshTask: Task<Void, Never>?
    private var uiFiles: [String: Data] = [:]
    private var replayData: Data?
    private var replayFixture: FixtureServices?
    private var replayReady = false
    private var icons: (plain: NSImage?, dot: NSImage?, overdue: NSImage?) = (nil, nil, nil)
    private var openedAt: CFTimeInterval?
    private var panelCloseTask: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ResumeBar", category: "latency")
    private static let onboardedKey = "onboarded"
    private let args = CommandLine.arguments

    private var needsOnboarding: Bool {
        if let s = arg("--show") { return s == "M00" }
        return !args.contains("--fixture") && !UserDefaults.standard.bool(forKey: Self.onboardedKey)
    }

    private func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var isSnapshot: Bool { args.contains("--snapshot") }

    private func activateUnlessSnapshot() {
        if !args.contains("--snapshot") { NSApp.activate() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        SystemPlatform.startTracking()
        let fixturePath = arg("--fixture")
        Task {
            let loaded = await Task.detached { Self.loadAssets(fixturePath: fixturePath) }.value
            uiFiles = loaded.files
            replayData = loaded.data
            replayFixture = loaded.fixture
            setup(fixture: loaded.fixture)
        }
    }

    private func applyRenderSwitches() {
        if args.contains("--fixture") {
            let link: UIState.RBLinkState?
            switch arg("--rb-link") {
            case "linked": link = .linked
            case "taken": link = .taken
            case "failed": link = .failed
            case "unreachable": link = .unreachable
            case "notRemoved": link = .notRemoved
            default: link = nil
            }
            if let link { engine.setRBLink(link, otherCommands: arg("--rb-other").map { [$0] } ?? []) }
            else if let other = arg("--rb-other") { engine.setRBLink(.linked, otherCommands: [other]) }
        }
    }

    private func setup(fixture: FixtureServices?) {
        let fixtureNow = fixture?.snapshot.now
        let services = fixture?.services ?? Self.services()
        engine = Engine(services: services, settings: .defaults, clock: { fixtureNow ?? Date() })
        let trainerPath = AppLanguage.current == .en ? "/trainer/uebung.en.json" : "/trainer/uebung.json"
        engine.configureTrainer(data: uiFiles[trainerPath])
        applyRenderSwitches()
        engine.host = self
        popWeb = WebHost(engine: engine, files: uiFiles, surface: "popover", screens: [.m00, .m01], width: 440, snapshot: isSnapshot)
        panelWeb = WebHost(engine: engine, files: uiFiles, surface: "panel", screens: [.m01s1], width: 440, snapshot: isSnapshot)
        for web in [popWeb!, panelWeb!] { web.onForeign = { [weak self] u in self?.push(u) } }
        popWeb.onSize = { [weak self] size in self?.resizePopover(size) }
        popWeb.onPainted = { [weak self] in self?.painted(self?.popWeb) }
        panelWeb.onSize = { [weak self] size in self?.panel.fit(size) }
        panelWeb.onPainted = { [weak self] in self?.painted(self?.panelWeb) }

        let vc = NSViewController()
        vc.view = popWeb.webView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 440, height: 300)
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        panel = PinPanel(content: panelWeb.webView)

        if !isSnapshot {
            icons = (Self.icon(uiFiles["/icons/menubar.svg"]), Self.icon(uiFiles["/icons/menubar-dot.svg"]),
                     Self.icon(uiFiles["/icons/menubar-dot-overdue.svg"], template: false))
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem.button {
                button.image = icons.plain
                button.setAccessibilityLabel(t("menubar.a11y"))
                if #available(macOS 27, *) {
                    let delegate = StatusItem27(
                        item: statusItem,
                        show: { [weak self] in self?.beginExpandedSession() },
                        close: { [weak self] in self?.closePopoverFromSession() },
                        menu: { [weak self] in self?.showMenu() }
                    )
                    statusItem27 = delegate
                    statusItem.expandedInterfaceDelegate = delegate
                } else {
                    button.target = self
                    button.action = #selector(statusClicked)
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
            }
        }
        let firstRun = fixture == nil && !args.contains("--fixture") && UserDefaults.standard.object(forKey: Self.onboardedKey) == nil
        Task {
            if firstRun, let store = services.store as? SQLiteStore,
               (try? await store.hasStoredSettings()) == false {
                let installed = await Task.detached {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
                }.value
                let terminals = Logic.firstRunTerminals(ghosttyInstalled: installed)
                _ = try? await store.apply(.terminals(terminals))
            }
            await engine.start()
            screenChanged(engine.state.screen)
            // Test hooks without driving the UI:
            //   --open               open the popover after start
            //   --show M00|M02|M01-S1 [--selection <text>]   show that surface
            //   --rb-link <linked|taken|failed|unreachable|notRemoved> [--rb-other <path>]  fixture only
            //   --snapshot <png>     write the shown surface after its first paint, then quit
            try? await Task.sleep(for: .milliseconds(600))
            if args.contains("--snapshot") {
                Task.detached { try? await Task.sleep(for: .seconds(10)); FileHandle.standardError.write(Data("snapshot timeout\n".utf8)); exit(3) }
            }
            switch arg("--show") {
            case "M02": openSettings()
            case "M01-S1": showPin(selection: arg("--selection"), context: nil, window: nil)
            case "M00": toggle()
            default:
                if needsOnboarding || args.contains("--open") || args.contains("--snapshot") { toggle() }
            }
            if args.contains("--replay") || args.contains("--trainer") || args.contains("--trainer-success") || args.contains("--trainer-end") { await popoverRefreshTask?.value }
            if args.contains("--replay"), let data = replayData, let fixture = replayFixture,
               let update = try? engine.replayFixture(data: data, snapshot: fixture.snapshot) {
                push(update)
                applyRenderSwitches()
            }
            if let number = arg("--trainer"), let n = Int(number) {
                push(engine.beginTrainer(lesson: n))
            } else if let number = arg("--trainer-success"), let n = Int(number) {
                push(engine.beginTrainer(lesson: n, success: true))
            } else if args.contains("--trainer-end") {
                push(engine.beginTrainer(lesson: TrainerLessons.all.count))
            }
            if isSnapshot, let script = arg("--trainer-script"), engine.state.trainer != nil {
                for token in script.split(separator: ",", omittingEmptySubsequences: true) {
                    let part = String(token)
                    if part == "hotkey:popover" { push(engine.trainerHotkey()) }
                    else if part == "hotkey:task" { push(engine.popoverWillOpen(context: nil, mode: .ziel)) }
                    else if part.hasPrefix("text:") { push(engine.handle(.text(field: "q", value: String(part.dropFirst(5))))) }
                    else if part.hasPrefix("key:") {
                        let key = String(part.dropFirst(4)), meta = key.hasSuffix("+meta")
                        push(engine.handle(.key(KeyPress(key: meta ? String(key.dropLast(5)) : key, meta: meta, fieldEmpty: engine.state.query.isEmpty))))
                    }
                }
            }
            replayReady = true
            if args.contains("--replay") || args.contains("--trainer") || args.contains("--trainer-success") || args.contains("--trainer-end") {
                let web = engine.state.screen == .m01s1 ? panelWeb : (engine.state.screen == .m02 ? settingsWeb : popWeb)
                snapshotIfRequested(web)
            }
        }
    }

    static func services() -> Services {
        let store = SQLiteStore()
        return Services(index: SessionIndex(), live: LiveMonitor(store: store), store: store,
                        terminal: AppleScriptTerminal(), platform: SystemPlatform())
    }

    nonisolated private static func loadAssets(fixturePath: String?) -> (files: [String: Data], data: Data?, fixture: FixtureServices?) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ui")
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("ui")
        let root = bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) ? $0 : nil } ?? fallback
        let names = ["index.html", "tokens.css", "app.css", "shell.css", "bridge.js", "icons/menubar.svg", "icons/menubar-dot.svg", "icons/menubar-dot-overdue.svg", "trainer/uebung.json", "trainer/uebung.en.json"]
        var files: [String: Data] = [:]
        for name in names { files["/" + name] = try? Data(contentsOf: root.appendingPathComponent(name)) }
        let url = fixturePath.map { URL(fileURLWithPath: $0) }
        return (files, url.flatMap { try? Data(contentsOf: $0) }, url.flatMap { try? FixtureServices(fixture: $0) })
    }

    private static func icon(_ data: Data?, template: Bool = true) -> NSImage? {
        let image = data.flatMap { NSImage(data: $0) }
        image?.isTemplate = template
        return image
    }

    // MARK: Status item

    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() } else { toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: t("menu.settings"), action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsAction() { openSettings() }

    // MARK: Popover

    @objc func toggle() {
        performPopoverAction(for: .click)
    }

    private func popoverHotkey() {
        performPopoverAction(for: .hotkey)
    }

    private func performPopoverAction(for trigger: PopoverTrigger) {
        if trigger == .hotkey, engine.state.trainer != nil { popWeb.apply(engine.trainerHotkey()); return }
        switch PopoverAction.decide(trigger: trigger, isShown: popover.isShown) {
        case .open: showPopover(mode: .resume)
        case .close: popover.performClose(nil)
        case .toggleMode: popWeb.apply(engine.handle(.action("toggleMode", arg: nil)))
        }
    }

    private func showPopover(mode: UIState.ListMode = .resume) {
        if popover.isShown {
            if mode == .ziel { popWeb.apply(engine.popoverWillOpen(context: engine.snapshot.context, mode: mode)) }
            return
        }
        if !isSnapshot, statusItem?.button == nil { return }
        closePanel()
        openedAt = CACurrentMediaTime()
        popWeb.apply(engine.popoverWillOpen(context: nil, onboarding: needsOnboarding, mode: mode))
        if isSnapshot {
            snapshotWindow = SnapshotWindow(content: popWeb.webView, width: 440)
        } else if let button = statusItem.button {
            activateUnlessSnapshot()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeFirstResponder(popWeb.webView)
        }
        let platform = engine.platform
        popoverRefreshTask = Task { [weak self] in
            let context = await platform.frontmostContext()
            self?.engine.contextChanged(context)
            await self?.engine.refreshWindows()
        }
    }

    private func beginExpandedSession() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func resizePopover(_ size: CGSize) {
        let h = min(max(size.height, 60), 600)
        if abs(popover.contentSize.height - h) > 0.5 { popover.contentSize = NSSize(width: 440, height: h) }
    }

    /// Give focus back to the app that was frontmost before the popover (e.g. the terminal).
    func popoverDidClose(_ notification: Notification) {
        engine.popoverDidClose()
        engine.endTrainer()
        if #available(macOS 27, *) { statusItem?.expandedInterfaceSession?.cancel() }
        if settingsWindow?.isVisible != true { NSApp.hide(nil) }
    }

    private func closePopoverFromSession() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: Pin panel (⇧⌘R)

    private func pinHotkey() {
        if engine.state.trainer != nil { popWeb.apply(engine.trainerOtherHotkey()); return }
        let platform = engine.platform
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { [weak self] in
            async let selection = platform.selectedText()
            async let window = Self.windowFrame(pid)
            let text = await selection
            let context = (text ?? "").isEmpty ? await platform.frontmostContext() : nil
            self?.showPin(selection: text, context: context, window: await window)
        }
    }

    nonisolated private static func windowFrame(_ pid: Int32?) async -> CGRect? {
        guard let pid else { return nil }
        return await frontWindowFrame(pid: pid)
    }

    private func showPin(selection: String?, context: Context?, window: CGRect?) {
        if popover.isShown { popover.performClose(nil) }
        panelCloseTask?.cancel()
        panelWeb.apply(engine.openPinPanel(selection: selection, context: context))
        if isSnapshot {
            snapshotWindow = SnapshotWindow(content: panelWeb.webView, width: 440)
        } else {
            panel.place(over: window)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panelWeb.webView)
        }
    }

    private func closePanel() {
        panelCloseTask?.cancel()
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// After „gespeichert“ the panel closes by itself after 1.5 s (SCREENS M01-S1 #4); undo keeps it open.
    private func schedulePanelClose() {
        guard engine.state.screen == .m01s1, engine.state.panel?.done == true else { panelCloseTask?.cancel(); return }
        guard panelCloseTask == nil || panelCloseTask!.isCancelled else { return }
        panelCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.engine.state.panel?.done == true else { return }
            self.closePanel()
            self.panelCloseTask = nil
        }
    }

    // MARK: Settings window

    func openSettings() {
        closePanel()
        if popover.isShown { popover.performClose(nil) }
        if settingsWeb == nil {
            let web = WebHost(engine: engine, files: uiFiles, surface: "settings", screens: [.m02], width: 520, snapshot: isSnapshot)
            web.onForeign = { [weak self] u in self?.push(u) }
            web.onSize = { [weak self] size in self?.resizeSettings(size) }
            web.onPainted = { [weak self] in self?.painted(self?.settingsWeb) }
            settingsWeb = web
            if isSnapshot {
                snapshotWindow = SnapshotWindow(content: web.webView, width: 520)
            } else {
                let w = makeSettingsWindow(content: web.webView, title: t("m02.title"))
                w.delegate = self
                settingsWindow = w
            }
        }
        settingsWeb?.apply(engine.show(.m02))
        if !isSnapshot {
            activateUnlessSnapshot()
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func resizeSettings(_ size: CGSize) {
        guard let w = settingsWindow else { return }
        let h = min(max(size.height, 200), (NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let content = w.contentRect(forFrameRect: w.frame)
        guard abs(content.height - h) > 0.5 else { return }
        var f = w.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - h, width: 520, height: h))
        f.origin.y = w.frame.maxY - f.height
        w.setFrame(f, display: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        closePanel()
        if engine.state.screen != .m02 { settingsWeb?.apply(engine.show(.m02)) }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        endHotkeyRecording()
        if engine.state.recording != nil { engine.feed(.record(nil)) }
    }

    // MARK: Latency and snapshots

    private func painted(_ web: WebHost?) {
        snapshotIfRequested(web)
        guard !isSnapshot, web === popWeb, let t0 = openedAt else { return }
        openedAt = nil
        let ms = (CACurrentMediaTime() - t0) * 1000
        log.info("open-to-paint \(ms, format: .fixed(precision: 1)) ms")
        let line = String(format: "open %.1f", ms)
        Task.detached { Self.appendMetric(line) }
    }

    private var snapshotTaken = false

    private func snapshotIfRequested(_ web: WebHost?) {
        guard (!(args.contains("--replay") || args.contains("--trainer") || args.contains("--trainer-success") || args.contains("--trainer-end")) || replayReady), !snapshotTaken, let web, web.screens.contains(engine.state.screen),
              snapshotWindow?.contentView === web.webView, let path = arg("--snapshot") else { return }
        snapshotTaken = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            // Replays push state directly, so an image alone cannot notice a cut message path: ask over the real bridge first.
            let bridge = "const r = await window.webkit.messageHandlers.curtain.postMessage({t:'ready'}); return typeof r?.screen === 'string';"
            if (try? await web.webView.callAsyncJavaScript(bridge, contentWorld: .page)) as? Bool != true {
                await Task.detached {
                    FileHandle.standardError.write(Data("snapshot: bridge gave no answer\n".utf8))
                    exit(5)
                }.value
            }
            guard let height = try? await web.webView.evaluateJavaScript("document.querySelector('[data-root]')?.offsetHeight") as? NSNumber,
                  height.doubleValue > 0, let window = snapshotWindow else { exit(3) }
            window.fit(height: CGFloat(truncating: height))
            try? await Task.sleep(for: .milliseconds(150))
            let config = WKSnapshotConfiguration()
            // Points; the image comes out at the screen's backing scale (2x like the references).
            config.snapshotWidth = NSNumber(value: web.webView.bounds.width)
            if let image = try? await web.webView.takeSnapshot(configuration: config),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                if NSApp.keyWindow != nil || NSApp.isActive {
                    await Task.detached {
                        FileHandle.standardError.write(Data("snapshot: key window present\n".utf8))
                        exit(4)
                    }.value
                }
                let written = await Task.detached { () -> Bool in
                    do { try png.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
                }.value
                if written { NSApp.terminate(nil); return }
            }
            exit(3)
        }
    }

    nonisolated static func appendMetric(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ResumeBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("latency.log")
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: EngineHost

    /// Routes an update to the surface that shows its screen.
    func push(_ update: ViewUpdate) {
        switch Screen(rawValue: update.screen) {
        case .m01s1:
            panelWeb.apply(update)
            schedulePanelClose()
        case .m02:
            if settingsWeb == nil { openSettings() } else { settingsWeb?.apply(update) }
        default:
            popWeb.apply(update)
        }
    }

    func closePopover() {
        if panel.isVisible { closePanel() }
        if popover.isShown {
            popover.performClose(nil)
        } else if #available(macOS 27, *) {
            statusItem?.expandedInterfaceSession?.cancel()
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func startHotkeyRecording(_ slot: HotkeySlot) {
        guard engine.state.screen == .m02, engine.state.recording == slot, settingsWindow?.isVisible == true else { return }
        endHotkeyRecording()
        taskHotkey.stop()
        taskHotkey = HotkeyCenter()
        let id = UUID()
        recordingID = id
        Task { [weak self] in
            guard let self, self.recordingID == id else { return }
            let combo = await self.hotkeys.record(slot == .popover ? .popover : .pin)
            guard self.recordingID == id else { return }
            self.engine.feed(combo.map { .recordCombo($0) } ?? .record(nil))
        }
    }

    func endHotkeyRecording() {
        guard recordingID != nil else { return }
        recordingID = nil
        hotkeys.stop()
        taskHotkey.stop()
        hotkeys = HotkeyCenter()
        taskHotkey = HotkeyCenter()
        registeredKeys = nil
        settingsChanged(engine.snapshot.settings)
    }

    func screenChanged(_ screen: Screen) {
        guard !isSnapshot, engine.state.trainer == nil else { return }
        // Leaving the first start for the list or the settings completes the onboarding.
        if screen != .m00, screen != .m01s1, arg("--show") == nil, !args.contains("--fixture"),
           engine.state.onboarding == .eingerichtet {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        }
        Task.detached { await LoginItem.shared.registerIfNeeded() }
    }

    func activate(_ app: TerminalApp) {
        let id = app == .ghostty ? "com.mitchellh.ghostty" : "com.apple.Terminal"
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    func prepareHotkey(_ slot: HotkeySlot, combo: String) -> Bool {
        guard let candidate = HotkeyCombo(combo) else { return false }
        let old = engine.snapshot.settings.hotkeys
        let others: [String]
        switch slot {
        case .popover: others = [old.pin, old.task]
        case .pin: others = [old.popover, old.task]
        case .task: others = [old.popover, old.pin]
        }
        guard !others.contains(where: { HotkeyCombo($0) == candidate }) else { return false }
        if args.contains("--fixture") { return true }
        if slot == .popover { return hotkeys.register(.popover, combo: combo) { [weak self] in self?.popoverHotkey() } }
        if slot == .task { return taskHotkey.register(.popover, combo: combo) { [weak self] in self?.showPopover(mode: .ziel) } }
        if HotkeyCombo(old.pin) != candidate, !HotkeyCenter.pinEnabled(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            let probe = HotkeyCenter()
            let available = probe.register(.popover, combo: combo) {}
            probe.stop()
            guard available else { return false }
        }
        return hotkeys.register(.pin, combo: combo) { [weak self] in self?.pinHotkey() }
    }

    nonisolated private static func rbBundleTarget() -> URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        return bundle.appendingPathComponent("Contents/MacOS/rb")
    }

    nonisolated private static func reconcileRBLink(enabled: Bool) -> (UIState.RBLinkState, [String])? {
        guard let target = rbBundleTarget() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let record = home.appendingPathComponent("Library/Application Support/ResumeBar/rb-link-target")
        do {
            let report = try RBLink.reconcile(home: home, record: record, target: target, enabled: enabled,
                                              alternatives: [URL(fileURLWithPath: "/usr/local/bin/rb"), URL(fileURLWithPath: "/opt/homebrew/bin/rb")])
            return enabled ? (report.taken ? .taken : .linked, report.otherCommands) : (.linked, [])
        } catch { return (enabled ? .failed : .notRemoved, []) }
    }

    func settingsChanged(_ settings: Settings) {
        let socketPath = arg("--rb-socket")
        if !isSnapshot && (!args.contains("--fixture") || socketPath != nil) {
            if settings.ai.enabled && rbServer == nil {
                let server = RBServer(path: socketPath, service: engine)
                rbServer = server
                let previous = rbServerTask
                rbServerTask = Task { [weak self] in
                    await previous?.value
                    let started = await Task.detached { () -> Bool in
                        do { try server.start(); return true } catch { return false }
                    }.value
                    if !started, let self, self.rbServer === server {
                        self.rbServer = nil
                        self.engine.setRBLink(.unreachable, otherCommands: [])
                    }
                    if started, let self, !self.args.contains("--fixture") {
                        if let (link, others) = await Task.detached(operation: { Self.reconcileRBLink(enabled: true) }).value {
                            self.engine.setRBLink(link, otherCommands: others)
                        }
                    }
                }
            } else if !settings.ai.enabled {
                let server = rbServer
                rbServer = nil
                let previous = rbServerTask
                let shouldUnlink = !args.contains("--fixture")
                rbServerTask = Task { [weak self] in
                    await previous?.value
                    let result = await Task.detached {
                        server?.stop()
                        return shouldUnlink ? Self.reconcileRBLink(enabled: false) : nil
                    }.value
                    if let (link, others) = result { self?.engine.setRBLink(link, otherCommands: others) }
                }
            }
        }
        guard !isSnapshot, settings.hotkeys != registeredKeys, !args.contains("--fixture") else { return }
        let pop = hotkeys.register(.popover, combo: settings.hotkeys.popover) { [weak self] in self?.popoverHotkey() }
        let pin = hotkeys.register(.pin, combo: settings.hotkeys.pin) { [weak self] in self?.pinHotkey() }
        let task = taskHotkey.register(.popover, combo: settings.hotkeys.task) { [weak self] in self?.showPopover(mode: .ziel) }
        if pop && pin && task { registeredKeys = settings.hotkeys }
    }

    func justEndedChanged(_ count: Int) {}

    func menuBarIconChanged(_ icon: Logic.MenuBarIcon) {
        switch icon {
        case .plain:
            statusItem?.button?.image = icons.plain
            statusItem?.button?.setAccessibilityLabel(t("menubar.a11y"))
        case .news:
            statusItem?.button?.image = icons.dot
            statusItem?.button?.setAccessibilityLabel(t("menubar.a11y_dot"))
        case .overdue:
            statusItem?.button?.image = icons.overdue
            statusItem?.button?.setAccessibilityLabel(t("menubar.a11y_overdue"))
        }
    }
}
