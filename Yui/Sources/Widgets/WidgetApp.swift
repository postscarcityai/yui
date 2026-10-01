import AppIntents
import CoreSpotlight
import Foundation
import UIKit
import WidgetKit
import YuiLines

// The app's half of widgets and Siri (YUI-40 steps 2 to 4, spec WIDGETS.md sections 3, 5, 6, 7).

@MainActor
enum WidgetApp {
    /// The running app's account, for intents that run in the app's process with no scene (Siri, a widget's Start).
    /// Two accounts in one process would spend one refresh token twice, so intents never make their own.
    static var account: Account?

    /// Siri can start the app cold to run an intent: wait a moment for `YuiApp.init` to have set the account.
    static func waitForAccount() async -> Account? {
        for _ in 0..<20 {
            if let account { return account }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return account
    }

    /// Launch and every time the app comes forward: ticks made on a widget reach the app's own lists,
    /// events that could not go out do, and the relay learns which saved screens this phone has pinned.
    static func foreground(_ account: Account) async {
        applyTicks()
        await WidgetQueue.flush()
        await WidgetRegistry.sync(account: account)
    }

    /// A tick made on a widget is a tick in the app (before the next publish writes the copy back).
    static func applyTicks() {
        for t in WidgetTickLog.take() { ListTicks.shared.set(t.agentID, t.partID, item: t.item, on: t.checked) }
    }

    /// Signed out: the relay forgets this phone's pins and the copies go (nothing of the account stays in the app group).
    static func signOut(_ account: Account) async {
        await WidgetRegistry.forget(account: account)
        WidgetSync.clear()
        AgentHandles.clear()
    }
}

/// Tells yui-widgets which saved screens are pinned (WidgetCenter's current configurations) and what lasting
/// ids they hold, with the widget push token, so an agent's patch can reload the right widget.
@MainActor
enum WidgetRegistry {
    private static let sentKey = "widgetRegistered"

    /// The pins as the relay wants them: one per pinned saved screen, with its lasting ids.
    static func pinList(_ configs: [(screen: ScreenEntity, hide: Bool)], snapshot: WidgetSnapshot) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for c in configs {
            guard let s = snapshot.screens.first(where: { $0.id == c.screen.id }), seen.insert(s.id).inserted else { continue }
            let ids = s.parts.filter { $0.ylID.range(of: #"^[nc]\d+$"#, options: .regularExpression) == nil }
                .map { ["id": $0.ylID, "preset": $0.preset] }
            out.append(["agent_id": s.agentID, "screen": s.name, "ids": ids])
        }
        return out
    }

    static func sync(account: Account) async {
        guard let user = account.session?.userID, user != "demo" else { return }
        let infos = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        let configs = infos.filter { $0.kind == WidgetKinds.savedScreen }.compactMap { info -> (ScreenEntity, Bool)? in
            guard let c = info.widgetConfigurationIntent(of: SavedScreenConfig.self), let s = c.screen else { return nil }
            return (s, c.hideOnLock)
        }
        let pins = pinList(configs.map { (screen: $0.0, hide: $0.1) }, snapshot: WidgetStore.read())
        let token = WidgetSecrets.token
        // Nothing pinned and nothing registered: nothing to say.
        if pins.isEmpty, token == nil { return }
        let push = WidgetSecrets.pushToken
        func signature(_ token: String?) -> String {
            let pinned = pins.map { p in
                let ids = (p["ids"] as? [[String: String]] ?? []).map { $0["id"] ?? "" }.joined(separator: ",")
                return "\(p["agent_id"] ?? "")/\(p["screen"] ?? "")/\(ids)"
            }
            return ([WidgetBudget.dayKey(.now), user, token ?? "", push ?? ""] + pinned.sorted()).joined(separator: "|")
        }
        let defaults = WidgetGroup.defaults
        if defaults.string(forKey: Self.sentKey) == signature(token) { return }
        guard let bearer = try? await account.validAccessToken() else { return }
        var body: [String: Any] = ["action": "register", "pins": pins, "environment": PushCenter.environment,
                                   "build": Int(PushCenter.build) ?? 0]
        if let token { body["widget_token"] = token }
        if let push { body["push_token"] = push }
        guard let reply = await call(body, bearer: bearer), let fresh = reply["widget_token"] as? String else { return }
        // No pins left: the token has nothing to read, so it goes too.
        WidgetSecrets.token = pins.isEmpty ? nil : fresh
        defaults.set(signature(pins.isEmpty ? nil : fresh), forKey: Self.sentKey)
        // The widgets now have a token: whatever waited for one can go out.
        await WidgetQueue.flush()
    }

    /// Sign out: every pin of this phone is forgotten on the relay.
    static func forget(account: Account) async {
        guard WidgetSecrets.token != nil, let bearer = try? await account.validAccessToken() else { WidgetSecrets.token = nil; return }
        _ = await call(["action": "register", "pins": [], "widget_token": WidgetSecrets.token ?? ""], bearer: bearer)
        WidgetSecrets.token = nil
        WidgetGroup.defaults.removeObject(forKey: sentKey)
    }

    private static func call(_ body: [String: Any], bearer: String) async -> [String: Any]? {
        var req = URLRequest(url: YuiBackend.function("yui-widgets"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Spotlight: agent names and saved screen names, nothing else (spec section 7).
enum WidgetIndex {
    static func reindex(_ snap: WidgetSnapshot) async {
        let index = CSSearchableIndex.default()
        let agents = Dictionary(snap.screens.map { ($0.agentID, AgentEntity(id: $0.agentID, name: $0.agentName)) }) { a, _ in a }
        let screens = snap.screens.map { ScreenEntity(id: $0.id, agentID: $0.agentID, agentName: $0.agentName, name: $0.name) }
        try? await index.deleteAppEntities(ofType: AgentEntity.self)
        try? await index.deleteAppEntities(ofType: ScreenEntity.self)
        try? await index.indexAppEntities(Array(agents.values))
        try? await index.indexAppEntities(screens)
    }
}

/// What the widget knows about a timer started from it: the Live Activity's key, and when the running phase ends.
@MainActor
enum WidgetLive {
    static func key(agent: String, screen: String, part: String) -> String { "widget|\(agent)|\(screen)|\(part)" }

    private static func parts(_ key: String) -> (agent: String, screen: String, part: String)? {
        let p = key.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        return p.count == 4 && p[0] == "widget" ? (p[1], p[2], p[3]) : nil
    }

    static func report(key: String, state: TimerActivityAttributes.ContentState) {
        set(key: key, live: state.phase == .done ? nil : key, endsAt: state.running && state.phase != .up && state.phase != .done ? state.end : nil)
    }

    static func clear(key: String) { set(key: key, live: nil, endsAt: nil) }

    private static func set(key: String, live: String?, endsAt: Date?) {
        guard let k = parts(key) else { return }
        var changed = false
        WidgetStore.update { snap in
            guard let si = snap.screens.firstIndex(where: { $0.agentID == k.agent && $0.name == k.screen }),
                  let pi = snap.screens[si].parts.firstIndex(where: { $0.ylID == k.part }) else { return }
            let part = snap.screens[si].parts[pi]
            guard part.liveKey != live || part.endsAt != endsAt else { return }
            snap.screens[si].parts[pi].liveKey = live
            snap.screens[si].parts[pi].endsAt = endsAt
            changed = true
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.savedScreen) }
    }
}
