import SwiftUI
import UIKit
import YuiLines

// The agent's home (YUI-54, Chris picked "Peek and tabs"): a drawer from the left
// with everything about the agent you're talking to. A drag to the right on the
// chat pulls it out and it follows the finger; it stops short of the right edge
// so the chat stays in view, and a tap on that sliver or a drag back closes it.
// Tabs: Home (pinned screens, what's next, the agent's backlog and screens,
// shortcuts), Review (what's waiting on you, answered in place), Controls, About.
// The agent sits at the bottom; a tap there opens the switcher, which springs up.
// The agent fills three lists itself with `menu` lines (YUI-86): review items
// sit under the thread's asks in Review, backlog and shortcuts on Home.

enum Drawer {
    /// Share of the screen the drawer covers. One constant, so it can shrink later.
    static let fraction: CGFloat = 0.86
    /// Past this share of the width (or a flick) a drag opens or closes it.
    static let threshold: CGFloat = 0.35
    static let flick: CGFloat = 600
}

// MARK: What's waiting on you

/// One ask in the thread with no answer yet: a question, a pick, a form, a plan.
struct ReviewItem: Identifiable, Equatable {
    let message: ChatMessage
    /// The ask itself and what came just before it in the reply (the card or
    /// mocks it asks about), in line order.
    let parts: [YLComponent]
    let ask: YLComponent
    var id: String { "\(message.id)#\(ask.serial)" }

    var kicker: String {
        switch ask.preset {
        case "choose": "Pick one"
        case "pick": "Pick any"
        case "form": "Fill in"
        case "plan": "Plan"
        case "slide": "Set it"
        default: "Question"
        }
    }

    /// The card it asks about, else the question, else the ask's own title.
    var title: String {
        let context = parts.last { $0.serial != ask.serial && $0.string("title") != nil }
        return context?.string("title") ?? ask.string("q") ?? ask.string("title") ?? kicker
    }

    /// The card's body, or the question when the title came from the card.
    var detail: String? {
        let context = parts.last { $0.serial != ask.serial && $0.string("title") != nil }
        if let context { return context.string("body") ?? context.string("sub") ?? ask.string("q") }
        return ask.string("q") == title ? nil : ask.string("q")
    }

    /// The parts as the open card shows them: the card's big heading already says
    /// the title, so a part carrying the same title drops it and keeps its body.
    var openParts: [YLComponent] {
        parts.map { p in
            guard p.serial != ask.serial, p.string("title") == title else { return p }
            var p = p
            p.props["title"] = nil
            return p
        }
    }
}

extension ChatStore {
    static let asks: Set<String> = ["ask", "choose", "pick", "form", "plan", "slide"]

    /// Asks the person hasn't answered, newest first. An ask counts while its
    /// reply is the newest one using its id (a re-sent screen replaces the old
    /// one), and either it sits on a screen beside the chat or nothing was said
    /// after it (typing past a question answers it, or lets it go).
    var awaitingYou: [ReviewItem] {
        // Reading both keeps the views that ask observing them.
        let messages = messages, answers = answers
        if let waitingCache { return waitingCache }
        let lastSaid = messages.lastIndex(where: \.fromUser) ?? -1
        var seen = Set<String>()
        var out: [ReviewItem] = []
        for (i, m) in messages.enumerated().reversed() {
            guard !m.fromUser, let yl = m.yl, !m.id.hasPrefix("shelf-") else { continue }
            let top = yl.top
            for (j, c) in top.enumerated().reversed() {
                let fresh = seen.insert(c.ylID).inserted
                guard fresh, Self.asks.contains(c.preset), !c.locked, answers[m.id]?[c.ylID] == nil,
                      c.page != 1 || i > lastSaid else { continue }
                // What leads up to it: back to the previous ask, at most two parts, same screen.
                var parts = [c]
                var k = j - 1
                while k >= 0, parts.count < 3, !Self.asks.contains(top[k].preset), top[k].screen == c.screen {
                    parts.insert(top[k], at: 0)
                    k -= 1
                }
                out.append(ReviewItem(message: m, parts: parts, ask: c))
            }
        }
        waitingCache = out
        return out
    }

    /// Everything waiting on the person: the thread's open asks plus the agent's review items.
    var waitingCount: Int { awaitingYou.count + menu.review.count }
}

// MARK: The drawer

struct AgentDrawer: View {
    let store: ChatStore
    /// Opens a page beside the chat, or the stage for a pinned screen: the drawer closes first.
    let close: () -> Void
    /// Puts words in the composer (a shortcut that takes more after it).
    let compose: (String) -> Void
    let manage: () -> Void
    let add: () -> Void
    let edit: (YuiAgent) -> Void
    var reduceMotion = false
    @Environment(AgentStore.self) private var agents
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var tab = DrawerTab.home
    @State private var switching = ProcessInfo.processInfo.arguments.contains("-yuiDrawerSwitcher")
    @Namespace private var tabs

    var body: some View {
        let c = theme.swatch(scheme)
        let waiting = store.awaitingYou
        VStack(alignment: .leading, spacing: 0) {
            header(c)
            TabStrip(tab: $tab, tabs: DrawerTab.shown(for: store.agent), review: waiting.count + store.menu.review.count, ns: tabs)
                .padding(.horizontal, theme.spacing.l)
                .padding(.bottom, theme.spacing.m)
            ScrollView {
                Group {
                    switch tab {
                    case .home: DrawerHome(store: store, waiting: waiting, close: close, compose: compose) { tab = .review }
                    case .review: DrawerReview(store: store, items: waiting, close: close, compose: compose)
                    case .controls: DrawerControls(store: store, close: close, edit: edit)
                    case .about: DrawerAbout(agent: store.agent)
                    }
                }
                .padding(.horizontal, theme.spacing.l)
                .padding(.bottom, theme.spacing.xl)
                .transition(.opacity)
            }
            .scrollIndicators(.hidden)
            .animation(reduceMotion ? nil : theme.spring, value: tab)
            AgentBar(agent: store.agent) { switching = true }
                .padding(.horizontal, theme.spacing.m)
                .padding(.bottom, theme.spacing.s)
        }
        .background(c.background)
        .overlay {
            if switching {
                Switcher(current: store.agent, reduceMotion: reduceMotion, done: { switching = false },
                         pick: { id in
                             switching = false
                             agents.selectedID = id
                             close()
                         },
                         add: { switching = false; add() },
                         manage: { switching = false; manage() })
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: switching)
        .sensoryFeedback(.selection, trigger: switching)
        .onChange(of: store.agent?.id, initial: true) {
            if !DrawerTab.shown(for: store.agent).contains(tab) { tab = .home }
        }
    }

    private func header(_ c: Swatch) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.agent?.name ?? "Yui")
                .font(theme.font(34, theme.strong))
                .foregroundStyle(c.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.spacing.m)
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(theme.font(theme.type.body, .bold))
                .foregroundStyle(c.inkSoft)
                .frame(width: 36, height: 36)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1))
                .accessibilityIdentifier("drawer-close")
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.m)
        .padding(.bottom, theme.spacing.m)
    }
}

enum DrawerTab: String, CaseIterable, Identifiable {
    case home = "Home", review = "Review", controls = "Controls", about = "About"
    var id: String { rawValue }

    /// Only the owner sees Controls (YUI-70): a shared agent's drawer has none.
    static func shown(for agent: YuiAgent?) -> [DrawerTab] {
        agent?.isShared == true ? allCases.filter { $0 != .controls } : allCases
    }
}

/// Four tabs in a capsule; the one on show sits on a coral pill that slides between them.
private struct TabStrip: View {
    @Binding var tab: DrawerTab
    let tabs: [DrawerTab]
    let review: Int
    let ns: Namespace.ID
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue)
                            .font(theme.font(15, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if t == .review, review > 0 {
                            Text("\(review)")
                                .font(theme.font(11, .heavy))
                                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                                .background(tab == t ? c.surface.opacity(0.9) : c.accent, in: Capsule())
                                .foregroundStyle(tab == t ? c.ink : c.onAccent)
                        }
                    }
                    .foregroundStyle(tab == t ? c.onAccent : c.inkSoft)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background {
                        if tab == t {
                            Capsule().fill(c.accent).matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t == .review && review > 0 ? "Review, \(review) waiting" : t.rawValue)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
                .accessibilityIdentifier("drawer-tab-\(t.rawValue.lowercased())")
            }
        }
        .padding(4)
        .background(c.surface, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
        .animation(theme.spring, value: tab)
        .sensoryFeedback(.selection, trigger: tab)
    }
}

/// A section's small heading.
private struct DrawerHeading: View {
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .heavy))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .padding(.top, theme.spacing.l)
            .padding(.bottom, theme.spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tappable row: a round icon, a title, a quieter line under it, a chevron.
private struct DrawerRow: View {
    let icon: String
    let title: String
    var sub: String?
    var tint: Color?
    var trailing: String = "chevron.right"
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            HStack(spacing: theme.spacing.m) {
                Image(systemName: icon)
                    .font(theme.font(15, .bold))
                    .foregroundStyle(c.ink)
                    .frame(width: 34, height: 34)
                    .background((tint ?? c.lavender).opacity(0.7), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let sub {
                        Text(sub).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: trailing).font(theme.font(13, .bold)).foregroundStyle(c.inkSoft)
            }
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.m)
            .background(c.surface, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(BounceButtonStyle())
    }
}

// MARK: Home

private struct DrawerHome: View {
    let store: ChatStore
    let waiting: [ReviewItem]
    let close: () -> Void
    let compose: (String) -> Void
    let review: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let name = store.agent?.name ?? "Yui"
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            DrawerHeading(text: "Pinned screens")
            let pinned = store.shelf.screens
            if pinned.isEmpty {
                Text("Nothing pinned yet. Ask \(name) to save a screen you'll want again, like a workout.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    .padding(theme.spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: theme.spacing.m) {
                        ForEach(Array(pinned.enumerated()), id: \.element.name) { i, s in
                            PinnedTile(screen: s, tint: [c.lavender, c.mint, c.butter][i % 3]) {
                                close()
                                store.reopen(s.name)
                            } remove: { store.unshelve(s.name) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }

            let count = waiting.count + store.menu.review.count
            if let next = waiting.first.map({ ($0.title, $0.kicker) })
                ?? store.menu.review.first.map({ ($0.label, $0.sub ?? "For you") }) {
                DrawerHeading(text: "Next up for you")
                Button(action: review) {
                    HStack(spacing: theme.spacing.m) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(theme.font(17, .bold)).foregroundStyle(c.onAccent)
                            .frame(width: 38, height: 38).background(c.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.0).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Text(next.1).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        }
                        Spacer(minLength: 0)
                        Text("\(count)")
                            .font(theme.font(13, .heavy)).foregroundStyle(c.onAccent)
                            .frame(minWidth: 26, minHeight: 26).background(c.accent, in: Circle())
                    }
                    .padding(theme.spacing.m)
                    .background(c.accent.opacity(0.12), in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.accent.opacity(0.4), lineWidth: 1.5))
                }
                .buttonStyle(BounceButtonStyle())
                .accessibilityLabel("Next up: \(next.0). \(count) waiting on you")
                .accessibilityIdentifier("drawer-next-up")
            }

            // What the agent is working on for you (`menu backlog`).
            let backlog = store.menu.backlog
            if !backlog.isEmpty {
                DrawerHeading(text: "Backlog")
                ForEach(backlog) { item in
                    DrawerRow(icon: MenuAction.icon(item, fallback: "hourglass"), title: item.label, sub: item.sub,
                              tint: c.lavender, trailing: MenuAction.trailing(item)) {
                        MenuAction.open(item, bucket: "backlog", store: store, close: close, openURL: openURL)
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { store.removeFromMenu(item.id) }
                    }
                    .accessibilityIdentifier("drawer-backlog-\(item.id)")
                }
            }

            let screens = store.screens.dropFirst()
            if !screens.isEmpty {
                DrawerHeading(text: "Screens")
                ForEach(Array(screens), id: \.self) { n in
                    DrawerRow(icon: "rectangle.portrait.on.rectangle.portrait.fill", title: store.pageTitle(n),
                              sub: "Screen \(n)", tint: c.mint) {
                        close()
                        store.goToPage(n)
                    }
                    .accessibilityIdentifier("drawer-screen-\(n)")
                }
            }

            // The agent's own shortcuts (`menu shortcut`) first, then the host's commands.
            let mine = store.menu.shortcuts
            let shortcuts = (store.agent?.commands ?? []).prefix(6)
            if !shortcuts.isEmpty || !mine.isEmpty {
                DrawerHeading(text: "Shortcuts")
                ForEach(mine) { item in
                    DrawerRow(icon: "sparkles", title: item.label, sub: item.sub, tint: c.butter,
                              trailing: item.say?.hasSuffix(" ") == true ? "text.cursor" : "paperplane.fill") {
                        close()
                        MenuAction.shortcut(item, store: store, compose: compose)
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { store.removeFromMenu(item.id) }
                    }
                    .accessibilityHint(item.say?.hasSuffix(" ") == true ? "Starts a message to finish" : "Sends it as your message")
                    .accessibilityIdentifier("drawer-shortcut-\(item.id)")
                }
                ForEach(Array(shortcuts)) { cmd in
                    DrawerRow(icon: "bolt.fill", title: cmd.description.isEmpty ? "/\(cmd.name)" : cmd.description,
                              sub: "/\(cmd.name)\(cmd.args.map { " " + $0 } ?? "")", tint: c.butter) {
                        close()
                        if cmd.args == nil { _ = store.send("/\(cmd.name)") } else { compose("/\(cmd.name) ") }
                    }
                }
            }
        }
    }
}

/// A pinned screen as a tall pastel card. Tap opens it full screen; hold for Remove.
private struct PinnedTile: View {
    let screen: SavedScreen
    let tint: Color
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: screen.stage || screen.parts.contains(where: \.isWorkout) ? "figure.run" : "star.fill")
                    .font(theme.font(24, .bold)).foregroundStyle(c.ink.opacity(0.8))
                Spacer(minLength: 0)
                Text(screen.name)
                    .font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                    .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
                Text(screen.parts.count == 1 ? "1 part" : "\(screen.parts.count) parts")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.ink.opacity(0.65))
            }
            .padding(theme.spacing.l)
            .frame(width: 138, height: 164, alignment: .leading)
            .background(tint.opacity(scheme == .dark ? 0.55 : 1), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(BounceButtonStyle())
        .contextMenu {
            Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
        }
        .accessibilityLabel("Open \(screen.name)")
        .accessibilityHint("Pinned screen. Opens full screen.")
        .accessibilityIdentifier("drawer-pin-\(screen.name)")
    }
}

extension ChatStore {
    /// What a screen beside the chat is called: its first title, else "Screen n".
    func pageTitle(_ n: Int) -> String {
        for m in messages.reversed() {
            guard let yl = m.yl else { continue }
            if let t = yl.top.first(where: { $0.page == n })?.string("title") ?? yl.top.first(where: { $0.page == n })?.string("q") {
                return t
            }
        }
        return "Screen \(n)"
    }
}

// MARK: Review

private struct DrawerReview: View {
    let store: ChatStore
    let items: [ReviewItem]
    let close: () -> Void
    let compose: (String) -> Void
    @State private var open: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let flagged = store.menu.review
        let count = items.count + flagged.count
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if count == 0 {
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    Text("All caught up.")
                        .font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                    Text("When \(store.agent?.name ?? "your agent") asks you something, it waits here until you answer.")
                        .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                }
                .padding(.top, theme.spacing.xl)
            } else {
                Text(count == 1 ? "1 thing is waiting on you" : "\(count) things are waiting on you")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                ForEach(items) { item in
                    ReviewCard(item: item, open: open == item.id, store: store) {
                        withAnimation(theme.spring) { open = open == item.id ? nil : item.id }
                    }
                }
                // What the agent flagged for you (`menu review`): a tap opens it.
                ForEach(flagged) { item in
                    MenuReviewCard(item: item, agent: store.agent?.name ?? "Your agent") {
                        MenuAction.open(item, bucket: "review", store: store, close: close, openURL: openURL)
                    } remove: { store.removeFromMenu(item.id) }
                }
            }
        }
        .onAppear { if open == nil { open = items.first?.id } }
    }
}

/// An ask as a card: the kicker, a big title, a line of context. Tap and it opens
/// in place with the whole ask and its answer buttons; the answer goes back like
/// a tap in the chat, and the card leaves the list.
private struct ReviewCard: View {
    let item: ReviewItem
    let open: Bool
    let store: ChatStore
    let toggle: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: theme.spacing.m) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.kicker)
                            .font(theme.font(12, .heavy)).textCase(.uppercase).kerning(0.8)
                            .foregroundStyle(c.accent)
                        Text(item.title)
                            .font(theme.font(open ? 26 : 21, theme.strong))
                            .foregroundStyle(c.ink)
                            .lineLimit(open ? 4 : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !open, let d = item.detail {
                            Text(d).font(theme.font(15)).foregroundStyle(c.inkSoft).lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(theme.font(14, .bold)).foregroundStyle(c.inkSoft)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .padding(.top, 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.kicker): \(item.title)")
            .accessibilityHint(open ? "Folds it away" : "Opens it here to answer")
            .accessibilityIdentifier("review-\(item.ask.ylID)")

            if open, let yl = item.message.yl {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    YLItemsView(items: YLItem.layout(item.openParts, pills: nil))
                }
                .environment(\.ylScope, item.message.id)
                .environment(\.ylComponents, yl.components)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(open ? c.accent.opacity(0.5) : c.outline, lineWidth: 1.5))
    }
}

/// An item the agent flagged with `menu review`: the same card as an ask, but a
/// tap opens what it points at (a saved screen, a link, or the agent's answer).
private struct MenuReviewCard: View {
    let item: YLMenuItem
    let agent: String
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: open) {
            HStack(alignment: .top, spacing: theme.spacing.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(agent)")
                        .font(theme.font(12, .heavy)).textCase(.uppercase).kerning(0.8)
                        .foregroundStyle(c.accent)
                    Text(item.label)
                        .font(theme.font(21, theme.strong)).foregroundStyle(c.ink)
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sub = item.sub {
                        Text(sub).font(theme.font(15)).foregroundStyle(c.inkSoft).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: MenuAction.trailing(item))
                    .font(theme.font(14, .bold)).foregroundStyle(c.onAccent)
                    .frame(width: 30, height: 30).background(c.accent, in: Circle())
            }
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(c.outline, lineWidth: 1.5))
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(BounceButtonStyle())
        .contextMenu {
            Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
        }
        .accessibilityLabel("From \(agent): \(item.label)")
        .accessibilityHint(MenuAction.hint(item))
        .accessibilityIdentifier("review-menu-\(item.id)")
    }
}

/// What a tap on an agent's drawer item does (spec YL.md section 5, The drawer).
@MainActor
enum MenuAction {
    /// A review or backlog item: its saved screen on the stage, its link in
    /// Safari, else back to the agent, who answers with the screen.
    static func open(_ item: YLMenuItem, bucket: String, store: ChatStore, close: () -> Void, openURL: OpenURLAction) {
        if let name = item.show, store.shelf[name] != nil {
            close()
            store.reopen(name)
        } else if let link = url(item) {
            openURL(link)
        } else {
            close()
            store.tapMenu(item, bucket: bucket)
        }
    }

    /// A shortcut sends its words as the person's message; words that end in a
    /// space go in the composer to finish.
    static func shortcut(_ item: YLMenuItem, store: ChatStore, compose: (String) -> Void) {
        let words = item.say ?? item.label
        if words.hasSuffix(" ") { compose(words) } else { _ = store.send(words) }
    }

    static func url(_ item: YLMenuItem) -> URL? {
        guard let raw = item.url, let u = URL(string: raw), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    static func icon(_ item: YLMenuItem, fallback: String) -> String {
        item.show != nil ? "star.fill" : url(item) != nil ? "link" : fallback
    }

    static func trailing(_ item: YLMenuItem) -> String {
        url(item) != nil ? "arrow.up.right" : item.show != nil ? "arrow.up.left.and.arrow.down.right" : "arrow.right"
    }

    static func hint(_ item: YLMenuItem) -> String {
        url(item) != nil ? "Opens in Safari" : item.show != nil ? "Opens full screen" : "Asks for it in the chat"
    }
}

// MARK: Controls

/// The agent's own settings, straight on its computer (YUI-70, spec yuigui
/// spec/CONTROLS.md): one row per area its host reports; each opens its screen.
/// A host that reports nothing gets the About card and one line. An offline host
/// greys the rows out instead of queueing changes.
private struct DrawerControls: View {
    let store: ChatStore
    let close: () -> Void
    let edit: (YuiAgent) -> Void
    /// The area on show, with its model: one value, so the sheet never opens without it.
    @State private var open: Opened?

    struct Opened: Identifiable {
        let section: ControlSection
        let model: ControlsModel
        var id: String { section.rawValue }
    }
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let name = store.agent?.name ?? "your agent"
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if let agent = store.agent, let report = agent.controls, !report.shown.isEmpty {
                DrawerHeading(text: "In Yui")
                DrawerRow(icon: "paintpalette.fill", title: "Name, look and notifications",
                          sub: agent.muted ? "Notifications off" : "Notifications on", tint: c.accent.opacity(0.6)) {
                    edit(agent)
                }
                .accessibilityIdentifier("drawer-edit-agent")
                DrawerHeading(text: "On its computer")
                let live = agent.liveness == .online
                if !live {
                    Label("\(name)'s computer is \(agent.liveness.spoken). Controls come back when it's online.",
                          systemImage: "moon.zzz.fill")
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(c.inkSoft)
                        .padding(.bottom, theme.spacing.xs)
                        .accessibilityIdentifier("controls-offline")
                }
                ForEach(report.shown) { s in
                    DrawerRow(icon: s.icon, title: s.title, sub: s.sub(name), tint: tint(s, c)) {
                        if let m = store.controlsModel() { open = Opened(section: s, model: m) }
                    }
                    .disabled(!live)
                    .opacity(live ? 1 : 0.45)
                    .accessibilityIdentifier("controls-\(s.rawValue)")
                }
            } else {
                ControlsAboutCard(agent: store.agent) { if let a = store.agent { edit(a) } }
                Text("This agent's host doesn't share its settings yet.")
                    .font(theme.font(15)).foregroundStyle(c.inkSoft)
                    .padding(.top, theme.spacing.s)
                    .accessibilityIdentifier("controls-not-shared")
            }
        }
        .sheet(item: $open) { o in
            ControlsSheet(model: o.model, section: o.section, agentID: store.agent?.id ?? "")
                .environment(\.yuiTheme, theme)
        }
    }

    private func tint(_ s: ControlSection, _ c: Swatch) -> Color {
        switch s {
        case .soul, .schedules: c.lavender
        case .memory, .channels: c.mint
        case .skills, .model: c.butter
        }
    }
}

/// The About card, for a host that shares no settings: who it is, where it runs.
private struct ControlsAboutCard: View {
    let agent: YuiAgent?
    let edit: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        if let agent {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                HStack(spacing: theme.spacing.m) {
                    AgentBadge(agent: agent, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                        StatusLine(agent: agent)
                    }
                    Spacer(minLength: 0)
                }
                if !agent.isShared {
                    Button("Name, look and notifications", systemImage: "paintpalette.fill", action: edit)
                        .font(theme.font(15, .bold))
                        .foregroundStyle(c.accent)
                        .accessibilityIdentifier("drawer-edit-agent")
                }
            }
            .padding(theme.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.surface, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
            .padding(.top, theme.spacing.m)
            .accessibilityIdentifier("controls-about-card")
        }
    }
}

// MARK: About

private struct DrawerAbout: View {
    let agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let agent {
                HStack(spacing: theme.spacing.m) {
                    AgentBadge(agent: agent, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                        StatusLine(agent: agent)
                    }
                }
                .padding(.top, theme.spacing.s)
                VStack(alignment: .leading, spacing: 0) {
                    fact("Runs on", agent.connectorName ?? host(agent.kind))
                    if let ref = agent.remoteRef, !ref.isEmpty { fact("Profile", ref) }
                    if let n = agent.commands?.count, n > 0 { fact("Commands", "\(n)") }
                    if agent.isDefault { fact("Default", "Yes") }
                }
                .background(c.surface, in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                Text("What it does")
                    .font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                Text("Yui doesn't own your agent, so this comes from where it runs. Once its host shares a profile, what it does, what it can reach and which model it uses show here.")
                    .font(theme.font(15)).foregroundStyle(c.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(theme.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    private func host(_ kind: String) -> String {
        switch kind {
        case "hermes": "Hermes"
        case "openclaw": "OpenClaw"
        case "mcp": "MCP"
        case "a2a": "A2A"
        case "webhook": "Webhook"
        default: kind.capitalized
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        let c = theme.swatch(scheme)
        return HStack {
            Text(label).font(theme.font(15)).foregroundStyle(c.inkSoft)
            Spacer()
            Text(value).font(theme.font(15, .bold)).foregroundStyle(c.ink)
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.m)
        .accessibilityElement(children: .combine)
    }
}

// MARK: The agent at the bottom, and the switcher

private struct AgentBar: View {
    let agent: YuiAgent?
    let open: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: open) {
            HStack(spacing: theme.spacing.m) {
                if let agent { AgentBadge(agent: agent, size: 42) } else { YuiAvatar(size: 42) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.name ?? "Yui").font(theme.font(theme.type.body, theme.strong)).foregroundStyle(c.ink)
                    if let agent { StatusLine(agent: agent) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(theme.font(14, .heavy)).foregroundStyle(c.inkSoft)
            }
            .padding(theme.spacing.m)
            .background(c.surface, in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(c.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Talking to \(agent?.name ?? "Yui"). Switch agent")
        .accessibilityIdentifier("drawer-agent-bar")
    }
}

/// Every agent, rising from the bar one at a time. Search once there are many.
private struct Switcher: View {
    let current: YuiAgent?
    let reduceMotion: Bool
    let done: () -> Void
    let pick: (String) -> Void
    let add: () -> Void
    let manage: () -> Void
    @Environment(AgentStore.self) private var agents
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var shown = false
    @State private var query = ""

    private var list: [YuiAgent] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? agents.agents : agents.agents.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let c = theme.swatch(scheme)
        ZStack(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(c.background.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture(perform: done)
                .accessibilityLabel("Close the agent list")
                .accessibilityAddTraits(.isButton)
            ScrollView {
                VStack(spacing: theme.spacing.s) {
                    Spacer(minLength: 0)
                    if agents.agents.count > 6 {
                        HStack(spacing: theme.spacing.s) {
                            Image(systemName: "magnifyingglass").foregroundStyle(c.inkSoft)
                            TextField("Find an agent", text: $query)
                                .font(theme.font(theme.type.body))
                        }
                        .padding(theme.spacing.m)
                        .background(c.surface, in: Capsule())
                        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
                        .rise(shown, 0, reduceMotion)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        Button { pick(a.id) } label: { row(a, c) }
                            .buttonStyle(BounceButtonStyle())
                            .accessibilityAddTraits(a.id == current?.id ? .isSelected : [])
                            .accessibilityIdentifier("switch-\(a.name)")
                            .rise(shown, list.count - i, reduceMotion)
                    }
                    // A shared agent gone since the app opened (YUI-97): one quiet line each.
                    ForEach(agents.unshared, id: \.self) { name in
                        Text(AgentStore.unsharedLine(name))
                            .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("switch-unshared")
                    }
                    HStack(spacing: theme.spacing.s) {
                        // An invited account starts with what it was given: no Add (YUI-97).
                        if !agents.onlyShared {
                            Button(action: add) {
                                Label("Add an agent", systemImage: "plus")
                                    .font(theme.font(15, .bold)).foregroundStyle(c.onAccent)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(c.accent, in: Capsule())
                            }
                            .accessibilityIdentifier("switch-add")
                        }
                        Button(action: manage) {
                            Label("Edit list", systemImage: "list.bullet")
                                .font(theme.font(15, .bold)).foregroundStyle(c.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(c.surface, in: Capsule())
                                .overlay(Capsule().stroke(c.outline, lineWidth: 1))
                        }
                        .accessibilityIdentifier("switch-manage")
                    }
                    .buttonStyle(BounceButtonStyle())
                    .rise(shown, 0, reduceMotion)
                }
                .padding(.horizontal, theme.spacing.m)
                .padding(.bottom, theme.spacing.s)
                .frame(minHeight: 0, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
        .onAppear { shown = true }
        .accessibilityIdentifier("agent-switcher")
    }

    private func row(_ a: YuiAgent, _ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.m) {
            AgentBadge(agent: a, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(theme.font(theme.type.body, theme.strong)).foregroundStyle(c.ink)
                StatusLine(agent: a)
            }
            Spacer(minLength: 0)
            if a.id == current?.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.font(22, .bold)).foregroundStyle(c.accent)
            }
        }
        .padding(theme.spacing.m)
        .background(c.surface, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(a.id == current?.id ? c.accent.opacity(0.6) : c.outline,
                                                           lineWidth: a.id == current?.id ? 2 : 1))
    }
}

private extension View {
    /// Rises into place after the ones below it (the nearest the bar go first), with a soft bounce.
    /// Reduce Motion: a fade, all together.
    func rise(_ shown: Bool, _ order: Int, _ reduceMotion: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 60)
            .scaleEffect(shown || reduceMotion ? 1 : 0.85, anchor: .bottom)
            .animation(reduceMotion ? .easeOut(duration: 0.2)
                       : .spring(response: 0.42, dampingFraction: 0.62).delay(Double(order) * 0.035), value: shown)
    }
}

// MARK: The drag

/// A sideways pan that only starts when nothing under the finger can scroll that
/// way first: on the chat a right drag opens the drawer, but on screens 2..N the
/// pager pages back toward the chat, and a gallery scrolled along scrolls back.
/// Scroll views under the finger wait for it to fail, so the pager doesn't
/// rubber-band while the drawer follows the finger.
struct DrawerPan: UIGestureRecognizerRepresentable {
    enum Direction { case right, left }
    let direction: Direction
    var enabled = true
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let x = g.translation(in: g.view).x
        switch g.state {
        case .began, .changed: changed(x)
        case .ended: ended(x, g.velocity(in: g.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true
        var direction = Direction.right

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let v = pan.velocity(in: view)
            let sideways = abs(v.x) > abs(v.y) * 1.2
            guard sideways, direction == .right ? v.x > 0 : v.x < 0 else { return false }
            // Anything under the finger that can still scroll this way goes first.
            var hit = view.hitTest(pan.location(in: view), with: nil)
            while let h = hit, h !== view.superview {
                if let s = h as? UIScrollView, s.isScrollEnabled, s.contentSize.width > s.bounds.width + 1 {
                    let x = s.contentOffset.x, lead = -s.adjustedContentInset.left
                    let end = s.contentSize.width - s.bounds.width + s.adjustedContentInset.right
                    if direction == .right ? x > lead + 1 : x < end - 1 { return false }
                }
                if h is UISlider || h is UISwitch { return false }
                hit = h.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView && other is UIPanGestureRecognizer
        }
    }
}
