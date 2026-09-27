import SwiftUI
import YuiLines

// Maps (YUI-158; Chris on the Mongol Empire answer, feedback AL2nKEYo: "Again,
// not bad but this should be a Map."). `map [title] caption= fit= center= zoom=`,
// then `area`, `pin` and `route` lines: countries or a drawn outline filled in,
// pins on the cities, routes traced between them, a beat apart. Laid out by
// MapModel (MapScene.swift, a port of the hub's map.mjs) over the bundled
// Natural Earth 110m outline, drawn with Canvas in the agent's colors: no
// tiles, no key, no network. Reduce Motion shows the finished map. In the chat
// it is a still card (a tap plays it again); on the stage, a deck or plan
// page's picture, it pinches and pans (a double tap sets it back), and a drag
// at full size still turns the page. Sends nothing.

/// `map` in the chat or on a page, and a lone `area`, `pin` or `route` as a map of just that part.
struct MapPreset: View {
    let c: YLComponent
    @Environment(\.ylComponents) private var all

    static let parts: Set<String> = ["area", "pin", "route"]

    var body: some View {
        PresetCard { MapDrawing(scene: Self.scene(c, all: all)) }
    }

    /// The scene for a map head (its members from `all`) or a lone part.
    @MainActor static func scene(_ c: YLComponent, all: [YLComponent]) -> MapModel.Scene {
        let lone = c.preset != "map"
        let head = lone ? [:] : c.props
        let members = lone ? [c] : all.members(of: c).filter { parts.contains($0.preset) }
        let key = "\(c.preset)|\(head)|" + members.map { "\($0.ylID)|\($0.preset)|\($0.props)" }.joined(separator: "\n")
        if let hit = MapCache.scenes[key] { return hit }
        let sc = MapModel.scene(head: head, members: members.map { (id: $0.ylID, preset: $0.preset, props: $0.props) })
        if MapCache.scenes.count > 24 { MapCache.scenes.removeAll() }
        MapCache.scenes[key] = sc
        return sc
    }
}

/// Scenes and their paths, so a redraw (every frame while it plays) projects nothing twice.
@MainActor enum MapCache {
    static var scenes: [String: MapModel.Scene] = [:]
    static var paths: [String: Path] = [:]

    /// Rings as one path in drawing units (100 wide).
    static func path(_ key: String, _ rings: [[[Double]]]) -> Path {
        if let p = paths[key] { return p }
        var p = Path()
        for r in rings where r.count > 1 {
            p.move(to: CGPoint(x: r[0][0], y: r[0][1]))
            for q in r.dropFirst() { p.addLine(to: CGPoint(x: q[0], y: q[1])) }
            p.closeSubpath()
        }
        if paths.count > 96 { paths.removeAll() }
        paths[key] = p
        return p
    }
}

struct MapDrawing: View {
    let scene: MapModel.Scene
    @State private var started = Date()
    @State private var finished = false
    @State private var runs = 0
    // Pinch and pan, on the stage only.
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }
    private var scale: CGFloat { min(max(zoom * pinch, 1), 6) }
    private var zoomed: Bool { scale > 1.01 }

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !scene.title.isEmpty {
                Text(scene.title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
            }
            GeometryReader { geo in
                TimelineView(.animation(paused: reduceMotion || (finished && !scene.pulses))) { tl in
                    let t = reduceMotion ? Double.infinity : tl.date.timeIntervalSince(started)
                    // The zoom is drawn, not scaled: lines and labels stay sharp and keep their size.
                    let o = bounded(pan + drag, in: geo.size)
                    Canvas { ctx, size in draw(ctx, size, MapModel.frame(scene, at: t), s, zoom: scale, offset: o) }
                }
            }
            .aspectRatio(scene.w / scene.h, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if onStage { withAnimation(theme.spring) { zoom = 1; pan = .zero } } }
            .onTapGesture { if !reduceMotion { started = Date(); runs += 1 } }
            .simultaneousGesture(magnify, including: onStage ? .all : .none)
            .gesture(panning, including: onStage && zoomed ? .all : .none)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MapModel.describe(scene))
            .accessibilityValue("\(scene.items.count) parts")
            .accessibilityIdentifier("map-drawing")
            .accessibilityAddTraits(.isImage)
            .task(id: runs) {
                finished = false
                try? await Task.sleep(for: .seconds(scene.total + 0.1))
                finished = true
            }
            if !scene.caption.isEmpty {
                Text(scene.caption).font(theme.font(theme.type.caption)).foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map-caption")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { v in
                zoom = min(max(zoom * v.magnification, 1), 6)
                pinch = 1
                if zoom <= 1.01 { withAnimation(theme.spring) { zoom = 1; pan = .zero } }
            }
    }

    private var panning: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag = $0.translation }
            .onEnded { v in pan = pan + v.translation; drag = .zero }
    }

    /// Keeps the zoomed map over its frame: no pan past an edge.
    private func bounded(_ o: CGSize, in size: CGSize) -> CGSize {
        let mx = size.width * (scale - 1) / 2, my = size.height * (scale - 1) / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
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

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ frames: [MapModel.Frame], _ s: Swatch,
                      zoom: CGFloat = 1, offset: CGSize = .zero) {
        let u0 = size.width / scene.w // points per drawing unit at full size
        let u = u0 * zoom
        // Zoomed about the middle, then panned.
        let ox = size.width / 2 * (1 - zoom) + offset.width, oy = size.height / 2 * (1 - zoom) + offset.height
        let unit = CGAffineTransform(a: u, b: 0, c: 0, d: u, tx: ox, ty: oy)
        let sw = 0.28 * u0
        let fs = scene.fs
        // The sea and the land: the agent's ink at a whisper.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(s.ink.opacity(0.04)))
        let land = MapCache.path("land|\(scene.view.lon)|\(scene.view.lat)|\(scene.h)", scene.land).applying(unit)
        ctx.fill(land, with: .color(s.ink.opacity(0.1)))
        ctx.stroke(land, with: .color(s.inkSoft.opacity(0.35)), style: StrokeStyle(lineWidth: sw * 0.6, lineJoin: .round))
        let P = { (p: [Double]) in CGPoint(x: p[0] * u + ox, y: p[1] * u + oy) }
        for f in frames where f.o > 0 {
            let it = f.item
            let color = tone(it.tone, s)
            var c = ctx
            c.opacity = f.o
            switch it.kind {
            case "area":
                let key = "area|\(scene.view.lon)|\(scene.view.lat)|\(it.i)|\(it.rings.count)|\(it.c)"
                let shape = MapCache.path(key, it.rings).applying(unit)
                c.fill(shape, with: .color(color.opacity(it.dash ? 0.12 : 0.32)))
                c.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: sw * 1.2, lineJoin: .round,
                                                                        dash: it.dash ? [sw * 3, sw * 2.5] : []))
                if !it.label.isEmpty { label(c, it, fs: fs, u: u0, at: P, s: s) }
            case "pin":
                let r = fs * 0.42 * u0
                let at = P(it.c)
                if f.p > 0 {
                    let rr = r * (1.4 + 1.6 * f.p)
                    c.fill(Path(ellipseIn: CGRect(x: at.x - rr, y: at.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(color.opacity(0.35 * (1 - f.p))))
                }
                let rs = r * max(f.s, 0)
                let dot = Path(ellipseIn: CGRect(x: at.x - rs, y: at.y - rs, width: rs * 2, height: rs * 2))
                c.fill(dot, with: .color(color))
                c.stroke(dot, with: .color(s.background), lineWidth: sw)
                if !it.label.isEmpty { var tc = c; tc.opacity = f.o * f.d; label(tc, it, fs: fs, u: u0, at: P, s: s) }
            default:
                // A route traces itself on along a smooth curve through its stops.
                var path = Path()
                path.move(to: P(it.pts[0]))
                for (a, b, q) in ShapesModel.smooth(it.pts, closed: false) { path.addCurve(to: P(q), control1: P(a), control2: P(b)) }
                var rc = c
                if it.dash { rc.opacity = f.d } else { path = path.trimmedPath(from: 0, to: f.d) }
                rc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: sw * 1.6, lineCap: .round,
                                                                        dash: it.dash ? [sw * 3, sw * 3] : []))
                if it.arrow && f.d >= 0.98 {
                    let end = it.pts[it.pts.count - 1], before = it.pts[it.pts.count - 2]
                    let hy = hypot(end[0] - before[0], end[1] - before[1])
                    let len = hy == 0 ? 1 : hy
                    let ux = (end[0] - before[0]) / len, uy = (end[1] - before[1]) / len
                    let k = fs * 0.55 / zoom, sn = sin(0.5), cs = cos(0.5)
                    var head = Path()
                    head.move(to: P([end[0] - k * (ux * cs - uy * sn), end[1] - k * (uy * cs + ux * sn)]))
                    head.addLine(to: P(end))
                    head.addLine(to: P([end[0] - k * (ux * cs + uy * sn), end[1] - k * (uy * cs - ux * sn)]))
                    c.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: sw * 1.6, lineCap: .round, lineJoin: .round))
                }
                if !it.label.isEmpty { var tc = c; tc.opacity = f.d; label(tc, it, fs: fs * 0.92, u: u0, at: P, s: s) }
            }
        }
    }

    /// A label at its spot, with a soft halo in the paper color so it reads over land and lines.
    /// `u` sizes the text (full-size points per unit); `at` places it, zoom and pan included.
    private func label(_ ctx: GraphicsContext, _ it: MapModel.Item, fs: Double, u: CGFloat, at P: ([Double]) -> CGPoint, s: Swatch) {
        guard let x = it.lx, let y = it.ly else { return }
        let lines = MapModel.wrap(it.label, width: 30, fs: fs)
        let lh = fs * 1.15
        let y0 = y - Double(lines.count - 1) * lh / 2
        let anchor: UnitPoint = it.anchor == "start" ? .leading : it.anchor == "end" ? .trailing : .center
        let halo = max(0.5, 0.35 * u * fs / 3.4)
        for (k, l) in lines.enumerated() {
            let base = P([x, y])
            let at = CGPoint(x: base.x, y: base.y + (y0 - y + Double(k) * lh) * u)
            let back = ctx.resolve(Text(l).font(theme.font(fs * u, .heavy)).foregroundColor(s.background))
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
                ctx.draw(back, at: CGPoint(x: at.x + dx * halo, y: at.y + dy * halo), anchor: anchor)
            }
            ctx.draw(Text(l).font(theme.font(fs * u, .heavy)).foregroundColor(s.ink), at: at, anchor: anchor)
        }
    }
}

private func + (a: CGSize, b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }
