import AppKit
@preconcurrency import ApplicationServices
import Foundation
import RBContract
import Darwin

/// System calls are replaceable so tests never access other applications or TCC.
public struct PlatformRunners: Sendable {
    public var frontmost: @Sendable () async -> (String, Int32)?
    public var script: @Sendable (TerminalApp) async -> String?
    public var shellCWD: @Sendable (String) async -> String?
    public var selection: @Sendable (Int32) async -> String?
    public var accessibility: @Sendable () async -> Bool
    public var automation: @Sendable (TerminalApp) async -> PermissionState
    public var requestAccessibility: @Sendable () async -> Void

    public init(frontmost: @escaping @Sendable () async -> (String, Int32)?,
                script: @escaping @Sendable (TerminalApp) async -> String?,
                shellCWD: @escaping @Sendable (String) async -> String?,
                selection: @escaping @Sendable (Int32) async -> String?,
                accessibility: @escaping @Sendable () async -> Bool,
                automation: @escaping @Sendable (TerminalApp) async -> PermissionState,
                requestAccessibility: @escaping @Sendable () async -> Void) {
        self.frontmost = frontmost; self.script = script; self.shellCWD = shellCWD
        self.selection = selection; self.accessibility = accessibility
        self.automation = automation; self.requestAccessibility = requestAccessibility
    }

    public static let system = PlatformRunners(
        frontmost: { await MainActor.run { FrontmostTracker.shared.last } },
        script: { app in await Task.detached { runScript(app) }.value },
        shellCWD: { tty in await Task.detached { cwdForTTY(tty) }.value },
        selection: { pid in await Task.detached {
            guard AXIsProcessTrusted() else { return nil }
            let app = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
            return value as? String
        }.value },
        accessibility: { await Task.detached { AXIsProcessTrusted() }.value },
        automation: { app in await Task.detached { automationState(app) }.value },
        requestAccessibility: {
            await Task.detached {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }.value
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        })
}

/// The last activated application other than Resume Bar. Opening the popover activates Resume Bar;
/// the context belongs to the app the user came from.
@MainActor final class FrontmostTracker {
    static let shared = FrontmostTracker()
    private(set) var last: (String, Int32)?
    private var observer: NSObjectProtocol?

    private init() {
        let app = NSWorkspace.shared.frontmostApplication
        note(app?.bundleIdentifier, app?.processIdentifier)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier, pid = app?.processIdentifier
            MainActor.assumeIsolated { FrontmostTracker.shared.note(id, pid) }
        }
    }

    private func note(_ id: String?, _ pid: Int32?) {
        guard let id, let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        last = (id, pid)
    }
}

public struct SystemPlatform: PlatformProviding {
    private let runners: PlatformRunners
    public init(runners: PlatformRunners = .system) { self.runners = runners }

    /// Call once at launch, before the popover can activate the app.
    @MainActor public static func startTracking() { _ = FrontmostTracker.shared }

    public func frontmostContext() async -> Context {
        guard let (bundle, _) = await runners.frontmost(), let app = Self.terminal(bundle) else {
            return Context(projectId: nil, source: nil, cwd: nil, windowIndex: nil)
        }
        let output = await runners.script(app)?.trimmingCharacters(in: .newlines)
        let parts = output?.components(separatedBy: "\u{1f}") ?? []
        let tty: String?
        let cwd: String?
        if app == .terminal {
            let raw = parts.first ?? ""
            tty = raw.isEmpty ? nil : Self.normalizedTTY(raw)
            cwd = tty == nil ? nil : await runners.shellCWD(raw)
        } else {
            cwd = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            tty = parts.count == 2 && !parts[1].isEmpty ? Self.normalizedTTY(parts[1]) : nil
        }
        return Context(projectId: nil, source: app, cwd: cwd, windowIndex: cwd == nil ? nil : 1, tty: tty)

    }

    public func selectedText() async -> String? {
        guard let (bundle, pid) = await runners.frontmost(), Self.terminal(bundle) != nil,
              await runners.accessibility() else { return nil }
        return await runners.selection(pid)
    }

    public func permissions() async -> Permissions {
        async let ax = runners.accessibility()
        async let ghostty = runners.automation(.ghostty)
        async let terminal = runners.automation(.terminal)
        return await Permissions(accessibility: ax, automation: .init(ghostty: ghostty, terminal: terminal))
    }
    public func requestAccessibility() async { await runners.requestAccessibility() }

    private static func normalizedTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    public static func terminal(_ bundle: String?) -> TerminalApp? {
        switch bundle {
        case "com.mitchellh.ghostty": .ghostty
        case "com.apple.Terminal": .terminal
        default: nil
        }
    }
}

private func runScript(_ app: TerminalApp) -> String? {
    let script = app == .ghostty
        ? """
        tell application id "com.mitchellh.ghostty"
          set t to focused terminal of selected tab of front window
          set d to working directory of t
          if d is missing value then set d to ""
          set terminalTTY to ""
          try
            set terminalTTY to tty of t
            if terminalTTY is missing value then set terminalTTY to ""
          end try
          return (d as text) & (ASCII character 31) & (terminalTTY as text)
        end tell
        """
        : "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window"
    return runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: .milliseconds(300))
}

func runCommand(executable: String, arguments: [String], timeout: DispatchTimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return nil }
    guard finished.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

private func cwdForTTY(_ tty: String) -> String? {
    guard tty.hasPrefix("/dev/") else { return nil }
    var info = stat()
    guard stat(tty, &info) == 0 else { return nil }
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var candidates: [(UInt64, pid_t)] = []
    for pid in pids.prefix(Int(max(0, actual))) where pid > 0 {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout<proc_bsdinfo>.size,
              bsd.e_tdev == UInt32(bitPattern: info.st_rdev) else { continue }
        let nameSize = MemoryLayout.size(ofValue: bsd.pbi_comm)
        let name = withUnsafePointer(to: &bsd.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: nameSize) { String(cString: $0) } }
        if ["zsh", "bash", "fish", "sh"].contains(name) { candidates.append((bsd.pbi_start_tvsec, pid)) }
    }
    // The oldest shell is the tab's login shell, rather than a nested shell.
    guard let pid = candidates.min(by: { $0.0 < $1.0 })?.1 else { return nil }
    var path = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &path, Int32(MemoryLayout.size(ofValue: path))) == MemoryLayout<proc_vnodepathinfo>.size else { return nil }
    return withUnsafePointer(to: &path.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
}

func permissionState(_ status: OSStatus) -> PermissionState {
    switch status {
    case noErr: .granted
    case OSStatus(errAEEventNotPermitted): .denied
    default: .unknown
    }
}

private func automationState(_ app: TerminalApp) -> PermissionState {
    let bundle = app == .ghostty ? "com.mitchellh.ghostty" : "com.apple.Terminal"
    var target = AEAddressDesc()
    let status = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, bundle.utf8.count, &target) }
    guard status == noErr else { return .unknown }
    defer { AEDisposeDesc(&target) }
    return permissionState(AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false))
}
