import Foundation
import Observation

/// A beat on a looper the agent named, kept on the phone until it is sent or the agent
/// changes the loop (YUI-184, Gouda's Looper page). Taps on the grid, the tempo and the
/// swing say nothing back until Send (Send is the save), so without this a kill, a relaunch
/// or another agent and back threw the beat away. It lives in UserDefaults per agent and
/// looper id, the real path on every account (Chris, Sep 28: the 0.5.0 switch-agent crash
/// hid behind the demo account's memory).
///
/// A draft remembers the loop the agent drew under it (`base`: its pattern, rows, steps,
/// tempo and swing). When the agent draws a different loop there (a saved session opened,
/// a new beat), the draft is dropped and the agent's loop shows.
@Observable @MainActor
final class LoopDrafts {
    static let shared = LoopDrafts()

    struct Draft: Equatable {
        var base: String
        var p: [String]
        var bpm: Int
        var swing: Int
    }

    private let defaults: UserDefaults
    private var drafts: [String: Draft?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.resetIfAsked(defaults)
    }

    /// Only a looper the agent named (`loop@looper`) is kept: `n3` is just its place in one reply.
    nonisolated static func keeps(_ agent: String, _ id: String) -> Bool { ListTicks.keeps(agent, id) }

    nonisolated static func key(_ agent: String, _ id: String) -> String { "yui.loop.\(agent).\(id)" }

    /// The loop as the agent drew it: what a draft sits on.
    nonisolated static func base(p: [String], rows: [String], steps: Int, bpm: Int, swing: Int) -> String {
        "\(p.joined(separator: "|"));\(rows.joined(separator: "|"));\(steps);\(bpm);\(swing)"
    }

    /// The draft on `base`, if there is one. Reads only.
    func draft(_ agent: String, _ id: String, base: String) -> Draft? {
        guard Self.keeps(agent, id), let d = saved(Self.key(agent, id)), d.base == base else { return nil }
        return d
    }

    /// The agent drew the loop again: a draft on a different loop goes for good.
    func prune(_ agent: String, _ id: String, base: String) {
        guard Self.keeps(agent, id) else { return }
        let k = Self.key(agent, id)
        if let d = saved(k), d.base != base { write(k, nil) }
    }

    func set(_ agent: String, _ id: String, _ d: Draft) {
        guard Self.keeps(agent, id) else { return }
        write(Self.key(agent, id), d)
    }

    func clear(_ agent: String, _ id: String) {
        guard Self.keeps(agent, id) else { return }
        write(Self.key(agent, id), nil)
    }

    private func saved(_ k: String) -> Draft? {
        if let d = drafts[k] { return d }
        guard let o = defaults.dictionary(forKey: k), let base = o["base"] as? String, let p = o["p"] as? [String] else { return nil }
        return Draft(base: base, p: p, bpm: o["bpm"] as? Int ?? 96, swing: o["swing"] as? Int ?? 0)
    }

    private func write(_ k: String, _ d: Draft?) {
        drafts[k] = .some(d)
        if let d { defaults.set(["base": d.base, "p": d.p, "bpm": d.bpm, "swing": d.swing] as [String: Any], forKey: k) }
        else { defaults.removeObject(forKey: k) }
    }

    /// `-yuiTicksReset` (UI tests): every kept looper starts as the agent drew it, once per launch.
    private static func resetIfAsked(_ d: UserDefaults) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-yuiTicksReset") else { return }
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("yui.loop.") { d.removeObject(forKey: k) }
        #endif
    }
}
