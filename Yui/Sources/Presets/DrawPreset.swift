import SwiftUI
import WebKit
import YuiLines

// The agent just draws (Chris, Oct 2: "how can the AI, via YL, just draw ... YL
// containers where the agent can write in whatever drawing or animation library";
// feedback AH_N-9fd: "you should totally be able to animate that"). `draw [title]
// [caption=] [ratio=]`, then SVG up to `end`. Every model already writes SVG, so
// nothing new is taught: the phone gives the drawing the agent's colors, a
// blueprint's line defaults and four words of motion, and draws it.
//
// The drawing runs in a box of its own: a web view with no network (a content
// policy that allows nothing but what is written inline), no storage, no links
// out and no touch. It can move itself with CSS or a script; it cannot fetch,
// open or send anything. It sends no events.
//
// What a drawing gets for free:
//   colors    var(--ink) --soft --accent --mint --lavender --butter --good --bad,
//             or the classes .ink .soft .accent .mint .lavender .butter .good .bad
//             (stroke) and .fill-accent ... (fill)
//   lines     a shape with no stroke of its own is a 1.5 pt line in ink, no fill;
//             class="rough" makes any part look drawn by hand, "wash" makes a fill a
//             soft see-through tint, so overlaps read darker, as in a Venn (YUI-276).
//             The wobble is sized for a viewBox a few hundred units wide, as in the example.
//   motion    class="draw" traces a line on, "pop" springs a part up, "fade" brings
//             it in, "pulse" keeps it breathing; parts with one of these come on in
//             the order they are written, a beat apart
// Reduce Motion shows it finished.

struct DrawPreset: View {
    let c: YLComponent

    var body: some View {
        PresetCard { DrawDrawing(props: c.props) }
    }
}

struct DrawDrawing: View {
    let props: [String: YLValue]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = theme.swatch(scheme)
        let title = props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let caption = props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if let title {
                Text(title.uppercased())
                    .font(theme.font(theme.type.caption - 2, .heavy))
                    .tracking(1.4)
                    .foregroundStyle(s.inkSoft)
                    .accessibilityHidden(true)
            }
            // Nothing to draw until the markup has landed (a reply still streaming).
            if let source = props["source"]?.string, !source.isEmpty {
                let page = DrawPage.html(source, palette: theme.palette(for: scheme), dark: scheme == .dark,
                                         good: scheme == .dark ? "#3fbf8a" : "#13875a", bad: scheme == .dark ? "#ff7a6b" : "#c93c2c",
                                         still: reduceMotion)
                // The shape is set here, by a clear box the canvas lies over: a web view has no size of its own.
                Color.clear
                    .aspectRatio(DrawPage.ratio(props["ratio"].flatMap { $0.string ?? $0.number.map { String($0) } }, source: source), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { DrawCanvas(html: page) }
                    // Its taps are the page's: a tap turns the page, a swipe changes the screen.
                    .allowsHitTesting(false)
            }
            if let caption {
                Text(caption)
                    .font(theme.font(theme.type.caption, .medium))
                    .foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title ?? "Drawing", caption].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("draw-drawing")
        .accessibilityAddTraits(.isImage)
    }
}

/// The page a drawing runs in.
enum DrawPage {
    /// Width over height: `ratio=16:9` (or `1.6`), else the SVG's own viewBox, else 4:3.
    /// Kept between a tall 7:10 and a wide 4:1, so a wrong number never makes a sliver or a page-long strip.
    static func ratio(_ said: String?, source: String) -> CGFloat {
        func clamp(_ r: Double) -> CGFloat { CGFloat(min(max(r, 0.7), 4)) }
        if let said {
            let p = said.split(whereSeparator: { $0 == ":" || $0 == "/" }).compactMap { Double($0) }
            if p.count == 2, p[0] > 0, p[1] > 0 { return clamp(p[0] / p[1]) }
            if p.count == 1, p[0] > 0 { return clamp(p[0]) }
        }
        if let m = try? viewBox.firstMatch(in: source) {
            let n = m.1.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if n.count == 4, n[2] > 0, n[3] > 0 { return clamp(n[2] / n[3]) }
        }
        return 4.0 / 3.0
    }

    nonisolated(unsafe) private static let viewBox = /viewBox\s*=\s*["']([^"']+)["']/

    /// Nothing loads from anywhere: only what the drawing wrote inline runs.
    static let policy = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:"

    static func html(_ source: String, palette p: YuiTheme.Palette, dark: Bool, good: String, bad: String, still: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>
        :root{--ink:\(p.ink);--soft:\(p.inkSoft);--accent:\(p.accent);--mint:\(p.mint);--lavender:\(p.lavender);--butter:\(p.butter);--good:\(good);--bad:\(bad);--ground:\(p.background);color-scheme:\(dark ? "dark" : "light")}
        html,body{margin:0;padding:0;height:100%;background:transparent;color:var(--ink);overflow:hidden;
          font:600 15px -apple-system,system-ui,sans-serif;-webkit-user-select:none;-webkit-text-size-adjust:none}
        body>svg:not(.yui-defs),body>canvas{display:block;width:100%;height:100%;overflow:visible}
        .yui-defs{position:absolute;width:0;height:0;overflow:hidden}
        :where(svg text){fill:var(--ink);stroke:none;font-family:-apple-system,system-ui,sans-serif}
        :where(svg :is(path,line,polyline,polygon,rect,circle,ellipse):not([fill])){fill:none}
        :where(svg :is(path,line,polyline,polygon,rect,circle,ellipse):not([stroke])){stroke:var(--ink);stroke-width:1.5}
        :where(svg :is(path,line,polyline,polygon,rect,circle,ellipse)){stroke-linecap:round;stroke-linejoin:round}
        .ink{stroke:var(--ink)}.soft{stroke:var(--soft)}.accent{stroke:var(--accent)}.mint{stroke:var(--mint)}.lavender{stroke:var(--lavender)}.butter{stroke:var(--butter)}.good{stroke:var(--good)}.bad{stroke:var(--bad)}
        .fill-ink{fill:var(--ink)}.fill-soft{fill:var(--soft)}.fill-accent{fill:var(--accent)}.fill-mint{fill:var(--mint)}.fill-lavender{fill:var(--lavender)}.fill-butter{fill:var(--butter)}.fill-good{fill:var(--good)}.fill-bad{fill:var(--bad)}.fill-ground{fill:var(--ground)}
        svg text:is(.ink,.soft,.accent,.mint,.lavender,.butter,.good,.bad){stroke:none}
        svg text.soft{fill:var(--soft)}svg text.accent{fill:var(--accent)}svg text.mint{fill:var(--mint)}svg text.good{fill:var(--good)}svg text.bad{fill:var(--bad)}svg text.butter{fill:var(--butter)}svg text.lavender{fill:var(--lavender)}
        .dash{stroke-dasharray:5 5}
        .wash{fill-opacity:.18}.rough{filter:url(#yui-rough)}
        .draw,.pop,.fade{animation-delay:calc(var(--i,0)*.22s + .1s);animation-fill-mode:both}
        .draw{animation-name:yui-draw;animation-duration:.8s;animation-timing-function:ease-in-out}
        .pop{animation-name:yui-pop;animation-duration:.5s;animation-timing-function:cubic-bezier(.3,1.6,.5,1);transform-box:fill-box;transform-origin:center}
        .fade{animation-name:yui-fade;animation-duration:.5s;animation-timing-function:ease-out}
        .pulse{animation:yui-pulse 2.2s ease-in-out infinite;animation-delay:calc(var(--i,0)*.22s + .6s);transform-box:fill-box;transform-origin:center}
        @keyframes yui-draw{from{stroke-dashoffset:var(--len,1000)}to{stroke-dashoffset:0}}
        @keyframes yui-pop{from{opacity:0;transform:scale(.4)}to{opacity:1;transform:scale(1)}}
        @keyframes yui-fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
        @keyframes yui-pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.08)}}
        \(still ? "*{animation:none!important;transition:none!important}" : "")
        </style></head><body>
        <svg class="yui-defs" aria-hidden="true"><filter id="yui-rough" filterUnits="userSpaceOnUse" x="-10%" y="-10%" width="120%" height="120%">
        <feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="7"/>
        <feDisplacementMap in="SourceGraphic" scale="2.5" xChannelSelector="R" yChannelSelector="G"/></filter></svg>
        \(source)
        <script>
        (function(){var i=0;document.querySelectorAll('.draw,.pop,.fade,.pulse').forEach(function(e){
          e.style.setProperty('--i',i++);
          if(e.classList.contains('draw')&&e.getTotalLength){var n=Math.ceil(e.getTotalLength());
            e.style.setProperty('--len',n);if(!\(still)){e.style.strokeDasharray=n}}
        })})();
        </script></body></html>
        """
    }
}

/// The box a drawing runs in: no network, no storage, no way out.
struct DrawCanvas: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Guard { Guard() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        web.accessibilityElementsHidden = true
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        // No base URL: the page has no origin to load from or talk to.
        web.loadHTMLString(html, baseURL: nil)
    }

    /// Only the drawing's own page ever loads. A link, a redirect or a frame goes nowhere.
    final class Guard: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let own = action.targetFrame?.isMainFrame == true && action.navigationType == .other
                && (action.request.url?.absoluteString ?? "about:blank") == "about:blank"
            return own ? .allow : .cancel
        }
    }
}
