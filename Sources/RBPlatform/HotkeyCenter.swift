import AppKit
import Carbon.HIToolbox

public struct HotkeyCombo: Equatable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    public let modifiers: UInt32
    private static let keys: [(String, Int)] = [
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D),
        ("E", kVK_ANSI_E), ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H),
        ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
        ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P),
        ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
        ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1),
        ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5),
        ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("Space", kVK_Space), ("Return", kVK_Return), ("←", kVK_LeftArrow),
        ("→", kVK_RightArrow), ("↑", kVK_UpArrow), ("↓", kVK_DownArrow)
    ]
    private static let symbols: [(Character, Int)] = [("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey)]

    public init?(_ text: String) {
        var rest = Substring(text)
        var mods: UInt32 = 0
        while let ch = rest.first, let entry = Self.symbols.first(where: { $0.0 == ch }) {
            let bit = UInt32(entry.1)
            guard mods & bit == 0 else { return nil }
            mods |= bit; rest = rest.dropFirst()
        }
        let name = String(rest)
        guard mods != 0, let key = Self.keys.first(where: { $0.0.lowercased() == name.lowercased() }) else { return nil }
        keyCode = UInt32(key.1); modifiers = mods
    }
    private init?(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods != 0, Self.keys.contains(where: { $0.1 == Int(event.keyCode) }) else { return nil }
        keyCode = UInt32(event.keyCode); modifiers = mods
    }
    public var description: String {
        Self.symbols.filter { modifiers & UInt32($0.1) != 0 }.map { String($0.0) }.joined()
            + (Self.keys.first { UInt32($0.1) == keyCode }?.0 ?? "")
    }
    fileprivate static func from(_ event: NSEvent) -> HotkeyCombo? { HotkeyCombo(event: event) }
}

@MainActor public final class HotkeyCenter {
    public enum Slot: Hashable, Sendable { case popover, pin }
    private struct Entry { var combo: HotkeyCombo; var action: () -> Void; var ref: EventHotKeyRef?; var id: UInt32 }
    private var entries: [Slot: Entry] = [:]
    private var observer: NSObjectProtocol?
    private var monitor: Any?
    private var recording: CheckedContinuation<String?, Never>?
    private static var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    public init() {
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == OSType(0x52424152) else { return OSStatus(eventNotHandledErr) }
                let value = id.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.actions[value]?() } }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPin() }
        }
    }

    /// Returns false for an invalid or unavailable shortcut; existing registration is retained.
    @discardableResult public func register(_ slot: Slot, combo text: String, action: @escaping () -> Void) -> Bool {
        guard let combo = HotkeyCombo(text) else { return false }
        if let old = entries[slot], old.combo == combo { entries[slot]?.action = action; Self.actions[old.id] = action; return true }
        let id = Self.nextID; Self.nextID &+= 1
        var ref: EventHotKeyRef?
        if slot != .pin || Self.pinEnabled(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            guard RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x52424152), id: id), GetApplicationEventTarget(), 0, &ref) == noErr else { return false }
        }
        unregister(slot)
        entries[slot] = Entry(combo: combo, action: action, ref: ref, id: id)
        Self.actions[id] = action
        return true
    }
    public func unregister(_ slot: Slot) {
        guard let entry = entries.removeValue(forKey: slot) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        Self.actions.removeValue(forKey: entry.id)
    }
    public static func pinEnabled(bundleID: String?) -> Bool { SystemPlatform.terminal(bundleID) != nil }
    private func refreshPin() {
        guard recording == nil, var entry = entries[.pin] else { return }
        let enabled = Self.pinEnabled(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        if !enabled, let ref = entry.ref { UnregisterEventHotKey(ref); entry.ref = nil }
        if enabled, entry.ref == nil {
            _ = RegisterEventHotKey(entry.combo.keyCode, entry.combo.modifiers, EventHotKeyID(signature: OSType(0x52424152), id: entry.id), GetApplicationEventTarget(), 0, &entry.ref)
        }
        entries[.pin] = entry
    }
    /// Captures a shortcut for the caller to persist and register. Escape cancels.
    public func record(_ slot: Slot) async -> String? {
        finishRecording(nil)
        // Registered global shortcuts otherwise consume key events before the local monitor.
        for slot in [Slot.popover, .pin] {
            if let ref = entries[slot]?.ref { UnregisterEventHotKey(ref); entries[slot]?.ref = nil }
        }
        return await withCheckedContinuation { continuation in
            recording = continuation
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let escape = event.keyCode == UInt16(kVK_Escape)
                let combo = HotkeyCombo.from(event)
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    if escape { self.finishRecording(nil); return true }
                    guard let combo else { return false }
                    self.finishRecording(combo.description)
                    return true
                }
                return consumed ? nil : event
            }
            if monitor == nil { finishRecording(nil) }
        }
    }
    private func finishRecording(_ value: String?) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let continuation = recording {
            recording = nil
            for slot in [Slot.popover, .pin] {
                guard var entry = entries[slot], entry.ref == nil,
                      slot != .pin || Self.pinEnabled(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { continue }
                _ = RegisterEventHotKey(entry.combo.keyCode, entry.combo.modifiers, EventHotKeyID(signature: OSType(0x52424152), id: entry.id), GetApplicationEventTarget(), 0, &entry.ref)
                entries[slot] = entry
            }
            continuation.resume(returning: value)
        }
    }
    public func stop() {
        finishRecording(nil)
        unregister(.pin); unregister(.popover)
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer); self.observer = nil }
    }
}
