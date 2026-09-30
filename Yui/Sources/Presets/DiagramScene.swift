import Foundation
import YuiLines

// Diagram layout (DRAW-2, the app half of DRAW-1): a line-for-line port of the hub's
// site/lib/yl/diagram.mjs, so a flowchart, a state diagram and a sequence land in
// the same places on the phone as in the playground. Pure functions, no drawing:
// the patch the parser gives at `end` goes in (YLValue props: type, dir, nodes,
// edges, groups, actors, steps), boxes, lines and their reveal order come out.
// The drawing is static: parts come on in the order the Mermaid wrote them
// (`order`, DELAY seconds apart).

enum DiagramModel {
    static let delay = 0.22 // one node to the next, in seconds
    static let fit = 360.0 // a left-to-right chart wider than this draws top down
    private static let char = 7.4 // px per character at the 13px label size
    private static let pad = 8.0
    private static let row = 38.0

    // MARK: Input, read from the patch

    struct NodeIn { var id: String; var label: String?; var shape: String? }
    struct EdgeIn { var from: String; var to: String; var label: String?; var line: String?; var plain = false; var both = false }
    struct GroupIn { var id: String; var label: String?; var nodes: [String]; var parent: String? }
    struct GraphIn { var type = "flow"; var dir = "TD"; var nodes: [NodeIn] = []; var edges: [EdgeIn] = []; var groups: [GroupIn] = [] }
    struct ActorIn { var id: String; var label: String?; var actor = false }
    struct StepIn {
        var type: String
        var from = "", to = "", text = "", line: String?, head: String?, both = false
        var side = "", on: [String] = [], block = ""
    }
    struct SeqIn { var actors: [ActorIn] = []; var steps: [StepIn] = []; var numbered = false }

    private static func str(_ v: YLValue?) -> String? {
        switch v {
        case .string(let s)?: s
        case .number(let n)?: n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b)?: b ? "true" : "false"
        default: nil
        }
    }
    private static func list(_ v: YLValue?) -> [YLValue] {
        switch v {
        case .array(let a)?: a
        case nil, .null?: []
        case let x?: [x]
        }
    }
    private static func flag(_ v: YLValue?) -> Bool { v?.bool ?? false }

    static func graphIn(_ p: [String: YLValue]) -> GraphIn {
        var g = GraphIn()
        g.type = str(p["type"]) ?? "flow"
        g.dir = str(p["dir"]) ?? "TD"
        g.nodes = list(p["nodes"]).compactMap { v in
            guard let id = str(v["id"]) else { return nil }
            return NodeIn(id: id, label: str(v["label"]), shape: str(v["shape"]))
        }
        g.edges = list(p["edges"]).compactMap { v in
            guard let f = str(v["from"]), let t = str(v["to"]) else { return nil }
            return EdgeIn(from: f, to: t, label: str(v["label"]), line: str(v["line"]), plain: flag(v["plain"]), both: flag(v["both"]))
        }
        g.groups = list(p["groups"]).compactMap { v in
            guard let id = str(v["id"]) else { return nil }
            return GroupIn(id: id, label: str(v["label"]), nodes: list(v["nodes"]).compactMap { str($0) }, parent: str(v["in"]))
        }
        return g
    }

    static func seqIn(_ p: [String: YLValue]) -> SeqIn {
        var s = SeqIn()
        s.numbered = flag(p["numbered"])
        s.actors = list(p["actors"]).compactMap { v in
            guard let id = str(v["id"]) else { return nil }
            return ActorIn(id: id, label: str(v["label"]), actor: flag(v["actor"]))
        }
        s.steps = list(p["steps"]).compactMap { v in
            guard let t = str(v["type"]) else { return nil }
            var st = StepIn(type: t)
            st.from = str(v["from"]) ?? ""; st.to = str(v["to"]) ?? ""; st.text = str(v["text"]) ?? ""
            st.line = str(v["line"]); st.head = str(v["head"]); st.both = flag(v["both"])
            st.side = str(v["side"]) ?? ""; st.on = list(v["on"]).compactMap { str($0) }; st.block = str(v["block"]) ?? ""
            return st
        }
        return s
    }

    // MARK: Text

    /// A label broken into lines of at most `max` characters, on spaces.
    static func wrap(_ text: String?, _ max: Int = 20) -> [String] {
        let words = (text ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var out: [String] = []
        var cur = ""
        for w in words {
            if !cur.isEmpty && (cur + " " + w).utf16.count > max { out.append(cur); cur = w } else { cur = cur.isEmpty ? w : cur + " " + w }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.isEmpty ? [""] : out
    }
    static func widest(_ lines: [String]) -> Double { Double(lines.map { $0.utf16.count }.max() ?? 0) * char }

    // MARK: Flowchart and state

    struct Node {
        var id: String; var label: String?; var shape: String?
        var order: Int; var w: Double; var h: Double; var lines: [String]
        var cx = 0.0, cy = 0.0
    }
    struct Edge {
        var from: String, to: String, label: String?, line: String?, plain: Bool, both: Bool
        var i: Int
        var pts: [[Double]]
        var mid: [Double]
        var back: Bool
        var order: Int
    }
    struct Box { var id: String; var x: Double; var y: Double; var w: Double; var h: Double; var label: String? }
    struct Graph {
        var w = 0.0, h = 0.0
        var nodes: [Node] = [], edges: [Edge] = [], groups: [Box] = []
        var dir = "TD"
        var turned = false
    }

    private static func sizeOf(_ n: NodeIn, state: Bool) -> (w: Double, h: Double, lines: [String]) {
        let isMark = state && (n.id.hasPrefix("_start") || n.id.hasPrefix("_end"))
        let lines = wrap(n.label ?? (isMark ? "" : n.id), 18)
        let tw = widest(lines)
        let th = Double(lines.count) * 17
        var w = Swift.max(56, tw + 28), h = Swift.max(36, th + 18)
        switch n.shape {
        case "start": return (16, 16, [])
        case "end": return (22, 22, [])
        case "choice": return (30, 30, [])
        case "fork", "join": return (70, 8, [])
        case "diamond": w = tw * 1.5 + 34; h = th * 1.5 + 30
        case "circle", "double": w = Swift.max(tw + 16, th + 22) + (n.shape == "double" ? 10 : 0); h = w
        case "hexagon": w += 24
        case "slant", "flag": w += 22
        case "cylinder": h += 12
        case "subroutine": w += 12
        default: break
        }
        return (jsRound(w), jsRound(h), lines)
    }

    /// Math.round: halves go up.
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// Ranks by longest path after reversing the edges that close a cycle.
    private static func ranks(_ ids: [String], _ edges: [EdgeIn]) -> (rank: [String: Int], back: Set<String>) {
        var out: [String: [String]] = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
        for e in edges where e.from != e.to { out[e.from]?.append(e.to) }
        var state: [String: Int] = [:]
        var back = Set<String>()
        func visit(_ u: String) {
            state[u] = 1
            for v in out[u] ?? [] {
                if state[v] == 1 { back.insert("\(u)>\(v)") } else if state[v] == nil { visit(v) }
            }
            state[u] = 2
        }
        for id in ids where state[id] == nil { visit(id) }
        let fwd = edges.filter { $0.from != $0.to }.map { e in back.contains("\(e.from)>\(e.to)") ? (from: e.to, to: e.from) : (from: e.from, to: e.to) }
        var rank = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for _ in 0..<ids.count {
            var moved = false
            for e in fwd where rank[e.to]! < rank[e.from]! + 1 { rank[e.to] = rank[e.from]! + 1; moved = true }
            if !moved { break }
        }
        return (rank, back)
    }

    /// Reorders each rank by the mean place of its neighbours, a few sweeps.
    private static func order(_ layers: inout [[String]], _ edges: [EdgeIn]) {
        var pos: [String: Int] = [:]
        for l in layers { for (i, id) in l.enumerated() { pos[id] = i } }
        func nb(_ id: String, _ dir: Int) -> [String] {
            edges.filter { dir > 0 ? $0.to == id : $0.from == id }.map { dir > 0 ? $0.from : $0.to }.filter { pos[$0] != nil }
        }
        for s in 0..<4 {
            let down = s % 2 == 0
            let seq = down ? Array(layers.indices) : layers.indices.reversed()
            for li in seq {
                let want = down ? li - 1 : li + 1
                var keyed: [(id: String, k: Double, n: Int)] = []
                for (i, id) in layers[li].enumerated() {
                    let ns = nb(id, down ? 1 : -1).filter { x in layers.firstIndex(where: { $0.contains(x) }) == want }
                    let k = ns.isEmpty ? Double(i) : Double(ns.reduce(0) { $0 + pos[$1]! }) / Double(ns.count)
                    keyed.append((id, k, i))
                }
                keyed.sort { $0.k != $1.k ? $0.k < $1.k : $0.n < $1.n }
                layers[li] = keyed.map(\.id)
                for (i, id) in layers[li].enumerated() { pos[id] = i }
            }
        }
    }

    private static func cubic(_ p0: [Double], _ p1: [Double], _ p2: [Double], _ p3: [Double], _ t: Double) -> [Double] {
        let m = 1 - t
        return (0..<2).map { k in m * m * m * p0[k] + 3 * m * m * t * p1[k] + 3 * m * t * t * p2[k] + t * t * t * p3[k] }
    }

    /// A flowchart or state diagram to boxes. A left-to-right (or right-to-left) chart
    /// wider than a phone draws top down instead, so its labels stay readable.
    static func layoutGraph(_ g: GraphIn, fit: Double = DiagramModel.fit) -> Graph {
        let first = place(g)
        if first.w > fit && (g.dir == "LR" || g.dir == "RL") {
            var t = g; t.dir = "TD"
            var down = place(t)
            if down.w < first.w { down.turned = true; return down }
        }
        return first
    }

    private static func place(_ g: GraphIn) -> Graph {
        let state = g.type == "state"
        var nodes = g.nodes.enumerated().map { i, n -> Node in
            let s = sizeOf(n, state: state)
            return Node(id: n.id, label: n.label, shape: n.shape, order: i, w: s.w, h: s.h, lines: s.lines)
        }
        var at: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { at[n.id] = i } // a repeated id: the last one, as a Map does
        let edges = g.edges.filter { at[$0.from] != nil && at[$0.to] != nil }
        let dir = ["TD", "TB", "BT", "LR", "RL"].contains(g.dir) ? g.dir : "TD"
        let horiz = dir == "LR" || dir == "RL"
        func len(_ n: Node) -> Double { horiz ? n.w : n.h }
        func wid(_ n: Node) -> Double { horiz ? n.h : n.w }

        let (rank, back) = ranks(nodes.map(\.id), edges)
        var layers: [[String]] = []
        for n in nodes {
            let r = rank[n.id]!
            while layers.count <= r { layers.append([]) }
            layers[r].append(n.id)
        }
        order(&layers, edges)

        let rankGap = horiz ? 64.0 : 46.0, crossGap = 26.0
        var start: [Double] = [], depth: [Double] = []
        var r0 = 0.0
        for l in layers {
            let d = Swift.max(0, l.map { len(nodes[at[$0]!]) }.max() ?? 0)
            start.append(r0); depth.append(d)
            r0 += d + rankGap
        }
        let spans = layers.map { l in l.reduce(0.0) { $0 + wid(nodes[at[$1]!]) } + Double(Swift.max(0, l.count - 1)) * crossGap }
        let cross = Swift.max(0, spans.max() ?? 0)
        for (i, l) in layers.enumerated() {
            var c = (cross - spans[i]) / 2
            for id in l {
                let k = at[id]!
                let rc = start[i] + depth[i] / 2, cc = c + wid(nodes[k]) / 2
                nodes[k].cx = horiz ? rc : cc
                nodes[k].cy = horiz ? cc : rc
                c += wid(nodes[k]) + crossGap
            }
        }
        let total = Swift.max(0, r0 - rankGap)
        if dir == "BT" { for k in nodes.indices { nodes[k].cy = total - nodes[k].cy } }
        if dir == "RL" { for k in nodes.indices { nodes[k].cx = total - nodes[k].cx } }

        var out: [Edge] = edges.enumerated().map { i, e in
            let a = nodes[at[e.from]!], b = nodes[at[e.to]!]
            let selfLoop = e.from == e.to
            let forward: Bool = horiz ? (dir == "LR" ? b.cx > a.cx : b.cx < a.cx) : (dir == "BT" ? b.cy < a.cy : b.cy > a.cy)
            var p0: [Double], p1: [Double], p2: [Double], p3: [Double]
            if selfLoop {
                let x = a.cx + a.w / 2, y = a.cy
                p0 = [x, y - 6]; p1 = [x + 34, y - 26]; p2 = [x + 34, y + 26]; p3 = [x, y + 6]
            } else if forward {
                let s: Double = horiz ? (b.cx > a.cx ? 1 : -1) : (b.cy > a.cy ? 1 : -1)
                if horiz {
                    p0 = [a.cx + s * a.w / 2, a.cy]; p3 = [b.cx - s * b.w / 2, b.cy]
                    let k = Swift.max(24, abs(p3[0] - p0[0]) / 2)
                    p1 = [p0[0] + s * k, p0[1]]; p2 = [p3[0] - s * k, p3[1]]
                } else {
                    p0 = [a.cx, a.cy + s * a.h / 2]; p3 = [b.cx, b.cy - s * b.h / 2]
                    let k = Swift.max(20, abs(p3[1] - p0[1]) / 2)
                    p1 = [p0[0], p0[1] + s * k]; p2 = [p3[0], p3[1] - s * k]
                }
            } else if horiz {
                let y = Swift.max(a.cy + a.h / 2, b.cy + b.h / 2) + 34
                p0 = [a.cx, a.cy + a.h / 2]; p3 = [b.cx, b.cy + b.h / 2]; p1 = [a.cx, y]; p2 = [b.cx, y]
            } else {
                let x = Swift.max(a.cx + a.w / 2, b.cx + b.w / 2) + 38
                p0 = [a.cx + a.w / 2, a.cy]; p3 = [b.cx + b.w / 2, b.cy]; p1 = [x, a.cy]; p2 = [x, b.cy]
            }
            let mid = cubic(p0, p1, p2, p3, 0.5)
            return Edge(from: e.from, to: e.to, label: e.label, line: e.line, plain: e.plain, both: e.both, i: i,
                        pts: [p0, p1, p2, p3], mid: mid, back: back.contains("\(e.from)>\(e.to)") || selfLoop,
                        order: Swift.max(a.order, b.order))
        }

        // Groups: a box round the members, the outer ones round the inner.
        var boxes: [String: Box?] = [:]
        var busy = Set<String>()
        func boxOf(_ gr: GroupIn) -> Box? {
            if let hit = boxes[gr.id] { return hit }
            if busy.contains(gr.id) { return nil }
            busy.insert(gr.id)
            var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
            for id in gr.nodes {
                guard let k = at[id] else { continue }
                let n = nodes[k]
                x0 = Swift.min(x0, n.cx - n.w / 2); x1 = Swift.max(x1, n.cx + n.w / 2)
                y0 = Swift.min(y0, n.cy - n.h / 2); y1 = Swift.max(y1, n.cy + n.h / 2)
            }
            for c in g.groups where c.parent == gr.id {
                guard let b = boxOf(c) else { continue }
                x0 = Swift.min(x0, b.x); x1 = Swift.max(x1, b.x + b.w)
                y0 = Swift.min(y0, b.y); y1 = Swift.max(y1, b.y + b.h)
            }
            let b: Box? = x0.isFinite ? Box(id: gr.id, x: x0 - 14, y: y0 - 30, w: x1 - x0 + 28, h: y1 - y0 + 44, label: gr.label) : nil
            boxes[gr.id] = .some(b)
            busy.remove(gr.id)
            return b
        }
        var gboxes = g.groups.compactMap(boxOf)

        // Bounds, then everything moves so the drawing starts at PAD.
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        func take(_ x: Double, _ y: Double) { x0 = Swift.min(x0, x); x1 = Swift.max(x1, x); y0 = Swift.min(y0, y); y1 = Swift.max(y1, y) }
        for n in nodes { take(n.cx - n.w / 2, n.cy - n.h / 2); take(n.cx + n.w / 2, n.cy + n.h / 2) }
        for e in out {
            for p in e.pts { take(p[0], p[1]) }
            if let l = e.label, !l.isEmpty {
                let hw = widest(wrap(l, 16))
                take(e.mid[0] - hw / 2 - 6, e.mid[1] - 12); take(e.mid[0] + hw / 2 + 6, e.mid[1] + 12)
            }
        }
        for b in gboxes { take(b.x, b.y); take(b.x + b.w, b.y + b.h) }
        if !x0.isFinite { return Graph() }
        let dx = pad - x0, dy = pad - y0
        for k in nodes.indices { nodes[k].cx += dx; nodes[k].cy += dy }
        for k in out.indices {
            out[k].pts = out[k].pts.map { [$0[0] + dx, $0[1] + dy] }
            out[k].mid = [out[k].mid[0] + dx, out[k].mid[1] + dy]
        }
        for k in gboxes.indices { gboxes[k].x += dx; gboxes[k].y += dy }
        return Graph(w: (x1 - x0 + pad * 2).rounded(.up), h: (y1 - y0 + pad * 2).rounded(.up),
                     nodes: nodes, edges: out, groups: gboxes, dir: dir, turned: false)
    }

    // MARK: Sequence

    struct Actor { var id: String; var label: String?; var actor: Bool; var lines: [String]; var x = 0.0, w = 0.0, h = 0.0 }
    struct Item {
        var kind: String // msg, note, block
        var order: Int
        var y = 0.0, h = 0.0
        // msg
        var step = StepIn(type: "")
        var x1 = 0.0, x2 = 0.0, selfMsg = false, textY = 0.0, tw = 0.0, n = 0
        var lines: [String] = []
        // note
        var x = 0.0, w = 0.0
        // block
        var block = "", text = ""
        var divs: [(y: Double, text: String)] = []
        var depth = 0
    }
    struct Sequence {
        var w = 0.0, h = 0.0, dx = 0.0
        var actors: [Actor] = [], items: [Item] = []
        var life = [0.0, 0.0], span = [0.0, 0.0]
        var numbered = false
    }

    static func layoutSequence(_ g: SeqIn) -> Sequence {
        var actors = g.actors.map { Actor(id: $0.id, label: $0.label, actor: $0.actor, lines: wrap($0.label ?? $0.id, 14)) }
        let n = actors.count
        if n == 0 { return Sequence() }
        var idx: [String: Int] = [:]
        for (i, a) in actors.enumerated() { idx[a.id] = i }
        // Steps naming an actor nobody declared are left out (the parser adds every speaker).
        let steps = g.steps.filter { s in
            switch s.type {
            case "msg": idx[s.from] != nil && idx[s.to] != nil
            case "note": !s.on.isEmpty && s.on.allSatisfy { idx[$0] != nil }
            default: true
            }
        }
        let wA = actors.map { Swift.max(84, widest($0.lines) + 24) }
        var gap = (0..<n).map { i in i < n - 1 ? Swift.max(40, (wA[i] + wA[i + 1]) / 2 + 18) : 0 }
        for s in steps where s.type == "msg" || s.type == "note" {
            let ids = s.type == "msg" ? [s.from, s.to] : s.on
            let lo = ids.map { idx[$0]! }.min()!, hi = ids.map { idx[$0]! }.max()!
            let need = widest(wrap(s.text, 34)) + 28
            if hi == lo { continue }
            let have = gap[lo..<hi].reduce(0, +)
            if have < need { for i in lo..<hi { gap[i] += (need - have) / Double(hi - lo) } }
        }
        var xs: [Double] = []
        var x = wA[0] / 2
        for i in 0..<n { xs.append(x); x += gap[i]; actors[i].x = xs[i]; actors[i].w = wA[i] }
        let head = Double(actors.map { $0.lines.count }.max()!) * 17 + 18
        for i in 0..<n { actors[i].h = head }
        let left = actors.map { $0.x - $0.w / 2 }.min()!
        let right = actors.map { $0.x + $0.w / 2 }.max()!

        var items: [Item] = []
        var y = head + 24
        var num = 0
        struct Open { var y0: Double; var order: Int; var block: String; var text: String; var divs: [(y: Double, text: String)] }
        var stack: [Open] = []
        for (order, s) in steps.enumerated() {
            switch s.type {
            case "msg":
                let a = xs[idx[s.from]!], b = xs[idx[s.to]!]
                let lines = wrap(s.text, 34)
                let h = Swift.max(row, Double(lines.count) * 16 + 22)
                let selfMsg = a == b
                var it = Item(kind: "msg", order: order)
                it.step = s; it.x1 = a; it.x2 = b; it.selfMsg = selfMsg; it.y = y + h - 12; it.textY = y + 4
                it.lines = lines; it.tw = widest(lines); it.depth = stack.count
                if g.numbered { num += 1; it.n = num }
                items.append(it)
                y += selfMsg ? h + 14 : h
            case "note":
                let lines = wrap(s.text, 28)
                let xsOn = s.on.map { xs[idx[$0]!] }
                let w = Swift.max(90, widest(lines) + 20)
                var nx: Double, nw = w
                if s.side == "over" {
                    let lo = xsOn.min()!, hi = xsOn.max()!
                    nw = Swift.max(w, hi - lo + 40)
                    nx = (lo + hi) / 2 - nw / 2
                } else if s.side == "right" { nx = xsOn[0] + 12 } else { nx = xsOn[0] - 12 - w }
                let h = Double(lines.count) * 16 + 14
                var it = Item(kind: "note", order: order)
                it.step = s; it.x = nx; it.w = nw; it.y = y; it.h = h; it.lines = lines
                items.append(it)
                y += h + 12
            case "open":
                stack.append(Open(y0: y, order: order, block: s.block, text: s.text, divs: []))
                y += 26
            case "else":
                if !stack.isEmpty { stack[stack.count - 1].divs.append((y, s.text)) }
                y += 26
            case "close":
                if let top = stack.popLast() {
                    var it = Item(kind: "block", order: top.order)
                    it.y = top.y0; it.h = y - top.y0 + 4; it.block = top.block; it.text = top.text; it.divs = top.divs; it.depth = stack.count
                    items.append(it)
                }
                y += 12
            default: break
            }
        }
        // A block left open at the end of the input closes there.
        while let top = stack.popLast() {
            var it = Item(kind: "block", order: top.order)
            it.y = top.y0; it.h = y - top.y0 + 4; it.block = top.block; it.text = top.text; it.divs = top.divs; it.depth = stack.count
            items.append(it)
        }
        let bottom = y + 10
        let padX = 26.0
        let notes = items.filter { $0.kind == "note" }
        let x0 = ([left - padX] + notes.map { $0.x - 8 }).min()!
        let x1 = ([right + padX] + notes.map { $0.x + $0.w + 8 }).max()!
        return Sequence(w: (x1 - x0 + pad * 2).rounded(.up), h: (bottom + pad).rounded(.up), dx: pad - x0, actors: actors, items: items,
                        life: [head, bottom], span: [left - 14, right + 14], numbered: g.numbered)
    }

    // MARK: Reveal clock and spoken text

    /// When the last part has finished coming on, in seconds.
    static func total(graph g: Graph) -> Double {
        let last = Swift.max(g.nodes.map { Double($0.order) * delay + 0.4 }.max() ?? 0,
                             g.edges.map { Double($0.order) * delay + 0.14 + 0.4 }.max() ?? 0)
        return last
    }
    static func total(sequence s: Sequence) -> Double {
        (s.items.map { Double($0.order) * delay * 1.4 + 0.2 + 0.4 }.max() ?? 0)
    }

    /// The part's opacity and rise at time `t`, `at` seconds after the start: 0 before, 1 after 0.4 s.
    static func progress(_ t: Double, at: Double) -> Double { Swift.min(1, Swift.max(0, (t - at) / 0.4)) }

    static func label(_ n: NodeIn) -> String { n.label ?? n.id }

    /// What VoiceOver reads: the kind, the parts in the order they were written, then the links.
    static func describe(_ c: [String: YLValue]) -> String {
        let type = str(c["type"]) ?? ""
        var parts: [String] = []
        if let t = str(c["title"]), !t.isEmpty { parts.append(t + ".") }
        switch type {
        case "flow", "state":
            let g = graphIn(c)
            let name = { (id: String) -> String in
                g.nodes.last(where: { $0.id == id }).map { n in
                    n.label ?? (n.shape == "start" ? "start" : n.shape == "end" ? "end" : n.id)
                } ?? id
            }
            let shown = g.nodes.map { n -> String in
                switch n.shape {
                case "start": return "start"
                case "end": return "end"
                default: return n.label ?? n.id
                }
            }
            parts.append("\(type == "state" ? "State diagram" : "Flowchart"): \(shown.joined(separator: ", ")).")
            let links = g.edges.map { e -> String in
                let l = e.label.flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
                return "\(name(e.from)) to \(name(e.to))\(l)"
            }
            if !links.isEmpty { parts.append(links.joined(separator: "; ") + ".") }
        case "sequence":
            let s = seqIn(c)
            let who = { (id: String) -> String in s.actors.first(where: { $0.id == id }).map { $0.label ?? $0.id } ?? id }
            parts.append("Sequence diagram: \(s.actors.map { $0.label ?? $0.id }.joined(separator: ", ")).")
            var num = 0
            var lines: [String] = []
            for st in s.steps {
                switch st.type {
                case "msg":
                    num += 1
                    lines.append("\(s.numbered ? "\(num). " : "")\(who(st.from)) to \(who(st.to)): \(st.text)")
                case "note": lines.append("Note, \(st.on.map(who).joined(separator: " and ")): \(st.text)")
                case "open": lines.append("\(st.block)\(st.text.isEmpty ? "" : " " + st.text)")
                default: break
                }
            }
            if !lines.isEmpty { parts.append(lines.joined(separator: "; ") + ".") }
        default:
            parts.append("Diagram, source: " + (str(c["source"]) ?? "") )
        }
        if let cap = str(c["caption"]), !cap.isEmpty { parts.append(cap) }
        return parts.joined(separator: " ")
    }
}
