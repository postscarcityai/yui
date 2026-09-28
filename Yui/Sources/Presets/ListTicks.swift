import Foundation
import Observation

/// Ticks on a checklist, kept on the phone (YUI-183). A tick on Basil's grocery list
/// says nothing back: the runtime marks the item got and it leaves the list the next
/// time the page is drawn. Until then the tick lives here, in UserDefaults per agent
/// and list id, so a kill, a relaunch or another agent and back keeps it. Chris
/// (Sep 28): the 0.5.0 switch-agent crash hid behind the demo account's memory, so
/// this is the real path on every account.
///
/// Items are kept by their words, not their place, so a patch that adds or drops an
/// item never moves a tick onto its neighbour. A redraw that no longer has an item
/// drops its tick.
@Observable @MainActor
final class ListTicks {
    static let shared = ListTicks()

    private let defaults: UserDefaults
    /// What is ticked, by key: read once per key, written through.
    private var ticks: [String: Set<String>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.resetIfAsked(defaults)
    }

    /// Only a list the agent named (`list@aisle-produce`) is kept: `n3` is just its place in one reply.
    nonisolated static func keeps(_ agent: String, _ list: String) -> Bool {
        !agent.isEmpty && !list.isEmpty && list.range(of: #"^n\d+$"#, options: .regularExpression) == nil
    }

    nonisolated static func key(_ agent: String, _ list: String) -> String { "yui.ticks.\(agent).\(list)" }

    /// The ticked items among `items`. Reads only, so a view can call it while it draws.
    func ticked(_ agent: String, _ list: String, items: [String]) -> Set<String> {
        guard Self.keeps(agent, list) else { return [] }
        return saved(Self.key(agent, list)).intersection(items)
    }

    /// The list was drawn again: a tick on an item that is no longer there is dropped for good.
    func prune(_ agent: String, _ list: String, items: [String]) {
        guard Self.keeps(agent, list) else { return }
        let k = Self.key(agent, list)
        let had = saved(k), now = had.intersection(items)
        guard now != had else { return }
        ticks[k] = now
        store(k, now)
    }

    func set(_ agent: String, _ list: String, item: String, on: Bool) {
        guard Self.keeps(agent, list) else { return }
        let k = Self.key(agent, list)
        var now = saved(k)
        if on { now.insert(item) } else { now.remove(item) }
        ticks[k] = now
        store(k, now)
    }

    private func saved(_ k: String) -> Set<String> { ticks[k] ?? Set(defaults.stringArray(forKey: k) ?? []) }

    private func store(_ k: String, _ items: Set<String>) {
        if items.isEmpty { defaults.removeObject(forKey: k) } else { defaults.set(items.sorted(), forKey: k) }
    }

    /// `-yuiTicksReset` (UI tests): every checklist starts unticked, once per launch.
    private static func resetIfAsked(_ d: UserDefaults) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-yuiTicksReset") else { return }
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("yui.ticks.") { d.removeObject(forKey: k) }
        #endif
    }
}

/// A page of checklists as plain words to send on (YUI-183, Basil's grocery list):
/// its name, then each list's title as a header over what is still to get.
enum ChecklistText {
    struct Section: Equatable {
        let title: String
        let items: [String]
    }

    static func text(title: String?, _ sections: [Section]) -> String {
        let left = sections.filter { !$0.items.isEmpty }
        var out: [String] = []
        if let title, !title.isEmpty { out.append(title) }
        for s in left {
            if !out.isEmpty { out.append("") }
            out.append(s.title)
            out += s.items.map { "- \($0)" }
        }
        return out.joined(separator: "\n")
    }

    /// The checklists on a page that can go out as one list: two or more with titles
    /// (a grocery list by aisle), each with its ticked items left off.
    @MainActor static func sections(_ components: [YLComponent], agent: String, ticks: ListTicks = .shared) -> [Section] {
        let lists = components.filter { $0.preset == "list" && $0.flag("check") && $0.string("title") != nil }
        guard lists.count >= 2 else { return [] }
        return lists.map { c in
            let items = c.strings("items") ?? []
            let got = ticks.ticked(agent, c.ylID, items: items)
            return Section(title: c.string("title") ?? "", items: items.filter { !got.contains($0) })
        }
    }
}
