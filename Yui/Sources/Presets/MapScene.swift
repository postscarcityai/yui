import Foundation
import YuiLines

// Maps (YUI-158; spec yuigui spec/YL.md "map"). The scene model behind `map`,
// `area`, `pin` and `route` lines: a line-for-line port of the hub's
// site/lib/yl/map.mjs, so the web and the phone draw the same map.
// YuiTests/MapSceneTests checks it against yuigui spec/map/scenes.json.
// Offline: the world outline is Natural Earth 110m (Resources/world.json,
// from yuigui site/lib/yl/world.mjs), no tiles, no key, no network.
// Pure values, no SwiftUI: MapPreset draws what frame(at:) returns.

enum MapModel {
    static let tones: Set<String> = ["accent", "mint", "lavender", "butter", "ink", "mute"]
    static let W = 100.0
    // The clock, in seconds: one part to the next, then how long each takes.
    static let step = 0.35
    static let durations: [String: Double] = ["area": 0.6, "pin": 0.5, "route": 0.9]
    static let pulse = 1.6
    /// Label size as a share of the width.
    static let label = 0.034
    /// The whole world, as drawn by fit=world (no Antarctica).
    static let world = (lon: [-180.0, 180.0], lat: [-56.0, 83.0])

    /// A country from the bundled outline: its rings as flat lon, lat pairs.
    struct Country { let code: String; let name: String; let rings: [[Double]] }

    /// The outline, in the order world.mjs lists it (the land path keeps that order).
    static let countries: [Country] = {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["countries"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let code = c["code"] as? String, let rings = c["rings"] as? [[NSNumber]] else { return nil }
            return Country(code: code, name: c["name"] as? String ?? code, rings: rings.map { $0.map(\.doubleValue) })
        }
    }()
    private static let byCode: [String: Int] = Dictionary(countries.enumerated().map { ($1.code, $0) }) { a, _ in a }
    private static let a3: [String: String] = {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root["a3"] as? [String: String] ?? [:]
    }()

    struct Item: Equatable {
        var i: Int
        var id: String?
        var kind: String
        var label: String
        var tone: String
        var dash: Bool
        var pulse: Bool
        var start: Double
        var dur: Double
        /// An area's outline, projected, one list of points per piece.
        var rings: [[[Double]]] = []
        /// An area's countries, a route's stops that are pins (nil for a bare place).
        var names: [String?] = []
        /// A pin's place, an area's label spot, a route's middle.
        var c: [Double] = [0, 0]
        var grow = false
        var pts: [[Double]] = []
        var arrow = false
        /// The label as drawn: the label, its short form, or "" when it found no room.
        var text = ""
        /// Where the label goes, and which side of that point it hangs from.
        var lx: Double? = nil
        var ly: Double? = nil
        var anchor: String? = nil
    }

    struct Scene: Equatable {
        var title: String
        var caption: String
        var w: Double
        var h: Double
        var fs: Double
        var land: [[[Double]]]
        var items: [Item]
        var total: Double
        var missing: [String]
        var view: (lon: [Double], lat: [Double])
        var pulses: Bool { items.contains { $0.pulse } }

        static func == (a: Scene, b: Scene) -> Bool {
            a.title == b.title && a.caption == b.caption && a.w == b.w && a.h == b.h && a.items == b.items
                && a.view.lon == b.view.lon && a.view.lat == b.view.lat && a.missing == b.missing
        }
    }

    /// One part `t` seconds in: o (opacity), d (how much is drawn, 0 to 1),
    /// s (scale), p (a pulse, 0 to 1, for +pulse pins once landed).
    struct Frame: Equatable {
        var item: Item
        var o: Double
        var d: Double
        var s: Double
        var p: Double
    }

    // MARK: - Helpers, as in map.mjs

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    /// JS Math.round: halves go up, toward +infinity.
    static func round(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
    static func r3(_ n: Double) -> Double { round(n * 1000) / 1000 }

    /// JS String(v) for the props these lines carry.
    static func text(_ v: YLValue?) -> String {
        switch v {
        case .string(let s)?: s
        case .number(let n)?: num(n)
        case .bool(let b)?: b ? "true" : "false"
        case .array(let a)?: a.map { text($0) }.joined(separator: ",")
        default: ""
        }
    }

    /// A number as JS writes it: 3, 12.5, -0.25.
    static func num(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return "\(n)"
    }

    private static func number(_ v: YLValue?) -> Double? {
        switch v {
        case .number(let n)? where n.isFinite: n
        case .string(let s)?:
            s.trimmingCharacters(in: .whitespaces).range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
                ? Double(s.trimmingCharacters(in: .whitespaces)) : nil
        default: nil
        }
    }

    /// "47.9,106.9" to [lat, lon]; out of range or anything else is nil.
    static func latlon(_ v: YLValue?) -> [Double]? {
        guard let v, v != .bool(true), v != .null else { return nil }
        let parts = text(v).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = number(.string(parts[0])), let lon = number(.string(parts[1])),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return [lat, lon]
    }

    /// A country by ISO alpha-2 or alpha-3 code, any case.
    static func country(_ code: String) -> Country? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let i = byCode[c] ?? a3[c].flatMap({ byCode[$0] }) else { return nil }
        return countries[i]
    }

    private static func pairs(_ flat: [Double]) -> [[Double]] {
        stride(from: 0, to: flat.count - 1, by: 2).map { [flat[$0], flat[$0 + 1]] }
    }

    /// The smallest run of longitudes that holds every one given, as [from, to]
    /// with to - from <= 360 (to may pass 180 when the run crosses the date line).
    static func lonSpan(_ lons: [Double]) -> [Double]? {
        let xs = Array(Set(lons.map { jsMod($0 + 540, 360) - 180 })).sorted()
        guard let first = xs.first, let last = xs.last else { return nil }
        if xs.count == 1 { return [first, first] }
        var gap = first + 360 - last
        var span = [first, last]
        for i in 1..<xs.count {
            let g = xs[i] - xs[i - 1]
            if g > gap { gap = g; span = [xs[i], xs[i - 1] + 360] }
        }
        return span
    }

    private static func jsMod(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }

    // MARK: - The scene

    private struct Part {
        var i: Int
        var id: String?
        var kind: String
        var label: String
        var tone: String
        var dash: Bool
        var pulse: Bool
        var rings: [[[Double]]] = []
        var names: [String?] = []
        var at: [Double] = []
        var grow = false
        var stops: [[Double]] = []
        var arrow = false
    }

    typealias Member = (id: String?, preset: String, props: [String: YLValue])

    private static func strings(_ v: YLValue?) -> [YLValue] {
        switch v {
        case .array(let a)?: a
        case nil, .null?: []
        case let x?: [x]
        }
    }

    /// Every part, resolved: its kind, what it holds on the globe, its look.
    private static func parts(_ members: [Member]) -> (list: [Part], missing: [String]) {
        var pins: [String: [Double]] = [:]
        for m in members where m.preset == "pin" {
            if let at = latlon(m.props["at"]), let id = m.id, !id.isEmpty { pins[id] = at }
        }
        var out: [Part] = []
        var missing: [String] = []
        for (i, m) in members.enumerated() {
            let p = m.props
            // JS truthiness, as map.mjs reads its flags.
            let flag = { (k: String) in p[k].map { $0 != .bool(false) && $0 != .null && $0 != .string("") && $0 != .number(0) } ?? false }
            let toneWord = p["tone"]?.string ?? ""
            let tone = tones.contains(toneWord) ? toneWord : m.preset == "area" && flag("dash") ? "mute" : "accent"
            var base = Part(i: i, id: m.id, kind: m.preset, label: text(p["label"]), tone: tone, dash: flag("dash"), pulse: flag("pulse"))
            switch m.preset {
            case "area":
                var rings: [[[Double]]] = []
                var names: [String?] = []
                for code in strings(p["codes"]) {
                    guard let c = country(text(code)) else { missing.append(text(code)); continue }
                    names.append(c.name)
                    for r in c.rings { rings.append(pairs(r)) }
                }
                let drawn = strings(p["pts"]).compactMap { latlon($0) }.map { [$0[1], $0[0]] }
                if drawn.count >= 3 { rings.append(drawn) }
                if !rings.isEmpty { base.rings = rings; base.names = names; out.append(base) }
            case "pin":
                if let at = latlon(p["at"]) { base.at = [at[1], at[0]]; base.grow = !base.pulse || flag("grow"); out.append(base) }
            case "route":
                var stops: [[Double]] = []
                var names: [String?] = []
                for s in strings(p["pts"]) {
                    let key = text(s)
                    guard let at = latlon(s) ?? pins[key] else { continue }
                    stops.append([at[1], at[0]])
                    let pin = members.first { $0.preset == "pin" && $0.id == key }
                    names.append(pin.map { l in let t = text(l.props["label"]); return t.isEmpty ? key : t })
                }
                if stops.count >= 2 { base.stops = stops; base.names = names; base.arrow = flag("arrow"); out.append(base) }
            default: break
            }
        }
        return (out, missing)
    }

    /// The view: which longitudes and latitudes the drawing covers.
    private static func view(_ head: [String: YLValue], _ list: [Part]) -> (lon: [Double], lat: [Double]) {
        if let c = latlon(head["center"]), let z = number(head["zoom"]) {
            let span = 360 / pow(2, clamp(z, 1, 12) - 1)
            return ([c[1] - span / 2, c[1] + span / 2], [c[0] - span / 4, c[0] + span / 4])
        }
        var lons: [Double] = [], lats: [Double] = []
        for it in list {
            let pts = it.kind == "area" ? it.rings.flatMap { $0 } : it.kind == "route" ? it.stops : [it.at]
            for p in pts { lons.append(p[0]); lats.append(p[1]) }
        }
        if text(head["fit"]) == "world" || lons.isEmpty { return (world.lon, world.lat) }
        let lon = lonSpan(lons)!
        let lat = [lats.min()!, lats.max()!]
        // Pad a tenth each way, and never closer than 8 degrees across.
        let pad = { (a: [Double]) -> [Double] in
            let d = max(a[1] - a[0], 8), mid = (a[0] + a[1]) / 2
            return [mid - d * 0.6, mid + d * 0.6]
        }
        return (pad(lon), pad(lat))
    }

    /// Fits and projects the whole map. Equirectangular, squeezed by the cosine
    /// of the middle latitude so the region keeps its shape; the drawing stays
    /// between square and twice as wide as tall (the short side grows to fit).
    static func scene(head: [String: YLValue], members: [Member]) -> Scene {
        let (list, missing) = parts(members)
        let v = view(head, list)
        var lon0 = v.lon[0], lon1 = v.lon[1]
        var lat0 = clamp(v.lat[0], -85, 85), lat1 = clamp(v.lat[1], -85, 85)
        let k = clamp(cos((lat0 + lat1) / 2 * .pi / 180), 0.35, 1)
        var sx = (lon1 - lon0) * k, sy = lat1 - lat0
        if sx / sy > 2 {
            let need = sx / 2 - sy
            lat0 -= need / 2; lat1 += need / 2
            if lat1 > 85 { lat0 -= lat1 - 85; lat1 = 85 }
            if lat0 < -85 { lat1 += -85 - lat0; lat0 = -85 }
            sy = lat1 - lat0
        } else if sx / sy < 1 {
            let need = (sy - sx) / k
            lon0 -= need / 2; lon1 += need / 2
            sx = sy
        }
        let s = W / sx
        let H = r3(sy * s)
        let mid = (lon0 + lon1) / 2
        // A longitude moved by whole turns to sit nearest the middle of the view.
        let near = { (lon: Double) in lon + 360 * round((mid - lon) / 360) }
        let P = { (lon: Double, lat: Double, shift: Double?) -> [Double] in
            [r3(((shift.map { lon + $0 } ?? near(lon)) - lon0) * k * s), r3((lat1 - lat) * s)]
        }
        // A ring keeps one shift for all its points, so it never tears.
        let ring = { (pts: [[Double]]) -> [[Double]] in
            let avg = pts.reduce(0) { $0 + $1[0] } / Double(pts.count)
            let shift = near(avg) - avg
            return pts.map { P($0[0], $0[1], shift) }
        }
        let inView = { (pp: [[Double]]) in pp.contains { $0[0] > -W * 0.2 && $0[0] < W * 1.2 && $0[1] > -H * 0.2 && $0[1] < H * 1.2 } }

        // The land: every country with a point near the view.
        var land: [[[Double]]] = []
        for c in countries {
            for r in c.rings {
                let pp = ring(pairs(r))
                if inView(pp) { land.append(pp) }
            }
        }

        let fs = r3(W * label)
        var items: [Item] = []
        for (n, it) in list.enumerated() {
            var out = Item(i: it.i, id: it.id, kind: it.kind, label: it.label, tone: it.tone, dash: it.dash, pulse: it.pulse,
                           start: r3(Double(n) * step), dur: durations[it.kind] ?? 0.5)
            switch it.kind {
            case "area":
                let rings = it.rings.map(ring).filter(inView)
                out.rings = rings
                out.names = it.names
                // The label sits on the biggest piece's middle.
                var best: [Double]? = nil
                var bestA = -1.0
                for r in rings {
                    var a = 0.0, cx = 0.0, cy = 0.0
                    for j in r.indices {
                        let p1 = r[j], p2 = r[(j + 1) % r.count]
                        let c = p1[0] * p2[1] - p2[0] * p1[1]
                        a += c; cx += (p1[0] + p2[0]) * c; cy += (p1[1] + p2[1]) * c
                    }
                    if abs(a) > bestA && a != 0 { bestA = abs(a); best = [r3(cx / (3 * a)), r3(cy / (3 * a))] }
                }
                out.c = best ?? rings.first?.first ?? [W / 2, H / 2]
            case "pin":
                out.c = P(it.at[0], it.at[1], nil)
                out.grow = it.grow
            default:
                let pts = it.stops.map { P($0[0], $0[1], nil) }
                out.pts = pts
                out.names = it.names
                out.arrow = it.arrow
                // Two stops bow a little, like a road over the curve of the earth.
                if pts.count == 2 {
                    let ax = pts[0][0], ay = pts[0][1], bx = pts[1][0], by = pts[1][1]
                    let hy = hypot(bx - ax, by - ay)
                    let len = hy == 0 ? 1 : hy
                    let bend = 0.12 * len
                    let sign: Double = bx - ax == 0 ? 1 : (bx - ax > 0 ? 1 : -1)
                    out.pts = [pts[0], [r3((ax + bx) / 2 + ((by - ay) / len) * bend), r3((ay + by) / 2 - ((bx - ax) / len) * bend * sign)], pts[1]]
                }
                out.c = out.pts[out.pts.count / 2]
            }
            items.append(out)
        }
        place(&items, fs: fs, w: W, h: H)
        let total = items.map { $0.start + $0.dur }.max() ?? 0
        return Scene(title: text(head["title"]), caption: text(head["caption"]), w: W, h: H, fs: fs, land: land, items: items,
                     total: r3(total), missing: missing, view: ([r3(lon0), r3(lon1)], [r3(lat0), r3(lat1)]))
    }

    /// JS string length (UTF-16 units), which the label sizes count in.
    private static func len(_ s: String) -> Int { s.utf16.count }

    /// Where each label goes. Pins claim first, then areas, then routes, and
    /// no label ever lands on a pin or on another label. A pin's label sits
    /// beside it, an area's on its biggest piece, a route's beside the middle
    /// of its line (never at its ends, where the pins are). Each label tries
    /// its spots clear of the route lines first, then over them; a label that
    /// finds no room at full length tries its short form (the words before a
    /// comma or a bracket), and one that still finds none is dropped. Sets
    /// text ("" when dropped), lx, ly and anchor. Same as map.mjs place().
    private static let rank: [String: Int] = ["pin": 0, "area": 1, "route": 2]
    private static func place(_ items: inout [Item], fs: Double, w: Double, h: Double) {
        var taken = items.filter { $0.kind == "pin" }.map { box($0.c[0], $0.c[1], fs * 0.9, fs * 0.9, "middle") }
        let lines = items.filter { $0.kind == "route" }.map(\.pts)
        let order = items.indices.sorted { p, q in
            let a = rank[items[p].kind] ?? 3, b = rank[items[q].kind] ?? 3
            return a != b ? a < b : p < q
        }
        for n in order {
            items[n].text = ""
            let it = items[n]
            guard !it.label.isEmpty else { continue }
            let f = it.kind == "route" ? fs * 0.92 : fs
            var pick: (String, Double, Double, String, [Double])? = nil
            search: for text in short(it.label) {
                let ls = wrap(text, width: 30, fs: f)
                let tw = Double(ls.map(len).max() ?? 0) * f * 0.58
                let th = f * 1.15 * Double(ls.count)
                let spots = spotsFor(it, f: f, fs: fs, tw: tw, th: th)
                for clear in [true, false] {
                    for (x0, y0, a) in spots {
                        guard let at = onto(x0, y0, tw, th, a, w, h) else { continue }
                        let x = at.0, y = at.1
                        let bx = box(x, y, tw, th, a)
                        if taken.contains(where: { hits($0, bx) }) { continue }
                        if clear && lines.contains(where: { crosses($0, bx) }) { continue }
                        pick = (text, x, y, a, bx)
                        break search
                    }
                }
            }
            guard let p = pick else { continue }
            items[n].text = p.0; items[n].lx = r3(p.1); items[n].ly = r3(p.2); items[n].anchor = p.3
            taken.append(p.4)
        }
    }

    /// A label, then its short form when it has one.
    private static func short(_ label: String) -> [String] {
        let u = Array(label.utf16)
        let stops: Set<UInt16> = [0x2C, 0x28, 0x2013, 0x2014]
        // Lazy `^(.+?)\s*[,(–—]`: the first stop after at least one unit.
        guard u.count > 1, let k = u.indices.dropFirst().first(where: { stops.contains(u[$0]) }) else { return [label] }
        let s = (String(utf16CodeUnits: Array(u[..<k]), count: k)).trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && s != label ? [label, s] : [label]
    }

    /// The spots a label may take, best first.
    private static func spotsFor(_ it: Item, f: Double, fs: Double, tw: Double, th: Double) -> [(Double, Double, String)] {
        let cx = it.c[0], cy = it.c[1]
        if it.kind == "pin" {
            let g = fs * 0.8, v = fs * 1.1
            return [(cx + g, cy, "start"), (cx - g, cy, "end"), (cx, cy - v, "middle"), (cx, cy + v, "middle"),
                    (cx + g, cy - v, "start"), (cx + g, cy + v, "start"), (cx - g, cy - v, "end"), (cx - g, cy + v, "end")]
        }
        if it.kind == "area" {
            let v = fs * 1.6
            return [(cx, cy, "middle"), (cx, cy + v, "middle"), (cx, cy - v, "middle"), (cx, cy + v * 2, "middle"), (cx, cy - v * 2, "middle"),
                    (cx + tw * 0.6, cy, "middle"), (cx - tw * 0.6, cy, "middle")]
        }
        // A route: points along its line from the middle out, a label's width
        // off the line on either side.
        var out: [(Double, Double, String)] = []
        for t in [0.5, 0.4, 0.6, 0.3, 0.7] {
            let (px, py, ux, uy) = along(it.pts, t)
            var nx = -uy, ny = ux
            if ny > 0 || (ny == 0 && nx < 0) { nx = -nx; ny = -ny }
            let d = abs(nx) * tw / 2 + abs(ny) * th / 2 + f * 0.4
            out += [(px + nx * d, py + ny * d, "middle"), (px - nx * d, py - ny * d, "middle")]
        }
        return out
    }

    /// The point a share t of the way along a line, and the line's direction there.
    private static func along(_ pts: [[Double]], _ t: Double) -> (Double, Double, Double, Double) {
        var segs: [Double] = []
        var total = 0.0
        for j in 1..<max(pts.count, 1) {
            let l = hypot(pts[j][0] - pts[j - 1][0], pts[j][1] - pts[j - 1][1])
            segs.append(l); total += l
        }
        var at = total * t
        for j in segs.indices {
            if at <= segs[j] || j == segs.count - 1 {
                let a = pts[j], b = pts[j + 1]
                let l = segs[j] == 0 ? 1 : segs[j]
                let k = clamp(at / l, 0, 1)
                return (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, (b[0] - a[0]) / l, (b[1] - a[1]) / l)
            }
            at -= segs[j]
        }
        return (pts.first?[0] ?? 0, pts.first?[1] ?? 0, 1, 0)
    }

    /// Moves a label back onto the drawing; nil when it cannot fit at all.
    private static func onto(_ x0: Double, _ y0: Double, _ tw: Double, _ th: Double, _ a: String, _ w: Double, _ h: Double) -> (Double, Double)? {
        if tw > w || th > h { return nil }
        var x = x0, y = y0
        let bx = box(x, y, tw, th, a)
        if bx[0] < 0 { x -= bx[0] } else if bx[2] > w { x -= bx[2] - w }
        if bx[1] < 0 { y -= bx[1] } else if bx[3] > h { y -= bx[3] - h }
        return (x, y)
    }

    private static func box(_ x: Double, _ y: Double, _ tw: Double, _ th: Double, _ a: String) -> [Double] {
        let x0 = a == "start" ? x : a == "end" ? x - tw : x - tw / 2
        return [x0, y - th / 2, x0 + tw, y + th / 2]
    }

    private static func hits(_ p: [Double], _ q: [Double]) -> Bool { p[0] < q[2] && q[0] < p[2] && p[1] < q[3] && q[1] < p[3] }

    /// Whether a line (a list of points) passes through a box.
    private static func crosses(_ pts: [[Double]], _ b: [Double]) -> Bool {
        guard pts.count > 1 else { return false }
        return (1..<pts.count).contains { cut(pts[$0 - 1], pts[$0], b) }
    }

    /// Liang-Barsky: whether the segment p-q enters the box.
    private static func cut(_ p: [Double], _ q: [Double], _ b: [Double]) -> Bool {
        let dx = q[0] - p[0], dy = q[1] - p[1]
        var t0 = 0.0, t1 = 1.0
        for (pp, qq) in [(-dx, p[0] - b[0]), (dx, b[2] - p[0]), (-dy, p[1] - b[1]), (dy, b[3] - p[1])] {
            if pp == 0 { if qq < 0 { return false }; continue }
            let r = qq / pp
            if pp < 0 { if r > t1 { return false }; if r > t0 { t0 = r } } else { if r < t0 { return false }; if r < t1 { t1 = r } }
        }
        return true
    }

    private static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// A spring for pins: up past full size, then settles.
    private static func spring(_ x: Double) -> Double { x >= 1 ? 1 : 1 - cos(x * .pi * 1.5) * pow(1 - x, 2) }

    /// Where each part stands `t` seconds in; t = infinity is the final still.
    static func frame(_ sc: Scene, at t: Double) -> [Frame] {
        sc.items.map { it in
            let x = t == .infinity ? 1 : clamp((t - it.start) / it.dur, 0, 1)
            let e = ease(x)
            var p = 0.0
            if it.pulse && t != .infinity && x >= 1 { p = 0.5 - 0.5 * cos((t - it.start - it.dur) / pulse * 2 * .pi) }
            return Frame(item: it, o: it.kind == "route" ? (x > 0 ? 1 : 0) : e, d: e,
                         s: it.kind == "pin" && it.grow ? spring(x) : 1, p: p)
        }
    }

    /// A label's lines when it may take `width` drawing units.
    static func wrap(_ label: String, width: Double, fs: Double) -> [String] {
        let per = max(4, Int((width / (fs * 0.55)).rounded(.down)))
        var lines: [String] = []
        var cur = ""
        for w in label.split(whereSeparator: \.isWhitespace).map(String.init) {
            if !cur.isEmpty && len(cur + " " + w) > per { lines.append(cur); cur = w } else { cur = cur.isEmpty ? w : cur + " " + w }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// The map in words, part by part in line order: for VoiceOver and
    /// anywhere that cannot draw.
    static func describe(_ sc: Scene) -> String {
        var bits: [String] = []
        for it in sc.items {
            let names = it.names.compactMap { $0 }
            switch it.kind {
            case "area":
                let what = !it.label.isEmpty ? it.label : !names.isEmpty ? names.joined(separator: ", ") : "An area"
                bits.append(!it.label.isEmpty && !names.isEmpty ? "\(what): \(names.joined(separator: ", "))" : what)
            case "pin": bits.append(it.label.isEmpty ? "A pin" : it.label)
            default:
                bits.append((it.label.isEmpty ? "A route" : it.label) + (names.count >= 2 ? ", " + names.joined(separator: " to ") : ""))
            }
        }
        let head = sc.title.isEmpty ? "" : "\(sc.title). "
        let tail = sc.caption.isEmpty ? "" : " \(sc.caption)"
        return "\(head)Map: \(bits.isEmpty ? "the world" : bits.joined(separator: "; ")).\(tail)"
    }

    /// Rings as an SVG path, written as map.mjs writes it (the tests compare them).
    static func path(_ rings: [[[Double]]]) -> String {
        rings.map { r in "M" + r.map { "\(num($0[0])) \(num($0[1]))" }.joined(separator: "L") + "Z" }.joined()
    }
}
