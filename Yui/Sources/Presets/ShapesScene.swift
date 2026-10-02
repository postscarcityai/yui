import Foundation
import YuiLines

// Shapes that move (YUI-104; spec yuigui spec/YL.md "shapes"). The scene model
// behind `shapes` and `shape` lines: a line-for-line port of the hub's
// site/lib/yl/shapes.mjs, so the web and the phone draw the same diagram.
// YuiTests/ShapesSceneTests checks it against yuigui spec/shapes/scenes.json.
// Pure values, no SwiftUI: ShapesPreset draws what frame(at:) returns.

enum ShapesModel {
    static let closed: Set<String> = ["circle", "box", "pill", "dot", "blob", "text", "venn", "contour"]
    static let connectors: Set<String> = ["line", "arrow"]
    /// Kinds drawn through points: an open curve, a closed outline, a hand-drawn stroke (YUI-276).
    static let traced: Set<String> = ["path", "region", "doodle"]
    static let kinds: Set<String> = closed.union(connectors).union(traced)
    static let tones: Set<String> = ["accent", "mint", "lavender", "butter", "ink", "mute"]

    /// Default sizes in canvas units, width and height.
    static let defaultSize: [String: [Double]] = ["circle": [2, 2], "box": [3, 2], "pill": [3, 1.2], "dot": [0.5, 0.5],
                                                  "blob": [2.6, 2.2], "text": [3, 0.9],
                                                  "venn": [5.2, 3.2], "contour": [3.2, 2.4], "doodle": [2.4, 1.6]]
    /// A Venn of three sets is rounder than one of two.
    static let venn3: [Double] = [4.8, 4.56]
    /// Kinds whose height keeps their proportions when size= is one number.
    static let keeps: Set<String> = ["pill", "box", "text", "venn", "contour", "doodle"]
    /// Kinds that trace themselves on unless told otherwise.
    static let traces: Set<String> = ["line", "arrow", "path", "region", "doodle", "contour"]
    /// A Venn's circles take the shape's tone, then the next ones in this order.
    static let cycle = ["accent", "mint", "lavender", "butter"]
    // The clock, in seconds.
    static let step = 0.35
    static let durations: [Motion: Double] = [.fade: 0.35, .grow: 0.5, .draw: 0.7]
    static let move = 0.8
    static let pulse = 1.6
    /// Label size as a share of the drawing's width, so text reads the same at any w.
    static let label = 0.042
    /// How much of a closed shape's width its label may use.
    static let share: [String: Double] = ["circle": 0.78, "blob": 0.74, "box": 0.88, "pill": 0.8]
    static let rowMin = 0.7
    static let glyph = 0.56
    static let line = 1.15

    enum Motion: String { case fade, grow, draw }

    /// A connector end: a closed shape (by its place in the scene) or a point.
    enum End: Equatable { case ref(Int), pt([Double]) }

    struct Item: Equatable {
        var i: Int
        var id: String?
        var kind: String
        var label: String
        var tone: String
        var fill: Bool
        var dash: Bool
        var motion: Motion
        var pulse: Bool
        var start: Double
        var dur: Double = 0
        var at: [Double]? = nil
        var size: [Double]? = nil
        var move: [Double]? = nil
        var pts: [[Double]]? = nil
        var from: End? = nil
        var to: End? = nil
        /// A Venn's sets (at most three) and its pair overlaps' labels (YUI-276).
        var sets: [String]? = nil
        var pairs: [String]? = nil
        /// A contour's ring count, 2 to 8.
        var rings: Int? = nil
        /// A connector's bow: the share of its length its middle stands off, + to the left of the way it goes.
        var bend: Double? = nil
    }

    struct Scene: Equatable {
        var w: Double
        var h: Double
        /// Label font size in canvas units (a crowded row scales it down).
        var fs: Double
        var title: String
        var caption: String
        var items: [Item]
        var total: Double
        /// A picture under the drawing (`img=`), filling the canvas: marks over a screenshot or a photo (YUI-276).
        var img: String = ""
        var pulses: Bool { items.contains { $0.pulse } }
        /// The row scale: 1 unless a crowded auto row shrank.
        var k: Double { fs / (ShapesModel.label * w) }
    }

    /// One part `t` seconds in: opacity, scale, share of the outline drawn,
    /// centre now, and a connector's ends now (clipped to the outlines they touch).
    struct Frame: Equatable {
        var item: Item
        var o: Double = 1
        var s: Double = 1
        var d: Double = 1
        var c: [Double]? = nil
        var a: [Double]? = nil
        var b: [Double]? = nil
        /// A bent connector's control point: it runs a to b as a curve through q (YUI-276).
        var q: [Double]? = nil
    }

    // MARK: values as the JS model reads them

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    private static func num(_ v: YLValue?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil ? Double(t) : nil
        default: return nil
        }
    }

    /// JavaScript's String(v) for the values a parser can give.
    static func text(_ v: YLValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let n)?: return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b)?: return b ? "true" : "false"
        default: return nil
        }
    }

    private static func truthy(_ v: YLValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        default: return false
        }
    }

    /// "2,3" to [2, 3]; anything else is nil.
    static func point(_ v: YLValue?) -> [Double]? {
        guard let v, v != .null, v != .bool(true), let s = text(v) else { return nil }
        let parts = s.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = num(.string(parts[0])), let y = num(.string(parts[1])) else { return nil }
        return [x, y]
    }

    /// A list prop as the parser gives it (a list), or one written as a|b.
    private static func list(_ v: YLValue?) -> [String] {
        switch v {
        case .array(let a)?: return a.compactMap { text($0) }.filter { !$0.isEmpty }
        case nil, .null?, .bool(true)?: return []
        default:
            return (text(v) ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        }
    }

    /// A Venn's sets: at most three.
    private static func setsOf(_ p: [String: YLValue]) -> [String] { Array(list(p["sets"]).prefix(3)) }

    /// A kind's default size; a Venn's depends on how many sets it has.
    private static func sizeOf(_ kind: String, _ p: [String: YLValue]) -> [Double] {
        kind == "venn" && setsOf(p).count >= 3 ? venn3 : defaultSize[kind] ?? defaultSize["box"]!
    }

    /// size=2 is 2 by 2 (a circle's diameter); size=3,2 is 3 wide, 2 tall.
    private static func size(_ v: YLValue?, _ kind: String, _ p: [String: YLValue] = [:]) -> [Double]? {
        let d = sizeOf(kind, p)
        guard let v else { return nil }
        if let one = num(v) { return keeps.contains(kind) ? [one, one * d[1] / d[0]] : [one, one] }
        return point(v)
    }

    private static func motion(_ p: [String: YLValue], _ kind: String) -> Motion {
        if truthy(p["draw"]) { return .draw }
        if truthy(p["grow"]) { return .grow }
        // Lines, arrows, paths, regions, doodles and contours trace themselves on unless told otherwise.
        if traces.contains(kind) { return .draw }
        return .fade
    }

    private struct Part { let i: Int; let id: String?; let kind: String; let p: [String: YLValue]; let closed: Bool }

    // MARK: the scene

    /// `head`: the `shapes` props; `members`: (id, props) in line order. A lone
    /// `shape` is a one-member scene with an empty head.
    static func scene(head: [String: YLValue], members: [(id: String?, props: [String: YLValue])]) -> Scene {
        let W = clamp(num(head["w"]) ?? 10, 4, 24)
        let parts = members.enumerated().map { i, m -> Part in
            let raw = (text(m.props["kind"]) ?? "box").lowercased()
            let kind = kinds.contains(raw) ? raw : "box"
            return Part(i: i, id: m.id, kind: kind, p: m.props, closed: closed.contains(kind))
        }
        // Closed shapes with no at= share one row across the middle, in line
        // order, each sized to hold its label. A crowded row scales down as a
        // whole, labels too, never below rowMin.
        let loose = parts.filter { $0.closed && point($0.p["at"]) == nil }
        let joined = parts.contains { connectors.contains($0.kind) }
        let row = rowLayout(loose, W, label * W, joined, parts)
        let k = row.k
        let onlyRow = !loose.isEmpty && loose.count == parts.filter(\.closed).count
            && !parts.contains { traced.contains($0.kind) || point($0.p["from"]) != nil || point($0.p["to"]) != nil }
        let H = clamp(num(head["h"]) ?? (onlyRow ? row.h + 1.4 * k : 6), 2, 16)
        var items: [Item] = []
        var t = 0.0
        for s in parts {
            let p = s.p, kind = s.kind
            let tn = text(p["tone"]) ?? ""
            var item = Item(i: s.i, id: s.id, kind: kind, label: text(p["label"]) ?? "",
                            tone: tones.contains(tn) ? tn : kind == "text" ? "ink" : "accent",
                            fill: truthy(p["fill"]) || kind == "dot" || kind == "venn", dash: truthy(p["dash"]),
                            motion: motion(p, kind), pulse: truthy(p["pulse"]), start: t)
            if s.closed {
                var at = point(p["at"])
                var sz = (size(p["size"], kind, p) ?? sizeOf(kind, p)).map { $0 * k }
                if at == nil, let j = loose.firstIndex(where: { $0.i == s.i }) {
                    at = [row.places[j].x, H / 2]
                    sz = row.places[j].size
                }
                item.at = inside(at!, sz, W, H)
                item.size = sz
                if let mv = point(p["move"]) { item.move = inside(mv, sz, W, H) }
                if kind == "venn" {
                    item.sets = setsOf(p)
                    let pairs = Array(list(p["pairs"]).prefix(3))
                    if !pairs.isEmpty { item.pairs = pairs }
                }
                if kind == "contour" { item.rings = Int(clamp((num(p["rings"]) ?? 4).rounded(), 2, 8)) }
            } else if traced.contains(kind) {
                var pts = (p["pts"]?.array ?? []).compactMap { point($0) }
                // A doodle with no points but a place is a ring scribbled round it (YUI-276).
                if kind == "doodle", pts.count < 2, let at = point(p["at"]) {
                    let sz = (size(p["size"], kind) ?? defaultSize["doodle"]!).map { $0 * k }
                    pts = ring(inside(at, sz, W, H), sz, seed: s.i)
                }
                // A region is a closed outline, so it needs three points.
                if pts.count < (kind == "region" ? 3 : 2) { continue }
                item.pts = pts
            } else {
                // A connector: from= and to= are a shape's id or a point. With
                // neither, it joins the closed shape before it to the one after it.
                item.from = end(p["from"], p["at"], parts, s.i, -1)
                item.to = end(p["to"], nil, parts, s.i, 1)
                if item.from == nil || item.to == nil { continue }
                if let bend = num(p["bend"]), bend != 0 { item.bend = clamp(bend, -1, 1) }
            }
            item.dur = durations[item.motion]!
            items.append(item)
            t += step
        }
        let last = items.reduce(0.0) { max($0, $1.start + $1.dur + ($1.move != nil ? move : 0)) }
        return Scene(w: W, h: H, fs: label * W * k, title: text(head["title"]) ?? "",
                     caption: text(head["caption"]) ?? "", items: items, total: last, img: text(head["img"]) ?? "")
    }

    private static func rowLayout(_ loose: [Part], _ W: Double, _ fs: Double, _ joined: Bool, _ parts: [Part])
        -> (k: Double, h: Double, places: [(x: Double, size: [Double])]) {
        func count(_ s: String) -> Double { Double(s.utf16.count) }
        func wordW(_ label: String) -> Double {
            label.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { count(String($0)) * glyph * fs }.max() ?? 0
        }
        func lines(_ label: String, _ width: Double) -> Double { Double(wrap(label, width: width, fs: fs).count) }
        let own = loose.map { s -> (sz: [Double], span: Double) in
            let lab = text(s.p["label"]) ?? ""
            let widest = max(0, wordW(lab))
            var sz: [Double]
            if let given = size(s.p["size"], s.kind, s.p) { sz = given }
            else {
                switch s.kind {
                case "box":
                    let w = max(2.25, widest / share["box"]! + 0.3)
                    sz = [w, max(1.5, lines(lab, w * share["box"]!) * line * fs + 0.5)]
                case "pill":
                    let w = max(2.25, widest / share["pill"]! + 0.4)
                    sz = [w, max(0.9, lines(lab, w * share["pill"]!) * line * fs + 0.35)]
                case "circle":
                    var d = max(1.5, widest / share["circle"]! + 0.2)
                    d = max(d, lines(lab, d * share["circle"]!) * line * fs + 0.5)
                    sz = [d, d]
                case "blob":
                    let w = max(1.95, widest / share["blob"]! + 0.3)
                    sz = [w, max(w * 0.85, lines(lab, w * share["blob"]!) * line * fs + 0.6)]
                case "text":
                    let w = min(3.4, max(widest, count(lab) * glyph * fs))
                    sz = [max(w, 0.5), max(1, lines(lab, 3.4)) * line * fs]
                case "venn", "contour":
                    sz = sizeOf(s.kind, s.p)
                default:
                    sz = defaultSize["dot"]!
                }
            }
            // A dot's label hangs under it, so the dot takes the label's width in the row.
            let span = s.kind == "dot" ? max(sz[0], min(3.4, count(lab) * glyph * fs)) : sz[0]
            return (sz, span)
        }
        let margin = 0.2
        let gaps: [Double] = loose.indices.dropLast().map { j in
            let a = loose[j].i, b = loose[j + 1].i
            let between = parts[(a + 1)..<max(a + 1, b)].first { connectors.contains($0.kind) && truthy($0.p["label"]) }
            let tw = between.map { count(text($0.p["label"]) ?? "") * glyph * fs * 0.9 + 0.3 } ?? 0
            return max(joined ? 1 : 0.5, tw)
        }
        let need = own.reduce(0) { $0 + $1.span } + gaps.reduce(0, +) + 2 * margin
        let k = need > W ? max(rowMin, W / need) : 1
        var x = (W - (need - 2 * margin) * k) / 2
        var places: [(x: Double, size: [Double])] = []
        for (j, o) in own.enumerated() {
            let c = x + o.span * k / 2
            x += (o.span + (j < gaps.count ? gaps[j] : 0)) * k
            places.append((c, o.sz.map { $0 * k }))
        }
        return (k, places.map { $0.size[1] }.max() ?? 0, places)
    }

    /// Keeps a closed shape on the canvas: its centre moves in until the whole
    /// shape fits (a shape bigger than the canvas stays centred on that axis).
    private static func inside(_ p: [Double], _ s: [Double], _ W: Double, _ H: Double) -> [Double] {
        func fit(_ v: Double, _ half: Double, _ m: Double) -> Double { half * 2 >= m ? m / 2 : clamp(v, half, m - half) }
        return [fit(p[0], s[0] / 2, W), fit(p[1], s[1] / 2, H)]
    }

    private static func end(_ v: YLValue?, _ fallback: YLValue?, _ parts: [Part], _ i: Int, _ dir: Int) -> End? {
        if case .string(let name)? = v, let hit = parts.first(where: { $0.closed && $0.id == name }) { return .ref(hit.i) }
        if let pt = point(v) ?? point(fallback) { return .pt(pt) }
        if let v, v != .null { return nil } // named something that is not here
        var k = i + dir
        while k >= 0 && k < parts.count {
            if parts[k].closed { return .ref(parts[k].i) }
            k += dir
        }
        return nil
    }

    // MARK: the clock

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeBack(_ x: Double) -> Double { 1 + 2.2 * pow(x - 1, 3) + 1.2 * pow(x - 1, 2) }
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    /// Where every part is `t` seconds in; `.infinity` is the finished still.
    static func frame(_ sc: Scene, at t: Double) -> [Frame] {
        let still = !t.isFinite
        var now: [Int: Frame] = [:]
        var out: [Frame] = []
        for it in sc.items {
            let k = still ? 1 : clamp((t - it.start) / it.dur, 0, 1)
            var f = Frame(item: it)
            switch it.motion {
            case .fade: f.o = easeOut(k)
            case .grow: f.s = k <= 0 ? 0 : easeBack(k); f.o = k > 0 ? 1 : 0
            case .draw: f.d = easeOut(k); f.o = k > 0 ? 1 : 0
            }
            if var c = it.at {
                if let mv = it.move {
                    let m = still ? 1 : clamp((t - it.start - it.dur) / move, 0, 1)
                    let e = easeInOut(m)
                    c = [c[0] + (mv[0] - c[0]) * e, c[1] + (mv[1] - c[1]) * e]
                }
                f.c = c
                if it.pulse && !still && t > it.start + it.dur {
                    f.s *= 1 + 0.06 * sin(2 * .pi * (t - it.start - it.dur) / pulse)
                }
                now[it.i] = f
            }
            out.append(f)
        }
        for j in out.indices {
            guard let from = out[j].item.from, let to = out[j].item.to else { continue }
            let A: Frame? = if case .ref(let r) = from { now[r] } else { nil }
            let B: Frame? = if case .ref(let r) = to { now[r] } else { nil }
            let a0 = A?.c ?? { if case .pt(let p) = from { p } else { [0, 0] } }()
            let b0 = B?.c ?? { if case .pt(let p) = to { p } else { [0, 0] } }()
            if let bend = out[j].item.bend {
                // A curve through q, its control point: its middle stands off bend times its length (YUI-276).
                let dx = b0[0] - a0[0], dy = b0[1] - a0[1]
                let q = [(a0[0] + b0[0]) / 2 + 2 * bend * dy, (a0[1] + b0[1]) / 2 - 2 * bend * dx]
                out[j].q = q
                out[j].a = A.map { edge($0, toward: q) } ?? a0
                out[j].b = B.map { edge($0, toward: q) } ?? b0
            } else {
                out[j].a = A.map { edge($0, toward: b0) } ?? a0
                out[j].b = B.map { edge($0, toward: a0) } ?? b0
            }
        }
        return out
    }

    /// A point on a curved connector, `t` from 0 (a) to 1 (b), and the way it heads there.
    static func bent(_ a: [Double], _ q: [Double], _ b: [Double], _ t: Double) -> (p: [Double], dir: [Double]) {
        let u = 1 - t
        return ([u * u * a[0] + 2 * u * t * q[0] + t * t * b[0], u * u * a[1] + 2 * u * t * q[1] + t * t * b[1]],
                [2 * u * (q[0] - a[0]) + 2 * t * (b[0] - q[0]), 2 * u * (q[1] - a[1]) + 2 * t * (b[1] - q[1])])
    }

    /// The point on a shape's outline on the way to `toward`, with a small gap.
    static func edge(_ f: Frame, toward: [Double]) -> [Double] {
        let c = f.c ?? [0, 0], sz = f.item.size ?? [0, 0]
        let dx = toward[0] - c[0], dy = toward[1] - c[1]
        let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let w = sz[0], h = sz[1]
        var r: Double
        if ["circle", "dot", "blob", "venn", "contour"].contains(f.item.kind) {
            let a = w / 2, b = h / 2
            r = a * b / hypot(b * ux, a * uy)
        } else {
            let rx = abs(ux) > 1e-9 ? w / 2 / abs(ux) : .infinity
            let ry = abs(uy) > 1e-9 ? h / 2 / abs(uy) : .infinity
            r = min(rx, ry)
        }
        r = min(r + 0.15, len)
        return [c[0] + ux * r, c[1] + uy * r]
    }

    // MARK: outlines and labels

    /// A blob: a closed, organic outline around (0, 0) for a w by h box, seeded by
    /// the shape's place in the scene so the same line always draws the same blob.
    static func blobPoints(_ w: Double, _ h: Double, seed: Int) -> [[Double]] {
        let n = 7
        return (0..<n).map { k in
            let ang = 2 * Double.pi * Double(k) / Double(n) - .pi / 2
            let r = 1 + 0.13 * sin(Double(seed + 1) * 12.9898 + Double(k) * 78.233)
            return [cos(ang) * (w / 2) * r * 0.94, sin(ang) * (h / 2) * r * 0.94]
        }
    }

    /// A doodle ring (YUI-276): a loop scribbled round `c` for a w by h box, a little more than one
    /// turn so its ends overlap, as guide points for `doodle`.
    static func ring(_ c: [Double], _ sz: [Double], seed: Int) -> [[Double]] {
        let n = 10, turn = 2 * Double.pi * 1.12, a0 = -Double.pi * 0.62
        return (0..<n).map { k in
            let t = Double(k) / Double(n - 1)
            let r = (0.96 + 0.1 * t) * (1 + 0.05 * sin(Double(seed + 1) * 12.9898 + Double(k) * 78.233))
            return [c[0] + cos(a0 + turn * t) * (sz[0] / 2) * r, c[1] + sin(a0 + turn * t) * (sz[1] / 2) * r]
        }
    }

    /// A hand-drawn stroke through guide points (YUI-276): the smooth curve sampled about every
    /// 0.035 w, each inner sample nudged off the line by up to 0.007 w (w the canvas width), seeded so
    /// the same line wobbles the same way. Join the result with `smooth(_, closed: false)`.
    static func doodle(_ pts: [[Double]], seed: Int, w: Double) -> [[Double]] {
        guard pts.count >= 2 else { return pts }
        let gap = 0.035 * w, amp = 0.007 * w
        var q: [[Double]] = [pts[0]]
        for (k, seg) in smooth(pts, closed: false).enumerated() {
            let (c1, c2, p3) = seg
            let p0 = pts[k]
            let m = max(2, Int((hypot(p3[0] - p0[0], p3[1] - p0[1]) / gap).rounded(.up)))
            for j in 1...m {
                let t = Double(j) / Double(m), u = 1 - t
                let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
                q.append([b0 * p0[0] + b1 * c1[0] + b2 * c2[0] + b3 * p3[0],
                          b0 * p0[1] + b1 * c1[1] + b2 * c2[1] + b3 * p3[1]])
            }
        }
        return q.indices.map { j in
            if j == 0 || j == q.count - 1 { return q[j] }
            let tx = q[j + 1][0] - q[j - 1][0], ty = q[j + 1][1] - q[j - 1][1]
            let len = hypot(tx, ty) == 0 ? 1 : hypot(tx, ty)
            let off = amp * sin(Double(seed + 1) * 12.9898 + Double(j) * 78.233)
            return [q[j][0] - ty / len * off, q[j][1] + tx / len * off]
        }
    }

    /// A Venn's circle radius for its box: two sets side by side, three in a triangle.
    static func vennRadius(_ it: Item, s: Double = 1) -> Double {
        let w = (it.size?[0] ?? 0) * s, h = (it.size?[1] ?? 0) * s
        return (it.sets ?? []).count >= 3 ? min(w / 3.2, h / 3.0392) : min(w / 3.2, h / 2)
    }

    struct VennCircle: Equatable { var c: [Double]; var r: Double; var tone: String }
    struct VennLabel: Equatable { var at: [Double]; var text: String; var width: Double; var middle = false }

    /// A Venn centred on `c` (YUI-276): its circles, each with a tone (the shape's own, then on through
    /// `cycle`), and its labels with the width each may wrap to. Two circles when it has fewer than three sets.
    static func venn(_ it: Item, center c: [Double], s: Double = 1) -> (circles: [VennCircle], labels: [VennLabel]) {
        let sets = it.sets ?? []
        let r = vennRadius(it, s: s)
        let three = sets.count >= 3
        let y = 0.5196 * r
        let at: [[Double]] = three ? [[-0.6 * r, -y], [0.6 * r, -y], [0, y]] : [[-0.6 * r, 0], [0.6 * r, 0]]
        let start = cycle.firstIndex(of: it.tone)
        let circles = at.enumerated().map { k, p in
            VennCircle(c: [c[0] + p[0], c[1] + p[1]], r: r, tone: start.map { cycle[($0 + k) % cycle.count] } ?? it.tone)
        }
        // The middle of the three centres, where every set overlaps.
        let g: [Double] = three ? [0, -y / 3] : [0, 0]
        func away(_ p: [Double], _ by: Double) -> [Double] {
            let dx = p[0] - g[0], dy = p[1] - g[1]
            let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
            return [c[0] + p[0] + dx / len * by, c[1] + p[1] + dy / len * by]
        }
        var labels: [VennLabel] = []
        for (k, p) in at.enumerated() where k < sets.count && !sets[k].isEmpty {
            labels.append(three ? VennLabel(at: away(p, 0.45 * r), text: sets[k], width: 0.8 * r)
                                : VennLabel(at: [c[0] + (k == 0 ? -1 : 1) * r, c[1]], text: sets[k], width: r))
        }
        if !it.label.isEmpty {
            labels.append(VennLabel(at: [c[0] + g[0], c[1] + g[1]], text: it.label, width: r * (three ? 0.5 : 0.7), middle: true))
        }
        if three {
            let pairs = it.pairs ?? []
            for (k, ij) in [(0, 1), (0, 2), (1, 2)].enumerated() where k < pairs.count && !pairs[k].isEmpty {
                let m = [(at[ij.0][0] + at[ij.1][0]) / 2, (at[ij.0][1] + at[ij.1][1]) / 2]
                labels.append(VennLabel(at: away(m, 0.35 * r), text: pairs[k], width: 0.55 * r))
            }
        }
        return (circles, labels)
    }

    /// A contour's rings round `c` (YUI-276), outermost first: one outline scaled in steps, each
    /// step's middle drifting toward the peak, where the label goes.
    static func contour(_ it: Item, center c: [Double], s: Double = 1) -> (rings: [[[Double]]], peak: [Double]) {
        let n = it.rings ?? 4
        let w = (it.size?[0] ?? 0) * s, h = (it.size?[1] ?? 0) * s
        let dx = 0.08 * w * sin(Double(it.i + 1) * 3.1), dy = -0.07 * h * abs(cos(Double(it.i + 1) * 3.1))
        let rings = (0..<n).map { k -> [[Double]] in
            let f = Double(n - k) / Double(n), m = Double(k) / Double(n)
            return blobPoints(w * f, h * f, seed: it.i).map { [$0[0] + c[0] + dx * m, $0[1] + c[1] + dy * m] }
        }
        return (rings, [c[0] + dx * Double(n - 1) / Double(n), c[1] + dy * Double(n - 1) / Double(n)])
    }

    /// Catmull-Rom through points, as cubic Bezier segments (c1, c2, p).
    static func smooth(_ pts: [[Double]], closed: Bool) -> [([Double], [Double], [Double])] {
        let n = pts.count
        func at(_ k: Int) -> [Double] { closed ? pts[((k % n) + n) % n] : pts[Int(clamp(Double(k), 0, Double(n - 1)))] }
        return (0..<(closed ? n : n - 1)).map { k in
            let p0 = at(k - 1), p1 = at(k), p2 = at(k + 1), p3 = at(k + 2)
            return ([p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6],
                    [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6], p2)
        }
    }

    /// A label as lines that fit `width` at font size `fs`: words wrap at spaces, at
    /// most three lines; a word longer than the width stays whole.
    static func wrap(_ label: String, width: Double, fs: Double) -> [String] {
        let words = label.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let most = max(1, Int((width / (fs * glyph)).rounded(.down)))
        var out: [String] = []
        for w in words {
            if let last = out.last, (last + " " + w).utf16.count <= most { out[out.count - 1] = last + " " + w } else { out.append(w) }
        }
        if out.count > 3 { out = Array(out[..<2]) + [out[2...].joined(separator: " ")] }
        return out
    }

    /// How wide a part's label may run before it wraps, in canvas units.
    static func labelWidth(_ it: Item, k: Double = 1) -> Double {
        let w = it.size?[0] ?? 0
        if let s = share[it.kind] { return w * s }
        // A Venn's label sits where every set overlaps; a contour's on its peak (YUI-276).
        if it.kind == "venn", it.size != nil { return vennRadius(it) * ((it.sets ?? []).count >= 3 ? 0.5 : 0.7) }
        if it.kind == "contour", it.size != nil { return w * 0.5 }
        if it.kind == "text", it.size != nil { return max(w, 1) }
        return 3.4 * k
    }

    /// Plain text of a drawing, for VoiceOver: the title, the labels in line order
    /// with connectors as arrows between their ends (A → B → C when they chain), the caption.
    static func describe(_ sc: Scene) -> String {
        func name(_ e: End?) -> String? {
            guard case .ref(let r)? = e, let it = sc.items.first(where: { $0.i == r }) else { return nil }
            return it.label.isEmpty ? it.kind : it.label
        }
        var joined = Set<Int>()
        for it in sc.items where it.from != nil && name(it.from) != nil && name(it.to) != nil {
            if case .ref(let a)? = it.from { joined.insert(a) }
            if case .ref(let b)? = it.to { joined.insert(b) }
        }
        var bits: [String] = []
        var tail: Int? = nil
        for it in sc.items {
            if it.from != nil {
                guard let a = name(it.from), let b = name(it.to) else {
                    if !it.label.isEmpty { bits.append(it.label) }
                    tail = nil
                    continue
                }
                let sign = (it.kind == "arrow" ? " → " : " – ") + b + (it.label.isEmpty ? "" : " (\(it.label))")
                if case .ref(let f)? = it.from, let tl = tail, tl == f, !bits.isEmpty { bits[bits.count - 1] += sign }
                else { bits.append(a + sign) }
                if case .ref(let t)? = it.to { tail = t }
            } else if it.kind == "venn", let s = it.sets, !s.isEmpty, !joined.contains(it.i) {
                // "Chat and Drawing overlap: Yui" (YUI-276).
                let names = s.count > 1 ? s.dropLast().joined(separator: ", ") + " and " + s[s.count - 1] + " overlap" : s[0]
                bits.append(names + (it.label.isEmpty ? "" : ": \(it.label)"))
                tail = nil
            } else if !it.label.isEmpty && !joined.contains(it.i) {
                bits.append(it.label)
                tail = nil
            }
        }
        return [sc.title, bits.joined(separator: ", "), sc.caption].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
