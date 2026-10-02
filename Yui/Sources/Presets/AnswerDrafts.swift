import Foundation
import YuiLines

/// What a person has typed or picked in a question and not sent yet, kept on the phone
/// (feedback NOTE-19357, "Forms keep your answers"). A form's fields, a pick's picks, the
/// words in a mic's box or in Type your own lived only in the view, so the stage paging
/// away, going home, another agent and back, the record and back or a relaunch threw them
/// away. Here they outlive the view: one small defaults entry per agent, keyed by the
/// reply (its message id), the component's YL id and a field name. A draft goes once its
/// answer is sent, and a view never puts one over an answer that already went.
@MainActor
final class AnswerDrafts {
    static let shared = AnswerDrafts()

    /// Each agent keeps its newest drafts only: a reply nobody came back to drops off the end.
    static let cap = 40

    private struct Entry: Codable, Equatable {
        var value: YLValue
        var at: Double
    }

    private let defaults: UserDefaults
    /// Each agent's drafts by `key`: read once per agent, written through.
    private var agents: [String: [String: Entry]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.resetIfAsked(defaults)
    }

    nonisolated static func storeKey(_ agent: String) -> String { "yui.answers.\(agent)" }

    nonisolated static func key(_ scope: String, _ id: String, _ field: String) -> String { "\(scope)|\(id)|\(field)" }

    /// Nothing worth keeping: no value, blank words, no picks, a form with every field blank.
    nonisolated static func isEmpty(_ v: YLValue) -> Bool {
        switch v {
        case .null: true
        case .string(let s): s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a): a.allSatisfy { Self.isEmpty($0) }
        case .object(let o): o.values.allSatisfy { Self.isEmpty($0) }
        case .bool, .number: false
        }
    }

    /// A key-shaped word anywhere in it: never kept on disk (YUI-34, as the composer's draft).
    nonisolated static func holdsKey(_ v: YLValue) -> Bool {
        switch v {
        case .string(let s): KeyShape.find(in: s) != nil
        case .array(let a): a.contains { Self.holdsKey($0) }
        case .object(let o): o.values.contains { Self.holdsKey($0) }
        case .null, .bool, .number: false
        }
    }

    /// The unsent value of `field` on the component `id` in reply `scope`. Reads only.
    func draft(_ agent: String, _ scope: String, _ id: String, _ field: String) -> YLValue? {
        guard !scope.isEmpty, !id.isEmpty else { return nil }
        return entries(agent)[Self.key(scope, id, field)]?.value
    }

    /// Keeps `value`, or forgets the field when it is nil, empty or holds a key.
    func set(_ agent: String, _ scope: String, _ id: String, _ field: String, _ value: YLValue?) {
        guard !scope.isEmpty, !id.isEmpty else { return }
        var all = entries(agent)
        let k = Self.key(scope, id, field)
        if let value, !Self.isEmpty(value), !Self.holdsKey(value) {
            guard all[k]?.value != value else { return }
            // Strictly newer than the newest, so two keys in one instant still keep their order.
            let at = max(Date().timeIntervalSince1970, (all.values.map(\.at).max() ?? 0) + 0.001)
            all[k] = Entry(value: value, at: at)
            if all.count > Self.cap {
                for old in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - Self.cap) { all[old.key] = nil }
            }
        } else {
            guard all[k] != nil else { return }
            all[k] = nil
        }
        write(agent, all)
    }

    /// Every field of the component `id` in reply `scope` goes: its answer was sent.
    func clear(_ agent: String, _ scope: String, _ id: String) {
        clear(agent, scope, ids: [id])
    }

    /// An answer went from this phone: the drafts it covers go. A plan or a flow carries
    /// its questions' answers by their ids, so theirs go with it.
    func sent(_ e: YLEvent, scope: String, agent: String) {
        var ids = [e.id]
        for k in ["plan", "flow"] { if let o = e.value[k]?.object { ids += o.keys } }
        clear(agent, scope, ids: ids)
    }

    private func clear(_ agent: String, _ scope: String, ids: [String]) {
        guard !scope.isEmpty else { return }
        var all = entries(agent)
        let prefixes = ids.map { "\(scope)|\($0)|" }
        let gone = all.keys.filter { k in prefixes.contains { k.hasPrefix($0) } }
        guard !gone.isEmpty else { return }
        for k in gone { all[k] = nil }
        write(agent, all)
    }

    private func entries(_ agent: String) -> [String: Entry] {
        if let all = agents[agent] { return all }
        // No agent (a chat on its own): kept while the app runs, never on disk.
        var all: [String: Entry] = [:]
        if !agent.isEmpty, let data = defaults.data(forKey: Self.storeKey(agent)),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { all = saved }
        agents[agent] = all
        return all
    }

    private func write(_ agent: String, _ all: [String: Entry]) {
        agents[agent] = all
        guard !agent.isEmpty else { return }
        if all.isEmpty {
            defaults.removeObject(forKey: Self.storeKey(agent))
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.storeKey(agent))
        }
    }

    /// The demo account (UI tests, screenshots) starts with no drafts, as the composer's do;
    /// `-yuiDraftsKeep` keeps them across a relaunch. Once per launch.
    private static var wasReset = false

    private static func resetIfAsked(_ d: UserDefaults) {
        let args = ProcessInfo.processInfo.arguments
        guard !wasReset, args.contains("-yuiDemoAccount"), !args.contains("-yuiDraftsKeep") else { return }
        wasReset = true
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("yui.answers.") { d.removeObject(forKey: k) }
    }
}
