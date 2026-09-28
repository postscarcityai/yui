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
        let icon = item.show != nil ? "rectangle.portrait.on.rectangle.portrait.fill"
            : item.say?.hasSuffix(" ") == true ? "text.cursor" : "sparkles"
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
            .background(c.accent.opacity(small ? 0.10 : 0.14), in: .rect(cornerRadius: small ? 20 : 22))
            .overlay(RoundedRectangle(cornerRadius: small ? 20 : 22).stroke(c.accent.opacity(0.45), lineWidth: 1.5))
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
/// on you (up to three, See all opens the drawer), or one quiet line when nothing is.
struct HomeHead: View {
    let agent: YuiAgent?
    /// One line under the name: what the agent does.
    let line: String
    let waiting: [AgentHome.Waiting]
    let open: (AgentHome.Waiting) -> Void
    let seeAll: () -> Void
    /// There are screens a swipe away: the quiet line says so.
    var hasScreens = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView {
            VStack(spacing: theme.spacing.l) {
                VStack(spacing: theme.spacing.s) {
                    if let agent {
                        AgentBadge(agent: agent, size: 72)
                            .shadow(color: c.accent.opacity(0.35), radius: 24, y: 6)
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
                if waiting.isEmpty {
                    Text(hasScreens ? "Nothing waiting on you. Swipe left for your screens." : "Nothing waiting on you.")
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("home-quiet")
                } else {
                    list(c)
                }
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
                    .padding(theme.spacing.m)
                    .background(c.surface, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline, lineWidth: 1.5))
                    .contentShape(.rect(cornerRadius: 18))
                }
                .buttonStyle(BounceButtonStyle())
                .accessibilityHint("Opens it to answer")
                .accessibilityIdentifier("home-\(w.id)")
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

/// The stage's dots (YUI-187, Chris Sep 28: "the dots we removed ... i also want those to
/// slide, not fade between them and the dots should animate"). One small dot per screen in
/// the agent's colors. The one on show is a pill that stretches toward the next dot and slides
/// there as the finger drags, read from the pager's offset, so it follows the finger and
/// springs with the page on release. A tap on a dot goes to that screen.
/// They sit in the bottom bar (YUI-189) and fit the room they get: the dots close up first,
/// then only the nearest seven (fewer on a tight bar) show, the ones at a cut edge faded and
/// smaller, and the row slides with the pill.
/// VoiceOver hears one control, as before: "Screen 2, 2 of 4", and swipes up or down to page.
struct PageDots: View, Animatable {
    let screens: [Int]
    /// Where the pager is, in screens: 0 the first, 1.5 halfway from the second to the third.
    var progress: CGFloat
    /// The screen on show, for VoiceOver.
    let page: Int
    /// The width the dots may take, background and all; nil draws them all at full pitch.
    var room: CGFloat? = nil
    let go: (Int) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static let dot: CGFloat = 6, pill: CGFloat = 16, pitch: CGFloat = 14
    /// The closest the dots get, the most drawn at once, and the padding either side.
    static let tightPitch: CGFloat = 10, most = 7, pad: CGFloat = 8

    /// How the row is laid out for `n` screens in `room`: the pitch, the pill, how many dots show.
    struct Layout: Equatable {
        var pitch: CGFloat, pill: CGFloat, shown: Int
        var width: CGFloat { CGFloat(shown - 1) * pitch + pill }
    }

    static func layout(_ n: Int, room: CGFloat?) -> Layout {
        let full = Layout(pitch: pitch, pill: pill, shown: min(n, most))
        guard let room, n > 1 else { return full }
        let inner = room - 2 * pad
        if full.width <= inner { return full }
        // All of them closed up, the pill 2 wider than a dot's pitch: (n - 1) * p + p + 2 fits.
        let p = max(tightPitch, min(pitch, (inner - 2) / CGFloat(n)))
        let pl = min(pill, p + 2)
        let fits = Int(((inner - pl) / p + 0.001).rounded(.down)) + 1
        return Layout(pitch: p, pill: pl, shown: max(2, min(n, most, fits)))
    }

    var body: some View {
        let c = theme.swatch(scheme)
        let n = screens.count
        let l = Self.layout(n, room: room)
        let p = min(max(progress, 0), CGFloat(n - 1))
        let i = screens.firstIndex(of: page) ?? 0
        // The first dot drawn: the window keeps the pill in its middle, stopping at the ends.
        let first = min(max(p - CGFloat(l.shown - 1) / 2, 0), CGFloat(n - l.shown))
        // Between two dots the pill reaches for the next one, most at halfway.
        let between = p - p.rounded(.down)
        let reach = (1 - abs(2 * between - 1)) * l.pitch * 0.7
        ZStack(alignment: .leading) {
            ForEach(0..<n, id: \.self) { k in
                let at = CGFloat(k) - first
                if at > -1, at < CGFloat(l.shown) {
                    // A dot past a cut edge fades out and shrinks as the row slides.
                    let edge = min(at + 1, CGFloat(l.shown) - at, 1)
                    let cut = (k > 0 && at < 0.5) || (k < n - 1 && at > CGFloat(l.shown) - 1.5)
                    let fade = cut ? min(max(edge, 0), 1) * 0.5 : 1
                    Circle().fill(c.inkSoft.opacity(0.4 * fade))
                        .frame(width: Self.dot, height: Self.dot)
                        .scaleEffect(cut ? 0.7 : 1)
                        .position(x: l.pill / 2 + at * l.pitch, y: 15)
                }
            }
            Capsule().fill(c.accent)
                .frame(width: l.pill + reach, height: Self.dot)
                .position(x: l.pill / 2 + (p - first) * l.pitch, y: 15)
        }
        .frame(width: l.width, height: 30)
        .padding(.horizontal, Self.pad)
        .background(c.surface.opacity(0.72), in: Capsule())
        .contentShape(Capsule())
        // A full finger to tap: the nearest dot to the touch.
        .onTapGesture { at in
            let k = Int(((at.x - Self.pad - l.pill / 2) / l.pitch + first).rounded())
            let hit = min(max(k, 0), n - 1)
            if screens[hit] != page { go(screens[hit]) }
        }
        .accessibilityElement()
        .accessibilityLabel(i == 0 ? "Home" : "Screen \(page)")
        .accessibilityValue("\(i + 1) of \(n)")
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
