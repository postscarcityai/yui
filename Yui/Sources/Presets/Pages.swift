import SwiftUI
import YuiLines

// Pages (YUI-31, spec yuigui/spec/YL.md section 5, "Pages"): every agent gets
// three screens side by side. Page 1 is the chat; screens 2 and 3 are a swipe
// away and keep what the agent puts there across replies. A reply that sends
// a line there brings the page forward; the chat keeps an "On screen 2" pill.

/// The chat and the agent's two screens, one swipe apart.
struct PagedThread<Chat: View>: View {
    let store: ChatStore
    /// The page on show, bound to the paging scroll (1, 2 or 3).
    @Binding var page: Int?
    /// Reduce Motion moves between pages with a cross-fade instead of a slide.
    var fade: Double = 1
    var agent: YuiAgent?
    var style: [String: String] = [:]
    @ViewBuilder var chat: () -> Chat

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                chat()
                    .containerRelativeFrame(.horizontal)
                    .id(1)
                ForEach([2, 3], id: \.self) { n in
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
        .opacity(fade)
    }
}

/// Chat · 2 · 3 above the composer (ChatView puts it in the composer's inset,
/// which every page respects). The highlight slides to the page on
/// show; a dot marks a page with something on it.
struct PageTabs: View {
    let page: Int
    let filled: Set<Int>
    let go: (Int) -> Void
    @Namespace private var tabs
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { n in
                let on = n == page
                Button { go(n) } label: {
                    Text(n == 1 ? "Chat" : "\(n)")
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(on ? c.onAccent : c.inkSoft)
                        .frame(minWidth: n == 1 ? 56 : 40, minHeight: 36)
                        .background {
                            if on { Capsule().fill(c.accent).matchedGeometryEffect(id: "on", in: tabs) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if filled.contains(n), !on {
                                Circle().fill(c.accent).frame(width: 6, height: 6).padding(.top, 7).padding(.trailing, 8)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(n == 1 ? "Chat" : "Screen \(n)")
                .accessibilityValue(on ? "showing" : filled.contains(n) ? "has something on it" : "")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("page-tab-\(n)")
            }
        }
        .padding(3)
        .background(c.surface, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
        .animation(theme.spring, value: page)
        .frame(maxWidth: .infinity)
    }
}

/// Screen 2 or 3: everything the agent put there, oldest reply first.
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
