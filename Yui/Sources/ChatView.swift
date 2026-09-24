import SwiftUI

/// The chat with the selected agent (one thread per agent, over the relay).
/// Agent replies in Yui Lines render inline as presets.
struct ChatView: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(PushCenter.self) private var push
    @Environment(\.agentStyle) private var agentStyle
    @State private var draft = ""
    @State private var store = ChatStore(messages: ChatView.seed)
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    @State private var settingsDetent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-yuiSettingsLarge") ? .large : .medium
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("-yuiAgents")
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        ZStack {
        NavigationStack {
            Group {
                if store.messages.isEmpty && !store.waiting {
                    EmptyChat(agent: store.agent, loading: store.agent != nil && !store.loaded)
                } else {
                    ScrollView {
                        // Not Lazy: LazyVStack drops preset cards from the accessibility tree (iOS 26/27),
                        // so VoiceOver and UI tests saw only the plain bubbles.
                        VStack(spacing: theme.spacing.m) {
                            ForEach(store.messages) { m in
                                if let yl = m.yl {
                                    YLReply(screen: yl, scope: m.id, agent: store.agent, style: agentStyle) { store.openStage(m.id) }
                                } else {
                                    Bubble(message: m, agent: store.agent)
                                }
                            }
                            if store.waiting { TypingDots(agent: store.agent).id("typing") }
                            if let error = store.error {
                                Text(error)
                                    .font(theme.font(theme.type.caption, .semibold))
                                    .foregroundStyle(c.inkSoft)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, theme.spacing.l)
                        .padding(.vertical, theme.spacing.m)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.background)
            .safeAreaInset(edge: .bottom) { inputBar(c) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Your agents", systemImage: "person.2.fill") { showAgents = true }
                        .tint(c.inkSoft)
                }
                ToolbarItem(placement: .principal) {
                    if let agent = store.agent {
                        Button { showAgents = true } label: {
                            HStack(spacing: theme.spacing.s) {
                                AgentBadge(agent: agent, size: 26)
                                Text(agent.name)
                                    .font(theme.font(theme.type.body, theme.strong))
                                    .foregroundStyle(c.ink)
                                Circle().fill(agent.status == .connected ? c.mint : c.outline).frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Talking to \(agent.name), \(agent.status == .connected ? "online" : "offline")")
                    } else {
                        Wordmark(height: 26)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape.fill") { showSettings = true }
                        .tint(c.inkSoft)
                }
            }
            .toolbarBackground(c.background, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large], selection: $settingsDetent)
                    .presentationCornerRadius(theme.radius.card)
            }
            .sheet(isPresented: $showAgents) {
                AgentsView()
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
        }
        // The chat steps back a little while the stage is up (YUI-13).
        .mask { RoundedRectangle(cornerRadius: store.stageOpen ? 38 : 0).ignoresSafeArea() }
        .scaleEffect(store.stageOpen ? 0.92 : 1)
        .background(Color.black.ignoresSafeArea())
        if let m = store.stageMessage, let yl = m.yl, !yl.staged(agentStyle).isEmpty {
            StageView(components: yl.staged(agentStyle), scope: m.id, agent: store.agent, open: store.stageOpen,
                      close: store.closeStage)
                .id(m.id)
                .transition(.opacity)
        }
        }
        .environment(\.ylEmit, store.emit)
        .environment(\.ylTimers, store.timers)
        .onChange(of: agentStyle, initial: true) { store.style = agentStyle }
        .onAppear {
            store.spring = theme.spring
            // A `theme` line in a reply restyles that agent, and the app with it.
            store.onLook = { id, props, at in Task { await agents.applyThemeLine(agentID: id, props: props, at: at) } }
        }
        .onChange(of: theme) { store.spring = theme.spring }
        #if DEBUG
        // -yuiThemeDemo "say Autumn it is.\ntheme autumn": the agent restyles itself, live, for screenshots.
        .task {
            guard let text = UserDefaults.standard.string(forKey: "yuiThemeDemo") else { return }
            try? await Task.sleep(for: .seconds(2.5))
            store.stream(text.replacingOccurrences(of: "\\n", with: "\n"))
        }
        #endif
        .task { await agents.refresh() }
        .onChange(of: agents.selected?.id, initial: true) {
            // The demo account keeps the local demo chat, with the agent's face on it.
            if account.session?.userID == "demo" { store.demo(agents.selected); return }
            store.attach(agents.selected, account: account)
        }
        .onChange(of: agents.selected) { store.refreshAgent(agents.selected) }
        .onChange(of: store.agent?.id, initial: true) { push.visibleAgentID = store.agent?.id }
        // A notification tap or yui://agent/<id>/thread: straight to that thread.
        .onChange(of: push.pendingAgentID, initial: true) {
            guard let id = push.pendingAgentID else { return }
            push.pendingAgentID = nil
            showAgents = false
            showSettings = false
            agents.selectedID = id
            if !agents.agents.contains(where: { $0.id == id }) { Task { await agents.refresh() } }
        }
        .tint(c.accent)
    }

    private func inputBar(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            TextField("Say something nice", text: $draft, axis: .vertical)
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.ink)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.pill))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(c.outline, lineWidth: 1.5))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(theme.font(theme.type.title, .black))
                    .foregroundStyle(draft.isEmpty ? c.inkSoft : c.onAccent)
                    .frame(width: 46, height: 46)
                    .background(draft.isEmpty ? c.outline : c.accent, in: Circle())
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(draft.isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.s)
        .background(c.background)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if store.agent != nil, account.session?.userID != "demo" {
            store.send(text)
            draft = ""
            return
        }
        withAnimation(theme.spring) { store.messages.append(ChatMessage(text: text, fromUser: true)) }
        draft = ""
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(theme.spring) {
                store.messages.append(ChatMessage(text: ChatView.replies.randomElement()!, fromUser: false))
            }
        }
    }

    static let replies = [
        "Noted! My agent friends move in soon, then I can really help.",
        "Mm, I heard you. Real answers arrive with the agents in Phase 1.",
        "Got it. Tucking that away for when my brain shows up.",
    ]

    static let demo = [
        ChatMessage(text: "Hi Yui!", fromUser: true),
        ChatMessage(text: "Hi hi! I'm Yui. Ask me anything, or tell me what you want to get done today.", fromUser: false),
        ChatMessage(text: "Can you set up a 20 minute tabata for me?", fromUser: true),
        ChatMessage(text: "", fromUser: false, yl: YLScreen(YLSamples.text("tabata")!)),
    ]

    /// `-yuiDemo` seeds a chat; `-yuiYL <sample>` seeds one YL reply (see `YLSamples`).
    static var seed: [ChatMessage] {
        if let name = UserDefaults.standard.string(forKey: "yuiYL"), let text = YLSamples.text(name) {
            return [ChatMessage(text: "Show me the \(name) one", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(text))]
        }
        return ProcessInfo.processInfo.arguments.contains("-yuiDemo") ? demo : []
    }
}

/// An agent reply in Yui Lines: the presets in line order, errors underneath.
/// Components that open on the stage show here as one pill that reopens it.
private struct YLReply: View {
    let screen: YLScreen
    let scope: String
    var agent: YuiAgent?
    var style: [String: String] = [:]
    let openStage: () -> Void
    @Environment(\.yuiTheme) private var theme

    /// Inline components as they are; each run of staged ones as one pill.
    private enum Item: Identifiable {
        case inline(YLComponent)
        case pill([YLComponent])
        var id: String {
            switch self {
            case .inline(let c): "c\(c.serial)"
            case .pill(let cs): "p\(cs[0].serial)"
            }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        for c in screen.components {
            if !c.onStage(style) { out.append(.inline(c)); continue }
            if case .pill(let run) = out.last { out[out.count - 1] = .pill(run + [c]) } else { out.append(.pill([c])) }
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            AgentFace(agent: agent)
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                ForEach(items) { item in
                    switch item {
                    case .inline(let c): PresetView(component: c)
                    case .pill(let cs): StagePill(components: cs, scope: scope, open: openStage)
                    }
                }
                ForEach(Array(screen.errors.enumerated()), id: \.offset) { YLErrorRow(node: $1) }
                ForEach(Array(screen.looks.enumerated()), id: \.offset) { _ in LookNote(agent: agent) }
            }
            .environment(\.ylScope, scope)
        }
        .transition(.opacity)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    var agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let r = theme.radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: r.bubble,
            bottomLeadingRadius: message.fromUser ? r.bubble : r.bubbleTail,
            bottomTrailingRadius: message.fromUser ? r.bubbleTail : r.bubble,
            topTrailingRadius: r.bubble)
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            if message.fromUser { Spacer(minLength: 48) } else { AgentFace(agent: agent) }
            Text(message.text)
                .font(theme.font(theme.type.body, .medium))
                .foregroundStyle(message.fromUser ? c.userInk : c.agentInk)
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
                .background(message.fromUser ? c.userBubble : c.agentBubble, in: shape)
                .overlay(shape.stroke(message.fromUser ? .clear : c.outline, lineWidth: 1.5))
            if !message.fromUser { Spacer(minLength: 48) }
        }
        .transition(.scale(scale: 0.85, anchor: message.fromUser ? .bottomTrailing : .bottomLeading)
            .combined(with: .opacity))
    }
}

/// A `theme` line landed: one quiet line, the new look does the talking.
private struct LookNote: View {
    var agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Label("\(agent?.name ?? "Yui") changed its look", systemImage: "paintbrush.pointed.fill")
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(c.inkSoft)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1))
    }
}

/// The agent's face next to its messages: its badge, or Yui's mark in the demo.
private struct AgentFace: View {
    var agent: YuiAgent?
    var body: some View {
        if let agent { AgentBadge(agent: agent, size: 34) } else { YuiAvatar(size: 34) }
    }
}

/// The agent is thinking.
private struct TypingDots: View {
    var agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            AgentFace(agent: agent)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(c.inkSoft).frame(width: 7, height: 7)
                        .phaseAnimator([0.3, 1.0]) { dot, o in dot.opacity(o) } animation: { _ in
                            .easeInOut(duration: 0.5).delay(Double(i) * 0.15)
                        }
                }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m + 4)
            .background(c.agentBubble, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
            Spacer(minLength: 48)
        }
        .accessibilityLabel("\(agent?.name ?? "Yui") is typing")
        .transition(.opacity)
    }
}

private struct EmptyChat: View {
    var agent: YuiAgent? = nil
    var loading = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        if loading {
            ProgressView().tint(c.inkSoft)
        } else if let agent, agent.avatar != "yui" {
            VStack(spacing: theme.spacing.l) {
                AgentBadge(agent: agent, size: 96)
                Text("Say hi to \(agent.name)!")
                    .font(theme.font(theme.type.display, theme.strong))
                    .foregroundStyle(c.ink)
                    .multilineTextAlignment(.center)
                Text(agent.status == .connected ? "Same agent as everywhere else,\nnow with buttons." :
                        "\(agent.name) is offline right now.\nMessages wait until it's back.")
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(c.inkSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(theme.spacing.xl)
        } else {
            greeting(c)
        }
    }

    private func greeting(_ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.l) {
            Wordmark(height: 110)
                .phaseAnimator([false, true]) { view, up in
                    view.offset(y: up ? -6 : 0)
                } animation: { _ in .easeInOut(duration: 1.1) }
            Text("is here, and happy to see you!")
                .font(theme.font(theme.type.display, theme.strong))
                .foregroundStyle(c.ink)
                .multilineTextAlignment(.center)
            Text("Say hi, ask a question, or tell me\nwhat you want to get done.")
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
            HStack(spacing: theme.spacing.s) {
                Chip(text: "Plan my day", color: c.mint)
                Chip(text: "Start a timer", color: c.butter)
                Chip(text: "Surprise me", color: c.lavender)
            }
            .padding(.top, theme.spacing.s)
        }
        .padding(theme.spacing.xl)
    }
}

private struct Chip: View {
    let text: String
    let color: Color
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(Color(hex: theme.light.ink))
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(color, in: Capsule())
    }
}
