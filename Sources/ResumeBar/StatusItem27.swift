import AppKit

@available(macOS 27, *)
@MainActor
final class StatusItem27: NSObject, @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    private let show: () -> Void
    private let close: () -> Void
    private let menu: () -> Void

    init(item: NSStatusItem, show: @escaping () -> Void, close: @escaping () -> Void, menu: @escaping () -> Void) {
        self.show = show
        self.close = close
        self.menu = menu
        super.init()
        let click = NSClickGestureRecognizer(target: self, action: #selector(secondaryClick))
        click.buttonMask = 1 << 1
        item.button?.addGestureRecognizer(click)
    }

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        show()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        close()
    }

    @objc private func secondaryClick() {
        menu()
    }
}
