import SwiftUI
import YuiLines

// An agent's home (YUI-168, spec yuigui/spec/HOME.md, mock www.yuigui.com/mockups/home).
// Chris on build 244: "when I go to one of these agent screens, I should see a unique set
// of shortcuts ... Notifications should really just be right on this home screen." Screen 1
// with nothing new on it is the home: the agent's face and what it does, what is waiting on
// you, and its shortcuts as big chips over the bar. Its starter screens are a swipe left.
// Everything comes from lines the agent already sends: `menu shortcut` for the chips, the
// thread's open asks and `menu review` for Waiting on you, pages for the screens.

/// The home's rules, shared by the stage and the drawer.
@MainActor
enum AgentHome {
    /// Chips the home shows: the newest four shortcuts, newest first.
    static let maxChips = 4
    /// Asks and notes the home lists before See all.
    static let maxWaiting = 3

    static func chips(_ store: ChatStore) -> [YLMenuItem] { Array(store.menu.shortcuts.prefix(maxChips)) }

    /// The page a shortcut's `show=` goes to: the page its saved screen was saved from,
    /// while that page is still there. That page is the live one, patched and current.
    static func page(for item: YLMenuItem, in store: ChatStore) -> Int? {
        guard let name = item.show, let first = store.shelf[name]?.parts.first else { return nil }
        let n = YuiLines.page(of: first.screen)
        return n > 1 && store.screens.contains(n) ? n : nil
    }

    /// What a shortcut does: its live page, else its saved screen on the stage, else its
    /// words go as the person's message (words ending in a space go in the field to finish).
    static func tap(_ item: YLMenuItem, store: ChatStore, goPage: (Int) -> Void, compose: (String) -> Void) {
        if let n = page(for: item, in: store) {
            goPage(n)
        } else if let name = item.show, store.shelf[name] != nil {
            store.reopen(name)
        } else {
            MenuAction.shortcut(item, store: store, compose: compose)
        }
    }

    /// One row of Waiting on you: an ask in the thread, or an item the agent put in Review.
    struct Waiting: Identifiable {
        let id: String
        let title: String
        let sub: String?
        let ask: ReviewItem?
        let item: YLMenuItem?
    }

    /// The thread's open asks, then the agent's review items not yet tapped (the same items
    /// as the drawer's Review, so answering one here clears it there).
    static func waiting(_ store: ChatStore) -> [Waiting] {
        store.awaitingYou.map { Waiting(id: "ask-\($0.id)", title: $0.title, sub: $0.detail, ask: $0, item: nil) }
            + store.menu.waiting.map { Waiting(id: "menu-\($0.id)", title: $0.label, sub: $0.sub, ask: nil, item: $0) }
    }
}

/// The shortcuts as chips over the bar: two to a row and big on the home, one small row
/// over an answer so they stay a thumb away.
struct HomeChips: View {
    let items: [YLMenuItem]
    var small = false
    let tap: (YLMenuItem) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if small {
                HStack(spacing: theme.spacing.s) {
                    ForEach(items) { chip($0) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.spacing.s), GridItem(.flexible())], spacing: theme.spacing.s) {
                    ForEach(items) { chip($0) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(small ? "home-chips-small" : "home-chips")
    }

    private func chip(_ item: YLMenuItem) -> some View {
        let c = theme.swatch(scheme)
        // A screen to open, words to finish in the field (a pencil: the text cursor read as a stray "A|"), or words that send.
        let icon = item.show != nil ? "rectangle.portrait.on.rectangle.portrait.fill"
            : item.say?.hasSuffix(" ") == true ? "pencil" : "sparkles"
        return Button { tap(item) } label: {
            HStack(spacing: small ? 6 : theme.spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: small ? 12 : 15, weight: .bold))
                    .foregroundStyle(c.accent)
                Text(item.label)
                    .font(theme.font(small ? theme.type.caption : theme.type.body, .heavy))
                    .foregroundStyle(c.ink)
                    .lineLimit(small ? 1 : 2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, small ? theme.spacing.m : theme.spacing.m)
            .frame(maxWidth: .infinity, minHeight: small ? 40 : 58)
            // Liquid Glass with a wash of the agent's color: they sit over the bar, with the rest of its glass.
            .glassEffect(.regular.tint(c.accent.opacity(small ? 0.10 : 0.16)).interactive(), in: .rect(cornerRadius: small ? 20 : 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(item.label)
        .accessibilityHint(item.show != nil ? "Opens that screen" : item.say?.hasSuffix(" ") == true
                           ? "Starts a message to finish" : "Sends it as your message")
        .accessibilityIdentifier("home-chip-\(item.id)")
    }
}

/// The top of the home: the agent's face, its name and what it does, then what is waiting
/// on you (up to three, See all opens the drawer). With nothing waiting it says nothing more:
/// the screens are the pills up top, and a line saying so was one more thing to read.
struct HomeHead: View {
    let agent: YuiAgent?
    /// One line under the name: what the agent does.
    let line: String
    let waiting: [AgentHome.Waiting]
    let open: (AgentHome.Waiting) -> Void
    let seeAll: () -> Void
    /// Dismiss on a row the host asked (YUI-265); nil when the row cannot be dismissed.
    var dismiss: ((AgentHome.Waiting) -> Void)? = nil
    /// The shader draws the agent (YUI-232): its orb is its face, in the place kept here. Off (the
    /// person switched the visual off, or the agent wears another look): its badge.
    var orb = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView {
            VStack(spacing: theme.spacing.l) {
                VStack(spacing: theme.spacing.s) {
                    if orb {
                        OrbSlot(size: StageFirstView.orbFace).padding(.bottom, theme.spacing.s)
                    } else if let agent {
                        AgentBadge(agent: agent, size: 72)
                            .shadow(color: c.accent.opacity(0.35), radius: 24, y: 6)
                    }
                    if let agent {
                        Text(agent.name)
                            .font(theme.font(theme.type.display, .heavy))
                            .foregroundStyle(c.ink)
                    }
                    Text(line)
                        .font(theme.font(theme.type.body))
                        .foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stage-greeting")
                if !waiting.isEmpty { list(c) }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.l)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center)
        .accessibilityIdentifier("stage-home")
    }

    private func list(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack {
                Text("Waiting on you")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.inkSoft)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if waiting.count > AgentHome.maxWaiting {
                    Button("See all \(waiting.count)", action: seeAll)
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.accent)
                        .accessibilityIdentifier("home-see-all")
                }
            }
            ForEach(waiting.prefix(AgentHome.maxWaiting)) { w in
                HStack(spacing: theme.spacing.s) {
                    Button { open(w) } label: {
                        HStack(spacing: theme.spacing.m) {
                            Circle().fill(c.accent).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.title)
                                    .font(theme.font(theme.type.body, .bold))
                                    .foregroundStyle(c.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if let sub = w.sub, !sub.isEmpty {
                                    Text(sub)
                                        .font(theme.font(theme.type.caption))
                                        .foregroundStyle(c.inkSoft)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(c.inkSoft)
                        }
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(BounceButtonStyle())
                    .accessibilityHint("Opens it to answer")
                    .accessibilityIdentifier("home-\(w.id)")
                    if let dismiss, w.item != nil {
                        Button { dismiss(w) } label: {
                            Text("Dismiss")
                                .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(c.inkSoft)
                                .padding(.horizontal, theme.spacing.s).frame(minHeight: 36)
                                .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
                                .contentShape(.capsule)
                        }
                        .buttonStyle(BounceButtonStyle())
                        .accessibilityHint("Takes it off your list for good")
                        .accessibilityIdentifier("home-dismiss-\(w.id)")
                    }
                }
                .padding(theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline, lineWidth: 1.5))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-waiting")
    }
}

/// Where the person is among the screens, for VoiceOver only: the screens have no dots
/// (Chris, Sep 27: "i don't think we need the little slider dots anymore"), so this reads
/// "Screen 2 of 4" and swiping up or down on it pages, like the dots' adjustable action did.
struct PagePosition: View {
    let page: Int
    let screens: [Int]
    /// What screen 1 is: the home on the stage, the chat in the chat.
    var first = "Home"
    let go: (Int) -> Void

    var body: some View {
        let i = screens.firstIndex(of: page) ?? 0
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityElement()
            .accessibilityLabel(i == 0 ? first : "Screen \(page)")
            .accessibilityValue("\(i + 1) of \(screens.count)")
            .accessibilityHint("Swipe up or down to change screens")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAdjustableAction { d in
                switch d {
                case .increment: if screens.indices.contains(i + 1) { go(screens[i + 1]) }
                case .decrement: if i > 0 { go(screens[i - 1]) }
                @unknown default: break
                }
            }
            .accessibilityIdentifier("page-position")
    }
}

/// The stage's screen pills (YUI-193, Chris Sep 28: "some pills for the screens ... kind of like
/// tabs on an internet browser. I can click them. They fade out to the right and I can slide them
/// back and forth. And when I swipe left and right through the screens, it just shows me which
/// screen I'm on with an active pill"). One pill per screen, the first the home, the rest by
/// their titles. The one on show is filled in the agent's accent and scrolls into view as the
/// screens turn; a tap on a pill goes to that screen. The row scrolls sideways and fades out at
/// the right edge when it overflows.
/// VoiceOver hears the pills as buttons, and `page-position` still says "Screen 2, 2 of 4"
/// and pages when adjusted.
struct ScreenPills: View {
    let screens: [Int]
    /// The screen on show.
    let page: Int
    let title: (Int) -> String
    let go: (Int) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var room: CGFloat = 0
    @State private var content: CGFloat = 0

    static let height: CGFloat = 38, fade: CGFloat = 28

    var body: some View {
        let c = theme.swatch(scheme)
        let overflows = content > room + 1
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: theme.spacing.s) {
                    ForEach(screens, id: \.self) { n in
                        let on = n == page
                        Button { if !on { go(n) } } label: {
                            Text(n == 1 ? "Home" : title(n))
                                .font(theme.font(theme.type.caption, .bold))
                                .foregroundStyle(on ? c.onAccent : c.ink)
                                .lineLimit(1)
                                .padding(.horizontal, theme.spacing.m)
                                .frame(height: Self.height)
                                // Glass, the one on show tinted in the agent's color.
                                .glassEffect(on ? .regular.tint(c.accent).interactive() : .regular.interactive(), in: .capsule)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(BounceButtonStyle())
                        .id(n)
                        .accessibilityLabel(n == 1 ? "Home" : title(n))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("screen-pill-\(n)")
                    }
                }
                .padding(.trailing, overflows ? Self.fade : 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { content = $0 }
            }
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { room = $0 }
            .onChange(of: page, initial: true) { _, n in
                withAnimation(reduceMotion ? nil : theme.spring) { proxy.scrollTo(n, anchor: .center) }
            }
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                if overflows {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                }
            }
        }
        .frame(height: 44)
        .background { PagePosition(page: page, screens: screens, go: go) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-pills")
    }
}
