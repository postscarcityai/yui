import Foundation

// Decks that move (TestFlight feedback ANhbech_, AMt71OZy, AHdP_lC4, Oct 5: "a card in a card
// with a tiny little stupid drawing", "a shitty PowerPoint deck", "animated vector graphics...
// that tween, morph between slides"). A full deck is one stage: every page's `shapes` picture is
// turned into glyphs (outlines sampled as points), the glyphs of two pages are matched (an @id,
// else the same label, else the same family in line order), and `tween` draws the stage any share
// of the way between them, so a swipe scrubs the drawing from one page into the next. Pure values,
// no SwiftUI: MorphStage draws what `tween` returns. YuiTests/DeckMorphTests covers the matcher
// and the tween.

enum DeckMorph {
    /// Points round a closed outline, and along an open stroke (two strands make one ring, so a loop
    /// can fold into a line and back).
    static let ring = 72
    static let strand = 36
    /// The biggest a label gets on the stage, in points, however far the camera zooms in.
    static let maxFont = 30.0

    /// One thing drawn on a page, in its scene's units.
    struct Glyph: Equatable {
        /// The shape's own @id, when it was given one.
        var key: String?
        var kind: String
        var label: String
        var tone: String
        var fill = false
        var dash = false
        var pulse = false
        /// The outline is a loop (circle, box, blob, region, a closed path).
        var closed = false
        /// An arrowhead rides the end of the stroke.
        var head = false
        /// The outline or stroke; empty for a bare label (`text`).
        var pts: [[Double]] = []
        var center: [Double]
        var labelAt: [Double]
        var labelWidth: Double
        /// The label sits inside its shape (heavier type).
        var inside = false
        /// Stroke weight, a multiple of the page's line.
        var weight = 1.0

        /// What kind of thing it is, for matching shapes that have no name: a closed shape, a connector, a stroke.
        var family: Int { ShapesModel.connectors.contains(kind) ? 1 : closed || pts.isEmpty ? 0 : 2 }
    }

    struct Page: Equatable {
        var glyphs: [Glyph]
        /// What the drawing covers, x0, y0, x1, y1 in scene units: the camera frames this, not the empty canvas.
        var bounds: [Double]
        /// Label size and stroke width in scene units.
        var fs: Double
        var lw: Double
    }

    /// One glyph as drawn this frame, in points on the stage.
    struct Ink: Equatable {
        var pts: [[Double]]
        var closed: Bool
        var head: Double
        var fill: Double
        var dash: Bool
        var toneA: String
        var toneB: String
        /// 0 is toneA, 1 is toneB.
        var mix: Double
        var opacity: Double
        /// Share of the stroke drawn on.
        var trim: Double
        var label: String
        var labelOpacity: Double
        var labelAt: [Double]
        var labelWidth: Double
        var fs: Double
        var lw: Double
        var inside: Bool
        var center: [Double]
        var pulse: Bool
        var dot: Bool
    }

    /// Scene units to points: p * s + o.
    struct Camera: Equatable {
        var s: Double
        var o: [Double]
        func at(_ p: [Double]) -> [Double] { [p[0] * s + o[0], p[1] * s + o[1]] }
        static func mix(_ a: Camera, _ b: Camera, _ t: Double) -> Camera {
            Camera(s: lerp(a.s, b.s, t), o: [lerp(a.o[0], b.o[0], t), lerp(a.o[1], b.o[1], t)])
        }
    }

    // MARK: pages

    /// A `shapes` picture as glyphs; nil when it holds a part only the full drawing can draw
    /// (a Venn, contour rings, a tap, a picture under it): that page cross-fades instead.
    static func page(_ sc: ShapesModel.Scene) -> Page? {
        guard sc.img.isEmpty, !sc.items.isEmpty else { return nil }
        let frames = ShapesModel.frame(sc, at: .infinity)
        let fs = sc.fs, lw = 0.0075 * sc.w
        var out: [Glyph] = []
        for f in frames {
            let it = f.item
            if ["venn", "contour", "tap"].contains(it.kind) { return nil }
            var g = Glyph(key: explicit(it.id), kind: it.kind, label: it.label, tone: it.tone, fill: it.fill, dash: it.dash,
                          pulse: it.pulse, center: [0, 0], labelAt: [0, 0], labelWidth: ShapesModel.labelWidth(it, k: sc.k))
            if let mark = it.mark, let pts = it.pts {
                g.pts = resample(mark == "check" || (mark == "scribble" && it.fill) ? pts : densify(pts, closed: false), strand, closed: false)
                g.weight = 1.3
                g.fill = false
                g.center = mid(g.pts)
                g.labelAt = g.center
            } else if let a = f.a, let b = f.b, f.c == nil {
                var along: [[Double]]
                if it.kind == "bracket" {
                    along = ShapesModel.bracket(a, b, side: it.side ?? 1, depth: ShapesModel.tick * (lw / 0.075)).pts
                } else if let bend = it.bend {
                    let q = ShapesModel.control(a, b, bend)
                    along = (0...24).map { ShapesModel.bent(a, q, b, Double($0) / 24).p }
                } else {
                    along = [a, b]
                }
                if it.hand { along = ShapesModel.rough(along, seed: it.i, amp: ShapesModel.hand * sc.w, step: 0.35) }
                g.pts = resample(it.hand ? densify(along, closed: false) : along, strand, closed: false)
                g.head = it.kind == "arrow" || it.kind == "arc"
                g.fill = false
                let m = g.pts[g.pts.count / 2]
                g.center = m
                g.labelAt = [m[0], m[1] - fs * 0.75]
            } else if let pts = it.pts {
                switch it.kind {
                case "region":
                    g.closed = true
                    g.pts = loop(densify(pts, closed: true))
                    let r = ShapesModel.regionLabel(it, fs: fs)
                    g.labelAt = r.at
                    g.inside = true
                case "doodle":
                    g.pts = resample(densify(ShapesModel.doodle(pts, seed: it.i, w: sc.w), closed: false), strand, closed: false)
                    g.weight = 1.6
                    let top = pts.min { $0[1] < $1[1] } ?? pts[0]
                    g.labelAt = [top[0], top[1] - fs * 0.85]
                default:
                    let line = it.hand ? ShapesModel.rough(pts, seed: it.i, amp: ShapesModel.hand * sc.w, closed: it.close) : pts
                    let dense = it.sharp ? line + (it.close ? [line[0]] : []) : densify(line, closed: it.close)
                    if it.close { g.closed = true; g.pts = loop(dense) } else { g.pts = resample(dense, strand, closed: false) }
                    let m = pts[pts.count / 2]
                    g.labelAt = [m[0], m[1] - fs * 0.85]
                }
                g.center = mid(g.pts)
            } else if let c = f.c, let sz = it.size {
                g.center = c
                g.labelAt = c
                if it.kind == "text" {
                    g.pts = []
                } else {
                    g.closed = true
                    let rel = it.hand ? densify(ShapesModel.handOutline(it.kind, sz, seed: it.i, amp: ShapesModel.hand * sc.w), closed: true)
                                      : outline(it.kind, sz, seed: it.i)
                    g.pts = loop(rel.map { [$0[0] + c[0], $0[1] + c[1]] })
                    g.inside = it.kind != "dot"
                    if it.kind == "dot" {
                        g.fill = true
                        g.labelAt = [c[0], c[1] + sz[1] / 2 + fs * 0.85]
                    }
                }
                if it.leader, let a = f.a, let b = f.b {
                    // A callout's leader is a line of its own, so it can come and go with the box.
                    out.append(Glyph(key: g.key.map { $0 + ".leader" }, kind: "line", label: "", tone: it.tone, dash: it.dash,
                                     pts: resample([a, b], strand, closed: false), center: mid([a, b]), labelAt: b, labelWidth: 0))
                }
            } else {
                continue
            }
            out.append(g)
        }
        guard !out.isEmpty else { return nil }
        return Page(glyphs: out, bounds: bounds(out, fs: fs), fs: fs, lw: lw)
    }

    /// The id a person wrote (`shape@string`), not one the parser made up (n12, c3).
    static func explicit(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.range(of: #"^[nc]\d+$"#, options: .regularExpression) == nil else { return nil }
        return id
    }

    /// What the glyphs cover, labels included, with a little air round it.
    static func bounds(_ gs: [Glyph], fs: Double) -> [Double] {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        func take(_ p: [Double]) { x0 = min(x0, p[0]); y0 = min(y0, p[1]); x1 = max(x1, p[0]); y1 = max(y1, p[1]) }
        for g in gs {
            g.pts.forEach(take)
            if !g.label.isEmpty {
                let lines = ShapesModel.wrap(g.label, width: max(g.labelWidth, 1), fs: fs)
                let w = Double(lines.map(\.count).max() ?? 0) * ShapesModel.glyph * fs / 2
                let h = Double(lines.count) * ShapesModel.line * fs / 2
                take([g.labelAt[0] - w, g.labelAt[1] - h]); take([g.labelAt[0] + w, g.labelAt[1] + h])
            }
        }
        guard x0.isFinite else { return [0, 0, 1, 1] }
        let pad = fs * 0.8
        return [x0 - pad, y0 - pad, x1 + pad, y1 + pad]
    }

    /// The camera that frames a page's drawing in a `w` by `h` stage, as big as it fits, never so close
    /// that a label passes `maxFont` or a lone dot fills the screen.
    static func camera(_ p: Page, w: Double, h: Double) -> Camera {
        let b = p.bounds
        let bw = max(b[2] - b[0], 0.5), bh = max(b[3] - b[1], 0.5)
        var s = min(w / bw, h / bh)
        s = min(s, maxFont / max(p.fs, 1e-6), w / 3.2)
        return Camera(s: s, o: [w / 2 - (b[0] + b[2]) / 2 * s, h / 2 - (b[1] + b[3]) / 2 * s])
    }

    // MARK: matching

    struct Pair: Equatable { var a: Int?; var b: Int? }

    /// Which glyph on page a becomes which on page b: the same @id first, then the same label, then
    /// unlabelled glyphs of one family in line order. The rest leave (a only) or arrive (b only).
    /// Leaving glyphs come first so they draw under the page coming in.
    static func match(_ a: [Glyph], _ b: [Glyph]) -> [Pair] {
        var toA: [Int: Int] = [:]
        var usedA = Set<Int>()
        func link(_ i: Int, _ j: Int) { toA[j] = i; usedA.insert(i) }
        for (j, g) in b.enumerated() {
            guard let k = g.key, let i = a.indices.first(where: { !usedA.contains($0) && a[$0].key == k }) else { continue }
            link(i, j)
        }
        let norm = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for (j, g) in b.enumerated() where toA[j] == nil && !norm(g.label).isEmpty {
            // A named glyph never takes one that has a name of its own elsewhere on page b.
            if let i = a.indices.first(where: { !usedA.contains($0) && a[$0].key.map { k in !b.contains { $0.key == k } } ?? true
                && norm(a[$0].label) == norm(g.label) }) { link(i, j) }
        }
        for (j, g) in b.enumerated() where toA[j] == nil && g.label.isEmpty && g.key == nil {
            if let i = a.indices.first(where: { !usedA.contains($0) && a[$0].label.isEmpty && a[$0].key == nil && a[$0].family == g.family }) {
                link(i, j)
            }
        }
        var out = a.indices.filter { !usedA.contains($0) }.map { Pair(a: $0, b: nil) }
        out += b.indices.map { Pair(a: toA[$0], b: $0) }
        return out
    }

    // MARK: the tween

    /// The stage `t` of the way from page a to page b (either may be nil: nothing there), in points
    /// on a `w` by `h` stage. `still` is Reduce Motion: no shape moves, a cross-fade only.
    static func tween(_ a: Page?, _ b: Page?, t raw: Double, w: Double, h: Double, still: Bool = false) -> [Ink] {
        let t = clamp(raw, 0, 1)
        guard a != nil || b != nil else { return [] }
        let camA = camera(a ?? b!, w: w, h: h), camB = camera(b ?? a!, w: w, h: h)
        if still {
            let fade = (a.map { $0.glyphs.map { ink($0, camA, $0.label, 1 - t, page: a!) } } ?? [])
                + (b.map { $0.glyphs.map { ink($0, camB, $0.label, t, page: b!) } } ?? [])
            return fade.filter { $0.opacity > 0.001 }
        }
        let e = smooth(t)
        let cam = Camera.mix(camA, camB, e)
        let fsA = a?.fs ?? b!.fs, fsB = b?.fs ?? a!.fs, lwA = a?.lw ?? b!.lw, lwB = b?.lw ?? a!.lw
        let fs = lerp(fsA, fsB, e), lw = lerp(lwA, lwB, e)
        var out: [Ink] = []
        for p in match(a?.glyphs ?? [], b?.glyphs ?? []) {
            switch (p.a.map { a!.glyphs[$0] }, p.b.map { b!.glyphs[$0] }) {
            case let (ga?, gb?):
                var pa = ga.pts, pb = gb.pts
                if pa.isEmpty { pa = Array(repeating: ga.center, count: max(pb.count, 1)) }
                if pb.isEmpty { pb = Array(repeating: gb.center, count: max(pa.count, 1)) }
                if pa.count != pb.count || ga.closed != gb.closed {
                    pa = ga.closed || gb.closed ? asLoop(pa, closed: ga.closed) : resample(pa, strand, closed: false)
                    pb = ga.closed || gb.closed ? asLoop(pb, closed: gb.closed) : resample(pb, strand, closed: false)
                }
                let pts = zip(pa, pb).map { cam.at([lerp($0[0], $1[0], e), lerp($0[1], $1[1], e)]) }
                let center = cam.at(mixp(ga.center, gb.center, e))
                let label = retype(ga.label, gb.label, t)
                out.append(Ink(pts: ga.pts.isEmpty && gb.pts.isEmpty ? [] : pts, closed: e < 0.5 ? ga.closed : gb.closed,
                               head: lerp(ga.head ? 1 : 0, gb.head ? 1 : 0, e), fill: lerp(fillOf(ga), fillOf(gb), e),
                               dash: e < 0.5 ? ga.dash : gb.dash, toneA: ga.tone, toneB: gb.tone, mix: e, opacity: 1, trim: 1,
                               label: label.text, labelOpacity: label.opacity, labelAt: cam.at(mixp(ga.labelAt, gb.labelAt, e)),
                               labelWidth: lerp(ga.labelWidth, gb.labelWidth, e) * cam.s, fs: fs * cam.s,
                               lw: lw * cam.s * lerp(ga.weight, gb.weight, e), inside: e < 0.5 ? ga.inside : gb.inside,
                               center: center, pulse: e < 0.5 ? ga.pulse : gb.pulse, dot: (e < 0.5 ? ga.kind : gb.kind) == "dot"))
            case let (ga?, nil):
                // Leaving: it shrinks toward its own middle and dissolves in the first part of the swipe.
                let k = 1 - 0.3 * e
                var g = ga
                g.pts = ga.pts.map { [ga.center[0] + ($0[0] - ga.center[0]) * k, ga.center[1] + ($0[1] - ga.center[1]) * k] }
                var i = ink(g, cam, ga.label, clamp(1 - t * 1.8, 0, 1), page: a!)
                i.fs = fs * cam.s * k
                out.append(i)
            case let (nil, gb?):
                // Arriving: its outline draws on, its fill washes in, its label types itself out.
                let d = smooth(clamp((t - 0.15) / 0.85, 0, 1))
                var i = ink(gb, cam, gb.label, d > 0 ? 1 : 0, page: b!)
                i.trim = d
                i.fill *= d
                i.head *= d > 0.85 ? 1 : 0
                let n = gb.label.count
                let typed = Int((Double(n) * clamp((t - 0.35) / 0.6, 0, 1)).rounded(.up))
                i.label = String(gb.label.prefix(typed))
                i.labelOpacity = typed > 0 ? 1 : 0
                i.fs = fs * cam.s
                out.append(i)
            default:
                break
            }
        }
        return out
    }

    private static func ink(_ g: Glyph, _ cam: Camera, _ label: String, _ opacity: Double, page: Page) -> Ink {
        Ink(pts: g.pts.map(cam.at), closed: g.closed, head: g.head ? 1 : 0, fill: fillOf(g), dash: g.dash, toneA: g.tone,
            toneB: g.tone, mix: 0, opacity: opacity, trim: 1, label: label, labelOpacity: opacity, labelAt: cam.at(g.labelAt),
            labelWidth: g.labelWidth * cam.s, fs: page.fs * cam.s, lw: page.lw * cam.s * g.weight, inside: g.inside,
            center: cam.at(g.center), pulse: g.pulse, dot: g.kind == "dot")
    }

    private static func fillOf(_ g: Glyph) -> Double { g.kind == "dot" ? 1 : g.fill ? 0.18 : 0 }

    /// A label on its way from `a` to `b`: the old one backs out letter by letter, the new one types itself in.
    static func retype(_ a: String, _ b: String, _ t: Double) -> (text: String, opacity: Double) {
        if a == b { return (a, a.isEmpty ? 0 : 1) }
        if t < 0.5 {
            let n = Int((Double(a.count) * (1 - t * 2)).rounded(.up))
            return (String(a.prefix(n)), n > 0 ? 1 : 0)
        }
        let n = Int((Double(b.count) * (t * 2 - 1)).rounded(.up))
        return (String(b.prefix(n)), n > 0 ? 1 : 0)
    }

    // MARK: life

    /// A page at rest still breathes: the drawing floats a little, each shape swells and settles on its own
    /// beat, a +pulse shape beats harder, and a +pulse stroke ripples like a plucked string. `time` in seconds.
    static func alive(_ inks: [Ink], time: Double, amp: Double) -> [Ink] {
        let fx = sin(time * 0.43) * amp, fy = sin(time * 0.31 + 1.7) * amp * 0.8
        return inks.enumerated().map { k, i in
            var o = i
            let beat = (i.pulse ? 0.05 : 0.014) * sin(time * (i.pulse ? 3.9 : 1.1) + Double(k) * 1.37)
            let s = 1 + beat
            func move(_ p: [Double]) -> [Double] {
                [i.center[0] + (p[0] - i.center[0]) * s + fx, i.center[1] + (p[1] - i.center[1]) * s + fy]
            }
            if i.pulse, !i.closed, i.pts.count > 2 {
                // A standing wave along the stroke, its ends held.
                let n = Double(i.pts.count - 1)
                o.pts = i.pts.enumerated().map { j, p in
                    let prev = i.pts[max(0, j - 1)], next = i.pts[min(i.pts.count - 1, j + 1)]
                    let dx = next[0] - prev[0], dy = next[1] - prev[1]
                    let len = max(hypot(dx, dy), 1e-9)
                    let u = Double(j) / n
                    let wave = sin(u * .pi * 3 - time * 6) * sin(u * .pi) * amp * 2.2
                    return [p[0] - dy / len * wave + fx, p[1] + dx / len * wave + fy]
                }
            } else {
                o.pts = i.pts.map(move)
            }
            o.center = [i.center[0] + fx, i.center[1] + fy]
            o.labelAt = move(i.labelAt)
            o.fs = i.fs * (i.inside ? s : 1)
            return o
        }
    }

    // MARK: geometry

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private static func mixp(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { [lerp(a[0], b[0], t), lerp(a[1], b[1], t)] }

    static func mid(_ pts: [[Double]]) -> [Double] {
        guard !pts.isEmpty else { return [0, 0] }
        let x = pts.map { $0[0] }, y = pts.map { $0[1] }
        return [(x.min()! + x.max()!) / 2, (y.min()! + y.max()!) / 2]
    }

    /// A closed shape's outline round (0, 0): an ellipse, a rounded box or a stadium, or the blob.
    static func outline(_ kind: String, _ sz: [Double], seed: Int) -> [[Double]] {
        let x = sz[0] / 2, y = sz[1] / 2
        switch kind {
        case "circle", "dot":
            return (0..<ring).map { k in
                let a = 2 * Double.pi * Double(k) / Double(ring) - .pi / 2
                return [cos(a) * x, sin(a) * y]
            }
        case "blob":
            return densify(ShapesModel.blobPoints(sz[0], sz[1], seed: seed), closed: true)
        default:
            let r = kind == "pill" ? y : min(0.3, y / 2)
            let cx = max(0, x - r), cy = max(0, y - r)
            func arc(_ ox: Double, _ oy: Double, _ a0: Double) -> [[Double]] {
                (0...6).map { j in
                    let a = a0 + Double.pi / 2 * Double(j) / 6
                    return [ox + cos(a) * r, oy + sin(a) * r]
                }
            }
            // From the top middle, clockwise on screen.
            return [[0, -y]] + arc(cx, -cy, -.pi / 2) + arc(cx, cy, 0) + arc(-cx, cy, .pi / 2) + arc(-cx, -cy, .pi)
        }
    }

    /// Points through a Catmull-Rom curve, eight to a span.
    static func densify(_ pts: [[Double]], closed: Bool) -> [[Double]] {
        guard pts.count > 2 || (closed && pts.count > 1) else { return pts }
        var out = [pts[0]]
        var p0 = pts[0]
        for (c1, c2, p) in ShapesModel.smooth(pts, closed: closed) {
            for j in 1...8 {
                let t = Double(j) / 8, u = 1 - t
                out.append([u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p[0],
                            u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p[1]])
            }
            p0 = p
        }
        if closed { out.removeLast() }
        return out
    }

    /// `n` points evenly spaced along a polyline (round a loop when `closed`).
    static func resample(_ pts: [[Double]], _ n: Int, closed: Bool) -> [[Double]] {
        guard pts.count > 1, n > 1 else { return Array(repeating: pts.first ?? [0, 0], count: max(n, 1)) }
        let path = closed ? pts + [pts[0]] : pts
        var acc = [0.0]
        for k in 1..<path.count { acc.append(acc[k - 1] + hypot(path[k][0] - path[k - 1][0], path[k][1] - path[k - 1][1])) }
        let total = acc.last!
        guard total > 1e-9 else { return Array(repeating: pts[0], count: n) }
        var out: [[Double]] = []
        var seg = 1
        for k in 0..<n {
            let d = total * Double(k) / Double(closed ? n : n - 1)
            while seg < path.count - 1 && acc[seg] < d { seg += 1 }
            let span = max(acc[seg] - acc[seg - 1], 1e-9)
            let t = clamp((d - acc[seg - 1]) / span, 0, 1)
            out.append([lerp(path[seg - 1][0], path[seg][0], t), lerp(path[seg - 1][1], path[seg][1], t)])
        }
        return out
    }

    /// A loop of `ring` points, clockwise on screen, starting at its top: two loops line up point for
    /// point, so one can turn into the other without twisting.
    static func loop(_ pts: [[Double]]) -> [[Double]] {
        var p = resample(pts, ring, closed: true)
        var area = 0.0
        for k in p.indices { let q = p[(k + 1) % p.count]; area += p[k][0] * q[1] - q[0] * p[k][1] }
        if area < 0 { p.reverse() }
        let c = mid(p)
        let top = p.indices.max { a, b in
            let da = [p[a][0] - c[0], p[a][1] - c[1]], db = [p[b][0] - c[0], p[b][1] - c[1]]
            return -da[1] / max(hypot(da[0], da[1]), 1e-9) < -db[1] / max(hypot(db[0], db[1]), 1e-9)
        } ?? 0
        return Array(p[top...] + p[..<top])
    }

    /// Points as a loop of `ring`: a loop stays one, a stroke runs out and back, so it can open into a loop.
    static func asLoop(_ pts: [[Double]], closed: Bool) -> [[Double]] {
        if closed { return pts.count == ring ? pts : loop(pts) }
        let half = resample(pts, ring / 2, closed: false)
        return half + half.reversed()
    }
}
