// Native frames for the surfaces besides the popover.
//   PinPanel        M01-S1 · borderless, non-activating: takes the keyboard while the terminal stays the
//                   active app, so esc and the auto-close after saving hand focus straight back.
//   settingsWindow  M02 · normal window, title hidden (the page has its own heading).

import AppKit
import CoreGraphics

@MainActor
final class PinPanel: NSPanel {
    private let container = NSView()

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Rounded clip equal to --radius-popover so the window shadow follows the page frame.
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Content height from the page (shell size message); keeps the top edge in place.
    func fit(_ size: CGSize) {
        let h = min(max(size.height, 60), 400)
        guard abs(frame.height - h) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - h
        f.size = NSSize(width: 440, height: h)
        setFrame(f, display: true)
        invalidateShadow()
    }

    /// Centered over the given window (Cocoa coordinates) in its upper third, else over the main screen.
    func place(over window: CGRect?) {
        let screen = window.flatMap { rect in
            NSScreen.screens.max { a, b in
                let x = a.frame.intersection(rect), y = b.frame.intersection(rect)
                return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
            }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let area = window ?? screen?.visibleFrame ?? .zero
        var x = area.midX - frame.width / 2
        var y = area.maxY - area.height / 3 - frame.height / 2
        if let v = screen?.visibleFrame {
            x = min(max(x, v.minX + 8), v.maxX - frame.width - 8)
            y = min(max(y, v.minY + 8), v.maxY - frame.height - 8)
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Frame of the frontmost window of `pid` in Cocoa coordinates. Window server query, no Apple Event,
/// no permission needed for bounds; runs off the main thread.
func frontWindowFrame(pid: Int32) async -> CGRect? {
    await Task.detached {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            // CG origin is top-left of the primary display; Cocoa is bottom-left.
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        return nil
    }.value
}

@MainActor
func makeSettingsWindow(content: NSView, title: String) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = title
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.appearance = NSAppearance(named: .darkAqua)
    w.backgroundColor = NSColor(srgbRed: 0x0f / 255, green: 0x13 / 255, blue: 0x11 / 255, alpha: 1) // --color-bg
    w.isReleasedWhenClosed = false
    w.contentView = content
    w.center()
    return w
}
