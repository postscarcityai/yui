import Observation
import SwiftUI

/// Yui's own look on this phone (RESTYLE.md): the state, the preview cards'
/// outcomes, and the write to the account. Cached in UserDefaults so the first
/// frame at launch is already right; the account copy wins once it loads.
@Observable @MainActor
final class AppLookStore {
    static let shared = AppLookStore()

    private(set) var state: AppLookState
    /// Each preview card's outcome, by the reply it is in: applied, kept or undone.
    private(set) var cards: [String: String]
    /// The card whose Apply one Undo takes back. Only that card shows Undo.
    private(set) var undoCard: String?
    /// Writes the look to the account (`yui-account` look). Set by the app once signed in.
    @ObservationIgnored var save: (@MainActor (AppLookState) async -> Void)?

    /// What the app's chrome wears.
    var theme: YuiTheme { AppLook.theme(state.look) }

    private static let key = "yuiAppLook"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        var defaults = defaults
        #if DEBUG
        // The demo account (screenshots, UI tests) starts from Yui's own look every launch.
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoAccount"), let demo = UserDefaults(suiteName: "yuiDemoLook") {
            demo.removePersistentDomain(forName: "yuiDemoLook")
            defaults = demo
        }
        #endif
        self.defaults = defaults
        let saved = (defaults.data(forKey: Self.key)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        state = AppLookState(json: saved?["look"] as? [String: Any])
        cards = saved?["cards"] as? [String: String] ?? [:]
        undoCard = saved?["undo"] as? String
        #if DEBUG
        // -yuiAppLookDemo autumn: the app already wears a look. -yuiAgentsOwnLooks NO: the switch off.
        if let name = UserDefaults.standard.string(forKey: "yuiAppLookDemo") {
            state.look = AppLook.offered(["name": name], on: nil)
        }
        if UserDefaults.standard.object(forKey: "yuiAgentsOwnLooks") != nil {
            state.agentsKeepLooks = UserDefaults.standard.bool(forKey: "yuiAgentsOwnLooks")
        }
        #endif
    }

    // MARK: Taps

    /// Use <set>: the look goes on, the one before it is what Undo puts back.
    func apply(_ props: [String: String], card: String, via: String?) {
        let now = state.look
        state.prev = now ?? AgentLook()
        state.look = AppLook.offered(props, on: now)
        state.via = via
        cards[card] = "applied"
        undoCard = card
        changed()
    }

    func keep(card: String) {
        cards[card] = "kept"
        persist()
    }

    /// Undo: back one step, and no further.
    func undo(card: String) {
        guard undoCard == card, let prev = state.prev else { return }
        state.look = prev.isEmpty ? nil : prev
        state.prev = nil
        state.via = nil
        cards[card] = "undone"
        undoCard = nil
        changed()
    }

    /// Settings > Look, Back to Yui's look. One tap, no agent.
    func reset() {
        guard state.look != nil else { return }
        state.prev = state.look
        state.look = nil
        state.via = nil
        undoCard = nil
        changed()
    }

    func setAgentsKeepLooks(_ on: Bool) {
        guard state.agentsKeepLooks != on else { return }
        state.agentsKeepLooks = on
        changed()
    }

    // MARK: The account

    /// The account's copy, fetched after sign-in: it wins over the device cache.
    func loaded(_ json: [String: Any]?) {
        let server = AppLookState(json: json)
        guard server != state else { return }
        state = server
        if state.prev == nil { undoCard = nil }
        persist()
    }

    /// Signed out: the next person starts from Yui's own look.
    func clear() {
        state = .yui
        cards = [:]
        undoCard = nil
        defaults.removeObject(forKey: Self.key)
    }

    private func changed() {
        state.at = Date.now.formatted(.iso8601)
        persist()
        let s = state
        if let save { Task { await save(s) } }
    }

    private func persist() {
        var o: [String: Any] = ["cards": cards]
        if let look = state.json { o["look"] = look }
        if let undoCard { o["undo"] = undoCard }
        if let data = try? JSONSerialization.data(withJSONObject: o) { defaults.set(data, forKey: Self.key) }
    }
}
