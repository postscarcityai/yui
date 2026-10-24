import SwiftUI
import YuiLines

// A deck is a stage, not a card (TestFlight feedback ANhbech_, AMt71OZy, AHdP_lC4, Oct 5). No card,
// no border, no dots, no pager arrows: the drawing fills most of the screen and the words are one big
// line under it. A swipe scrubs the drawing from this page's shapes into the next page's (DeckMorph):
// the same shape slides, grows, recolours and changes outline as the finger moves, and springs to the
// page on release; new shapes draw on, old ones dissolve, labels type themselves. At rest the drawing
// breathes. Reduce Motion cross-fades. A tap on the drawing's right side turns the page, its left side
// turns back. Pages whose picture is not `shapes` (a chart, math, a sketch, a calc) and quiz questions
// ride the same swipe with their own views.

/// Where the swipe is, in pages (1.5 is halfway from page two to page three). Its own object, so the
/// deck's body is not rebuilt on every scroll frame: only the drawing reads it.
@Observable final class DeckScroll {
    var pos = 0.0
}

struct MorphStage: View {
    let c: YLComponent
    let pages: [YLComponent]
    @Binding var at: Int
    /// In the chat: as tall as `height`, the full-screen button in its corner.
    var inline = false
    var height: CGFloat = 470
    let notes: Bool
    let toggleNotes: () -> Void
    var openFull: (() -> Void)?
    var close: (() -> Void)?
    /// On the stage, under its top bar and over its bottom bar: the drawing takes half the height instead of
    /// two thirds and the words step down a size, so a page's body never runs under the bar.
    var stage = false
    let emit: YLEmit
    @State private var scroll = DeckScroll()
    @State private var opened = Date()
    /// The page the scroll view is on. Its own state, mirrored to `at`: a paging scroll view turns reliably
    /// on a state binding, and the stage (whose page index is an observable model's) turns it through `at`.
    @State private var shown = 0
    @State private var position = ScrollPosition(idType: Int.self)
    /// On the stage there is no scroll view: the page on show is `at`, and the drawing tweens from the page it was
    /// on to the new one on its own clock.
    @State private var tween = MorphTween(from: 0, to: 0, start: .distantPast)
    @Environment(\.ylComponents) private var all
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var still: Bool { systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion") }

    /// Each page's drawing as glyphs, when its picture is `shapes` the stage can morph.
    private var morphs: [DeckMorph.Page?] {
        pages.map { p in
            guard p.preset == "page", let pic = all.picture(of: p), pic.preset == "shapes" else { return nil }
            let parts = all.members(of: pic).filter { $0.preset == "shape" }
            return DeckMorph.page(ShapesModel.scene(head: pic.props, members: parts.map { (id: $0.ylID, props: $0.props) }))
        }
    }

    var body: some View {
        let s = theme.swatch(scheme)
        let morphs = morphs
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let art = inline ? H * 0.6 : stage ? H * 0.5 : H * 0.64
            ZStack(alignment: .top) {
                // A soft light behind the drawing, so the stage has depth and no edge.
                RadialGradient(colors: [s.accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear], center: .init(x: 0.5, y: 0.3),
                               startRadius: 0, endRadius: max(W, H) * 0.6)
                    // Faded in from the top, so the light has no edge under the header.
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.22)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                MorphCanvas(pages: morphs, scroll: scroll, tween: stage ? tween : nil, opened: opened, still: still)
                    .frame(width: W, height: art)
                    .padding(.top, inline ? 0 : theme.spacing.l)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if stage { stagePager(art: art, W: W, H: H, s) } else { pager(art: art, W: W, H: H, s) }
            }
            .overlay(alignment: .topTrailing) { corner(s) }
            .overlay(alignment: .topLeading) {
                // In the chat the deck's name sits small in its corner, so the thread says what this is.
                if inline, let t = c.string("title"), !t.isEmpty {
                    Text(t).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                        .lineLimit(1)
                        .padding(.top, theme.spacing.s)
                        .padding(.trailing, 60)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: inline ? height : nil)
        .frame(maxHeight: inline ? nil : .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deck-stage")
        .accessibilityValue("Page \(at + 1) of \(pages.count)")
        .environment(\.ylEmit, emit)
        .onAppear {
            opened = Date(); shown = at; scroll.pos = Double(at)
            tween = MorphTween(from: Double(at), to: Double(at), start: .distantPast)
            if at > 0, !stage { position.scrollTo(id: at, anchor: .leading) }
        }
        // The stage turned the page (its arrows, a tap on the page, a swipe back from the questions): the drawing
        // tweens from wherever it is to the new page.
        .onChange(of: at) {
            guard stage else { return }
            let now = Date()
            tween = MorphTween(from: tween.pos(at: now, still: still), to: Double(at), start: now)
        }
        // The finger or a tap turned the page: tell the owner. The owner turned it (the stage's arrows, a dot):
        // scroll there.
        .onChange(of: shown) { if at != shown { at = shown } }
    }

    /// In the chat and on the deck's own cover: the pages side by side, one screen wide each. The finger pages them;
    /// the owner's `at` scrolls them.
    private func pager(art: CGFloat, W: CGFloat, H: CGFloat, _ s: Swatch) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element.serial) { i, p in
                    slot(p, i, art: art + (inline ? 0 : theme.spacing.l), size: CGSize(width: W, height: H), s)
                        .containerRelativeFrame(.horizontal)
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onChange(of: position.viewID(type: Int.self)) { _, id in
            if let id, id != shown { shown = id }
        }
        .onChange(of: at) {
            guard shown != at, pages.indices.contains(at) else { return }
            shown = at
            withAnimation(still ? .easeInOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.86)) {
                position.scrollTo(id: at, anchor: .leading)
            }
        }
        .onScrollGeometryChange(for: Double.self) { g in
            g.contentOffset.x / max(g.containerSize.width, 1)
        } action: { _, x in
            scroll.pos = x
        }
    }

    /// On the stage: one page at a time, no scroll view (a paging scroll view inside the stage would not turn on
    /// the stage's arrows). The page comes on in the stage's own transition, a tap on the left quarter goes back
    /// and anywhere else on (Chris, TestFlight AOM_F89JfsVH), and the drawing above tweens between the pages.
    private func stagePager(art: CGFloat, W: CGFloat, H: CGFloat, _ s: Swatch) -> some View {
        let i = min(max(0, at), pages.count - 1)
        let forward = Double(i) >= tween.from
        return ZStack {
            slot(pages[i], i, art: art + theme.spacing.l, size: CGSize(width: W, height: H), s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(i)
                .transition(still ? .opacity : .asymmetric(
                    insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
                    removal: .opacity))
        }
        .animation(still ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.9), value: i)
    }

    /// One page: room for the drawing (its own picture, when it is not one the stage morphs), then its words.
    @ViewBuilder
    private func slot(_ p: YLComponent, _ i: Int, art: CGFloat, size: CGSize, _ s: Swatch) -> some View {
        let active = i == at
        if p.preset != "page" {
            // A quiz question on its own page, in the middle of the stage.
            StageCenter { PresetView(component: p).padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.xl) }
                .environment(\.ylBare, true)
                .fading(!stage)
                .accessibilityHidden(!active)
        } else {
            ZStack(alignment: .top) {
                // On the stage the whole page turns: words and space too, as on every other stage page.
                if stage, active { turners(i) }
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        if active, !stage { turners(i) }
                        picture(p, art: art)
                    }
                    .frame(height: art)
                    words(p, size: size, s)
                        .padding(.horizontal, theme.spacing.l + theme.spacing.s)
                        .fading(!stage)
                        .accessibilityHidden(!active)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The picture the stage does not morph: a sketch, a chart, math, a calc, a stat, a photo.
    @ViewBuilder
    private func picture(_ p: YLComponent, art: CGFloat) -> some View {
        if let drawn = all.art(of: p) {
            SketchDrawing(sketch: drawn.sketch, parts: drawn.parts)
                .padding(.horizontal, theme.spacing.l)
                .fading(!stage)
        } else if let pic = all.picture(of: p), pic.preset != "shapes" {
            PresetView(component: pic)
                .environment(\.ylBare, true)
                .padding(.horizontal, theme.spacing.l)
                .frame(maxHeight: art)
                .fading(!stage)
        } else if all.picture(of: p) == nil, let img = YLMediaURL.url(p.string("img")) {
            MediaTile(src: img)
                .frame(maxWidth: .infinity, maxHeight: art - theme.spacing.xl)
                .clipShape(.rect(cornerRadius: theme.radius.bubble))
                .padding(.horizontal, theme.spacing.l)
                .fading(!stage)
        }
    }

    /// The words: one big line, and a quieter one under it.
    private func words(_ p: YLComponent, size: CGSize, _ s: Swatch) -> some View {
        let title = p.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let body = p.string("body").flatMap { $0.isEmpty ? nil : $0 }
        let points = p.strings("points") ?? []
        let width = size.width - 2 * (theme.spacing.l + theme.spacing.s)
        let big = title ?? body ?? ""
        let display = inline || stage ? theme.type.display * 0.85 : theme.type.display
        let fs = StoryPage.headlineSize(big, width: width, display: display, floor: theme.type.title + 3, statement: title == nil)
        let voice = typeSize.isAccessibilitySize ? theme.type.title * 1.25 : theme.type.title + (inline ? -1 : 1)
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !big.isEmpty {
                Text(big)
                    .font(theme.font(min(fs, inline ? 34 : stage ? 36 : 44), theme.strong))
                    .tracking(-fs * 0.02)
                    .foregroundStyle(s.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(title == nil ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: !inline)
                    .accessibilityIdentifier(title == nil ? "story-body" : "story-title")
                    .accessibilityAddTraits(.isHeader)
            }
            if title != nil, let body {
                Text(body)
                    .font(theme.font(voice, .medium))
                    .foregroundStyle(s.ink.opacity(0.72))
                    .lineLimit(inline ? 3 : stage ? 4 : 5)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: !inline && !stage)
                    .accessibilityIdentifier("story-body")
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    ForEach(Array(points.enumerated()), id: \.offset) { k, pt in
                        HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                            Text(String(format: "%02d", k + 1)).font(theme.font(voice * 0.8, .black).monospacedDigit())
                                .foregroundStyle(s.accent).accessibilityHidden(true)
                            Text(pt).font(theme.font(voice, .semibold)).foregroundStyle(s.ink)
                                .accessibilityIdentifier("story-point")
                        }
                    }
                }
            }
            if notes, let n = p.string("notes") {
                Text(n).font(theme.font(theme.type.caption, .medium)).foregroundStyle(s.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The drawing's two halves turn the page: right is on, left is back. Clear, so the drawing shows through.
    private func turners(_ i: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Button("Previous page") { turn(to: i - 1) }
                    .buttonStyle(ClearTurn())
                    .frame(width: stage ? geo.size.width * 0.25 : geo.size.width * 0.5)
                    .accessibilityLabel("Previous page")
                    .disabled(i == 0)
                Button("Next page") { turn(to: i + 1) }
                    .buttonStyle(ClearTurn())
                    .accessibilityLabel("Next page")
                    .disabled(i >= pages.count - 1)
            }
        }
    }

    private func turn(to i: Int) {
        guard pages.indices.contains(i) else { return }
        withAnimation(still ? .easeInOut(duration: 0.3) : .spring(response: 0.7, dampingFraction: 0.86)) { at = i }
    }

    /// The only chrome: full screen in the chat, close on its own cover, notes when a page has them.
    private func corner(_ s: Swatch) -> some View {
        HStack(spacing: theme.spacing.xs) {
            if pages.contains(where: { $0.string("notes") != nil }) {
                round(notes ? "Hide notes" : "Notes", "note.text", s, action: toggleNotes)
            }
            if let openFull { round("Full screen", "arrow.up.left.and.arrow.down.right", s, action: openFull) }
            if let close { round("Close", "xmark", s, action: close) }
        }
        .padding(.trailing, inline ? 0 : theme.spacing.s)
    }

    private func round(_ label: String, _ icon: String, _ s: Swatch, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(theme.font(theme.type.caption, .black))
                .foregroundStyle(s.ink.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
    }
}

/// A turn zone: nothing to see, the whole half takes the tap.
private struct ClearTurn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Color.clear.contentShape(.rect).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    /// Words and pictures that ride the swipe fade as they leave the middle and lag behind the page a
    /// little, so they dissolve in place more than they slide.
    @ViewBuilder
    func fading(_ on: Bool = true) -> some View {
        if !on { self } else {
        visualEffect { content, proxy in
            let x = proxy.frame(in: .scrollView(axis: .horizontal)).minX
            let w = max(proxy.size.width, 1)
            let d = min(abs(x) / w, 1)
            return content
                .opacity(1 - min(d * 1.7, 1))
                .offset(x: -x * 0.55)
                .blur(radius: d * 8)
        }
        }
    }
}

/// The drawing: the morph between the two pages either side of the swipe, alive at rest.
/// Where the drawing is between two pages when the stage, not a finger, turns them: from one page to the next on
/// its own clock, eased out, 0.7 s.
struct MorphTween: Equatable {
    var from: Double
    var to: Double
    var start: Date
    static let duration = 0.7

    func pos(at date: Date, still: Bool) -> Double {
        if still { return to }
        let k = min(1, max(0, date.timeIntervalSince(start) / Self.duration))
        return from + (to - from) * (1 - pow(1 - k, 3))
    }
}

struct MorphCanvas: View {
    let pages: [DeckMorph.Page?]
    let scroll: DeckScroll
    /// Set on the stage: the drawing's place comes from the tween, not from a scroll view.
    var tween: MorphTween? = nil
    let opened: Date
    let still: Bool
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// How long the first page takes to draw itself on.
    static let entrance = 1.4

    var body: some View {
        let s = theme.swatch(scheme)
        TimelineView(.animation(paused: still)) { tl in
            let time = tl.date.timeIntervalSince(opened)
            let at = tween?.pos(at: tl.date, still: still) ?? scroll.pos
            Canvas { ctx, size in
                draw(ctx, size, inks(size, time: time, pos: at), s)
            }
        }
    }

    private func inks(_ size: CGSize, time: Double, pos raw: Double) -> [DeckMorph.Ink] {
        guard !pages.isEmpty else { return [] }
        let pad = 22.0
        let w = size.width - 2 * pad, h = size.height - 2 * pad
        let pos = DeckMorph.clamp(raw, 0, Double(pages.count - 1))
        let i = Int(pos.rounded(.down)), t = pos - Double(i)
        var inks: [DeckMorph.Ink]
        if t < 0.0005 {
            // At rest on a page. Just opened: it draws itself on from nothing.
            let enter = still ? 1 : DeckMorph.clamp(time / Self.entrance, 0, 1)
            inks = DeckMorph.tween(nil, pages[i], t: enter, w: w, h: h, still: still)
        } else {
            inks = DeckMorph.tween(pages[i], i + 1 < pages.count ? pages[i + 1] : nil, t: t, w: w, h: h, still: still)
        }
        if !still { inks = DeckMorph.alive(inks, time: time, amp: 2.2) }
        return inks.map { var k = $0; k.pts = k.pts.map { [$0[0] + pad, $0[1] + pad] }
            k.labelAt = [k.labelAt[0] + pad, k.labelAt[1] + pad]; k.center = [k.center[0] + pad, k.center[1] + pad]; return k }
    }

    private func tone(_ name: String, _ s: Swatch) -> Color {
        switch name {
        case "mint": s.mint
        case "lavender": s.lavender
        case "butter": s.butter
        case "ink": s.ink
        case "mute": s.inkSoft
        default: s.accent
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ inks: [DeckMorph.Ink], _ s: Swatch) {
        let P = { (p: [Double]) in CGPoint(x: p[0], y: p[1]) }
        for i in inks where i.opacity > 0.001 {
            var c = ctx
            c.opacity = i.opacity
            let color = i.mix <= 0 ? tone(i.toneA, s) : i.mix >= 1 ? tone(i.toneB, s) : tone(i.toneA, s).mix(with: tone(i.toneB, s), by: i.mix)
            let lw = max(1.5, i.lw * 1.35)
            if i.pts.count > 1 {
                var path = Path()
                path.move(to: P(i.pts[0]))
                for q in i.pts.dropFirst() { path.addLine(to: P(q)) }
                if i.closed { path.closeSubpath() }
                if i.fill > 0.001 { c.fill(path, with: .color(color.opacity(i.fill))) }
                let stroke = i.trim < 0.999 ? path.trimmedPath(from: 0, to: i.trim) : path
                if i.trim > 0.001, !i.dot {
                    // A glow under the line, then the line.
                    var glow = c
                    glow.addFilter(.blur(radius: lw * 2.2))
                    glow.opacity = i.opacity * 0.45
                    glow.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round, lineJoin: .round))
                    c.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round,
                                                                             dash: i.dash ? [lw * 3, lw * 2.5] : []))
                }
                if i.head > 0.05, !i.closed, i.trim > 0.05 {
                    let n = i.pts.count
                    let k = max(1, min(n - 1, Int((Double(n - 1) * i.trim).rounded())))
                    let tip = i.pts[k], back = i.pts[max(0, k - 2)]
                    let dx = tip[0] - back[0], dy = tip[1] - back[1]
                    let len = max(hypot(dx, dy), 1e-9), ux = dx / len, uy = dy / len
                    let hk = lw * 4.2, sn = sin(0.5), cs = cos(0.5)
                    var head = Path()
                    head.move(to: CGPoint(x: tip[0] - hk * (ux * cs - uy * sn), y: tip[1] - hk * (uy * cs + ux * sn)))
                    head.addLine(to: P(tip))
                    head.addLine(to: CGPoint(x: tip[0] - hk * (ux * cs + uy * sn), y: tip[1] - hk * (uy * cs - ux * sn)))
                    var hc = c
                    hc.opacity = i.opacity * i.head
                    hc.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                }
            }
            if !i.label.isEmpty, i.labelOpacity > 0.001, i.fs > 1 {
                var tc = c
                tc.opacity = i.opacity * i.labelOpacity
                let lines = ShapesModel.wrap(i.label, width: max(i.labelWidth, i.fs * 3), fs: i.fs)
                let lh = i.fs * ShapesModel.line
                let y0 = i.labelAt[1] - Double(lines.count - 1) * lh / 2
                let ink = i.pts.isEmpty ? color : s.ink
                for (k, l) in lines.enumerated() {
                    tc.draw(Text(l).font(theme.font(i.fs, i.inside || i.pts.isEmpty ? .heavy : .bold)).foregroundColor(ink),
                            at: CGPoint(x: i.labelAt[0], y: y0 + Double(k) * lh), anchor: .center)
                }
            }
        }
    }
}
