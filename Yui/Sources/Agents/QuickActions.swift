import SwiftUI
import UIKit
import YuiLines

// Hold the Yui icon, see your agents' shortcuts (YUI-191). The same `menu shortcut`
// lines that fill an agent's drawer are the candidates; iOS shows up to four as
// dynamic home screen quick actions. The person's picks (Settings > Home screen
// actions) win over the default: one per agent, newest used first.

/// One shortcut an agent put in its drawer, as a candidate for the icon.
struct QuickCandidate: Identifiable, Equatable {
    let agentID: String
    let agentName: String
    let item: YLMenuItem
    var id: String { Self.key(agentID, item.id) }
    static func key(_ agent: String, _ item: String) -> String { "\(agent)/\(item)" }
}

enum QuickActions {
    /// iOS shows about four.
    static let cap = 4
    static let type = "com.yuigui.app.quick"
    static let picksKey = "quickActionPicks"
    static let usedKey = "quickActionUsed"

    /// What the icon shows. `picks` (nil until the person chooses) wins, in their order, minus
    /// any that left the drawer. Otherwise the default: newest used first, then drawer order, one per
    /// agent before any agent gets a second, up to `cap`.
    static func pick(_ all: [QuickCandidate], picks: [String]?, used: [String: Date]) -> [QuickCandidate] {
        if let picks {
            return Array(picks.compactMap { key in all.first { $0.id == key } }.prefix(cap))
        }
        var perAgent: [String: [QuickCandidate]] = [:]
        var order: [String] = []
        for c in all {
            if perAgent[c.agentID] == nil { order.append(c.agentID) }
            perAgent[c.agentID, default: []].append(c)
        }
        // Inside an agent: used newest first, then the order it sent them.
        for (agent, list) in perAgent {
            let ranked = list.enumerated().sorted { a, b in
                let ua = used[a.element.id] ?? .distantPast, ub = used[b.element.id] ?? .distantPast
                return ua != ub ? ua > ub : a.offset < b.offset
            }
            perAgent[agent] = ranked.map(\.element)
        }
        // Agents with the newest use first, ties in list order.
        let agents = order.enumerated().sorted { a, b in
            let ua = used[perAgent[a.element]![0].id] ?? .distantPast, ub = used[perAgent[b.element]![0].id] ?? .distantPast
            return ua != ub ? ua > ub : a.offset < b.offset
        }.map(\.element)
        var out: [QuickCandidate] = []
        var round = 0
        while out.count < cap {
            var added = false
            for agent in agents where out.count < cap {
                if let list = perAgent[agent], round < list.count { out.append(list[round]); added = true }
            }
            if !added { break }
            round += 1
        }
        return out
    }

    /// Every shortcut across the agents this person can see. A client sees only what was shared
    /// with them, because `agents` is their list (a revoke drops the agent and its shortcuts).
    static func candidates(agents: [YuiAgent], menu: (String) -> AgentMenu = { AgentMenu.load(agentID: $0) }) -> [QuickCandidate] {
        agents.flatMap { agent in
            menu(agent.id).shortcuts.filter { $0.url == nil }.map {
                QuickCandidate(agentID: agent.id, agentName: agent.name, item: $0)
            }
        }
    }

    static var picks: [String]? {
        get { UserDefaults.standard.stringArray(forKey: picksKey) }
        set { UserDefaults.standard.set(newValue, forKey: picksKey) }
    }

    static var used: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: usedKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) } }
        set { UserDefaults.standard.set(newValue.mapValues(\.timeIntervalSince1970), forKey: usedKey) }
    }

    /// The icon menu, now. Signed out: nothing.
    @MainActor
    static func refresh(agents: [YuiAgent], signedIn: Bool) {
        let shown = signedIn ? pick(candidates(agents: agents), picks: picks, used: used) : []
        UIApplication.shared.shortcutItems = shown.map { c in
            var info: [String: NSSecureCoding] = ["agent": c.agentID as NSString, "item": c.item.id as NSString]
            if let say = c.item.say { info["say"] = say as NSString }
            return UIApplicationShortcutItem(
                type: type, localizedTitle: c.item.label, localizedSubtitle: c.agentName,
                icon: UIApplicationShortcutIcon(systemImageName: symbol(for: c.item)), userInfo: info)
        }
    }

    /// An SF Symbol by keyword in what the shortcut says.
    static func symbol(for item: YLMenuItem) -> String {
        let words = "\(item.label) \(item.say ?? "")".lowercased()
        let table: [(String, String)] = [
            ("food", "fork.knife"), ("meal", "fork.knife"), ("eat", "fork.knife"), ("grocer", "cart"),
            ("workout", "figure.strengthtraining.traditional"), ("progress", "chart.line.uptrend.xyaxis"),
            ("practice", "music.note"), ("beat", "music.note"), ("jam", "music.note"), ("tune", "tuningfork"),
            ("review", "checkmark.circle"), ("to-do", "checklist"), ("plan", "calendar"), ("week", "calendar"),
            ("learn", "book"), ("problem", "lightbulb"), ("log", "plus.circle"),
        ]
        return table.first { words.contains($0.0) }?.1 ?? "bubble.left"
    }

    /// The tap, kept until a thread can take it.
    @MainActor
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == type, let agent = item.userInfo?["agent"] as? String,
              let id = item.userInfo?["item"] as? String else { return false }
        QuickActionTap.shared.pending = QuickActionTap.Tap(agentID: agent, itemID: id, say: item.userInfo?["say"] as? String,
                                                           label: item.localizedTitle)
        var used = used
        used[QuickCandidate.key(agent, id)] = .now
        self.used = used
        return true
    }
}

/// A quick action tapped and not yet sent.
@MainActor @Observable
final class QuickActionTap {
    static let shared = QuickActionTap()
    struct Tap: Equatable { let agentID: String; let itemID: String; let say: String?; let label: String }
    var pending: Tap?
}

/// Cold launch and a tap while the app runs both come through the scene.
final class YuiSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { Task { @MainActor in _ = QuickActions.handle(item) } }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in completionHandler(QuickActions.handle(shortcutItem)) }
    }
}

// MARK: Settings > Home screen actions

/// Every shortcut across the agents; up to four go on the icon, in the order the person drags them.
struct HomeActionsSection: View {
    @Environment(AgentStore.self) private var agents
    @Environment(Account.self) private var account
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var picks: [String]? = QuickActions.picks
    @State private var all: [QuickCandidate] = []

    private var shown: [String] {
        picks ?? QuickActions.pick(all, picks: nil, used: QuickActions.used).map(\.id)
    }

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Home screen actions").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            Text("Hold the Yui icon to see up to four. Your agents fill the list. You choose.")
                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            if all.isEmpty {
                Text("Your agents haven't added any yet.").font(theme.font(theme.type.body)).foregroundStyle(c.ink)
            }
            // On the icon first, in order; drag a row to move it.
            ForEach(shown.compactMap { key in all.first { $0.id == key } }) { row($0, on: true, c) }
            ForEach(all.filter { !shown.contains($0.id) }) { row($0, on: false, c) }
            if picks != nil {
                Button("Back to the default") { set(nil) }
                    .font(theme.font(theme.type.caption, .semibold)).tint(c.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("home-actions-default")
            }
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
        .animation(theme.spring, value: shown)
        .task(id: agents.agents) { all = QuickActions.candidates(agents: agents.agents) }
    }

    private func row(_ cand: QuickCandidate, on: Bool, _ c: Swatch) -> some View {
        let full = shown.count >= QuickActions.cap
        return HStack(spacing: theme.spacing.m) {
            Toggle(isOn: Binding(get: { on }, set: { toggle(cand, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cand.item.label).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                    Text(cand.agentName).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
            }
            .tint(c.accent)
            .disabled(!on && full)
            if on {
                Image(systemName: "line.3.horizontal").foregroundStyle(c.inkSoft)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("home-action-\(cand.id)")
        .modifier(DragToOrder(id: cand.id, enabled: on) { move($0, before: cand.id) })
        .accessibilityAction(named: "Move up") { nudge(cand.id, -1) }
        .accessibilityAction(named: "Move down") { nudge(cand.id, 1) }
    }

    private func toggle(_ cand: QuickCandidate, _ on: Bool) {
        var list = shown
        if on, list.count < QuickActions.cap, !list.contains(cand.id) { list.append(cand.id) }
        if !on { list.removeAll { $0 == cand.id } }
        set(list)
    }

    private func move(_ id: String, before target: String) {
        var list = shown
        guard id != target, let from = list.firstIndex(of: id), let to = list.firstIndex(of: target) else { return }
        list.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        set(list)
    }

    private func nudge(_ id: String, _ by: Int) {
        var list = shown
        guard let i = list.firstIndex(of: id), list.indices.contains(i + by) else { return }
        list.swapAt(i, i + by)
        set(list)
    }

    private func set(_ list: [String]?) {
        picks = list
        QuickActions.picks = list
        QuickActions.refresh(agents: agents.agents, signedIn: account.isSignedIn)
    }
}

private struct DragToOrder: ViewModifier {
    let id: String
    let enabled: Bool
    let drop: (String) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first else { return false }
                    drop(first)
                    return true
                }
        } else {
            content
        }
    }
}

/// Keeps the icon menu current: when the agents change, when someone signs in or out, and as the
/// app leaves the screen. `-yuiDemoQuickAction <agent>/<item>[/<say>]` (dev builds) sends the tap a held icon sends.
struct QuickActionHooks: ViewModifier {
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: agents.agents) { refresh() }
            .onChange(of: account.isSignedIn) { refresh() }
            .onChange(of: scenePhase) { if scenePhase != .active { refresh() } }
            #if DEBUG
            .task {
                let d = UserDefaults.standard
                guard let raw = d.string(forKey: "yuiDemoQuickAction") else { return }
                let parts = raw.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return }
                var info: [String: NSSecureCoding] = ["agent": parts[0] as NSString, "item": parts[1] as NSString]
                if parts.count == 3 { info["say"] = parts[2] as NSString }
                _ = QuickActions.handle(UIApplicationShortcutItem(type: QuickActions.type, localizedTitle: parts[1],
                                                                  localizedSubtitle: nil, icon: nil, userInfo: info))
            }
            #endif
    }

    private func refresh() { QuickActions.refresh(agents: agents.agents, signedIn: account.isSignedIn) }
}
