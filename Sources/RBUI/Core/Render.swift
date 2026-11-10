// Rendering contract (curtain).
//
// Each screen has a fixed skeleton (sent once when the screen changes) and named regions.
// A region is an element with `data-region="<name>"`; the bridge replaces its innerHTML.
// Rules for all templates:
//  1. Class names and DOM structure follow prototype/app.js so prototype/styles.css applies 1:1.
//  2. Every dynamic text goes through `h()`; no raw interpolation of data.
//  3. An input never sits in a region that changes while the user types into that input.
//     Inputs render their *initial* value (editInitial, PanelState.initialText); the visible
//     text lives in the mirror region next to them. Region wrappers use `display: contents`.
//  4. Child regions appear in the parent as empty placeholders and are sent separately.
// Areas provide the region contents.

import RBContract

public struct RenderedScreen: Sendable, Equatable {
    public var screen: Screen
    /// Static frame with persistent inputs and empty region placeholders.
    public var skeleton: String
    /// Region name → inner HTML, parents before children.
    public var regions: [(String, String)]
    /// Field to focus: "q", "e", "b", "p" or nil.
    public var focus: String?
    public var selectAll: Bool
    /// Values the reducer changed for fields (e.g. chips took "@pag " out of the query).
    public var fieldValues: [String: String]

    public static func == (a: RenderedScreen, b: RenderedScreen) -> Bool {
        a.screen == b.screen && a.skeleton == b.skeleton && a.focus == b.focus && a.selectAll == b.selectAll
            && a.fieldValues == b.fieldValues
            && a.regions.map(\.0) == b.regions.map(\.0) && a.regions.map(\.1) == b.regions.map(\.1)
    }

    public func region(_ name: String) -> String? { regions.first { $0.0 == name }?.1 }

    /// Full HTML (skeleton with regions filled in), used for snapshots and reference comparisons.
    public var fullHTML: String {
        var html = skeleton
        for (name, inner) in regions {
            html = html.replacingOccurrences(of: Self.placeholderInner(name), with: Self.filledInner(name, inner))
        }
        return html
    }

    static func placeholderInner(_ name: String) -> String { "data-region=\"\(name)\"></" }
    static func filledInner(_ name: String, _ inner: String) -> String { "data-region=\"\(name)\">\(inner)</" }
}

/// HTML escaping for text and attribute values.
@inline(__always)
public func h(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out
}

public enum Renderer {
    public static func stripAvailable(_ s: UIState, _ snap: Snapshot) -> Bool {
        s.screen == .m01 && TaskArea.stripAvailable(s, snap)
    }

    public static func render(_ s: UIState, _ snap: Snapshot) -> RenderedScreen {
        switch s.screen {
        case .m01: return TaskArea.render(s, snap)
        case .m01s1: return panel(s, snap)
        case .m00, .m02: return page(s, snap)
        }
    }

    // MARK: M01 popover

    static let m01Skeleton = """
    <div class="pop" data-root data-screen="M01" role="dialog" aria-label="\(h(t("a11y.popover")))">\
    <h1 class="sr">\(h(t("m01.title")))</h1>\
    <div class="search"><span class="prompt" aria-hidden="true">\(h(t("m01.mode.resume")))</span>\
    <span class="region" data-region="chips"></span>\
    <div class="field"><input class="q" aria-label="\(h(t("m01.search.label")))" aria-controls="rb-list" \
    spellcheck="false" autocomplete="off"><span class="mirror" aria-hidden="true" data-region="mirror"></span></div>\
    <span class="region" data-region="key"></span></div>\
    <span class="region" data-region="legend"></span>\
    <span class="region" data-region="body"></span>\
    <footer data-region="footer"></footer></div>
    """

    static let toastRegion = "<span class=\"region\" data-region=\"toast\"></span>"

    static func toast(_ n: Note?) -> String {
        guard let n else { return "" }
        return "<div class=\"toast \(n.kind.rawValue)\" role=\"status\" aria-live=\"polite\">\(h(n.text))</div>"
    }

    // MARK: M01-S1 panel

    static let panelSkeleton = """
    <div class="pop panel" data-root data-screen="M01-S1" role="dialog" aria-label="\(h(t("m01s1.title")))">\
    <h1 class="sr">\(h(t("m01s1.title")))</h1><span class="region" data-region="panel"></span></div>
    """

    static func panel(_ s: UIState, _ snap: Snapshot) -> RenderedScreen {
        let r = EdgesArea.regions(s, snap)
        var regions: [(String, String)] = [("panel", r["panel"] ?? "")]
        if (r["panel"] ?? "").contains("data-region=\"pmirror\"") { regions.append(("pmirror", r["pmirror"] ?? "")) }
        let editing = s.panel.map { !$0.done && $0.sessionId != nil } ?? false
        return RenderedScreen(screen: .m01s1, skeleton: panelSkeleton, regions: regions,
                              focus: editing ? "p" : nil, selectAll: s.selectAll,
                              fieldValues: editing ? ["p": s.panel?.text ?? ""] : [:])
    }

    // MARK: M00 / M02 pages

    /// The page frame (data-root for the bridge and the shell size message); EdgesArea fills `page` with its children.
    static func pageSkeleton(_ s: UIState) -> String {
        let region = "<span class=\"region\" data-region=\"page\"></span></div>"
        if s.screen == .m00 {
            return "<div class=\"pop onboard\" data-root data-screen=\"M00\" data-state=\"\(s.onboarding.rawValue)\" "
                + "role=\"dialog\" aria-label=\"\(h(t("a11y.popover")))\">" + region
        }
        return "<div class=\"pop settings\" data-root data-screen=\"M02\" data-state=\"standard\" "
            + "role=\"dialog\" aria-label=\"\(h(t("m02.title")))\">" + region
    }

    static func page(_ s: UIState, _ snap: Snapshot) -> RenderedScreen {
        let skeleton = pageSkeleton(s)
        return RenderedScreen(screen: s.screen, skeleton: skeleton,
                              regions: [("page", EdgesArea.regions(s, snap)["page"] ?? "")],
                              focus: nil, selectAll: false, fieldValues: [:])
    }
}
