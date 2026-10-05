import SwiftUI

// YUI-216, pick your crew: a new account's first minute. After sign-in, Yui asks who joins
// (Arnold, Basil, Gouda, Penny, Quill). Each has a short page, and "Bring my own agent" is a
// row in the same list that leads into pairing. The pick is saved on the account
// (yui-agents crew_choose), so the picker never comes back. Yui is always on the crew.
// Own file on purpose: YUI-217 builds on the first run next.

private extension CrewStarter {
    /// The face the rows draw, before it is an agent in the list.
    var face: YuiAgent {
        YuiAgent(id: base, name: name, handle: base, color: color, avatar: base == "yui" ? "yui" : nil,
                 kind: "hosted", status: .connected, isDefault: false, sort: 0)
    }
}

struct CrewPickView: View {
    /// Done: the agent to open (a paired one after "Say hi"), or nil for Yui.
    let finish: (String?) -> Void
    @Environment(AgentStore.self) private var store
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var picked: Set<String> = []
    @State private var detail: CrewStarter?
    @State private var working = false
    @State private var error: String?
    @State private var pairing = false

    private var crew: [CrewStarter] { store.crew ?? [] }
    private var others: [CrewStarter] { crew.filter { $0.base != "yui" } }
    private var yui: CrewStarter? { crew.first { $0.base == "yui" } }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Wordmark(height: 48, centered: false)
                    Text("Hi, I'm Yui.\nLet's pick your crew.")
                        .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                        .accessibilityIdentifier("crew-pick-title")
                    Text("Tap to add. Change it any time.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    if let yui { yuiRow(yui, c) }
                    ForEach(others) { row($0, c) }
                    blankRow
                    ownRow(c)
                    if let error {
                        Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, theme.spacing.xl)
                .padding(.top, theme.spacing.l)
                .padding(.bottom, theme.spacing.xl)
            }
            .background {
                // The wash the sign-in screen and the stage wear: one place from the first screen on.
                ZStack {
                    c.background
                    RadialGradient(colors: [c.accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                                   center: .top, startRadius: 0, endRadius: 520)
                }
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom) {
                PillButton(title: startTitle, working: working) { Task { await start() } }
                    .accessibilityIdentifier("crew-start")
                    .padding(.horizontal, theme.spacing.xl).padding(.vertical, theme.spacing.m)
                    .background(c.background)
            }
            .navigationDestination(item: $detail) { s in
                CrewAgentPage(starter: s, picked: picked.contains(s.base)) { toggle(s.base) }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $pairing, onDismiss: { finish(nil) }) {
            // Paired and "Say hi": that agent's thread is the chat.
            AddAgentSheet { id in
                pairing = false
                finish(id)
            }
            .presentationDetents([.large])
            .presentationCornerRadius(theme.radius.card)
            .environment(\.yuiTheme, theme)
        }
    }

    private var startTitle: String {
        picked.isEmpty ? "Start with Yui" : "Start with Yui and \(picked.count)"
    }

    private func toggle(_ base: String) {
        withAnimation(theme.spring) {
            if picked.contains(base) { picked.remove(base) } else { picked.insert(base) }
        }
    }

    private func yuiRow(_ s: CrewStarter, _ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            AgentBadge(agent: s.face, size: 44).environment(\.yuiTheme, s.face.yuiTheme)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yui").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                Text("Always with you").font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(c.inkSoft)
        }
        .padding(theme.spacing.s)
        .background(c.surface.opacity(0.6), in: .rect(cornerRadius: theme.radius.bubble))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yui, always with you")
    }

    private func row(_ s: CrewStarter, _ c: Swatch) -> some View {
        let on = picked.contains(s.base)
        return HStack(spacing: 0) {
            Button { toggle(s.base) } label: {
                HStack(spacing: theme.spacing.s) {
                    AgentBadge(agent: s.face, size: 44).environment(\.yuiTheme, s.face.yuiTheme)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        Text(s.tagline ?? s.role)
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            .multilineTextAlignment(.leading).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(on ? c.accent : c.inkSoft.opacity(0.7))
                }
                .contentShape(.rect)
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(on ? "\(s.name), added" : "Add \(s.name), \(s.role)")
            .accessibilityIdentifier("crew-pick-\(s.base)")
            Button { detail = s } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(c.inkSoft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("About \(s.name)")
            .accessibilityIdentifier("crew-more-\(s.base)")
        }
        .padding(.leading, theme.spacing.s).padding(.vertical, theme.spacing.xs)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(on ? c.accent : c.outline, lineWidth: on ? 2 : 1))
    }

    /// Start blank (YUI-138): saves the pick so far, makes the empty agent and opens its setup flow.
    private var blankRow: some View {
        StartBlankRow(working: working) { Task { await startBlank() } }
    }

    private func startBlank() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await store.chooseCrew(others.map(\.base).filter { picked.contains($0) })
            finish(try await store.startBlank())
        } catch {
            self.error = "Couldn't start a blank agent just now. Check your connection and tap again."
        }
    }

    /// The branch into pairing: same list, same weight as a starter.
    private func ownRow(_ c: Swatch) -> some View {
        Button { Task { await bringOwn() } } label: {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "link")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(c.accent)
                    .frame(width: 44, height: 44)
                    .background(c.accent.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bring my own agent").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    Text("Hermes, OpenClaw, Claude Code or something else")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.leading).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(c.inkSoft)
            }
            .padding(theme.spacing.s)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble)
                .stroke(c.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(working)
        .accessibilityIdentifier("crew-own")
    }

    private func start() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await store.chooseCrew(others.map(\.base).filter { picked.contains($0) })
            finish(nil)
        } catch {
            self.error = "Couldn't save your crew just now. Check your connection and tap again."
        }
    }

    /// Saves the pick so far, then opens pairing. Closing pairing ends the picker either way.
    private func bringOwn() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await store.chooseCrew(others.map(\.base).filter { picked.contains($0) }, own: true)
            pairing = true
        } catch {
            self.error = "Couldn't save your crew just now. Check your connection and tap again."
        }
    }
}

/// "Start blank" (YUI-138): the dashed row under the crew, in the first-run picker and in Add agent.
/// A new empty agent whose first screen is a setup flow (name, how it talks, look, screens, model).
struct StartBlankRow: View {
    var working = false
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(c.accent)
                    .frame(width: 44, height: 44)
                    .background(c.accent.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start blank").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    Text("Make your own. Five taps and it's yours.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.leading).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(c.inkSoft)
            }
            .padding(theme.spacing.s)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble)
                .stroke(c.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(working)
        .accessibilityIdentifier("crew-blank")
    }
}

/// One starter's short page: what it does and what to ask it. Add it from here.
struct CrewAgentPage: View {
    let starter: CrewStarter
    let picked: Bool
    let toggle: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                AgentBadge(agent: starter.face, size: 88).environment(\.yuiTheme, starter.face.yuiTheme)
                Text(starter.name)
                    .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                Text(starter.role)
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                if let tagline = starter.tagline {
                    Text(tagline).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                }
                if let about = starter.about {
                    Text(about).font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                }
                if let can = starter.can, !can.isEmpty {
                    Text("Try asking").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                        .padding(.top, theme.spacing.s)
                    ForEach(can, id: \.self) { ask in
                        Text(ask)
                            .font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                            .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
                            .background(c.surface, in: .rect(cornerRadius: theme.radius.pill))
                            .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(c.outline, lineWidth: 1))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.spacing.xl)
        }
        .background(c.background)
        .safeAreaInset(edge: .bottom) {
            PillButton(title: picked ? "Added. Tap to remove" : "Add \(starter.name)", systemImage: picked ? "checkmark" : "plus", action: toggle)
                .accessibilityIdentifier("crew-page-add")
                .padding(.horizontal, theme.spacing.xl).padding(.vertical, theme.spacing.m)
                .background(c.background)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
