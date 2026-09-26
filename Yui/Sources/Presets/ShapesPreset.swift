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

/// `shapes` in the chat, and a lone `shape` as a one-part drawing.
struct ShapesPreset: View {
    let c: YLComponent
    @Environment(\.ylComponents) private var all

    var body: some View {
        let head = c.preset == "shape" ? [:] : c.props
        let parts = c.preset == "shape" ? [c] : all.members(of: c).filter { $0.preset == "shape" }
        PresetCard {
            ShapesDrawing(scene: ShapesModel.scene(head: head, members: parts.map { (id: $0.ylID, props: $0.props) }))
        }
    }
}

struct ShapesDrawing: View {
    let scene: ShapesModel.Scene
    @State private var started = Date()
    @State private var finished = false
    @State private var runs = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !scene.title.isEmpty {
                Text(scene.title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
            }
            TimelineView(.animation(paused: reduceMotion || (finished && !scene.pulses))) { tl in
                let t = reduceMotion ? Double.infinity : tl.date.timeIntervalSince(started)
                Canvas { ctx, size in draw(ctx, size, ShapesModel.frame(scene, at: t), s) }
            }
            .aspectRatio(scene.w / scene.h, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if !reduceMotion { started = Date(); runs += 1 } }
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

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ frames: [ShapesModel.Frame], _ s: Swatch) {
        let u = size.width / scene.w // points per canvas unit
        let P = { (p: [Double]) in CGPoint(x: p[0] * u, y: p[1] * u) }
        let sw = 0.0075 * scene.w // stroke width in units
        let fs = scene.fs
        let lw = sw * u
        let dash: [CGFloat] = [lw * 3, lw * 2.5]
        for f in frames where f.o > 0 {
            let it = f.item
            let color = tone(it.tone, s)
            var c = ctx
            c.opacity = f.o
            if let a = f.a, let b = f.b {
                // A line or an arrow, traced from a toward b.
                let len = max(hypot(b[0] - a[0], b[1] - a[1]), 1e-9)
                let ux = (b[0] - a[0]) / len, uy = (b[1] - a[1]) / len
                let h = [a[0] + (b[0] - a[0]) * f.d, a[1] + (b[1] - a[1]) * f.d]
                var line = Path()
                line.move(to: P(a)); line.addLine(to: P(h))
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
                    label(tc, it.label, at: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - fs * 0.75], fs: fs * 0.9,
                          width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                }
                continue
            }
            if let pts = it.pts {
                var path = curve(pts, closed: false, u: u)
                if !it.dash { path = path.trimmedPath(from: 0, to: f.d) }
                c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: it.dash ? dash : []))
                if !it.label.isEmpty {
                    let m = pts[pts.count / 2]
                    var tc = c; tc.opacity = f.o * f.d
                    label(tc, it.label, at: [m[0], m[1] - fs * 0.85], fs: fs * 0.9,
                          width: ShapesModel.labelWidth(it, k: scene.k), u: u, color: s.ink, weight: .bold)
                }
                continue
            }
            guard let cen = f.c, let sz = it.size else { continue }
            let scaled = [sz[0] * f.s, sz[1] * f.s]
            if it.kind != "text" {
                let shape = outline(it.kind, scaled, seed: it.i, center: cen, u: u)
                if it.fill { c.fill(shape, with: .color(color.opacity((it.kind == "dot" ? 1 : 0.18) * f.d))) }
                let stroke = it.dash || f.d >= 1 ? shape : shape.trimmedPath(from: 0, to: f.d)
                c.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: lw, lineJoin: .round, dash: it.dash ? dash : []))
            }
            if !it.label.isEmpty {
                // Labels scale with their shape (grow and pulse).
                let lfs = fs * f.s
                guard lfs > 0.01 else { continue }
                let inside = it.kind != "dot" && it.kind != "text"
                if it.kind == "dot" {
                    label(c, it.label, at: [cen[0], cen[1] + scaled[1] / 2 + lfs * 0.25], fs: lfs,
                          width: ShapesModel.labelWidth(it, k: scene.k) * f.s, u: u, color: s.ink, weight: .bold, top: true)
                } else {
                    label(c, it.label, at: cen, fs: lfs, width: ShapesModel.labelWidth(it, k: scene.k) * f.s, u: u,
                          color: it.kind == "text" ? color : s.ink, weight: inside ? .heavy : .bold)
                }
            }
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
