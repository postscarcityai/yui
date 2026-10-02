import SwiftUI
import YuiLines

// Shapes that move (YUI-104; Chris on build 96: "simple SVG style vector
// graphics... basic shapes both geometric and organic to show some complex
// ideas very quickly... not an immersive experience, still just in the chat
// with captions"). `shapes [title] caption= w= h=`, then `shape KIND [label]`
// lines: circles, boxes, pills, dots, blobs, labels, lines, arrows and paths
// that come on one after another (fade, +draw, +grow, +pulse, move=). Drawn
// here with Canvas from ShapesModel, no images and no network. Reduce Motion
// shows the finished drawing. A tap plays it again. Sends nothing.
//
// Draw anything on any screen (YUI-276): Venns with labelled overlaps, contour
// rings, free regions, hand-drawn doodles (a stroke or a ring round a spot),
// bent arrows (bend=), and img= to mark up a picture under the drawing. The
// same view draws in the chat, on pages 2 to 12, on the stage and in a deck or
// plan, since every one of them draws through PresetView.

/// `shapes` in the chat, and a lone `shape` as a one-part drawing.
struct ShapesPreset: View {
    let c: YLComponent
    @Environment(\.ylComponents) private var all

    var body: some View {
        let head = c.preset == "shape" ? [:] : c.props
        let parts = c.preset == "shape" ? [c] : all.members(of: c).filter { $0.preset == "shape" }
        PresetCard {
            ShapesDrawing(head: head, members: parts.map { (id: $0.ylID, props: $0.props) })
        }
    }
}

/// A drawing with its title and caption. With img= and no h= it takes the picture's shape (YUI-276):
/// the shape the picture had last time, else the old default until it loads, the marks held back
/// until then so nothing jumps once they are on.
struct ShapesDrawing: View {
    let head: [String: YLValue]
    let members: [(id: String?, props: [String: YLValue])]
    @State private var started = Date()
    @State private var finished = false
    @State private var runs = 0
    /// The picture's width over its height, once it has loaded; or it failed, and the drawing goes on without it.
    @State private var ratio: Double?
    @State private var failed = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    /// The picture under the drawing, when it has one (`img=`).
    private var picture: URL? { YLMediaURL.url(head["img"].flatMap { ShapesModel.text($0) }) }
    /// The picture's shape as far as it is known: loaded now, or remembered from an earlier load.
    private var known: Double? { ratio ?? picture.flatMap { Pictures.ratio($0) }.map { Double($0) } }
    /// The drawing waits for the picture's shape before its marks come on.
    private var waiting: Bool { picture != nil && ShapesModel.pictureShaped(head) && known == nil && !failed }

    var body: some View {
        let s = theme.swatch(scheme)
        let scene = ShapesModel.scene(head: head, members: members, ratio: known)
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !scene.title.isEmpty {
                Text(scene.title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
            }
            ShapesCanvas(scene: scene, start: waiting ? nil : started, finished: finished, still: reduceMotion)
                .aspectRatio(scene.w / scene.h, contentMode: .fit)
                .frame(maxWidth: .infinity)
                // Marks over a picture (YUI-276): it fills the canvas under the drawing, cropped to its shape.
                .background {
                    if let src = picture {
                        RemoteImage(src: src, fit: .fill, onRatio: { r in
                            guard ShapesModel.pictureShaped(head), Double(r) != known else { return }
                            let first = known == nil
                            withAnimation(reduceMotion ? nil : .snappy) { ratio = Double(r) }
                            // The marks start once the drawing has its shape.
                            if first { started = Date(); runs += 1 }
                        }, onFail: {
                            if waiting { failed = true; started = Date(); runs += 1 }
                        })
                    }
                }
                .clipShape(.rect(cornerRadius: picture == nil ? 0 : theme.radius.card))
                .contentShape(Rectangle())
                .onTapGesture { if !reduceMotion, !waiting { started = Date(); runs += 1 } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ShapesModel.describe(scene))
                .accessibilityValue("\(scene.items.count) parts")
                .accessibilityIdentifier("shapes-drawing")
                .accessibilityAddTraits(.isImage)
                .task(id: runs) {
                    finished = false
                    try? await Task.sleep(for: .seconds(scene.total + 0.1))
                    finished = true
                }
            if !scene.caption.isEmpty {
                Text(scene.caption).font(theme.font(theme.type.caption)).foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shapes-caption")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The drawing itself: a scene on its clock, drawn with Canvas. `start` nil holds it before its first
/// part (a picture's shape still coming, a mock's parts still coming on); `delay` waits that long after
/// `start`; `still` is Reduce Motion, the finished drawing. Used by `shapes` and by marks over a mock.
struct ShapesCanvas: View {
    let scene: ShapesModel.Scene
    var start: Date?
    var delay: Double = 0
    var finished = false
    var still = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        TimelineView(.animation(paused: still || start == nil || (finished && !scene.pulses))) { tl in
            let t = still ? Double.infinity : start.map { tl.date.timeIntervalSince($0) - delay } ?? -1
            Canvas { ctx, size in draw(ctx, size, ShapesModel.frame(scene, at: t), t, s) }
        }
    }

    /// The picture under the drawing, when it has one (`img=`).
    private var picture: URL? { YLMediaURL.url(scene.img) }

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

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ frames: [ShapesModel.Frame], _ t: Double, _ s: Swatch) {
        let u = size.width / scene.w // points per canvas unit
        let P = { (p: [Double]) in CGPoint(x: p[0] * u, y: p[1] * u) }
        let sw = 0.0075 * scene.w // stroke width in units
        let fs = scene.fs
        let lw = sw * u
        let dash: [CGFloat] = [lw * 3, lw * 2.5]
        // Over a picture every line and label gets a soft halo of the page's ground, so it reads on any photo (YUI-276).
        var base = ctx
        if picture != nil { base.addFilter(.shadow(color: s.background.opacity(0.9), radius: max(1.5, lw * 1.2))) }
        for f in frames where f.o > 0 {
            let it = f.item
            let color = tone(it.tone, s)
            var c = base
            c.opacity = f.o
            if let a = f.a, let b = f.b, it.kind == "swipe" {
                // A finger sliding from a to b (YUI-276): a trail that thickens and darkens toward the
                // fingertip, which travels with the trace. +pulse swipes again, once a breath.
                var d = f.d
                if it.pulse, t.isFinite, t > it.start + it.dur {
                    d = ((t - it.start - it.dur) / ShapesModel.pulse).truncatingRemainder(dividingBy: 1)
                }
                let at = { (x: Double) -> [Double] in
                    f.q.map { ShapesModel.bent(a, $0, b, x).p } ?? [a[0] + (b[0] - a[0]) * x, a[1] + (b[1] - a[1]) * x]
                }
                let n = 12
                for i in 0..<n where d > 0 {
                    let x0 = d * Double(i) / Double(n), x1 = d * Double(i + 1) / Double(n)
                    var seg = Path()
                    seg.move(to: P(at(x0))); seg.addLine(to: P(at(x1)))
                    let w = Double(i + 1) / Double(n)
                    c.stroke(seg, with: .color(color.opacity(0.15 + 0.85 * w)),
                             style: StrokeStyle(lineWidth: lw * (1 + 2 * w), lineCap: .round, dash: it.dash ? dash : []))
                }
                let tip = at(d), rr = 0.28 * (sw / 0.075)
                let finger = Path(ellipseIn: CGRect(x: (tip[0] - rr) * u, y: (tip[1] - rr) * u, width: 2 * rr * u, height: 2 * rr * u))
                c.fill(finger, with: .color(color.opacity(0.3)))
                c.stroke(finger, with: .color(color), lineWidth: lw)
                if !it.label.isEmpty {
                    var tc = c; tc.opacity = f.o * f.d
                    let m = at(0.5)
                    label(tc, it.label, at: [m[0], m[1] - fs * 0.85], fs: fs * 0.9,
                          width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                }
                continue
            }
            if let a = f.a, let b = f.b {
                // A line or an arrow, traced from a toward b: straight, or bent through q (YUI-276).
                var line = Path()
                line.move(to: P(a))
                let h: [Double], dir: [Double]
                if let q = f.q {
                    // The first d of the curve is itself a curve: a to bent(d), its control a d of the way to q.
                    let e = ShapesModel.bent(a, q, b, f.d)
                    h = e.p
                    dir = e.dir
                    line.addQuadCurve(to: P(h), control: P([a[0] + (q[0] - a[0]) * f.d, a[1] + (q[1] - a[1]) * f.d]))
                } else {
                    h = [a[0] + (b[0] - a[0]) * f.d, a[1] + (b[1] - a[1]) * f.d]
                    dir = [b[0] - a[0], b[1] - a[1]]
                    line.addLine(to: P(h))
                }
                let len = max(hypot(dir[0], dir[1]), 1e-9)
                let ux = dir[0] / len, uy = dir[1] / len
                c.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: it.dash ? dash : []))
                if it.kind == "arrow" && f.d > 0.05 {
                    let k = 0.34 * (sw / 0.07), sn = sin(0.5), cs = cos(0.5)
                    var head = Path()
                    head.move(to: P([h[0] - k * (ux * cs - uy * sn), h[1] - k * (uy * cs + ux * sn)]))
                    head.addLine(to: P(h))
                    head.addLine(to: P([h[0] - k * (ux * cs + uy * sn), h[1] - k * (uy * cs - ux * sn)]))
                    c.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                }
                if !it.label.isEmpty {
                    var tc = c; tc.opacity = f.o * f.d
                    // Over the middle of the line, or the top of the bow.
                    let m = f.q.map { ShapesModel.bent(a, $0, b, 0.5).p } ?? [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
                    label(tc, it.label, at: [m[0], m[1] - fs * 0.75], fs: fs * 0.9,
                          width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                }
                continue
            }
            if let pts = it.pts {
                switch it.kind {
                case "region":
                    // A free outline (YUI-276): traced on, then washed when it says +fill.
                    let shape = curve(pts, closed: true, u: u)
                    if it.fill { c.fill(shape, with: .color(color.opacity(0.18 * f.d))) }
                    let edge = it.dash || f.d >= 1 ? shape : shape.trimmedPath(from: 0, to: f.d)
                    c.stroke(edge, with: .color(color), style: StrokeStyle(lineWidth: lw, lineJoin: .round, dash: it.dash ? dash : []))
                case "doodle":
                    // A hand-drawn stroke (YUI-276): a wobbly line, a little heavier than a ruled one.
                    var path = curve(ShapesModel.doodle(pts, seed: it.i, w: scene.w), closed: false, u: u)
                    if !it.dash { path = path.trimmedPath(from: 0, to: f.d) }
                    c.stroke(path, with: .color(color),
                             style: StrokeStyle(lineWidth: lw * 1.6, lineCap: .round, lineJoin: .round, dash: it.dash ? dash : []))
                default:
                    var path = curve(pts, closed: false, u: u)
                    if !it.dash { path = path.trimmedPath(from: 0, to: f.d) }
                    c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: it.dash ? dash : []))
                }
                if !it.label.isEmpty {
                    var tc = c; tc.opacity = f.o * f.d
                    switch it.kind {
                    case "region":
                        // Inside it, in its widest part, fitted to it.
                        let r = ShapesModel.regionLabel(it, fs: fs)
                        lines(tc, r.lines, at: r.at, fs: r.fs, u: u, color: s.ink, weight: .heavy)
                    case "doodle":
                        // Over its highest point, like a note written above a mark.
                        let top = pts.min { $0[1] < $1[1] } ?? pts[0]
                        label(tc, it.label, at: [top[0], top[1] - fs * 0.85], fs: fs * 0.9,
                              width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                    default:
                        let m = pts[pts.count / 2]
                        label(tc, it.label, at: [m[0], m[1] - fs * 0.85], fs: fs * 0.9,
                              width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                    }
                }
                continue
            }
            guard let cen = f.c, let sz = it.size else { continue }
            let scaled = [sz[0] * f.s, sz[1] * f.s]
            if it.kind == "venn" {
                // Circles washed in their tones, so where they overlap reads darker; a label in each part (YUI-276).
                let v = ShapesModel.venn(it, center: cen, s: f.s, fs: fs)
                for circle in v.circles {
                    let shape = outline("circle", [circle.r * 2, circle.r * 2], seed: it.i, center: circle.c, u: u)
                    let col = tone(circle.tone, s)
                    c.fill(shape, with: .color(col.opacity(0.16 * f.d)))
                    let edge = it.dash || f.d >= 1 ? shape : shape.trimmedPath(from: 0, to: f.d)
                    c.stroke(edge, with: .color(col), style: StrokeStyle(lineWidth: lw, lineJoin: .round, dash: it.dash ? dash : []))
                }
                if fs * f.s > 0.01 {
                    // Each in the widest part of its own region, at most two lines, shrunk to fit.
                    for l in v.labels { lines(c, l.lines, at: l.at, fs: l.fs, u: u, color: s.ink, weight: l.middle ? .heavy : .bold) }
                }
                continue
            }
            if it.kind == "contour" {
                // Rings like a height map (YUI-276): traced outside in, the inner ones stronger, washes stacking toward the peak.
                let ct = ShapesModel.contour(it, center: cen, s: f.s, fs: fs)
                let last = Double(max(ct.rings.count - 1, 1))
                for (k, ring) in ct.rings.enumerated() {
                    let shape = curve(ring, closed: true, u: u)
                    let col = color.opacity(0.5 + 0.5 * Double(k) / last)
                    if it.fill { c.fill(shape, with: .color(color.opacity(0.08 * f.d))) }
                    let local = min(1, max(0, f.d * 1.6 - 0.6 * Double(k) / last))
                    guard local > 0 else { continue }
                    let edge = it.dash || local >= 1 ? shape : shape.trimmedPath(from: 0, to: local)
                    c.stroke(edge, with: .color(col), style: StrokeStyle(lineWidth: lw, lineJoin: .round, dash: it.dash ? dash : []))
                }
                if !it.label.isEmpty, fs * f.s > 0.01 {
                    lines(c, ct.label.lines, at: ct.peak, fs: ct.label.fs, u: u, color: s.ink, weight: .heavy)
                }
                continue
            }
            if it.kind == "tap" {
                // A fingertip landing (YUI-276): a washed disc, a dot in its middle, and a ring that spreads
                // and fades as it lands (and again each breath with +pulse).
                let disc = outline("circle", scaled, seed: it.i, center: cen, u: u)
                c.fill(disc, with: .color(color.opacity(0.28)))
                c.stroke(disc, with: .color(color), lineWidth: lw)
                c.fill(outline("circle", scaled.map { $0 * 0.3 }, seed: it.i, center: cen, u: u), with: .color(color))
                if t.isFinite, t > it.start {
                    let landed = t - it.start - it.dur
                    let k = landed < 0 ? (t - it.start) / it.dur
                        : it.pulse ? (landed / ShapesModel.pulse).truncatingRemainder(dividingBy: 1) : 1
                    if k < 1 {
                        var ring = c
                        ring.opacity = f.o * 0.55 * (1 - k)
                        ring.stroke(outline("circle", sz.map { $0 * (1 + 0.9 * k) }, seed: it.i, center: cen, u: u),
                                    with: .color(color), lineWidth: lw)
                    }
                }
            } else if it.kind != "text" {
                let shape = outline(it.kind, scaled, seed: it.i, center: cen, u: u)
                if it.fill { c.fill(shape, with: .color(color.opacity((it.kind == "dot" ? 1 : 0.18) * f.d))) }
                let stroke = it.dash || f.d >= 1 ? shape : shape.trimmedPath(from: 0, to: f.d)
                c.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: lw, lineJoin: .round, dash: it.dash ? dash : []))
            }
            if !it.label.isEmpty {
                // Labels scale with their shape (grow and pulse).
                let lfs = fs * f.s
                guard lfs > 0.01 else { continue }
                let inside = it.kind != "dot" && it.kind != "tap" && it.kind != "text"
                if it.kind == "dot" || it.kind == "tap" {
                    label(c, it.label, at: [cen[0], cen[1] + scaled[1] / 2 + lfs * 0.25], fs: lfs,
                          width: ShapesModel.labelWidth(it, k: scene.k) * f.s, u: u, color: s.ink, weight: .bold, top: true)
                } else {
                    label(c, it.label, at: cen, fs: lfs, width: ShapesModel.labelWidth(it, k: scene.k) * f.s, u: u,
                          color: it.kind == "text" ? color : s.ink, weight: inside ? .heavy : .bold)
                }
            }
        }
    }

    /// Lines already fitted (a Venn's, a region's or a contour's label, YUI-276), centred on `p`.
    private func lines(_ ctx: GraphicsContext, _ ls: [String], at p: [Double], fs: Double, u: CGFloat, color: Color, weight: Font.Weight) {
        let lh = fs * ShapesModel.line
        let y0 = p[1] - Double(ls.count - 1) * lh / 2
        for (k, l) in ls.enumerated() {
            ctx.draw(Text(l).font(theme.font(fs * u, weight)).foregroundColor(color),
                     at: CGPoint(x: p[0] * u, y: (y0 + Double(k) * lh) * u), anchor: .center)
        }
    }

    /// A label as centred lines; `at` is the middle of the block (top: its top edge).
    private func label(_ ctx: GraphicsContext, _ text: String, at p: [Double], fs: Double, width: Double, u: CGFloat,
                       color: Color, weight: Font.Weight, top: Bool = false) {
        let lines = ShapesModel.wrap(text, width: width, fs: fs)
        let lh = fs * ShapesModel.line
        let y0 = top ? p[1] + lh / 2 : p[1] - Double(lines.count - 1) * lh / 2
        for (k, l) in lines.enumerated() {
            let t = Text(l).font(theme.font(fs * u, weight)).foregroundColor(color)
            ctx.draw(t, at: CGPoint(x: p[0] * u, y: (y0 + Double(k) * lh) * u), anchor: .center)
        }
    }

    private func curve(_ pts: [[Double]], closed: Bool, u: CGFloat, center: [Double] = [0, 0]) -> Path {
        let P = { (p: [Double]) in CGPoint(x: (p[0] + center[0]) * u, y: (p[1] + center[1]) * u) }
        var path = Path()
        path.move(to: P(pts[0]))
        for (a, b, c) in ShapesModel.smooth(pts, closed: closed) { path.addCurve(to: P(c), control1: P(a), control2: P(b)) }
        if closed { path.closeSubpath() }
        return path
    }

    /// A closed shape's outline, centred on `center`, starting at its top so +draw traces from there.
    private func outline(_ kind: String, _ sz: [Double], seed: Int, center: [Double], u: CGFloat) -> Path {
        let w = sz[0] * u, h = sz[1] * u
        let rect = CGRect(x: center[0] * u - w / 2, y: center[1] * u - h / 2, width: w, height: h)
        switch kind {
        case "circle", "dot":
            // From the top, clockwise, like the web's two arcs.
            var p = Path()
            p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 1, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
            return p.applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(scaleX: w / 2, y: h / 2))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
        case "blob":
            return curve(ShapesModel.blobPoints(sz[0], sz[1], seed: seed), closed: true, u: u, center: center)
        default:
            let r = kind == "pill" ? h / 2 : min(0.3 * u, h / 4)
            return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        }
    }
}
