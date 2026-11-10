import AppKit

/// A render surface that cannot receive keyboard or mouse input.
@MainActor
final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init(content: NSView, width: CGFloat) {
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let bottom = NSScreen.screens.map(\.frame.minY).min() ?? 0
        super.init(contentRect: NSRect(x: left - width - 10000, y: bottom - 10000, width: width, height: 600),
                   styleMask: .borderless, backing: .buffered, defer: false)
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        contentView = content
        orderFront(nil)
    }

    func fit(height: CGFloat) {
        guard height > 0 else { return }
        setContentSize(NSSize(width: frame.width, height: ceil(height)))
    }
}
