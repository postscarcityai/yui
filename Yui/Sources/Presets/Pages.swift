import SwiftUI
import YuiLines

// Pages (YUI-31, spec yuigui/spec/YL.md section 5, "Pages"): the chat, then a
// page for each screen the agent puts something on, `>2` up to `>12`. Screens
// keep what lands there across replies; a reply that sends a line there brings
// the page forward, and the chat keeps an "On screen 2" pill. `>N clear` empties
// a screen and takes its page away.

/// The chat and the agent's screens, one swipe apart.
struct PagedThread<Chat: View>: View {
    let store: ChatStore
    /// The pages there are: 1 (the chat), then each screen with something on it.
    let screens: [Int]
    /// The page on show, bound to the paging scroll.
    @Binding var page: Int?
    /// Reduce Motion moves between pages with a cross-fade instead of a slide.
    var fade: Double = 1
    var agent: YuiAgent?
    var style: [String: String] = [:]
    @ViewBuilder var chat: () -> Chat

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                chat()
                    .containerRelativeFrame(.horizontal)
                    .id(1)
                ForEach(screens.dropFirst(), id: \.self) { n in
                    ScreenPage(number: n, parts: store.onPage(n), agent: agent, style: style) { store.openStage($0) }
                    .containerRelativeFrame(.horizontal)
                    .id(n)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        // Chat only: nothing to swipe to, so the chat doesn't rubber-band sideways.
        .scrollDisabled(screens.count < 2)
        .opacity(fade)
        // Reduce Motion jumps without animation, and a jump to a page that just
        // arrived can stop short while the pager is still sizing it: scroll there
        // again once it has settled, before the fade-in ends.
        .onChange(of: page) { _, n in
            guard let n, fade < 1 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if page == n { proxy.scrollTo(n, anchor: .leading) }
            }
        }
        }
    }
}

/// Above the composer when there is more than the chat (ChatView puts it in the
/// composer's inset, which every page respects): a small chat glyph, then one
/// dot per screen. The one on show is filled and wider.
struct PageTabs: View {
    let page: Int
    let screens: [Int]
    let go: (Int) -> Void
    @Namespace private var tabs
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: 0) {
            ForEach(screens, id: \.self) { n in
                let on = n == page
                Button { go(n) } label: {
                    Group {
                        if n == 1 {
                            Image(systemName: on ? "bubble.left.fill" : "bubble.left")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(on ? c.accent : c.inkSoft)
                        } else {
                            ZStack {
                                Capsule().fill(c.inkSoft.opacity(0.45)).frame(width: 7, height: 7)
                                if on {
                                    Capsule().fill(c.accent).frame(width: 18, height: 7)
                                        .matchedGeometryEffect(id: "on", in: tabs)
                                }
                            }
                        }
                    }
                    // Small to look at, a full finger to tap.
                    .frame(minWidth: n == 1 ? 30 : (on ? 30 : 20), minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(n == 1 ? "Chat" : "Screen \(n)")
                .accessibilityValue(on ? "showing" : "")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("page-tab-\(n)")
            }
        }
        .padding(.horizontal, 6)
        .background(c.surface, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
        .animation(theme.spring, value: page)
        .animation(theme.spring, value: screens)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-tabs")
        .frame(maxWidth: .infinity)
    }
}

/// A screen beside the chat: everything the agent put there, oldest reply first.
struct ScreenPage: View {
    let number: Int
    let parts: [ChatMessage]
    var agent: YuiAgent?
    var style: [String: String] = [:]
    let openStage: (String) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = theme.swatch(scheme)
        Group {
            if parts.isEmpty {
                VStack(spacing: theme.spacing.m) {
                    Text("\(number)")
                        .font(theme.font(theme.type.display, .black))
                        .foregroundStyle(c.onAccent)
                        .frame(width: 64, height: 64)
                        .background(c.accent.opacity(0.85), in: Circle())
                    Text("Screen \(number)")
                        .font(theme.font(theme.type.title, theme.strong))
                        .foregroundStyle(c.ink)
                    Text("Nothing here yet. \(agent?.name ?? "Your agent") puts things here that should stay while you chat, like a timer or a list.")
                        .font(theme.font(theme.type.body))
                        .foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.center)
                }
                .padding(theme.spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.spacing.m) {
                        ForEach(parts) { m in
                            if let yl = m.yl {
                                VStack(alignment: .leading, spacing: theme.spacing.m) {
                                    YLItemsView(items: YLItem.layout(yl.onPage(number, style: style), pills: nil)) { openStage(m.id) }
                                }
                                .environment(\.ylScope, m.id)
                                .environment(\.ylComponents, yl.components)
                                .transition(reduceMotion ? .opacity
                                            : .scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.vertical, theme.spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The nav bar with its round glass buttons is taller than the safe area it
                // reports, so a page's first card would start under it (the chat is
                // anchored to the bottom and never shows this).
                .contentMargins(.top, theme.spacing.xl, for: .scrollContent)
            }
        }
        .background(c.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-\(number)")
    }
}

/// Where page components sit in the chat: one pill per run that goes to the page.
struct PagePill: View {
    let page: Int
    let components: [YLComponent]
    @Environment(\.ylPage) private var go
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button { go(page) } label: {
            HStack(spacing: theme.spacing.s) {
                Text("\(page)")
                    .font(theme.font(theme.type.body, .black))
                    .foregroundStyle(c.onAccent)
                    .frame(width: 30, height: 30)
                    .background(c.accent, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text("On screen \(page)")
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.inkSoft)
                    Text(title)
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(c.ink)
                        .lineLimit(1)
                }
                if components.count > 1 {
                    Text("+\(components.count - 1)")
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.inkSoft)
                }
                Image(systemName: "chevron.right")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.inkSoft)
            }
            .padding(.leading, theme.spacing.xs)
            .padding(.trailing, theme.spacing.m)
            .padding(.vertical, theme.spacing.xs)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Go to screen \(page), \(title)")
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
    }

    /// Named after the first thing on it that has a name.
    private var title: String {
        for c in components {
            if let t = c.string("label") ?? c.string("title") ?? c.string("q") ?? c.string("prompt") ?? c.string("text"),
               !t.isEmpty { return t }
        }
        return components[0].preset.capitalized
    }
}
