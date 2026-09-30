import Foundation

// A flow's runtime (spec FLOWS.md sections 4-6): where Next goes, the path the
// answers take, what the review sends, and variants. Pure functions over the
// graph, ported from the JS reference (`site/lib/yl/yl.mjs`, "flow runtime").
// The app keeps the answers; everything here is derived from them.

public struct YLFlowClause: Equatable, Sendable {
    public var path: String?
    public var op: String
    public var value: YLValue
}

public struct YLFlowNode: Equatable, Sendable {
    public var id: String
    public var label: String?
    public var preset: String?
    public var props: [String: YLValue]
    /// A question takes an answer; a page is read, a node with no step only routes.
    public var isQuestion: Bool { preset != nil && preset != "page" }
}

public struct YLFlowEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public var label: String?
    /// Alternatives ("or"), each a list of clauses that must all hold ("and"). nil: a default edge.
    public var when: [[YLFlowClause]]?
}

public struct YLFlowGraph: Equatable, Sendable {
    public var dir: String?
    public var start: String?
    public var nodes: [YLFlowNode]
    public var edges: [YLFlowEdge]

    public init(dir: String? = nil, start: String? = nil, nodes: [YLFlowNode] = [], edges: [YLFlowEdge] = []) {
        self.dir = dir; self.start = start; self.nodes = nodes; self.edges = edges
    }

    /// The graph a flow's patch props describe (`{dir, start, nodes, edges}`).
    public init(props: [String: YLValue]) {
        dir = props["dir"]?.string
        start = props["start"]?.string
        nodes = (props["nodes"]?.array ?? []).compactMap { v in
            guard let id = v["id"]?.string else { return nil }
            return YLFlowNode(id: id, label: v["label"]?.string, preset: v["preset"]?.string, props: v["props"]?.object ?? [:])
        }
        edges = (props["edges"]?.array ?? []).compactMap { v in
            guard let from = v["from"]?.string, let to = v["to"]?.string else { return nil }
            let when = v["when"]?.array?.map { alt in
                (alt.array ?? []).map { c in
                    YLFlowClause(path: c["path"]?.string, op: c["op"]?.string ?? "=", value: c["value"] ?? .null)
                }
            }
            return YLFlowEdge(from: from, to: to, label: v["label"]?.string, when: when)
        }
    }

    public func node(_ id: String) -> YLFlowNode? { nodes.first { $0.id == id } }

    /// The graph as a patch spells it (`{dir?, start?, nodes, edges}`): what the
    /// app stores for a run and what `init(props:)` reads back.
    public var value: YLValue {
        var o: [String: YLValue] = [
            "nodes": .array(nodes.map { n in
                var x: [String: YLValue] = ["id": .string(n.id)]
                if let l = n.label { x["label"] = .string(l) }
                if let p = n.preset { x["preset"] = .string(p); x["props"] = .object(n.props) }
                return .object(x)
            }),
            "edges": .array(edges.map { e in
                var x: [String: YLValue] = ["from": .string(e.from), "to": .string(e.to)]
                if let l = e.label { x["label"] = .string(l) }
                if let w = e.when {
                    x["when"] = .array(w.map { alt in
                        .array(alt.map { c in
                            var y: [String: YLValue] = ["op": .string(c.op), "value": c.value]
                            if let p = c.path { y["path"] = .string(p) }
                            return .object(y)
                        })
                    })
                }
                return .object(x)
            }),
        ]
        if let d = dir { o["dir"] = .string(d) }
        if let s = start { o["start"] = .string(s) }
        return .object(o)
    }
}

/// One line of a variant (FLOWS.md section 9), as the parser gives them.
public enum YLFlowChange: Equatable, Sendable {
    case step(id: String, preset: String, props: [String: YLValue])
    case drop(id: String)
    case add(id: String, after: String, preset: String, props: [String: YLValue])

    /// The changes a variant patch's props hold, in order; a line it cannot read is skipped.
    public static func list(_ props: [String: YLValue]) -> [YLFlowChange] {
        (props["changes"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            let p = c["props"]?.object ?? [:]
            switch c["op"]?.string {
            case "drop": return .drop(id: id)
            case "step": return c["preset"]?.string.map { .step(id: id, preset: $0, props: p) }
            case "add":
                guard let after = c["after"]?.string, let preset = c["preset"]?.string else { return nil }
                return .add(id: id, after: after, preset: preset, props: p)
            default: return nil
            }
        }
    }
}

public struct YLFlowRoute: Equatable, Sendable {
    /// Step ids on the path, in order, pages included.
    public var path: [String]
    /// The first question with no answer, or nil when the path reaches its end.
    public var open: String?
}

extension YuiLines {
    // MARK: conditions

    private static func low(_ v: YLValue) -> String {
        if case .bool(let b) = v { return b ? "yes" : "no" }
        return String(String.UnicodeScalarView(trimJS(Scalars(jsString(v).unicodeScalars)))).lowercased()
    }

    private static func num(_ v: YLValue) -> Double? {
        if case .number(let n) = v { return n }
        if case .string(let s) = v {
            let t = dgTrim(s)
            if t.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil { return Double(t) }
        }
        return nil
    }

    /// One clause against the answers. `last` is the question answered before a
    /// step-less node, for bare labels on its edges.
    static func clauseHolds(_ c: YLFlowClause, _ answers: [String: YLValue], _ last: String?) -> Bool {
        let parts: [String?] = c.path.map { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) } ?? [last]
        guard let key = parts[0] else { return c.op == "!=" }
        var v = answers[key]
        for k in parts.dropFirst() { v = k.flatMap { v?.object?[$0] } }
        guard var v, v != .null else { return c.op == "!=" }
        let want = c.value
        if let list = v.array {
            let has = list.contains { low($0) == low(want) }
            if c.op == "=" || c.op == "~" { return has }
            if c.op == "!=" { return !has }
            v = .number(Double(list.count))
        }
        let a = num(v), b = num(want)
        switch c.op {
        case "=": return a != nil && b != nil ? a == b : low(v) == low(want)
        case "!=": return a != nil && b != nil ? a != b : low(v) != low(want)
        case "~": return low(v).contains(low(want))
        default:
            guard let a, let b else { return false }
            switch c.op {
            case ">": return a > b
            case ">=": return a >= b
            case "<": return a < b
            default: return a <= b
            }
        }
    }

    public static func flowTest(_ when: [[YLFlowClause]]?, _ answers: [String: YLValue], last: String? = nil) -> Bool {
        guard let when else { return true }
        return when.contains { alt in alt.allSatisfy { clauseHolds($0, answers, last) } }
    }

    // MARK: routes

    /// The edge taken out of `from`: the first labelled edge that holds, else
    /// the first default edge. With `guess`, a question with no answer yet still
    /// takes a labelled edge earlier answers already decide, else the default
    /// (or its first edge), to estimate what is left.
    private static func edgeOut(_ g: YLFlowGraph, _ answers: [String: YLValue], _ from: String, _ last: String?, _ guess: Bool) -> YLFlowEdge? {
        let out = g.edges.filter { $0.from == from }
        let unknown = guess && g.node(from)?.isQuestion == true && answers[from] == nil
        if let hit = out.first(where: { $0.when != nil && flowTest($0.when, answers, last: last) }) { return hit }
        return out.first { $0.when == nil } ?? (unknown ? out.first : nil)
    }

    /// The next step after `from`, passing through nodes with no step. nil: the
    /// flow ends (the review comes next).
    public static func flowNext(_ g: YLFlowGraph, _ answers: [String: YLValue], from: String, guess: Bool = false) -> String? {
        var seen: Set<String> = [from]
        let last: String? = g.node(from)?.isQuestion == true ? from : nil
        var at = from
        while true {
            guard let e = edgeOut(g, answers, at, last, guess), !seen.contains(e.to), let n = g.node(e.to) else { return nil }
            if n.preset != nil { return n.id }
            seen.insert(n.id)
            at = n.id
        }
    }

    /// The first step: the start node, or the first step after it.
    public static func flowFirst(_ g: YLFlowGraph) -> String? {
        guard let s = g.start.flatMap(g.node) else { return nil }
        return s.preset != nil ? s.id : flowNext(g, [:], from: s.id)
    }

    /// The path the answers take from the start. It stops at the first question
    /// with no answer (`open`, not in the path) or at the end. A step already on
    /// the path ends it: flows do not loop.
    public static func flowPath(_ g: YLFlowGraph, _ answers: [String: YLValue]) -> YLFlowRoute {
        var path: [String] = []
        var at = flowFirst(g)
        while let id = at, !path.contains(id) {
            if g.node(id)?.isQuestion == true, answers[id] == nil { return YLFlowRoute(path: path, open: id) }
            path.append(id)
            at = flowNext(g, answers, from: id)
        }
        return YLFlowRoute(path: path, open: nil)
    }

    /// The steps still ahead of `from` (not counting it), guessing at branches
    /// not answered yet. For the progress line.
    public static func flowAhead(_ g: YLFlowGraph, _ answers: [String: YLValue], from: String?) -> [String] {
        var out: [String] = []
        var at = from.flatMap { flowNext(g, answers, from: $0, guess: true) }
        while let id = at, !out.contains(id), id != from {
            out.append(id)
            at = flowNext(g, answers, from: id, guess: true)
        }
        return out
    }

    /// What a flow sends at submit: the answers of the questions on the path,
    /// keyed by step id, and the path itself (pages included).
    public static func flowEvent(_ g: YLFlowGraph, _ answers: [String: YLValue]) -> (flow: [String: YLValue], path: [String]) {
        let path = flowPath(g, answers).path
        var flow: [String: YLValue] = [:]
        for id in path where g.node(id)?.isQuestion == true {
            if let a = answers[id] { flow[id] = a }
        }
        return (flow, path)
    }

    // MARK: variants

    /// A base flow's graph with a variant's changes applied, in order. A change
    /// that names a step the base does not have (or adds one it already has) is
    /// skipped, so a variant survives its base being edited.
    public static func flowVariant(_ base: YLFlowGraph, _ changes: [YLFlowChange]) -> YLFlowGraph {
        var nodes = base.nodes, edges = base.edges, start = base.start
        func has(_ id: String) -> Bool { nodes.contains { $0.id == id } }
        for c in changes {
            switch c {
            case .drop(let id) where has(id):
                // Edges into the step go where it went: its default edge, else its first.
                let out = edges.filter { $0.from == id }
                let on = (out.first { $0.when == nil } ?? out.first)?.to
                edges = edges.filter { $0.from != id }.flatMap { e -> [YLFlowEdge] in
                    if e.to != id { return [e] }
                    guard let on, on != e.from else { return [] }
                    var moved = e
                    moved.to = on
                    return [moved]
                }
                nodes.removeAll { $0.id == id }
                if start == id { start = on.flatMap { has($0) ? $0 : nil } ?? nodes.first?.id }
            case .step(let id, let preset, let props) where has(id):
                nodes = nodes.map { n in
                    guard n.id == id else { return n }
                    var m = n
                    m.preset = preset; m.props = props
                    return m
                }
            case .add(let id, let after, let preset, let props)
                where !has(id) && nodes.first(where: { $0.id == after })?.preset != nil:
                // The new step takes over the edges out of `after`, and `after` goes to it.
                edges = edges.map { e in
                    guard e.from == after else { return e }
                    var m = e
                    m.from = id
                    return m
                }
                edges.append(YLFlowEdge(from: after, to: id))
                let at = nodes.firstIndex { $0.id == after }!
                nodes.insert(YLFlowNode(id: id, preset: preset, props: props), at: at + 1)
            default: break
            }
        }
        return YLFlowGraph(dir: base.dir, start: start, nodes: nodes, edges: edges)
    }

    /// How saved flows are matched by name: letters and digits only, case aside
    /// (`Website intake`, `website-intake` and `websiteintake` are one flow).
    public static func flowKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) })
    }

    /// A variant's name from its `as=`: "Restaurant intake" and "restaurant-intake"
    /// are both the name restaurant-intake, title "Restaurant intake".
    public static func flowName(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).joined(separator: "-")
    }
}
