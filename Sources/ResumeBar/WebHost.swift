// One permanently loaded WKWebView per surface (curtain presentation layer): popover, pin panel, settings.
// Serves ui/ through the app:// scheme, forwards bridge messages to the engine and applies its replies.

import AppKit
import RBContract
import RBEngine
import RBUI
import UniformTypeIdentifiers
import WebKit

/// Serves files of the ui folder under app://local/.
final class UISchemeHandler: NSObject, WKURLSchemeHandler {
    let files: [String: Data]
    init(files: [String: Data]) { self.files = files }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "app", url.host == "local" else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        guard let data = files[path] else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class WebHost: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let engine: Engine
    /// Screens this surface shows; updates for other screens go to `onForeign` (the shell routes them).
    let screens: Set<Screen>
    var onSize: ((CGSize) -> Void)?
    var onPainted: (() -> Void)?
    var onForeign: ((ViewUpdate) -> Void)?

    init(engine: Engine, files: [String: Data], surface: String, screens: Set<Screen>, width: CGFloat, snapshot: Bool = false) {
        self.engine = engine
        self.screens = screens
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(UISchemeHandler(files: files), forURLScheme: "app")
        // shell.css styles each surface (native frame for popover and settings, own frame for the panel).
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.dataset.surface = '\(surface)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if snapshot {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.__rbSnapshot = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "curtain")
        config.userContentController.add(self, contentWorld: .page, name: "shell")
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.load(URLRequest(url: URL(string: "app://local/index.html")!))
    }

    func shows(_ update: ViewUpdate) -> Bool { Screen(rawValue: update.screen).map(screens.contains) ?? false }

    /// Pushes an update from the engine (index or live changes) into the page.
    func apply(_ update: ViewUpdate) {
        guard !update.isEmpty else { return }
        webView.callAsyncJavaScript("window.curtain && window.curtain.apply(u)", arguments: ["u": Self.plist(update)],
                                    in: nil, in: .page, completionHandler: nil)
    }

    // Bridge request with reply: raw input → engine → regions to apply.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard Self.trusted(message), let body = message.body as? [String: Any], let kind = body["t"] as? String else { return (nil, nil) }
        // A surface that loads while another one is active stays empty until it is shown (forced render).
        if kind == "ready" { return screens.contains(engine.state.screen) ? (Self.plist(engine.ready()), nil) : (nil, nil) }
        guard screens.contains(engine.state.screen), let input = Self.rawInput(kind, body) else { return (nil, nil) }
        let update = engine.handle(input)
        if !update.isEmpty && !shows(update) { onForeign?(update); return (nil, nil) }
        return (Self.plist(update), nil)
    }

    // Shell messages without reply: content size and paint mark.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.trusted(message), let body = message.body as? [String: Any] else { return }
        if let w = body["w"] as? Double, let h = body["h"] as? Double, w > 0, h > 0 { onSize?(CGSize(width: w, height: h)) }
        onPainted?()
    }

    private static func trusted(_ message: WKScriptMessage) -> Bool {
        let frame = message.frameInfo
        return frame.isMainFrame && frame.securityOrigin.protocol == "app" && frame.securityOrigin.host == "local"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        return url?.scheme == "app" && url?.host == "local" ? .allow : .cancel
    }

    static func rawInput(_ kind: String, _ b: [String: Any]) -> RawInput? {
        switch kind {
        case "key":
            return .key(KeyPress(key: b["key"] as? String ?? "", code: b["code"] as? String, meta: b["meta"] as? Bool ?? false,
                                 ctrl: b["ctrl"] as? Bool ?? false, alt: b["alt"] as? Bool ?? false,
                                 shift: b["shift"] as? Bool ?? false, field: b["field"] as? String,
                                 fieldEmpty: b["fieldEmpty"] as? Bool ?? true,
                                 hasSelection: b["hasSelection"] as? Bool ?? false))
        case "text": return .text(field: b["field"] as? String ?? "", value: b["value"] as? String ?? "")
        case "setting": return .setting(path: b["path"] as? String ?? "", value: b["value"] as? String ?? "")
        case "action": return .action(b["name"] as? String ?? "", arg: b["arg"] as? String)
        case "select": return .select(b["id"] as? String ?? "")
        case "dbl": return .doubleSelect(b["id"] as? String ?? "")
        default: return nil
        }
    }

    /// ViewUpdate as plist types (WKScriptMessage replies and callAsyncJavaScript arguments).
    static func plist(_ u: ViewUpdate) -> [String: Any] {
        var d: [String: Any] = ["screen": u.screen, "regions": u.regions, "selectAll": u.selectAll, "values": u.values]
        if let s = u.skeleton { d["skeleton"] = s }
        if let f = u.focus { d["focus"] = f }
        return d
    }
}
