import Foundation

// `diagram` (spec YL.md, diagram): a Mermaid block between `diagram` and `end`,
// drawn static. Port of the diagram section of the JS reference
// (`site/lib/yl/yl.mjs`, dgmLine/diagramGraph and the Mermaid statement reader
// it shares with `flow`). The Swift parser has no `flow` reader, so this is the
// reader for diagram only: flowcharts (node shapes, links, labels, chains, `&`,
// subgraphs), sequenceDiagram and stateDiagram. Any other Mermaid type keeps
// only its `source`. The closing `end` gives one patch onto the diagram's add:
// { type, ...the drawing, source }. See "Reading the draws" in Presets.swift for how a
// view reads it.

private let W = "A-Za-z0-9_"
private let diagramHeaderRE = JSRegex(#"^(flowchart|graph|sequenceDiagram|stateDiagram(?:-v2)?)(?=[\#(JSWS);]|$)"#)
private let diagramOtherRE = JSRegex(#"^(classDiagram(?:-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|C4[\#(W)]*|sankey-beta|xychart-beta|block-beta)(?=[\#(JSWS)]|$)"#)
let flowHeaderRE = JSRegex(#"^(flowchart|graph)([\#(JSWS)]|$)"#)
let flowSkipRE = JSRegex(#"^(classDef|class|style|linkStyle|click|direction|accTitle|accDescr)([\#(JSWS)]|:|$)"#)
let textLinkRE = JSRegex(#"^[\#(JSWS)]*<?(?:--|==|-\.)(?![->=.])[\#(JSWS)]*(.*?)[\#(JSWS)]*(?:-{2,}>|={2,}>|\.-+>|-{3,}|={3,}|\.-+)(?=[\#(JSWS)\#(W)])"#)
let linkRE = JSRegex(#"^[\#(JSWS)]*(<?)(-{2,}>|-{3,}|={2,}>|={3,}|-\.+->|-\.+-|--[ox]|==[ox]|~{3,})"#)
let pipeRE = JSRegex(#"^[\#(JSWS)]*\|([^|]*)\|"#)
private let subgraphRE1 = JSRegex(#"^subgraph[\#(JSWS)]+([\#(W)]+)[\#(JSWS)]*(?:\[(.*)\])?[\#(JSWS)]*$"#)
private let subgraphRE2 = JSRegex(#"^subgraph[\#(JSWS)]+(.+?)[\#(JSWS)]*$"#)
let endRE = JSRegex(#"^end[\#(JSWS)]*;?$"#)

private let seqPartRE = JSRegex(#"^(participant|actor)[\#(JSWS)]+([\#(W).]+)(?:[\#(JSWS)]+as[\#(JSWS)]+(.+))?$"#)
private let seqAutoRE = JSRegex(#"^autonumber([\#(JSWS)]|$)"#)
private let seqSkipRE = JSRegex(#"^(activate|deactivate|title|box|create|destroy|link|links|properties|details)([\#(JSWS)]|$)"#)
private let seqNoteRE = JSRegex(#"(?i)^Note[\#(JSWS)]+(right of|left of|over)[\#(JSWS)]+([\#(W).]+)(?:[\#(JSWS)]*,[\#(JSWS)]*([\#(W).]+))?[\#(JSWS)]*:[\#(JSWS)]*(.*)$"#)
private let seqBlockRE = JSRegex(#"^(loop|alt|opt|par|critical|break|rect)(?:[\#(JSWS)]+(.*))?$"#)
private let seqElseRE = JSRegex(#"^(else|and|option)(?:[\#(JSWS)]+(.*))?$"#)
private let seqMsgRE = JSRegex(#"^([\#(W).]+)[\#(JSWS)]*(<<-->>|<<->>|-->>|->>|--\)|-\)|--x|-x|-->|->)[\#(JSWS)]*([+-]?)[\#(JSWS)]*([\#(W).]+)[\#(JSWS)]*(?::[\#(JSWS)]*(.*))?$"#)
private let seqHead: [String: String] = [">>": "arrow", ">": "none", ")": "async", "x": "cross"]

private let stateNoteRE = JSRegex(#"(?i)^note[\#(JSWS)]"#)
private let stateSkipRE = JSRegex(#"^(direction|classDef|class|style|click|accTitle|accDescr|hide)([\#(JSWS)]|$)"#)
private let stateDirRE = JSRegex(#"^direction[\#(JSWS)]+([\#(W)]+)"#)
private let stateDeclRE = JSRegex(#"^state[\#(JSWS)]+(?:"([^"]*)"[\#(JSWS)]+as[\#(JSWS)]+([\#(W)]+)|([\#(W)]+))[\#(JSWS)]*(<<(?:choice|fork|join)>>)?[\#(JSWS)]*(\{)?$"#)
private let stateEdgeRE = JSRegex(#"^(\[\*\]|[\#(W)]+)[\#(JSWS)]*(<?-->)[\#(JSWS)]*(\[\*\]|[\#(W)]+)[\#(JSWS)]*(?::[\#(JSWS)]*(.*))?$"#)
private let stateLabelRE = JSRegex(#"^([\#(W)]+)[\#(JSWS)]*:[\#(JSWS)]*(.+)$"#)
private let endNoteRE = JSRegex(#"(?i)^end[\#(JSWS)]+note$"#)

private let nodeShapes: [(String, [String])] = [
    ("(((", [")))"]), ("([", ["])"]), ("[[", ["]]"]), ("[(", [")]"]), ("((", ["))"]), ("{{", ["}}"]),
    ("[/", ["/]", "\\]"]), ("[\\", ["\\]", "/]"]), ("[", ["]"]), ("(", [")"]), ("{", ["}"]), (">", ["]"]),
]
private let nodeShapeName: [String: String] = [
    "(((": "double", "([": "stadium", "[[": "subroutine", "[(": "cylinder", "((": "circle", "{{": "hexagon",
    "[/": "slant", "[\\": "slant", "(": "round", "{": "diamond", ">": "flag",
]

// MARK: - Small string helpers (JS semantics: trim, UTF-16 free)

func sc(_ s: String) -> Scalars { Array(s.unicodeScalars) }
func str<S: Sequence>(_ a: S) -> String where S.Element == Unicode.Scalar { String(String.UnicodeScalarView(a)) }
func dgTrim(_ s: String) -> String { str(trimJS(sc(s))) }
func dgTrimStart(_ s: String) -> String { str(sc(s).drop(while: isSpace)) }
func dropping(_ s: String, _ matched: String) -> String { str(s.unicodeScalars.dropFirst(matched.unicodeScalars.count)) }
func isWordChar(_ c: Unicode.Scalar) -> Bool { isAlpha(c) || isDigit(c) || c == "_" }

private func indexOf(_ hay: Scalars, _ needle: String, _ from: Int) -> Int? {
    let n = sc(needle)
    guard !n.isEmpty, from >= 0, hay.count >= n.count else { return nil }
    var i = from
    while i + n.count <= hay.count {
        if Array(hay[i..<i + n.count]) == n { return i }
        i += 1
    }
    return nil
}

private extension JSRegex {
    /// `s.replace(re, fn)` with every match replaced; `fn` gets the capture groups.
    func replacing(in s: String, _ fn: ([String?]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += fn((0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            })
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

private let brRE = JSRegex(#"(?i)<br[\#(JSWS)]*/?>"#)
private let entityRE = JSRegex(#"#(quot|amp|lt|gt|nbsp|35);"#)
private let numEntityRE = JSRegex(#"#([0-9]+);"#)

/// Mermaid label text: quotes, markdown backticks, entity codes and <br> undone.
func unlabel(_ s: String) -> String {
    var t = dgTrim(s)
    if t.unicodeScalars.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = str(sc(t).dropFirst().dropLast()) }
    if t.unicodeScalars.count >= 2, t.hasPrefix("`"), t.hasSuffix("`") { t = str(sc(t).dropFirst().dropLast()) }
    t = brRE.replacing(in: t) { _ in " " }
    t = entityRE.replacing(in: t) { g in
        switch g[1]! {
        case "quot": return "\""
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default: return "#"
        }
    }
    t = numEntityRE.replacing(in: t) { g in
        let n = (Int(g[1]!) ?? 0) & 0xFFFF
        return Unicode.Scalar(UInt32(n)).map { String(Character($0)) } ?? "\u{FFFD}"
    }
    return dgTrim(t)
}

/// Splits a Mermaid line on ";" outside quotes and brackets.
func statements(_ line: String) -> [String] {
    var out: [String] = []
    var cur = Scalars()
    var q = false
    var depth = 0
    for c in line.unicodeScalars {
        if c == "\"" { q.toggle() }
        else if !q, "[({".unicodeScalars.contains(c) { depth += 1 }
        else if !q, "])}".unicodeScalars.contains(c) { depth = max(0, depth - 1) }
        if c == ";", !q, depth == 0 { out.append(str(cur)); cur = [] } else { cur.append(c) }
    }
    out.append(str(cur))
    return out.map(dgTrim).filter { !$0.isEmpty }
}

struct ReadNode {
    var id: String
    var label: String?
    var shape: String?
    var rest: String = ""
}

/// Reads one node at the start of `s`: id, then an optional shape with a label.
func readNode(_ s: String) -> ReadNode? {
    let u = sc(s)
    var i = 0
    while i < u.count, isWordChar(u[i]) { i += 1 }
    if i == 0 { return nil }
    var node = ReadNode(id: str(u[0..<i]))
    var rest = Array(u[i...])
    if let (open, closers) = nodeShapes.first(where: { rest.starts(with: sc($0.0)) }) {
        node.shape = nodeShapeName[open]
        let body = Array(rest[sc(open).count...])
        var end = -1, len = 0
        var from = 0
        if body.drop(while: isSpace).first == "\"" {
            let q = indexOf(body, "\"", 0) ?? -1
            from = (indexOf(body, "\"", q + 1) ?? -1) + 1
        }
        for c in closers {
            if let k = indexOf(body, c, max(0, from)), end < 0 || k < end { end = k; len = sc(c).count }
        }
        if end < 0 { return nil }
        node.label = unlabel(str(body[0..<end]))
        rest = Array(body[(end + len)...])
    }
    // rest.replace(/^:::\w+/, "")
    if rest.starts(with: sc(":::")) {
        var j = 3
        while j < rest.count, isWordChar(rest[j]) { j += 1 }
        if j > 3 { rest = Array(rest[j...]) }
    }
    node.rest = str(rest)
    return node
}

/// A node, or several joined with "&".
func readNodes(_ s: String) -> (nodes: [ReadNode], rest: String)? {
    var out: [ReadNode] = []
    var rest = dgTrimStart(s)
    while true {
        guard let n = readNode(rest) else { return out.isEmpty ? nil : (out, rest) }
        out.append(n)
        rest = n.rest
        let u = sc(rest)
        var j = 0
        while j < u.count, isSpace(u[j]) { j += 1 }
        guard j < u.count, u[j] == "&" else { return (out, rest) }
        j += 1
        while j < u.count, isSpace(u[j]) { j += 1 }
        rest = str(u[j...])
    }
}

// MARK: - The reader's state

struct YLDiagramReader: Sendable {
    enum Kind { case flow, sequence, state, other }

    var id: String
    var screen: String
    var src: [String] = []
    var kind: Kind?
    var dir = "TD"

    // flow and state
    private var nodes: [(id: String, label: String?, shape: String?)] = []
    private var edges: [YLValue] = []
    private var groups: [(id: String, label: String?, nodes: [String], parent: String?)] = []
    private var stack: [Int] = []
    private var depth = 0
    private var note = false
    // sequence
    private var actors: [(id: String, label: String?, actor: Bool)] = []
    private var steps: [YLValue] = []
    private var numbered = false
    private var openBlocks = 0

    init(id: String, screen: String) { self.id = id; self.screen = screen }

    /// Starts the reader once the header is known.
    mutating func start(_ header: String) {
        guard let h = diagramHeaderRE.match(header) else { kind = .other; return }
        let words = header.split(whereSeparator: { $0.unicodeScalars.allSatisfy(isSpace) })
        var d = words.count > 1 ? String(words[1]) : "TD"
        if d.hasSuffix(";") { d.removeLast() }
        dir = d.uppercased()
        switch h[1]! {
        case "flowchart", "graph": kind = .flow
        case "sequenceDiagram": kind = .sequence
        default: kind = .state
        }
    }

    // MARK: nodes

    private mutating func upsert(_ id: String, label: String?, shape: String?) {
        if let i = nodes.firstIndex(where: { $0.id == id }) {
            if let label { nodes[i].label = label }
            if let shape { nodes[i].shape = shape }
        } else {
            nodes.append((id, label, shape))
        }
        // A subgraph (or composite state) holds the nodes first written inside it.
        if let top = stack.last, !groups.contains(where: { $0.nodes.contains(id) }) { groups[top].nodes.append(id) }
    }

    private mutating func openGroup(id: String, label: String?) {
        groups.append((id, label, [], stack.last.map { groups[$0].id }))
        stack.append(groups.count - 1)
    }

    private func edgeValue(from: String, to: String, label: String? = nil, extra: [String: YLValue] = [:]) -> YLValue {
        var e: [String: YLValue] = ["from": .string(from), "to": .string(to)]
        if let label, !label.isEmpty { e["label"] = .string(label) }
        return .object(e.merging(extra) { $1 })
    }

    // MARK: flow

    private mutating func flowStatement(_ t: String) {
        if t.isEmpty || t.hasPrefix("%%") { return }
        if t.hasPrefix("subgraph"), t == "subgraph" || t.unicodeScalars.dropFirst(8).first.map(isSpace) == true {
            depth += 1
            let m = subgraphRE1.match(t) ?? subgraphRE2.match(t)
            let label = m.map { unlabel($0[2] ?? $0[1]!) } ?? ""
            let plain = m.flatMap { $0[1] }.map { !$0.isEmpty && sc($0).allSatisfy(isWordChar) } ?? false
            openGroup(id: plain ? m![1]! : "g\(groups.count + 1)", label: label.isEmpty ? nil : label)
            return
        }
        if flowSkipRE.match(t) != nil || flowHeaderRE.match(t) != nil { return }
        for st in statements(t) {
            guard var g = readNodes(st) else { continue }
            for n in g.nodes { upsert(n.id, label: n.label, shape: n.shape) }
            while true {
                var rest = g.rest
                var label: String?
                var hidden = false, both = false
                var how = ""
                if let tl = textLinkRE.match(rest) {
                    label = tl[1]
                    var t0 = dgTrim(tl[0]!)
                    both = t0.hasPrefix("<")
                    if both { t0.removeFirst() }
                    let last = str(sc(t0).reversed().prefix(while: { !isSpace($0) }).reversed())
                    how = str(sc(t0).prefix(2)) + last
                    rest = dropping(rest, tl[0]!)
                } else {
                    guard let l = linkRE.match(rest) else { break }
                    how = l[2]!
                    both = l[1] == "<"
                    hidden = how.hasPrefix("~")
                    rest = dropping(rest, l[0]!)
                    if let p = pipeRE.match(rest) { label = p[1]; rest = dropping(rest, p[0]!) }
                }
                guard let to = readNodes(rest) else { break }
                for n in to.nodes { upsert(n.id, label: n.label, shape: n.shape) }
                if !hidden {
                    var extra: [String: YLValue] = [:]
                    if how.contains("=") { extra["line"] = .string("thick") }
                    else if how.contains(".") { extra["line"] = .string("dash") }
                    if !how.hasSuffix(">") { extra["plain"] = .bool(true) }
                    if both { extra["both"] = .bool(true) }
                    let text = label.map(unlabel) ?? ""
                    for a in g.nodes {
                        for b in to.nodes { edges.append(edgeValue(from: a.id, to: b.id, label: text, extra: extra)) }
                    }
                }
                g = to
            }
        }
    }

    // MARK: sequence

    private mutating func seqActor(_ id: String, _ label: String = "", actor: Bool = false) {
        if let i = actors.firstIndex(where: { $0.id == id }) {
            if !label.isEmpty { actors[i].label = label }
            if actor { actors[i].actor = true }
        } else {
            actors.append((id, label.isEmpty ? nil : label, actor))
        }
    }

    private mutating func seqLine(_ t: String) {
        if let m = seqPartRE.match(t) {
            seqActor(m[2]!, m[3].map(unlabel) ?? "", actor: m[1] == "actor")
            return
        }
        if seqAutoRE.match(t) != nil { numbered = true; return }
        if seqSkipRE.match(t) != nil { return }
        if let m = seqNoteRE.match(t) {
            let on = [m[2]!] + (m[3].map { [$0] } ?? [])
            on.forEach { seqActor($0) }
            var side = m[1]!.lowercased()
            if side.hasSuffix(" of") { side.removeLast(3) }
            steps.append(.object(["type": .string("note"), "side": .string(side), "on": .array(on.map(YLValue.string)), "text": .string(unlabel(m[4]!))]))
            return
        }
        if let m = seqBlockRE.match(t) {
            openBlocks += 1
            var o: [String: YLValue] = ["type": .string("open"), "block": .string(m[1]!)]
            if let x = m[2], !x.isEmpty { o["text"] = .string(unlabel(x)) }
            steps.append(.object(o))
            return
        }
        if let m = seqElseRE.match(t) {
            var o: [String: YLValue] = ["type": .string("else")]
            if let x = m[2], !x.isEmpty { o["text"] = .string(unlabel(x)) }
            steps.append(.object(o))
            return
        }
        if let m = seqMsgRE.match(t) {
            seqActor(m[1]!)
            seqActor(m[4]!)
            let arrow = m[2]!
            var tail = Substring(arrow)
            while tail.first == "<" { tail.removeFirst() }
            while tail.first == "-" { tail.removeFirst() }
            let head = seqHead[String(tail)] ?? "arrow"
            var e: [String: YLValue] = ["type": .string("msg"), "from": .string(m[1]!), "to": .string(m[4]!), "text": .string(unlabel(m[5] ?? ""))]
            if arrow.hasPrefix("--") || arrow.hasPrefix("<<--") { e["line"] = .string("dash") }
            if head != "arrow" { e["head"] = .string(head) }
            if arrow.hasPrefix("<<") { e["both"] = .bool(true) }
            steps.append(.object(e))
        }
    }

    // MARK: state

    /// [*] is the start when a transition leaves it and the end when one
    /// reaches it: _start and _end, with the composite state appended inside one.
    private mutating func stateLine(_ t: String) {
        if note { if endNoteRE.match(t) != nil { note = false }; return }
        if stateNoteRE.match(t) != nil { if !t.contains(":") { note = true }; return }
        if stateSkipRE.match(t) != nil {
            if let m = stateDirRE.match(t) { dir = m[1]!.uppercased() }
            return
        }
        if t == "}" { _ = stack.popLast(); return }
        if let m = stateDeclRE.match(t) {
            let id = m[2] ?? m[3]!
            var shape: String?
            if let x = m[4] { shape = str(sc(x).dropFirst(2).dropLast(2)) }
            upsert(id, label: m[1].flatMap { $0.isEmpty ? nil : $0 }, shape: shape)
            if m[5] != nil {
                openGroup(id: id, label: nodes.first(where: { $0.id == id })?.label.flatMap { $0.isEmpty ? nil : $0 })
            }
            return
        }
        if let m = stateEdgeRE.match(t) {
            let scope = stack.last.map { "_" + groups[$0].id } ?? ""
            let from = m[1] == "[*]" ? "_start" + scope : m[1]!
            let to = m[3] == "[*]" ? "_end" + scope : m[3]!
            upsert(from, label: nil, shape: m[1] == "[*]" ? "start" : nil)
            upsert(to, label: nil, shape: m[3] == "[*]" ? "end" : nil)
            edges.append(edgeValue(from: from, to: to, label: m[4].map(unlabel)))
            return
        }
        if let m = stateLabelRE.match(t) {
            upsert(m[1]!, label: nil, shape: nil)
            if let i = nodes.firstIndex(where: { $0.id == m[1]! }), nodes[i].label?.isEmpty ?? true { nodes[i].label = unlabel(m[2]!) }
        }
    }

    // MARK: line loop

    enum Result { case notMine, more, done }

    /// One line of an open diagram. `.notMine` means no Mermaid header came, so
    /// the caller reads the line as YL. A nested block's `end` (subgraph, loop,
    /// alt...) closes that block first, then the diagram.
    mutating func line(_ src: String) -> Result {
        let line = src.hasSuffix("\r") ? str(src.unicodeScalars.dropLast()) : src
        let t = dgTrim(line)
        guard kind != nil else {
            let u = sc(t)
            if u.isEmpty || (u[0] == "#" && (u.count == 1 || isSpace(u[1]))) { return .more }
            if t.hasPrefix("%%") { self.src.append(line); return .more }
            if diagramHeaderRE.match(t) == nil, diagramOtherRE.match(t) == nil { return .notMine }
            self.src.append(line)
            start(t)
            return .more
        }
        if endRE.match(t) != nil, kind != .state {
            let open = kind == .flow ? depth : kind == .sequence ? openBlocks : 0
            if open > 0 {
                self.src.append(line)
                if kind == .flow { depth -= 1; _ = stack.popLast() } else { openBlocks -= 1; steps.append(.object(["type": .string("close")])) }
                return .more
            }
            return .done
        }
        if endRE.match(t) != nil, !note { return .done }
        self.src.append(line)
        if t.isEmpty || kind == .other { return .more }
        switch kind! {
        case .flow: flowStatement(t)
        case .sequence: seqLine(t)
        case .state: stateLine(t)
        case .other: break
        }
        return .more
    }

    // MARK: the patch

    private func nodeValues() -> YLValue {
        .array(nodes.map { n in
            var o: [String: YLValue] = ["id": .string(n.id)]
            if let l = n.label { o["label"] = .string(l) }
            if let s = n.shape { o["shape"] = .string(s) }
            return .object(o)
        })
    }

    private func groupValues() -> YLValue {
        .array(groups.map { g in
            var o: [String: YLValue] = ["id": .string(g.id), "nodes": .array(g.nodes.map(YLValue.string))]
            if let l = g.label { o["label"] = .string(l) }
            if let p = g.parent { o["in"] = .string(p) }
            return .object(o)
        })
    }

    /// The patch props a diagram's end gives. Empty lists are left out, as `clean` does.
    func props() -> [String: YLValue] {
        var o: [String: YLValue] = ["source": .string(src.joined(separator: "\n"))]
        func put(_ k: String, _ v: YLValue) { if v.array?.isEmpty != true { o[k] = v } }
        switch kind {
        case .flow, .state:
            o["type"] = .string(kind == .flow ? "flow" : "state")
            o["dir"] = .string(dir)
            put("nodes", nodeValues())
            put("edges", .array(edges))
            put("groups", groupValues())
        case .sequence:
            o["type"] = .string("sequence")
            put("actors", .array(actors.map { a in
                var x: [String: YLValue] = ["id": .string(a.id)]
                if let l = a.label { x["label"] = .string(l) }
                if a.actor { x["actor"] = .bool(true) }
                return .object(x)
            }))
            put("steps", .array(steps))
            if numbered { o["numbered"] = .bool(true) }
        default:
            o["type"] = .string("other")
        }
        return o
    }
}

extension YLParser {
    /// Handles one line for an open diagram. Nil when the line is not the
    /// diagram's (the caller reads it as YL); else the node it gives, if any.
    mutating func diagramLine(_ src: String) -> YLNode?? {
        guard var d = dgm else { return nil }
        let r = d.line(src)
        switch r {
        case .notMine:
            dgm = nil
            return nil
        case .more:
            dgm = d
            return .some(nil)
        case .done:
            dgm = d
            return .some(diagramDone(line: src.hasSuffix("\r") ? String(src.dropLast()) : src))
        }
    }

    /// The patch an open diagram gives at its end (or at the end of input).
    mutating func diagramDone(line: String) -> YLNode? {
        guard let d = dgm else { return nil }
        dgm = nil
        guard d.kind != nil else { return nil }
        return YLNode(op: .patch, screen: d.screen, target: d.id, props: d.props(), line: line)
    }
}
