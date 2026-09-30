import Foundation

// `flow` (spec FLOWS.md): a Mermaid flowchart between `flow` and `end`, each
// node carrying one step. Port of the flow section of the JS reference
// (`site/lib/yl/yl.mjs`): the reader below gives the graph patch, the
// variant reader gives a change list, and FlowRun.swift is the runtime.

let flowSteps: Set<String> = ["page", "ask", "choose", "pick", "slide", "form", "mic", "camera"]
private let flowStepRE = JSRegex(#"^(page|ask|choose|pick|slide|form|mic|camera)(?=[\#(JSWS)]|$)"#)
private let flowCommentRE = JSRegex(#"^%%[\#(JSWS)]*([A-Za-z0-9_]+)[\#(JSWS)]*:[\#(JSWS)]*(.*)$"#)
private let flowHeadRE = JSRegex(#"^([a-z]+)(?=[\#(JSWS)]|$)"#)
private let flowEndRE = JSRegex(#"^end[\#(JSWS)]*;?$"#)
private let variantAddRE = JSRegex(#"^add[\#(JSWS)]+([A-Za-z0-9_]+)[\#(JSWS)]+after[\#(JSWS)]+([A-Za-z0-9_]+)[\#(JSWS)]*:[\#(JSWS)]*(.*)$"#)
private let variantDropRE = JSRegex(#"^drop((?:[\#(JSWS)]+[A-Za-z0-9_]+)+)[\#(JSWS)]*$"#)
private let clauseRE = JSRegex(#"^([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_-]+)*)[\#(JSWS)]*(>=|<=|!=|=|>|<|~)[\#(JSWS)]*(.*)$"#)
private let numRE = JSRegex(#"^-?[0-9]+(\.[0-9]+)?$"#)
private let variantBad = "flow: a variant line is drop, add or a %% step"

/// A step from a YL line, or nil when the line is not a flow step.
private func stepOf(_ text: String) -> (preset: String, props: Props)? {
    guard let m = flowStepRE.match(text) else { return nil }
    let preset = m[1]!
    return (preset, parseArgs(preset, tokenize(sc(dropping(text, m[0]!)))))
}

/// What a `%%` step line says: an error message, a step, or neither (a plain comment).
private enum StepRead { case step(String, Props), error(String), none }

private func readStep(_ text: String) -> StepRead {
    if let head = flowHeadRE.match(text)?[1], presets.contains(head) || head == "say", !flowSteps.contains(head) {
        return .error("flow: a \(head) cannot be a step (page, ask, choose, pick, slide, form, mic, camera)")
    }
    if let s = stepOf(text) { return .step(s.preset, s.props) }
    return .none
}

struct YLFlowReader: Sendable {
    var id: String
    var screen: String
    var src: [String]
    var depth = 0
    var variant = false
    var dir = "TD"
    private var nodes: [(id: String, label: String?)] = []
    private var edges: [(from: String, to: String, label: String?)] = []
    private var stepLines: [String: (preset: String, props: Props)] = [:]
    var changes: [YLValue] = []

    init(id: String, screen: String, pre: [String], header: String) {
        self.id = id; self.screen = screen
        src = pre + [header]
        let words = dgTrim(header).split(whereSeparator: { $0.unicodeScalars.allSatisfy(isSpace) })
        dir = (words.count > 1 ? String(words[1]) : "TD").uppercased()
    }

    init(variantId id: String, screen: String) {
        self.id = id; self.screen = screen; src = []; variant = true
    }

    private mutating func addNode(_ n: ReadNode) {
        if let i = nodes.firstIndex(where: { $0.id == n.id }) {
            if let l = n.label { nodes[i].label = l }
        } else {
            nodes.append((n.id, n.label))
        }
    }

    /// One Mermaid line. Returns an error message or nil.
    mutating func statement(_ t: String) -> String? {
        if t.isEmpty { return nil }
        if t.hasPrefix("%%") {
            if t.hasPrefix("%%{") { return nil }
            guard let m = flowCommentRE.match(t) else { return nil }
            switch readStep(m[2]!) {
            case .error(let e): return e
            case .step(let p, let props): stepLines[m[1]!] = (p, props)
            case .none: break
            }
            return nil
        }
        if t.hasPrefix("subgraph"), t == "subgraph" || t.unicodeScalars.dropFirst(8).first.map(isSpace) == true {
            depth += 1
            return nil
        }
        if flowSkipRE.match(t) != nil || flowHeaderRE.match(t) != nil { return nil }
        for st in statements(t) {
            guard var g = readNodes(st) else { continue }
            g.nodes.forEach { addNode($0) }
            while true {
                var rest = g.rest
                var label: String?
                var hidden = false
                if let tl = textLinkRE.match(rest) {
                    label = tl[1]
                    rest = dropping(rest, tl[0]!)
                } else {
                    guard let l = linkRE.match(rest) else { break }
                    hidden = l[2]!.hasPrefix("~")
                    rest = dropping(rest, l[0]!)
                    if let p = pipeRE.match(rest) { label = p[1]; rest = dropping(rest, p[0]!) }
                }
                guard let to = readNodes(rest) else { break }
                to.nodes.forEach { addNode($0) }
                if !hidden {
                    let text = label.map(unlabel) ?? ""
                    for a in g.nodes { for b in to.nodes { edges.append((a.id, b.id, text.isEmpty ? nil : text)) } }
                }
                g = to
            }
        }
        return nil
    }

    /// One line of an open variant. Returns an error message or nil.
    mutating func variantStatement(_ t: String) -> String? {
        if t.isEmpty || (t.hasPrefix("#") && (t.unicodeScalars.count == 1 || isSpace(Array(t.unicodeScalars)[1]))) { return nil }
        if t.hasPrefix("%%") {
            guard let m = flowCommentRE.match(t) else { return nil }
            switch readStep(m[2]!) {
            case .error(let e): return e
            case .step(let p, let props):
                changes.append(.object(["op": .string("step"), "id": .string(m[1]!), "preset": .string(p), "props": .object(props)]))
            case .none: break
            }
            return nil
        }
        if let m = variantDropRE.match(t) {
            for id in dgTrim(m[1]!).split(whereSeparator: { $0.unicodeScalars.allSatisfy(isSpace) }) {
                changes.append(.object(["op": .string("drop"), "id": .string(String(id))]))
            }
            return nil
        }
        if let m = variantAddRE.match(t) {
            switch readStep(m[3]!) {
            case .error(let e): return e
            case .step(let p, let props):
                changes.append(.object(["op": .string("add"), "id": .string(m[1]!), "after": .string(m[2]!),
                                        "preset": .string(p), "props": .object(props)]))
                return nil
            case .none: return variantBad
            }
        }
        return variantBad
    }

    /// The patch props a flow's end gives.
    func props() -> Props {
        if variant {
            var o: Props = ["source": .string(src.joined(separator: "\n"))]
            if !changes.isEmpty { o["changes"] = .array(changes) }
            return o
        }
        var graphNodes: [YLValue] = []
        for n in nodes {
            var o: Props = ["id": .string(n.id)]
            let said = stepLines[n.id]
            let step = said ?? n.label.flatMap(stepOf)
            if let step {
                // A label that is the step's own line is not kept twice.
                if said != nil, let l = n.label { o["label"] = .string(l) }
                o["preset"] = .string(step.preset)
                o["props"] = .object(step.props)
            } else if let l = n.label {
                o["label"] = .string(l)
            }
            graphNodes.append(.object(o))
        }
        let isStep = Set(graphNodes.compactMap { $0["preset"] != nil ? $0["id"]?.string : nil })
        let into = Set(edges.map(\.to))
        let start = graphNodes.first(where: { !into.contains($0["id"]!.string!) }) ?? graphNodes.first
        let graphEdges: [YLValue] = edges.map { e in
            var o: Props = ["from": .string(e.from), "to": .string(e.to)]
            if let l = e.label { o["label"] = .string(l) }
            if let w = YuiLines.flowWhen(e.label, from: isStep.contains(e.from) ? e.from : nil) { o["when"] = w }
            return .object(o)
        }
        var o: Props = ["dir": .string(dir), "source": .string(src.joined(separator: "\n"))]
        if let s = start?["id"] { o["start"] = s }
        if !graphNodes.isEmpty { o["nodes"] = .array(graphNodes) }
        if !graphEdges.isEmpty { o["edges"] = .array(graphEdges) }
        return o
    }
}

extension YuiLines {
    /// Splits on a word (" or ") outside double quotes.
    private static func splitWord(_ t: String, _ word: String) -> [String] {
        let u = sc(t), w = Array(word.unicodeScalars)
        var out: [String] = [], cur = Scalars(), q = false, i = 0
        while i < u.count {
            if u[i] == "\"" { q.toggle() }
            if !q, isSpace(u[i]) {
                var j = i
                while j < u.count, isSpace(u[j]) { j += 1 }
                let k = j + w.count
                if j > i, k < u.count, str(u[j..<k]).lowercased() == word, isSpace(u[k]) {
                    var e = k
                    while e < u.count, isSpace(u[e]) { e += 1 }
                    out.append(str(cur)); cur = []; i = e
                    continue
                }
            }
            cur.append(u[i]); i += 1
        }
        out.append(str(cur))
        return out
    }

    /// An edge label as a condition: a list of alternatives ("or"), each a list
    /// of clauses that must all hold ("and"). nil for a default edge.
    static func flowWhen(_ label: String?, from: String?) -> YLValue? {
        let t = dgTrim(label ?? "")
        if t.isEmpty || ["else", "default", "otherwise"].contains(t.lowercased()) { return nil }
        return .array(splitWord(t, "or").map { alt in
            .array(splitWord(alt, "and").map { c in
                let c = dgTrim(c)
                let m = clauseRE.match(c)
                let raw = m.map { dgTrim($0[3]!) } ?? c
                let v: YLValue
                if raw.unicodeScalars.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") { v = .string(str(sc(raw).dropFirst().dropLast())) }
                else if numRE.match(raw) != nil { v = .number(Double(raw)!) }
                else { v = .string(raw) }
                if let m { return .object(["path": .string(m[1]!), "op": .string(m[2]!), "value": v]) }
                // A bare label ("Shop", "yes") is the answer of the step it leaves.
                if let from { return .object(["path": .string(from), "op": .string("="), "value": v]) }
                return .object(["op": .string("="), "value": v])
            })
        })
    }
}

extension YLParser {
    /// Handles one line for an open flow or a flow head waiting for its header.
    /// Nil when the line is not the flow's (the caller reads it as YL).
    mutating func flowLine(_ src: String) -> YLNode?? {
        let line = src.hasSuffix("\r") ? String(src.unicodeScalars.dropLast()) : src
        let t = dgTrim(line)
        if var f = flow {
            if flowEndRE.match(t) != nil {
                if f.depth > 0 { f.depth -= 1; f.src.append(line); flow = f; return .some(nil) }
                return .some(flowDone(line: line))
            }
            f.src.append(line)
            let err = f.variant ? f.variantStatement(t) : f.statement(t)
            flow = f
            return .some(err.map { YLNode(op: .error, screen: f.screen, message: $0, line: line) })
        }
        if let h = flowHead {
            // The line after a flow head decides: a Mermaid header starts the
            // chart (an inline flow), anything else leaves it a saved flow by name.
            if t.isEmpty || (t.hasPrefix("#") && (t.unicodeScalars.count == 1 || isSpace(Array(t.unicodeScalars)[1]))) { return .some(nil) }
            if t.hasPrefix("%%") { flowHead?.pre.append(line); return .some(nil) }
            flowHead = nil
            if flowHeaderRE.match(t) != nil { flow = YLFlowReader(id: h.id, screen: h.screen, pre: h.pre, header: line); return .some(nil) }
        }
        return nil
    }

    /// The patch an open flow gives at its end (or at the end of input).
    mutating func flowDone(line: String) -> YLNode? {
        flowHead = nil
        guard let f = flow else { return nil }
        flow = nil
        return YLNode(op: .patch, screen: f.screen, target: f.id, props: f.props(), line: line)
    }
}
