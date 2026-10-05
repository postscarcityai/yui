import Foundation
import YuiLines

// Shapes that move (YUI-104; spec yuigui spec/YL.md "shapes"). The scene model
// behind `shapes` and `shape` lines: a line-for-line port of the hub's
// site/lib/yl/shapes.mjs, so the web and the phone draw the same diagram.
// YuiTests/ShapesSceneTests checks it against yuigui spec/shapes/scenes.json.
// Pure values, no SwiftUI: ShapesPreset draws what frame(at:) returns.

enum ShapesModel {
    static let closed: Set<String> = ["circle", "box", "pill", "dot", "blob", "text", "venn", "contour", "tap", "callout"]
    /// `arc` is an arrow that bends; `bracket` spans two places with a label beyond it (YUI-297).
    static let connectors: Set<String> = ["line", "arrow", "swipe", "arc", "bracket"]
    /// Kinds drawn through points: an open curve, a closed outline, a hand-drawn stroke (YUI-276).
    static let traced: Set<String> = ["path", "region", "doodle"]
    /// Marks (YUI-299) are drawn on top of the picture, hand drawn and animated on: a scribble fills or rings
    /// a spot, an underline sits under a shape, a check is a tick.
    static let marks: Set<String> = ["scribble", "underline", "check"]
    static let kinds: Set<String> = closed.union(connectors).union(traced).union(marks)
    /// The kinds +hand roughens: closed outlines, lines, arrows, arcs and paths (the hub's list).
    static let handed: Set<String> = ["circle", "box", "pill", "blob", "line", "arrow", "arc", "path"]
    static let tones: Set<String> = ["accent", "mint", "lavender", "butter", "ink", "mute"]

    /// Default sizes in canvas units, width and height.
    static let defaultSize: [String: [Double]] = ["circle": [2, 2], "box": [3, 2], "pill": [3, 1.2], "dot": [0.5, 0.5],
                                                  "blob": [2.6, 2.2], "text": [3, 0.9],
                                                  "venn": [5.2, 3.2], "contour": [3.2, 2.4], "doodle": [2.4, 1.6], "tap": [0.9, 0.9], "callout": [2.6, 1]]
    /// Short labels the new kinds draw are capped: at most three words and 18 characters, whole words
    /// while they fit, then "…" (YUI-276).
    static let capWords = 3, capChars = 18
    static let capped: Set<String> = ["venn", "contour", "region", "doodle", "tap", "swipe"]
    /// A swipe with dir= and no to= runs this far that way.
    static let swipe = 3.0
    static let dirs: [String: [Double]] = ["left": [-1, 0], "right": [1, 0], "up": [0, -1], "down": [0, 1]]
    /// How far an arc bends by default (a share of its length, the side is the sign), and how deep a bracket's ticks run (YUI-297).
    static let bendDefault = 0.35
    static let tick = 0.3
    /// A Venn of three sets is rounder than one of two.
    static let venn3: [Double] = [4.8, 4.56]
    /// Kinds whose height keeps their proportions when size= is one number.
    static let keeps: Set<String> = ["pill", "box", "text", "venn", "contour", "doodle", "callout"]
    /// Kinds that trace themselves on unless told otherwise.
    static let traces: Set<String> = ["line", "arrow", "path", "region", "doodle", "contour", "swipe", "arc", "bracket"]
    /// A Venn's circles take the shape's tone, then the next ones in this order.
    static let cycle = ["accent", "mint", "lavender", "butter"]
    // The clock, in seconds.
    static let step = 0.35
    static let durations: [Motion: Double] = [.fade: 0.35, .grow: 0.5, .draw: 0.7]
    /// A mark draws on in half a second.
    static let markDur = 0.5
    /// The hand: how far a hand drawn stroke strays from its true line, as a share of the drawing's
    /// width, and how far apart its wobble points sit (canvas units).
    static let hand = 0.009
    static let handStep = 0.35
    static let move = 0.8
    static let pulse = 1.6
    /// Label size as a share of the drawing's width, so text reads the same at any w.
    static let label = 0.042
    /// How much of a closed shape's width its label may use.
    static let share: [String: Double] = ["circle": 0.78, "blob": 0.74, "box": 0.88, "pill": 0.8, "callout": 0.88]
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
        /// A bracket's side: 1 puts the ticks up when it runs left to right, -1 the other way (YUI-297).
        var side: Double? = nil
        /// A callout's leader: the line from its box to where `to=` points (YUI-297).
        var leader = false
        /// +hand: a seeded roughened stroke (YUI-299).
        var hand = false
        /// A mark's kind (scribble, underline, check); its `pts` are already roughened (YUI-299).
        var mark: String? = nil
        /// A path's +close (a zone, washed when it says +fill) and +sharp (straight sides, no curve) (YUI-302).
        var close = false
        var sharp = false
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
        if traces.contains(kind) || marks.contains(kind) { return .draw }
        // A tap lands: it springs up.
        if kind == "tap" { return .grow }
        return .fade
    }

    /// A drawing over a picture with no h= of its own takes the picture's shape once it is known (YUI-276).
    static func pictureShaped(_ head: [String: YLValue]) -> Bool { truthy(head["img"]) && num(head["h"]) == nil }

    private struct Part { let i: Int; let id: String?; let kind: String; let p: [String: YLValue]; let closed: Bool }

    // MARK: the scene

    /// `head`: the `shapes` props; `members`: (id, props) in line order. A lone
    /// `shape` is a one-member scene with an empty head. `ratio`: the picture's width over its height once
    /// it has loaded, so a drawing with img= and no h= takes the picture's shape. `free`: no cap on h, for
    /// marks over a mock (`marksOver`). Both YUI-276.
    static func scene(head: [String: YLValue], members: [(id: String?, props: [String: YLValue])],
                      ratio: Double? = nil, free: Bool = false) -> Scene {
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
        let pictured: Double? = if pictureShaped(head), let ratio, ratio > 0 { W / ratio } else { nil }
        let hRaw = num(head["h"]) ?? pictured ?? (onlyRow ? row.h + 1.4 * k : 6)
        let H = free ? max(2, hRaw) : clamp(hRaw, 2, 16)
        var items: [Item] = []
        var t = 0.0
        for s in parts {
            let p = s.p, kind = s.kind
            let tn = text(p["tone"]) ?? ""
            let said = text(p["label"]) ?? ""
            var item = Item(i: s.i, id: s.id, kind: kind, label: capped.contains(kind) && !said.isEmpty ? cap(said) : said,
                            tone: tones.contains(tn) ? tn : kind == "text" ? "ink" : "accent",
                            fill: truthy(p["fill"]) || kind == "dot" || kind == "venn", dash: truthy(p["dash"]),
                            motion: motion(p, kind), pulse: truthy(p["pulse"]), start: t)
            // +hand: a seeded roughened stroke (the seed is the part's place in the scene).
            if truthy(p["hand"]), handed.contains(kind) { item.hand = true }
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
                    item.sets = setsOf(p).map(cap)
                    let pairs = Array(list(p["pairs"]).prefix(3)).map(cap)
                    if !pairs.isEmpty { item.pairs = pairs }
                }
                if kind == "contour" { item.rings = Int(clamp((num(p["rings"]) ?? 4).rounded(), 2, 8)) }
                // A callout points at where `to=` says: a shape's id or a point (YUI-297).
                if kind == "callout", p["to"] != nil, p["to"] != .bool(true), let to = end(p["to"], nil, parts, s.i, 1) {
                    item.from = .ref(s.i); item.to = to; item.leader = true
                }
            } else if marks.contains(kind) {
                // A mark sits on a shape written before it (to=id) or at a place (at=).
                guard let pts = markPoints(kind, p, items, parts, W, s.i) else { continue }
                item.mark = kind
                item.pts = pts
                item.tone = tones.contains(tn) ? tn : kind == "check" ? "mint" : "accent"
                item.fill = kind == "scribble" && truthy(p["fill"])
                item.motion = .draw
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
                // +close joins the last point back to the first; +sharp keeps straight sides (the hub's path).
                if kind == "path" {
                    if truthy(p["close"]), pts.count >= 3 { item.close = true; item.fill = truthy(p["fill"]) }
                    item.sharp = truthy(p["sharp"])
                }
            } else {
                // A connector: from= and to= are a shape's id or a point. With
                // neither, it joins the closed shape before it to the one after it.
                item.from = end(p["from"], p["at"], parts, s.i, -1)
                // A swipe with dir= and no to= runs `swipe` that way from where it starts (YUI-276).
                if kind == "swipe", p["to"] == nil, let d = dirs[text(p["dir"]) ?? ""], let a = point(p["from"]) ?? point(p["at"]) {
                    item.to = .pt([a[0] + swipe * d[0], a[1] + swipe * d[1]])
                } else {
                    item.to = end(p["to"], nil, parts, s.i, 1)
                }
                if item.from == nil || item.to == nil { continue }
                if kind == "bracket" { item.side = (num(p["bend"]) ?? 1) < 0 ? -1 : 1 }
                else if kind == "arc" || p["bend"] != nil { item.bend = clamp(num(p["bend"]) ?? bendDefault, -2, 2) }
            }
            item.dur = item.mark != nil ? markDur : durations[item.motion]!
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
                case "box", "callout":
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
                case "venn", "contour", "tap":
                    sz = sizeOf(s.kind, s.p)
                default:
                    sz = defaultSize["dot"]!
                }
            }
            // A dot's label hangs under it, so the dot takes the label's width in the row.
            let span = s.kind == "dot" || s.kind == "tap" ? max(sz[0], min(3.4, count(lab) * glyph * fs)) : sz[0]
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

    /// A bent connector's control point: its middle stands off `bend` times its length, + to the left of the way it goes.
    static func control(_ a: [Double], _ b: [Double], _ bend: Double) -> [Double] {
        let dx = b[0] - a[0], dy = b[1] - a[1]
        return [(a[0] + b[0]) / 2 + 2 * bend * dy, (a[1] + b[1]) / 2 - 2 * bend * dx]
    }

    /// A bracket from a to b: tick, spine, tick, the ticks to `side` (1: up when a to b runs left to right).
    /// The corner points, and the unit direction the ticks point so the label can sit on the other side.
    static func bracket(_ a: [Double], _ b: [Double], side: Double, depth: Double) -> (pts: [[Double]], n: [Double]) {
        let dx = b[0] - a[0], dy = b[1] - a[1]
        let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
        let n = [dy / len * side, -dx / len * side]
        return ([[a[0] + n[0] * depth, a[1] + n[1] * depth], a, b, [b[0] + n[0] * depth, b[1] + n[1] * depth]], n)
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
        if ["circle", "dot", "blob", "venn", "contour", "tap"].contains(f.item.kind) {
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

    // MARK: the hand (YUI-299)

    /// A smooth noise in [-1, 1] along a stroke, so a line drifts like a hand instead of buzzing; the same
    /// seed gives the same stroke on every renderer.
    static func wobble(_ seed: Int, _ k: Int) -> Double {
        0.6 * sin(Double(seed + 1) * 12.9898 + Double(k) * 0.9) + 0.4 * sin(Double(seed + 1) * 78.233 + Double(k) * 2.1)
    }

    private static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// A polyline roughened: every segment is cut into steps of about `step` and each point is pushed `amp`
    /// times wobble sideways. Open strokes end where they started (the last point is pushed too); closed ones
    /// join up. step `.infinity` keeps the points you gave it.
    static func rough(_ pts: [[Double]], seed: Int, amp: Double, closed: Bool = false, step: Double = handStep) -> [[Double]] {
        var out: [[Double]] = []
        let n = pts.count
        let segs = closed ? n : n - 1
        var k = 0
        for s in 0..<max(0, segs) {
            let a = pts[s], b = pts[(s + 1) % n]
            let dx = b[0] - a[0], dy = b[1] - a[1]
            let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
            let m = step.isFinite ? max(1, Int((len / step).rounded(.up))) : 1
            for j in 0..<m {
                let t = Double(j) / Double(m), o = amp * wobble(seed, k)
                k += 1
                out.append([r3(a[0] + dx * t - dy / len * o), r3(a[1] + dy * t + dx / len * o)])
            }
        }
        if !closed {
            let a = n >= 2 ? pts[n - 2] : pts[0], b = pts[n - 1]
            let len = hypot(b[0] - a[0], b[1] - a[1]) == 0 ? 1 : hypot(b[0] - a[0], b[1] - a[1])
            let o = amp * wobble(seed, k)
            out.append([r3(b[0] - (b[1] - a[1]) / len * o), r3(b[1] + (b[0] - a[0]) / len * o)])
        }
        return out
    }

    /// A closed shape's true outline as points around (0, 0), roughened: a circle as an ellipse, a box and
    /// a pill as their rectangle and stadium. Join with `smooth(_, closed: true)`.
    static func handOutline(_ kind: String, _ sz: [Double], seed: Int, amp: Double) -> [[Double]] {
        let w = sz[0], h = sz[1]
        let x = w / 2, y = h / 2
        switch kind {
        case "blob":
            return rough(blobPoints(w, h, seed: seed), seed: seed, amp: amp, closed: true, step: .infinity)
        case "circle":
            let n = 20
            return rough((0..<n).map { j in
                let a = 2 * Double.pi * Double(j) / Double(n) - .pi / 2
                return [cos(a) * x, sin(a) * y]
            }, seed: seed, amp: amp, closed: true, step: .infinity)
        case "pill":
            let r = y, cx = max(0, x - r)
            func arc(_ c: Double, _ a0: Double) -> [[Double]] {
                (0..<7).map { j in [c + cos(a0 + Double.pi * Double(j) / 6) * r, sin(a0 + Double.pi * Double(j) / 6) * r] }
            }
            return rough(arc(cx, -.pi / 2) + arc(-cx, .pi / 2), seed: seed, amp: amp, closed: true)
        default:
            return rough([[-x, -y], [x, -y], [x, y], [-x, y]], seed: seed, amp: amp, closed: true)
        }
    }

    /// A mark's points in canvas units, already roughened (the numbers are in spec/shapes/scenes.json).
    /// `to=` names a closed shape written before it; with no to=, at= (and size=) place it.
    private static func markPoints(_ kind: String, _ p: [String: YLValue], _ items: [Item], _ parts: [Part],
                                   _ W: Double, _ i: Int) -> [[Double]]? {
        var tgt: Item?
        if case .string(let name)? = p["to"] {
            guard let hit = parts.first(where: { $0.closed && $0.id == name && $0.i < i }),
                  let it = items.first(where: { $0.i == hit.i && $0.at != nil }) else { return nil }
            tgt = it
        }
        let at = point(p["at"])
        let amp = hand * W
        let seed = i
        let sz = size(p["size"], "box")
        switch kind {
        case "scribble":
            let box: [Double]
            if let t = tgt, let a = t.at, let s = t.size { box = [a[0], a[1], s[0] + 0.5, s[1] + 0.5] }
            else if let at { box = [at[0], at[1]] + (sz ?? [2, 1.2]) }
            else { return nil }
            let cx = box[0], cy = box[1], bw = box[2], bh = box[3]
            if truthy(p["fill"]) {
                // Back and forth strokes down the box.
                let rows = Int(clamp((bh / 0.2).rounded(), 3, 14))
                var pts: [[Double]] = []
                for r in 0...rows {
                    let y = cy - bh / 2 + bh * Double(r) / Double(rows)
                    pts.append(r % 2 == 1 ? [cx + bw / 2, y] : [cx - bw / 2, y])
                    pts.append(r % 2 == 1 ? [cx - bw / 2, y] : [cx + bw / 2, y])
                }
                return rough(pts, seed: seed, amp: amp * 0.5)
            }
            // Two loops round the spot, the second a little wider, ending open.
            let n = 44
            let pts: [[Double]] = (0...n).map { j in
                let a = -Double.pi / 2 + 2.15 * 2 * Double.pi * Double(j) / Double(n)
                let g = 1 + 0.08 * (Double(j) / Double(n)) * 2
                return [cx + cos(a) * (bw / 2) * g, cy + sin(a) * (bh / 2) * g]
            }
            return rough(pts, seed: seed, amp: amp * 0.6, closed: false, step: .infinity)
        case "underline":
            let c: [Double]
            if let t = tgt, let a = t.at, let s = t.size { c = [a[0], a[1] + s[1] / 2 + 0.2, s[0] * 0.95] }
            else if let at { c = [at[0], at[1], sz?[0] ?? 2] }
            else { return nil }
            return rough([[c[0] - c[2] / 2, c[1] + 0.03], [c[0] + c[2] / 2, c[1] - 0.04]], seed: seed, amp: amp * 0.7)
        default:
            // check: a short stroke down, a long one up.
            let s = num(p["size"]) ?? 1
            let c: [Double]
            if let t = tgt, let a = t.at, let z = t.size { c = [a[0] + z[0] / 2 + 0.6 * s, a[1]] }
            else if let at { c = at }
            else { return nil }
            return rough([[c[0] - 0.4 * s, c[1] + 0.02 * s], [c[0] - 0.12 * s, c[1] + 0.34 * s], [c[0] + 0.42 * s, c[1] - 0.36 * s]],
                         seed: seed, amp: amp * 0.4, closed: false, step: 0.18)
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
    /// A label in a part of a Venn: where it goes, how wide that part is there, its lines and its size.
    struct VennLabel: Equatable {
        var at: [Double]; var text: String; var width: Double; var lines: [String]; var fs: Double; var middle = false
    }

    /// A Venn centred on `c` (YUI-276): its circles, each with a tone (the shape's own, then on through
    /// `cycle`), and its labels. Each label sits in the widest part of its own region (`widest`), at most
    /// two lines, shrunk to fit down to 0.7 of its size (`fit`). `fs` is the scene's label size; set and
    /// pair names draw at 0.85 of it. Two circles when it has fewer than three sets.
    static func venn(_ it: Item, center c: [Double], s: Double = 1, fs: Double = ShapesModel.label * 10)
        -> (circles: [VennCircle], labels: [VennLabel]) {
        let sets = it.sets ?? []
        let r = vennRadius(it, s: s)
        let three = sets.count >= 3
        let y = 0.5196 * r
        let at: [[Double]] = three ? [[-0.6 * r, -y], [0.6 * r, -y], [0, y]] : [[-0.6 * r, 0], [0.6 * r, 0]]
        let start = cycle.firstIndex(of: it.tone)
        let circles = at.enumerated().map { k, p in
            VennCircle(c: [c[0] + p[0], c[1] + p[1]], r: r, tone: start.map { cycle[($0 + k) % cycle.count] } ?? it.tone)
        }
        let all = Array(circles.indices)
        var labels: [VennLabel] = []
        func place(_ inside: [Int], _ text: String, _ size: Double, middle: Bool) {
            let outside = all.filter { !inside.contains($0) }
            let y0 = inside.map { circles[$0].c[1] - r }.max()!, y1 = inside.map { circles[$0].c[1] + r }.min()!
            let spot = widest(vennRuns(circles, inside, outside), y0, y1, th: size * line)
            let width = spot.map { $0.width * 0.9 } ?? r * 0.5
            let f = fit(text, width: width, fs: size)
            let n = Double(inside.count)
            let mid = [inside.map { circles[$0].c[0] }.reduce(0, +) / n, inside.map { circles[$0].c[1] }.reduce(0, +) / n]
            labels.append(VennLabel(at: spot?.at ?? mid, text: text, width: width, lines: f.lines, fs: f.fs, middle: middle))
        }
        for (k, t) in sets.prefix(circles.count).enumerated() where !t.isEmpty { place([k], t, 0.85 * fs * s, middle: false) }
        if !it.label.isEmpty { place(all, it.label, fs * s, middle: true) }
        if three {
            let pairs = it.pairs ?? []
            for (k, pair) in [[0, 1], [0, 2], [1, 2]].enumerated() where k < pairs.count && !pairs[k].isEmpty {
                place(pair, pairs[k], 0.85 * fs * s, middle: false)
            }
        }
        return (circles, labels)
    }

    /// A circle's chord at height y, or nil.
    private static func chord(_ q: VennCircle, _ y: Double) -> [Double]? {
        let d = y - q.c[1]
        if abs(d) >= q.r { return nil }
        let h = (q.r * q.r - d * d).squareRoot()
        return [q.c[0] - h, q.c[0] + h]
    }

    /// Runs with one interval cut out of them.
    private static func minus(_ runs: [[Double]], _ cut: [Double]?) -> [[Double]] {
        guard let cut else { return runs }
        var out: [[Double]] = []
        for run in runs {
            let lo = run[0], hi = run[1]
            if cut[1] <= lo || cut[0] >= hi { out.append(run); continue }
            if cut[0] > lo { out.append([lo, cut[0]]) }
            if cut[1] < hi { out.append([cut[1], hi]) }
        }
        return out
    }

    /// A Venn region's runs at height y: inside every circle in `inside`, outside the rest.
    private static func vennRuns(_ circles: [VennCircle], _ inside: [Int], _ outside: [Int]) -> (Double) -> [[Double]] {
        { y in
            var lo = -Double.infinity, hi = Double.infinity
            for k in inside {
                guard let ch = chord(circles[k], y) else { return [] }
                lo = max(lo, ch[0])
                hi = min(hi, ch[1])
            }
            if hi <= lo { return [] }
            var runs: [[Double]] = [[lo, hi]]
            for k in outside { runs = minus(runs, chord(circles[k], y)) }
            return runs
        }
    }

    /// The widest place for a label in a region, given its runs at a height y between y0 and y1: 25
    /// heights (an odd count, so the middle is one), at each the longest run, narrowed to what the
    /// region still holds half a line (th / 2) above and below. Nil when nothing fits.
    static func widest(_ runs: (Double) -> [[Double]], _ y0: Double, _ y1: Double, th: Double) -> (at: [Double], width: Double)? {
        let n = 25
        var best: (at: [Double], width: Double)? = nil
        for j in 0..<n {
            let y = y0 + (y1 - y0) * (Double(j) + 0.5) / Double(n)
            let here = runs(y)
            guard var top = here.first else { continue }
            for q in here.dropFirst() where q[1] - q[0] > top[1] - top[0] { top = q }
            var lo = top[0], hi = top[1]
            for dy in [-th / 2, th / 2] {
                var most = 0.0
                var pick: [Double]? = nil
                for q in runs(y + dy) {
                    let o = min(hi, q[1]) - max(lo, q[0])
                    if o > most { most = o; pick = q }
                }
                guard let pick else { hi = lo; break }
                lo = max(lo, pick[0])
                hi = min(hi, pick[1])
            }
            if hi - lo > (best?.width ?? 0) { best = ([(lo + hi) / 2, y], hi - lo) }
        }
        return best
    }

    /// A short label capped at `capWords` words and `capChars` characters: whole words while they fit,
    /// then "…"; a first word longer than that is cut (YUI-276).
    static func cap(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var out: [String] = []
        for w in words {
            let next = out.isEmpty ? w : out.joined(separator: " ") + " " + w
            if out.count >= capWords || next.utf16.count > capChars { break }
            out.append(w)
        }
        if out.count == words.count { return words.joined(separator: " ") }
        if out.isEmpty { return String(decoding: Array(words[0].utf16.prefix(capChars - 1)), as: UTF16.self) + "…" }
        return out.joined(separator: " ") + "…"
    }

    /// A short label as at most two lines that fit `width`, at fs or a step smaller (0.05 fs a step)
    /// down to 0.7 fs. What still does not fit at the floor runs a little wide rather than lose letters.
    static func fit(_ text: String, width: Double, fs: Double) -> (lines: [String], fs: Double) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return ([], fs) }
        func two(_ f: Double) -> (out: [String], most: Int) {
            let most = max(1, Int((width / (f * glyph)).rounded(.down)))
            var out: [String] = []
            for w in words {
                if let last = out.last, (last + " " + w).utf16.count <= most { out[out.count - 1] = last + " " + w } else { out.append(w) }
            }
            if out.count > 2 { out = [out[0], out[1...].joined(separator: " ")] }
            return (out, most)
        }
        for i in 0...6 {
            let f = fs * (1 - 0.05 * Double(i))
            let t = two(f)
            if t.out.allSatisfy({ $0.utf16.count <= t.most }) { return (t.out, f) }
        }
        let f = fs * (1 - 0.05 * 6)
        return (two(f).out, f)
    }

    /// A region's outline as a polygon: its smooth curve, eight points a segment.
    private static func outlinePoints(_ pts: [[Double]]) -> [[Double]] {
        var out: [[Double]] = []
        for (k, seg) in smooth(pts, closed: true).enumerated() {
            let (c1, c2, p3) = seg
            let p0 = pts[k]
            for j in 1...8 {
                let t = Double(j) / 8, u = 1 - t
                let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
                out.append([b0 * p0[0] + b1 * c1[0] + b2 * c2[0] + b3 * p3[0],
                            b0 * p0[1] + b1 * c1[1] + b2 * c2[1] + b3 * p3[1]])
            }
        }
        return out
    }

    /// A polygon's runs at height y (even-odd).
    private static func polyRuns(_ poly: [[Double]]) -> (Double) -> [[Double]] {
        { y in
            var xs: [Double] = []
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if (a[1] <= y) != (b[1] <= y) { xs.append(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])) }
            }
            xs.sort()
            return stride(from: 0, to: xs.count - 1, by: 2).map { [xs[$0], xs[$0 + 1]] }
        }
    }

    /// Where a region's label goes (YUI-276): the widest part of its outline, fitted to it at 0.9 of fs.
    static func regionLabel(_ it: Item, fs: Double) -> (at: [Double], width: Double, lines: [String], fs: Double) {
        let pts = it.pts ?? []
        guard pts.count >= 3 else { return (pts.first ?? [0, 0], 3.4, [], fs * 0.9) }
        let poly = outlinePoints(pts)
        let ys = poly.map { $0[1] }
        let size = fs * 0.9
        let spot = widest(polyRuns(poly), ys.min()!, ys.max()!, th: size * line)
        let n = Double(pts.count)
        let width = spot.map { $0.width * 0.9 } ?? 3.4
        let f = fit(it.label, width: width, fs: size)
        let mid = [pts.map { $0[0] }.reduce(0, +) / n, pts.map { $0[1] }.reduce(0, +) / n]
        return (spot?.at ?? mid, width, f.lines, f.fs)
    }

    /// A contour's rings round `c` (YUI-276), outermost first: one outline scaled in steps, each
    /// step's middle drifting toward the peak, and its label there, fitted to half its width.
    static func contour(_ it: Item, center c: [Double], s: Double = 1, fs: Double = ShapesModel.label * 10)
        -> (rings: [[[Double]]], peak: [Double], label: (lines: [String], fs: Double)) {
        let n = it.rings ?? 4
        let w = (it.size?[0] ?? 0) * s, h = (it.size?[1] ?? 0) * s
        let dx = 0.08 * w * sin(Double(it.i + 1) * 3.1), dy = -0.07 * h * abs(cos(Double(it.i + 1) * 3.1))
        let rings = (0..<n).map { k -> [[Double]] in
            let f = Double(n - k) / Double(n), m = Double(k) / Double(n)
            return blobPoints(w * f, h * f, seed: it.i).map { [$0[0] + c[0] + dx * m, $0[1] + c[1] + dy * m] }
        }
        return (rings, [c[0] + dx * Double(n - 1) / Double(n), c[1] + dy * Double(n - 1) / Double(n)],
                fit(it.label, width: w * 0.5, fs: fs * s))
    }

    /// Gesture marks over a mock (YUI-276): its `shape` lines drawn over its screen. `cells`: each part's
    /// box by its id, [x, y, w, h] in points from the screen's top left; `box`: the screen, [w, h] in
    /// points. A place is a part's id (its middle) or x,y with 0,0 the screen's top left and 10,10 its
    /// bottom right; a size is in tenths of the screen's width. A doodle round a part with no size rings
    /// the whole part; an arrow or a line to a part stops at its edge. The scene is 10 wide and as tall
    /// as the screen: draw it over the screen.
    static func marksOver(_ members: [(id: String?, props: [String: YLValue])], cells: [String: [Double]], box: [Double]) -> Scene {
        let unit = box[0] / 10, H = box[1] / unit
        let own = Set(members.compactMap { $0.id })
        func cell(_ v: YLValue?) -> [Double]? {
            guard case .string(let name)? = v, !own.contains(name), let r = cells[name] else { return nil }
            return r.map { $0 / unit }
        }
        func fmt(_ q: [Double]) -> YLValue {
            .string("\((q[0] * 1e4).rounded() / 1e4),\((q[1] * 1e4).rounded() / 1e4)")
        }
        func down(_ v: YLValue) -> YLValue {
            guard let q = point(v) else { return v }
            return fmt([q[0], q[1] * H / 10])
        }
        let out = members.map { m -> (id: String?, props: [String: YLValue]) in
            var p = m.props
            let kind = (text(p["kind"]) ?? "box").lowercased()
            var rect: [String: [Double]] = [:]
            for key in ["at", "from", "to", "move"] {
                if let r = cell(p[key]) {
                    rect[key] = r
                    p[key] = fmt([r[0] + r[2] / 2, r[1] + r[3] / 2])
                } else if let v = p[key] {
                    p[key] = down(v)
                }
            }
            if let pts = p["pts"]?.array { p["pts"] = .array(pts.map(down)) }
            let traced = (p["pts"]?.array?.count ?? 0) >= 2
            if kind == "doodle", let r = rect["at"], p["size"] == nil, !traced { p["size"] = fmt([r[2] + 0.8, r[3] + 0.8]) }
            if kind == "arrow" || kind == "line" {
                let startRect = rect["from"] ?? (p["from"] == nil ? rect["at"] : nil)
                if let a = point(p["from"] ?? p["at"]), let b = point(p["to"]) {
                    if let r = startRect { p["from"] = fmt(edgeOf(r, toward: b)) }
                    if let r = rect["to"] { p["to"] = fmt(edgeOf(r, toward: a)) }
                }
            }
            return (m.id, p)
        }
        return scene(head: ["w": .number(10), "h": .number(H)], members: out, free: true)
    }

    /// The point on a part's box [x, y, w, h] on the way to `toward`, with a small gap.
    private static func edgeOf(_ r: [Double], toward: [Double]) -> [Double] {
        let cx = r[0] + r[2] / 2, cy = r[1] + r[3] / 2
        let dx = toward[0] - cx, dy = toward[1] - cy
        let len = hypot(dx, dy) == 0 ? 1 : hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let rx = abs(ux) > 1e-9 ? r[2] / 2 / abs(ux) : .infinity
        let ry = abs(uy) > 1e-9 ? r[3] / 2 / abs(uy) : .infinity
        let d = min(min(rx, ry) + 0.15, len)
        return [cx + ux * d, cy + uy * d]
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
        for it in sc.items where it.from != nil && !it.leader && name(it.from) != nil && name(it.to) != nil {
            if case .ref(let a)? = it.from { joined.insert(a) }
            if case .ref(let b)? = it.to { joined.insert(b) }
        }
        var bits: [String] = []
        var tail: Int? = nil
        for it in sc.items {
            if it.from != nil && !it.leader {
                guard let a = name(it.from), let b = name(it.to) else {
                    // A swipe says so: "swipe, slide to cancel" (YUI-276).
                    let words = it.kind == "swipe" ? ["swipe", it.label].filter { !$0.isEmpty }.joined(separator: ", ") : it.label
                    if !words.isEmpty { bits.append(words) }
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
            } else if it.kind == "tap", !joined.contains(it.i) {
                // "tap, hold to talk" (YUI-276).
                bits.append(["tap", it.label].filter { !$0.isEmpty }.joined(separator: ", "))
                tail = nil
            } else if !it.label.isEmpty && !joined.contains(it.i) {
                bits.append(it.label)
                tail = nil
            }
        }
        return [sc.title, bits.joined(separator: ", "), sc.caption].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
