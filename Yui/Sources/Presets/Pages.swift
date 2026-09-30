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
        // swipe (YUI-102): the finger lifts, the page settles.
        .onScrollPhaseChange { old, new in
            if old == .interacting, new != .interacting { Perf.shared.begin(.swipe) }
            if new == .idle { Perf.shared.end(.swipe) }
            if new == .interacting { Perf.shared.cancel(.swipe) }
        }
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
    @Environment(\.ylAgent) private var agentID

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
                        shareRow(c)
                    }
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.vertical, theme.spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A screen has no nav bar (ChatView hides it off the chat and lays two buttons over the top): room
                // under them for the first card.
                .contentMargins(.top, theme.spacing.xl + 52, for: .scrollContent)
            }
        }
        .background(c.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-\(number)")
    }

    /// A page of checklists (Basil's grocery list by aisle, YUI-183) goes out as plain
    /// words: the aisles as headers, what is still to get under each, ticks left off.
    @ViewBuilder
    private func shareRow(_ c: Swatch) -> some View {
        let all = parts.flatMap { $0.yl?.onPage(number, style: style) ?? [] }
        let sections = ChecklistText.sections(all, agent: agentID)
        if sections.contains(where: { !$0.items.isEmpty }) {
            let title = all.first { $0.preset == "stat" }?.string("label")
            ShareLink(item: ChecklistText.text(title: title, sections)) {
                Label("Share list", systemImage: "square.and.arrow.up")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(c.ink)
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.vertical, theme.spacing.m)
                    .frame(maxWidth: .infinity)
                    .background(c.surface, in: Capsule())
                    .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("page-share-\(number)")
        }
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
