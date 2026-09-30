import SwiftUI
import YuiLines

// Diagrams (DRAW-2, the app half of DRAW-1). `diagram [title] [caption=]`, then
// Mermaid up to `end`: a flowchart, a sequence or a state diagram, drawn static
// in the agent's look. Laid out by DiagramModel (DiagramScene.swift, a port of the
// hub's site/lib/yl/diagram.mjs), drawn with Canvas: no image, no network, no
// Mermaid library. Nodes are the agent's accent, lines its ink, notes its butter.
// Nodes come on in the order they were written, a fifth of a second apart, each
// edge right after the later of its two ends; a sequence comes on message by
// message. Reduce Motion shows it finished. Any other Mermaid type (`other`) shows
// its source as text. In the chat it is a card (a tap plays it again); as a deck
// or plan page's picture it draws the same way. VoiceOver reads the parts in the
// order they were written. Sends nothing.

struct DiagramPreset: View {
    let c: YLComponent

    var body: some View {
        PresetCard { DiagramDrawing(props: c.props) }
    }
}

@MainActor enum DiagramCache {
    enum Laid { case graph(DiagramModel.Graph), sequence(DiagramModel.Sequence), other }
    static var laid: [[String: YLValue]: Laid] = [:]

    static func layout(_ props: [String: YLValue]) -> Laid {
        if let hit = laid[props] { return hit }
        let out: Laid
        switch props["type"]?.string {
        case "flow", "state": out = .graph(DiagramModel.layoutGraph(DiagramModel.graphIn(props)))
        case "sequence": out = .sequence(DiagramModel.layoutSequence(DiagramModel.seqIn(props)))
        default: out = .other
        }
        if laid.count > 24 { laid.removeAll() }
        laid[props] = out
        return out
    }
}

struct DiagramDrawing: View {
    let props: [String: YLValue]
    @State private var started = Date()
    @State private var finished = false
    @State private var runs = 0
    @State private var avail: CGFloat = 300
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    private var title: String { props["title"]?.string ?? "" }
    private var caption: String { props["caption"]?.string ?? "" }

    var body: some View {
        let s = theme.swatch(scheme)
        let laid = DiagramCache.layout(props)
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !title.isEmpty {
                Text(title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
            }
            switch laid {
            case .graph(let g) where !g.nodes.isEmpty: canvas(size: CGSize(width: g.w, height: g.h), total: DiagramModel.total(graph: g)) { ctx, t in
                drawGraph(ctx, g, t, s)
            }
            case .sequence(let q) where !q.actors.isEmpty: canvas(size: CGSize(width: q.w, height: q.h), total: DiagramModel.total(sequence: q)) { ctx, t in
                drawSequence(ctx, q, t, s)
            }
            case .other:
                Text(props["source"]?.string ?? "")
                    .font(.system(size: theme.type.caption, design: .monospaced))
                    .foregroundStyle(s.inkSoft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("diagram-source")
            default: EmptyView()
            }
            if !caption.isEmpty {
                Text(caption).font(theme.font(theme.type.caption)).foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("diagram-caption")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { avail = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(describe)
    }

    private var describe: String {
        if case .other = DiagramCache.layout(props) { return title.isEmpty ? "Diagram" : title }
        return DiagramModel.describe(props)
    }

    /// The drawing scaled to the card, between 0.72 and 1.2 of its natural size like the web; wider than the card, it scrolls.
    @ViewBuilder
    private func canvas(size: CGSize, total: Double, draw: @escaping (GraphicsContext, Double) -> Void) -> some View {
        let scale = min(max(avail / max(size.width, 1), 0.72), 1.2)
        let w = size.width * scale, h = size.height * scale
        let drawing = TimelineView(.animation(paused: reduceMotion || finished)) { tl in
            let t = reduceMotion ? Double.infinity : tl.date.timeIntervalSince(started)
            Canvas { ctx, _ in
                var c = ctx
                c.scaleBy(x: scale, y: scale)
                draw(c, t)
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture { if !reduceMotion { started = Date(); finished = false; runs += 1 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(describe)
        .accessibilityValue("\(partCount) parts")
        .accessibilityIdentifier("diagram-drawing")
        .accessibilityAddTraits(.isImage)
        .task(id: runs) {
            finished = false
            try? await Task.sleep(for: .seconds(total + 0.1))
            finished = true
        }
        if w > avail + 1 {
            ScrollView(.horizontal, showsIndicators: false) { drawing }
        } else {
            drawing.frame(maxWidth: .infinity)
        }
    }

    private var partCount: Int {
        switch DiagramCache.layout(props) {
        case .graph(let g): g.nodes.count + g.edges.count
        case .sequence(let q): q.items.filter { $0.kind != "block" }.count
        case .other: 0
        }
    }

    // MARK: Drawing

    private func text(_ ctx: GraphicsContext, _ s: String, _ size: Double, _ weight: Font.Weight, _ color: Color,
                      at p: CGPoint, anchor: UnitPoint = .center) {
        ctx.draw(Text(s).font(theme.font(size, weight)).foregroundColor(color), at: p, anchor: anchor)
    }

    /// Centered lines, 16.5 apart, around `cy`.
    private func label(_ ctx: GraphicsContext, _ lines: [String], _ cx: Double, _ cy: Double, size: Double = 13, weight: Font.Weight = .bold, _ color: Color) {
        let y0 = cy - Double(lines.count - 1) * 16.5 / 2
        for (i, l) in lines.enumerated() { text(ctx, l, size, weight, color, at: CGPoint(x: cx, y: y0 + Double(i) * 16.5)) }
    }

    private func pt(_ p: [Double]) -> CGPoint { CGPoint(x: p[0], y: p[1]) }

    private func curve(_ q: [[Double]]) -> Path {
        var p = Path()
        p.move(to: pt(q[0]))
        p.addCurve(to: pt(q[3]), control1: pt(q[1]), control2: pt(q[2]))
        return p
    }

    private func head(at tip: [Double], from: [Double], size: Double, _ ctx: GraphicsContext, _ color: Color) {
        let dx = tip[0] - from[0], dy = tip[1] - from[1]
        let d = hypot(dx, dy)
        guard d > 0 else { return }
        let ux = dx / d, uy = dy / d
        let hw = size * 0.4
        var p = Path()
        p.move(to: pt(tip))
        p.addLine(to: CGPoint(x: tip[0] - ux * size - uy * hw, y: tip[1] - uy * size + ux * hw))
        p.addLine(to: CGPoint(x: tip[0] - ux * size + uy * hw, y: tip[1] - uy * size - ux * hw))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    /// The direction a curve leaves or arrives in: the nearest control point that is not on the end.
    private func toward(_ q: [[Double]], end: Bool) -> [Double] {
        let order = end ? [q[2], q[1], q[0]] : [q[1], q[2], q[3]]
        let tip = end ? q[3] : q[0]
        return order.first { hypot($0[0] - tip[0], $0[1] - tip[1]) > 0.5 } ?? order[2]
    }

    private func drawGraph(_ ctx: GraphicsContext, _ g: DiagramModel.Graph, _ t: Double, _ s: Swatch) {
        for b in g.groups {
            let r = RoundedRectangle(cornerRadius: 12).path(in: CGRect(x: b.x, y: b.y, width: b.w, height: b.h))
            ctx.fill(r, with: .color(s.ink.opacity(0.04)))
            ctx.stroke(r, with: .color(s.outline), style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
            if let l = b.label, !l.isEmpty { text(ctx, l, 11.5, .heavy, s.inkSoft, at: CGPoint(x: b.x + 12, y: b.y + 15), anchor: .leading) }
        }
        for e in g.edges {
            let p = DiagramModel.progress(t, at: Double(e.order) * DiagramModel.delay + 0.14)
            guard p > 0 else { continue }
            var c = ctx
            c.opacity = p
            let lw = e.line == "thick" ? 3.0 : 1.6
            let path = curve(e.pts).trimmedPath(from: 0, to: p)
            c.stroke(path, with: .color(s.inkSoft), style: StrokeStyle(lineWidth: lw, lineCap: .round,
                                                                         dash: e.line == "dash" ? [5, 4] : []))
            if p > 0.98 {
                let size = 10 + (lw - 1.6) * 2
                if !e.plain { head(at: e.pts[3], from: toward(e.pts, end: true), size: size, c, s.inkSoft) }
                if e.both { head(at: e.pts[0], from: toward(e.pts, end: false), size: size, c, s.inkSoft) }
            }
            if let l = e.label, !l.isEmpty {
                var lc = c
                lc.opacity = p * p
                let w = Double(l.utf16.count) * 6.8 + 12
                lc.fill(RoundedRectangle(cornerRadius: 6).path(in: CGRect(x: e.mid[0] - w / 2, y: e.mid[1] - 10, width: w, height: 20)),
                        with: .color(s.background.opacity(0.92)))
                text(lc, l, 11.5, .bold, s.inkSoft, at: pt(e.mid))
            }
        }
        for n in g.nodes {
            let p = DiagramModel.progress(t, at: Double(n.order) * DiagramModel.delay)
            guard p > 0 else { continue }
            var c = ctx
            c.opacity = p
            // It grows in from 0.9 about its middle.
            let k = 0.9 + 0.1 * p
            c.translateBy(x: n.cx * (1 - k), y: n.cy * (1 - k))
            c.scaleBy(x: k, y: k)
            drawNode(c, n, s)
            if !n.lines.isEmpty { label(c, n.lines, n.cx, n.cy, s.ink) }
        }
    }

    private func drawNode(_ c: GraphicsContext, _ n: DiagramModel.Node, _ s: Swatch) {
        let x = n.cx - n.w / 2, y = n.cy - n.h / 2, w = n.w, h = n.h, cx = n.cx, cy = n.cy
        let box = CGRect(x: x, y: y, width: w, height: h)
        func poly(_ pts: [(Double, Double)]) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath()
            return p
        }
        func node(_ p: Path) {
            c.fill(p, with: .color(s.background))
            c.fill(p, with: .color(s.accent.opacity(0.13)))
            c.stroke(p, with: .color(s.accent), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        func inner(_ p: Path) { c.stroke(p, with: .color(s.accent.opacity(0.7)), lineWidth: 1.2) }
        switch n.shape {
        case "start": c.fill(Path(ellipseIn: box), with: .color(s.ink))
        case "end":
            c.stroke(Path(ellipseIn: box.insetBy(dx: 1, dy: 1)), with: .color(s.ink), lineWidth: 1.8)
            c.fill(Path(ellipseIn: box.insetBy(dx: 6, dy: 6)), with: .color(s.ink))
        case "choice", "diamond": node(poly([(cx, y), (x + w, cy), (cx, y + h), (x, cy)]))
        case "fork", "join": c.fill(RoundedRectangle(cornerRadius: 3).path(in: box), with: .color(s.ink))
        case "circle": node(Path(ellipseIn: box))
        case "double":
            node(Path(ellipseIn: box))
            inner(Path(ellipseIn: box.insetBy(dx: 5, dy: 5)))
        case "hexagon": node(poly([(x + 12, y), (x + w - 12, y), (x + w, cy), (x + w - 12, y + h), (x + 12, y + h), (x, cy)]))
        case "slant": node(poly([(x + 12, y), (x + w, y), (x + w - 12, y + h), (x, y + h)]))
        case "flag": node(poly([(x + 14, y), (x + w, y), (x + w, y + h), (x + 14, y + h), (x, cy)]))
        case "cylinder":
            let k = 0.5523, ry = 7.0, rx = w / 2
            func arc(_ p: inout Path, _ y0: Double, up: Bool) {
                let sgn = up ? -1.0 : 1.0
                p.addCurve(to: CGPoint(x: cx, y: y0 + sgn * ry), control1: CGPoint(x: x, y: y0 + sgn * ry * k), control2: CGPoint(x: cx - rx * k, y: y0 + sgn * ry))
                p.addCurve(to: CGPoint(x: x + w, y: y0), control1: CGPoint(x: cx + rx * k, y: y0 + sgn * ry), control2: CGPoint(x: x + w, y: y0 + sgn * ry * k))
            }
            var body = Path()
            body.move(to: CGPoint(x: x, y: y + 7))
            arc(&body, y + 7, up: true)
            body.addLine(to: CGPoint(x: x + w, y: y + h - 7))
            // Back along the bottom, left to right mirrored.
            body.addCurve(to: CGPoint(x: cx, y: y + h), control1: CGPoint(x: x + w, y: y + h - 7 + ry * k), control2: CGPoint(x: cx + rx * k, y: y + h))
            body.addCurve(to: CGPoint(x: x, y: y + h - 7), control1: CGPoint(x: cx - rx * k, y: y + h), control2: CGPoint(x: x, y: y + h - 7 + ry * k))
            body.closeSubpath()
            node(body)
            var lid = Path()
            lid.move(to: CGPoint(x: x, y: y + 7))
            arc(&lid, y + 7, up: false)
            inner(lid)
        case "subroutine":
            node(RoundedRectangle(cornerRadius: 4).path(in: box))
            for dx in [7.0, w - 7] {
                var l = Path(); l.move(to: CGPoint(x: x + dx, y: y)); l.addLine(to: CGPoint(x: x + dx, y: y + h)); inner(l)
            }
        case "stadium": node(Capsule().path(in: box))
        case "round": node(RoundedRectangle(cornerRadius: 14).path(in: box))
        default: node(RoundedRectangle(cornerRadius: 6).path(in: box))
        }
    }

    private func drawSequence(_ ctx: GraphicsContext, _ q: DiagramModel.Sequence, _ t: Double, _ s: Swatch) {
        var ctx = ctx
        ctx.translateBy(x: q.dx, y: 0)
        let d = DiagramModel.delay * 1.4
        for b in q.items where b.kind == "block" {
            let p = DiagramModel.progress(t, at: Double(b.order) * d)
            guard p > 0 else { continue }
            var c = ctx
            c.opacity = p
            let x0 = q.span[0] + Double(b.depth) * 7, x1 = q.span[1] - Double(b.depth) * 7
            let r = RoundedRectangle(cornerRadius: 6).path(in: CGRect(x: x0, y: b.y, width: x1 - x0, height: b.h))
            c.fill(r, with: .color(s.ink.opacity(0.03)))
            c.stroke(r, with: .color(s.outline), lineWidth: 1.3)
            var tab = Path()
            let tw = Double(b.block.utf16.count) * 7 + 18
            tab.move(to: CGPoint(x: x0, y: b.y)); tab.addLine(to: CGPoint(x: x0 + tw, y: b.y))
            tab.addLine(to: CGPoint(x: x0 + tw, y: b.y + 14)); tab.addLine(to: CGPoint(x: x0 + tw - 6, y: b.y + 20))
            tab.addLine(to: CGPoint(x: x0, y: b.y + 20)); tab.closeSubpath()
            c.fill(tab, with: .color(s.outline.opacity(0.55)))
            text(c, b.block, 11, .heavy, s.ink, at: CGPoint(x: x0 + 8, y: b.y + 11), anchor: .leading)
            if !b.text.isEmpty { text(c, "[\(b.text)]", 11.5, .semibold, s.inkSoft, at: CGPoint(x: x0 + tw + 8, y: b.y + 11), anchor: .leading) }
            for dv in b.divs {
                var l = Path(); l.move(to: CGPoint(x: x0, y: dv.y + 8)); l.addLine(to: CGPoint(x: x1, y: dv.y + 8))
                c.stroke(l, with: .color(s.outline), style: StrokeStyle(lineWidth: 1.3, dash: [5, 4]))
                if !dv.text.isEmpty { text(c, "[\(dv.text)]", 11.5, .semibold, s.inkSoft, at: CGPoint(x: x0 + 8, y: dv.y + 20), anchor: .leading) }
            }
        }
        for a in q.actors {
            var l = Path(); l.move(to: CGPoint(x: a.x, y: a.h)); l.addLine(to: CGPoint(x: a.x, y: q.life[1]))
            ctx.stroke(l, with: .color(s.outline), style: StrokeStyle(lineWidth: 1.4, dash: [4, 4]))
            let r = RoundedRectangle(cornerRadius: a.actor ? a.h / 2 : 6).path(in: CGRect(x: a.x - a.w / 2, y: 0, width: a.w, height: a.h))
            ctx.fill(r, with: .color(s.background))
            ctx.fill(r, with: .color(s.accent.opacity(0.13)))
            ctx.stroke(r, with: .color(s.accent), lineWidth: 1.6)
            label(ctx, a.lines, a.x, a.h / 2, s.ink)
        }
        for it in q.items where it.kind != "block" {
            let p = DiagramModel.progress(t, at: Double(it.order) * d + 0.2)
            guard p > 0 else { continue }
            var c = ctx
            c.opacity = p
            if it.kind == "note" {
                let r = RoundedRectangle(cornerRadius: 6).path(in: CGRect(x: it.x, y: it.y, width: it.w, height: it.h))
                c.fill(r, with: .color(s.background))
                c.fill(r, with: .color(s.butter.opacity(0.3)))
                c.stroke(r, with: .color(s.butter), lineWidth: 1.2)
                label(c, it.lines, it.x + it.w / 2, it.y + it.h / 2, size: 12, weight: .semibold, s.ink)
                continue
            }
            let dir: Double = it.x2 >= it.x1 ? 1 : -1
            let mx = (it.x1 + it.x2) / 2
            let dash: [CGFloat] = it.step.line != nil ? [5, 4] : []
            let st = StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dash)
            let noHead = it.step.head == "none"
            if it.selfMsg {
                var l = Path()
                l.move(to: CGPoint(x: it.x1, y: it.y - 14)); l.addLine(to: CGPoint(x: it.x1 + 28, y: it.y - 14))
                l.addLine(to: CGPoint(x: it.x1 + 28, y: it.y)); l.addLine(to: CGPoint(x: it.x1 + 4, y: it.y))
                c.stroke(l, with: .color(s.inkSoft), style: st)
                if !noHead { head(at: [it.x1 + 4, it.y], from: [it.x1 + 28, it.y], size: 10, c, s.inkSoft) }
            } else {
                var l = Path()
                l.move(to: CGPoint(x: it.x1 + dir * 2, y: it.y)); l.addLine(to: CGPoint(x: it.x2 - dir * 2, y: it.y))
                c.stroke(l, with: .color(s.inkSoft), style: st)
                if !noHead { head(at: [it.x2 - dir * 2, it.y], from: [it.x1, it.y], size: 10, c, s.inkSoft) }
                if it.step.both { head(at: [it.x1 + dir * 2, it.y], from: [it.x2, it.y], size: 10, c, s.inkSoft) }
            }
            if it.step.head == "cross" { text(c, "×", 18, .heavy, ChartPalette.bad(scheme), at: CGPoint(x: it.x2 - dir * 10, y: it.y)) }
            let tx = it.selfMsg ? it.x1 + 34 : mx
            let baseY = it.selfMsg ? it.y - 6 : it.y - 7 - Double(it.lines.count - 1) * 16
            for (i, l) in it.lines.enumerated() {
                text(c, l, 12.5, .semibold, s.ink, at: CGPoint(x: tx, y: baseY + Double(i) * 16 - 6),
                     anchor: it.selfMsg ? .leading : .center)
            }
            if it.n > 0 {
                let nx = tx - (it.selfMsg ? 12 : it.tw / 2 + 12), ny = it.y - 13 - Double(it.lines.count - 1) * 8
                c.fill(Path(ellipseIn: CGRect(x: nx - 8, y: ny - 8, width: 16, height: 16)), with: .color(s.accent))
                text(c, "\(it.n)", 10, .heavy, s.background, at: CGPoint(x: nx, y: ny))
            }
        }
    }
}
