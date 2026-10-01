import Foundation
import YuiLines

// Saved flows (spec yuigui/spec/FLOWS.md sections 1, 5 and 9): what `flow website-intake`
// finds by name. The starter flows ship in the app (StarterFlows.swift); a variant an
// agent sends is kept as its base's name plus its changes, never a copy of the chart,
// and runs again by its own name. Names match on letters and digits, case and spacing aside.

/// A saved flow, ready to run.
struct ResolvedFlow: Equatable {
    var name: String
    var title: String
    var submit: String?
    var graph: YLFlowGraph
    /// The flow a variant starts from.
    var base: String?
}

/// A variant the phone keeps: its name, what it starts from and the changes, as the parser gave them.
struct KeptVariant: Codable, Equatable {
    var name: String
    var title: String
    var base: String
    var changes: [YLValue]
    /// The agent that sent it (My flows lists it under its base with this name).
    var agent: String?
}

@MainActor
enum SavedFlows {
    static let variantsKey = "yui.flows.variants"
    /// Names of the hub's own variants the person removed from My flows (they ship in the app, so removing hides them).
    static let removedKey = "yui.flows.removed"
    /// A variant follows its base at most this deep; a loop or a missing base is "no saved flow".
    static let maxDepth = 5

    private static var graphs: [String: YLFlowGraph] = [:]

    /// The graph a starter flow runs, read once with the parser an inline flow uses.
    static func starter(_ f: StarterFlow) -> YLFlowGraph {
        if let g = graphs[f.name] { return g }
        let text = "flow@\(f.id) \"\(f.title)\" submit=\"\(f.submit)\"\n\(f.source)\nend"
        let props = YuiLines.parse(text).first { $0.op == .patch }?.props ?? [:]
        let g = YLFlowGraph(props: props)
        graphs[f.name] = g
        return g
    }

    static func kept(in d: UserDefaults = .standard) -> [KeptVariant] {
        d.data(forKey: variantsKey).flatMap { try? JSONDecoder().decode([KeptVariant].self, from: $0) } ?? []
    }

    /// Keeps a variant under its name. Sending the same name again replaces it: that is how an agent edits its own.
    static func keep(_ v: KeptVariant, in d: UserDefaults = .standard) {
        var all = kept(in: d).filter { $0.name != v.name }
        // Sent again after a Remove: it is back.
        setRemoved(removed(in: d).filter { $0 != v.name }, in: d)
        all.append(v)
        if let data = try? JSONEncoder().encode(all) { d.set(data, forKey: variantsKey) }
    }

    static func removed(in d: UserDefaults = .standard) -> [String] { d.stringArray(forKey: removedKey) ?? [] }

    static func setRemoved(_ names: [String], in d: UserDefaults = .standard) { d.set(names, forKey: removedKey) }

    /// Forgets a kept variant, or hides one of the hub's own. A starter stays.
    static func forget(_ name: String, in d: UserDefaults = .standard) {
        let key = YuiLines.flowKey(name)
        if let data = try? JSONEncoder().encode(kept(in: d).filter { YuiLines.flowKey($0.name) != key }) { d.set(data, forKey: variantsKey) }
        if let v = StarterFlows.variants.first(where: { YuiLines.flowKey($0.name) == key }), !removed(in: d).contains(v.name) {
            setRemoved(removed(in: d) + [v.name], in: d)
        }
    }

    private static var wasReset = false

    /// `-yuiFlowsReset` (UI tests): no kept variants and none removed, once per launch.
    static func resetForTests(in d: UserDefaults = .standard) {
        #if DEBUG
        guard !wasReset, ProcessInfo.processInfo.arguments.contains("-yuiFlowsReset") else { return }
        wasReset = true
        d.removeObject(forKey: variantsKey)
        d.removeObject(forKey: removedKey)
        #endif
    }

    static func starters() -> [StarterFlow] { StarterFlows.all }

    /// A saved flow by name (`website-intake`, `"Website intake"`): a starter, a variant of the hub
    /// or one an agent sent. Nil: no saved flow by that name.
    static func resolve(_ name: String, in d: UserDefaults = .standard, depth: Int = 0) -> ResolvedFlow? {
        let key = YuiLines.flowKey(name)
        guard !key.isEmpty else { return nil }
        if let f = StarterFlows.all.first(where: { YuiLines.flowKey($0.name) == key || YuiLines.flowKey($0.title) == key }) {
            return ResolvedFlow(name: f.name, title: f.title, submit: f.submit, graph: starter(f))
        }
        guard depth < maxDepth else { return nil }
        if let v = kept(in: d).first(where: { YuiLines.flowKey($0.name) == key }) {
            return variant(base: v.base, changes: v.changes, as: v.name, title: v.title, in: d, depth: depth)
        }
        if let v = StarterFlows.variants.first(where: { YuiLines.flowKey($0.name) == key && !removed(in: d).contains($0.name) }) {
            let text = "flow@v \(v.base) as=\(v.name)\n\(v.lines)\nend"
            let changes = YuiLines.parse(text).first { $0.op == .patch }?.props?["changes"]?.array ?? []
            return variant(base: v.base, changes: changes, as: v.name, title: title(ofName: v.name), in: d, depth: depth)
        }
        return nil
    }

    /// A variant's graph: the base's, with the changes applied.
    static func variant(base: String, changes: [YLValue], as name: String, title: String? = nil,
                        in d: UserDefaults = .standard, depth: Int = 0) -> ResolvedFlow? {
        guard let b = resolve(base, in: d, depth: depth + 1) else { return nil }
        let list = YLFlowChange.list(["changes": .array(changes)])
        return ResolvedFlow(name: YuiLines.flowName(name), title: title ?? Self.title(ofName: name), submit: b.submit,
                            graph: YuiLines.flowVariant(b.graph, list), base: b.name)
    }

    /// "restaurant-intake" and "Restaurant intake" both read "Restaurant intake".
    static func title(ofName s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
