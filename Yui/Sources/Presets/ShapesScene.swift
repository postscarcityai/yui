import Foundation
import YuiLines

// Shapes that move (YUI-104; spec yuigui spec/YL.md "shapes"). The scene model
// behind `shapes` and `shape` lines: a line-for-line port of the hub's
// site/lib/yl/shapes.mjs, so the web and the phone draw the same diagram.
// YuiTests/ShapesSceneTests checks it against yuigui spec/shapes/scenes.json.
// Pure values, no SwiftUI: ShapesPreset draws what frame(at:) returns.

enum ShapesModel {
    static let closed: Set<String> = ["circle", "box", "pill", "dot", "blob", "text"]
    static let connectors: Set<String> = ["line", "arrow"]
    static let kinds: Set<String> = closed.union(connectors).union(["path"])
    static let tones: Set<String> = ["accent", "mint", "lavender", "butter", "ink", "mute"]

    /// Default sizes in canvas units, width and height.
    static let defaultSize: [String: [Double]] = ["circle": [2, 2], "box": [3, 2], "pill": [3, 1.2], "dot": [0.5, 0.5],
                                                  "blob": [2.6, 2.2], "text": [3, 0.9]]
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

    /// size=2 is 2 by 2 (a circle's diameter); size=3,2 is 3 wide, 2 tall.
    private static func size(_ v: YLValue?, _ kind: String) -> [Double]? {
        let d = defaultSize[kind] ?? defaultSize["box"]!
        guard let v else { return nil }
        if let one = num(v) { return ["pill", "box", "text"].contains(kind) ? [one, one * d[1] / d[0]] : [one, one] }
        return point(v)
    }

    private static func motion(_ p: [String: YLValue], _ kind: String) -> Motion {
        if truthy(p["draw"]) { return .draw }
        if truthy(p["grow"]) { return .grow }
        // Lines, arrows and paths trace themselves on unless told otherwise.
        if kind == "line" || kind == "arrow" || kind == "path" { return .draw }
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
            && !parts.contains { $0.kind == "path" || point($0.p["from"]) != nil || point($0.p["to"]) != nil }
        let H = clamp(num(head["h"]) ?? (onlyRow ? row.h + 1.4 * k : 6), 2, 16)
        var items: [Item] = []
        var t = 0.0
        for s in parts {
            let p = s.p, kind = s.kind
            let tn = text(p["tone"]) ?? ""
            var item = Item(i: s.i, id: s.id, kind: kind, label: text(p["label"]) ?? "",
                            tone: tones.contains(tn) ? tn : kind == "text" ? "ink" : "accent",
                            fill: truthy(p["fill"]) || kind == "dot", dash: truthy(p["dash"]),
                            motion: motion(p, kind), pulse: truthy(p["pulse"]), start: t)
            if s.closed {
                var at = point(p["at"])
                var sz = (size(p["size"], kind) ?? defaultSize[kind]!).map { $0 * k }
                if at == nil, let j = loose.firstIndex(where: { $0.i == s.i }) {
                    at = [row.places[j].x, H / 2]
                    sz = row.places[j].size
                }
                item.at = inside(at!, sz, W, H)
                item.size = sz
                if let mv = point(p["move"]) { item.move = inside(mv, sz, W, H) }
            } else if kind == "path" {
                let pts = (p["pts"]?.array ?? []).compactMap { point($0) }
                if pts.count < 2 { continue }
                item.pts = pts
            } else {
                // A connector: from= and to= are a shape's id or a point. With
                // neither, it joins the closed shape before it to the one after it.
                item.from = end(p["from"], p["at"], parts, s.i, -1)
                item.to = end(p["to"], nil, parts, s.i, 1)
                if item.from == nil || item.to == nil { continue }
            }
            item.dur = durations[item.motion]!
            items.append(item)
            t += step
        }
        let last = items.reduce(0.0) { max($0, $1.start + $1.dur + ($1.move != nil ? move : 0)) }
        return Scene(w: W, h: H, fs: label * W * k, title: text(head["title"]) ?? "",
                     caption: text(head["caption"]) ?? "", items: items, total: last)
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
            if let given = size(s.p["size"], s.kind) { sz = given }
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
            out[j].a = A.map { edge($0, toward: b0) } ?? a0
            out[j].b = B.map { edge($0, toward: a0) } ?? b0
        }
        return out
    }

    /// The point on a shape's outline on the way to `toward`, with a small gap.
    static func edge(_ f: Frame, toward: [Double]) -> [Double] {
        let c = f.c ?? [0, 0], sz = f.item.size ?? [0, 0]
        let dx = toward[0] - c[0], dy = toward[1] - c[1]
        let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let w = sz[0], h = sz[1]
        var r: Double
        if ["circle", "dot", "blob"].contains(f.item.kind) {
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
            } else if !it.label.isEmpty && !joined.contains(it.i) {
                bits.append(it.label)
                tail = nil
            }
        }
        return [sc.title, bits.joined(separator: ", "), sc.caption].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
