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
    /// Bumped on every send: a fresh text field. Clearing `draft` alone can leave
    /// the sent words drawn in the field (TestFlight feedback APthnqcdHvqEP).
    @State private var composerID = 0
    @State private var store = ChatStore(messages: ChatView.seed)
    @State private var outbox = Outbox.shared
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    @State private var settingsDetent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-yuiSettingsLarge") ? .large : .medium
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("-yuiAgents")
    /// The first-run button opens Add agent straight from the chat.
    @State private var addFirst = false
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        ZStack {
        NavigationStack {
            Group {
                if firstRun {
                    FirstRun(loaded: agents.loaded, error: agents.error) {
                        addFirst = true
                    } retry: {
                        Task { await agents.refresh() }
                    }
                } else if store.messages.isEmpty && !store.waiting {
                    EmptyChat(agent: store.agent, loading: store.agent != nil && !store.loaded) { store.send($0) }
                } else {
                    ScrollView {
                        // Not Lazy: LazyVStack drops preset cards from the accessibility tree (iOS 26/27),
                        // so VoiceOver and UI tests saw only the plain bubbles.
                        VStack(spacing: theme.spacing.m) {
                            ForEach(store.messages) { m in
                                if let yl = m.yl {
                                    YLReply(screen: yl, scope: m.id, agent: store.agent, style: agentStyle) { store.openStage(m.id) }
                                } else {
                                    Bubble(message: m, agent: store.agent, pending: outbox.isPending(m.id))
                                }
                            }
                            if let agent = store.agent, outbox.offline, !outbox.pending(agentID: agent.id).isEmpty {
                                // On the phone, not on Yui yet: it sends itself when the connection is back.
                                QuietNote(text: "Not sent yet. It goes the moment you're back online.", icon: "clock")
                            } else if store.waiting, let agent = store.agent, agent.liveness != .online {
                                // Delivered, but the agent's computer is away: say so instead of fake dots.
                                QuietNote(text: agent.liveness == .asleep
                                          ? "\(agent.name) is asleep. It gets this when its computer wakes."
                                          : "\(agent.name) is offline. It gets this when its gateway starts again.",
                                          icon: agent.liveness == .asleep ? "moon.zzz" : "powersleep")
                            } else if store.waiting {
                                TypingDots(agent: store.agent).id("typing")
                                SlowReplyHint(agent: store.agent, since: store.waitingSince)
                            }
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
            .safeAreaInset(edge: .bottom) { if !firstRun { inputBar(c) } }
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
                                Circle().fill(agent.liveness == .online ? c.mint : agent.liveness == .asleep ? c.lavender : c.outline)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Talking to \(agent.name), \(agent.liveness == .pending ? "offline" : agent.liveness.rawValue)")
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
            .sheet(isPresented: $addFirst) {
                // Paired and "Say hi": the new agent's thread is the chat.
                AddAgentSheet { id in
                    agents.selectedID = id
                    addFirst = false
                }
                .presentationDetents([.large])
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
                .environment(\.ylComponents, yl.components)
                .id(m.id)
                .transition(.opacity)
        }
        }
        .environment(\.ylEmit, store.emit)
        .environment(\.ylShow, store.ylShow)
        .environment(\.ylAnswers, store.ylAnswers)
        .environment(\.yuiMedia, store.agent.flatMap { a in account.session?.userID == "demo" ? nil : YuiMedia(account: account, agentID: a.id) })
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
        // -yuiDemoPrompt "Tabata tonight?" puts the person's message above it, after
        // -yuiDemoDelay seconds [1.5] (demo clips wait for the recording to catch up).
        .task {
            guard let text = UserDefaults.standard.string(forKey: "yuiThemeDemo") else { return }
            if let prompt = UserDefaults.standard.string(forKey: "yuiDemoPrompt") {
                let delay = UserDefaults.standard.object(forKey: "yuiDemoDelay") == nil
                    ? 1.5 : UserDefaults.standard.double(forKey: "yuiDemoDelay")
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(theme.spring) { store.messages.append(ChatMessage(text: prompt, fromUser: true)) }
                try? await Task.sleep(for: .seconds(1.2))
                store.stream(text.replacingOccurrences(of: "\\n", with: "\n"))
                return
            }
            try? await Task.sleep(for: .seconds(2.5))
            store.stream(text.replacingOccurrences(of: "\\n", with: "\n"))
        }
        // -yuiThreadRows <path>: a JSON array of yui_messages rows, loaded the way a
        // reopened thread loads them (answers-on-reopen tests, no network).
        .task {
            guard let path = UserDefaults.standard.string(forKey: "yuiThreadRows"),
                  let data = FileManager.default.contents(atPath: path),
                  let rows = try? JSONDecoder().decode([ThreadRow].self, from: data) else { return }
            store.load(rows)
        }
        #endif
        .task {
            // Presence changes on its own (a Mac falls asleep): keep it honest while the chat is up.
            while !Task.isCancelled {
                await agents.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
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

    /// Signed in with no agents yet (every new account): nothing here can answer,
    /// so the chat says how to connect one instead of pretending.
    private var firstRun: Bool {
        account.session?.userID != "demo" && agents.agents.isEmpty
    }

    private func inputBar(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            TextField("Say something nice", text: $draft, axis: .vertical)
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.ink)
                .lineLimit(1...5)
                .focused($focused)
                .accessibilityIdentifier("composer")
                .onSubmit(send)
                .id(composerID)
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
        if account.session?.userID != "demo" {
            // Not sent (no agent, no session): the words stay in the field.
            guard store.agent != nil, store.send(text) else { return }
            clearComposer()
            return
        }
        withAnimation(ChatStore.sendSpring) { store.messages.append(ChatMessage(text: text, fromUser: true)) }
        clearComposer()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(theme.spring) {
                store.messages.append(ChatMessage(text: ChatView.replies.randomElement()!, fromUser: false))
            }
        }
    }

    /// Empties the field and swaps in a new one, keeping the keyboard up.
    private func clearComposer() {
        draft = ""
        composerID += 1
        // The new field mounts on the next pass; focus it then so the keyboard stays.
        Task { @MainActor in focused = true }
    }

    /// The demo account's canned answers (screenshots only; real accounts never see them).
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

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            AgentFace(agent: agent)
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                YLItemsView(items: YLItem.layout(screen.top, pills: style), openStage: openStage)
                ForEach(Array(screen.errors.enumerated()), id: \.offset) { YLErrorRow(node: $1) }
                ForEach(Array(screen.looks.enumerated()), id: \.offset) { _ in LookNote(agent: agent) }
            }
            .environment(\.ylScope, scope)
            .environment(\.ylComponents, screen.components)
        }
        .transition(.opacity)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    var agent: YuiAgent?
    /// Still in the outbox: on the phone, not on Yui yet.
    var pending = false
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
                .opacity(pending ? 0.6 : 1)
                .accessibilityLabel(pending ? "\(message.text), not sent yet" : message.text)
            if !message.fromUser { Spacer(minLength: 48) }
        }
        .animation(.easeInOut(duration: 0.3), value: pending)
        .transition(message.fromUser
            // Sent: lifts off the composer and floats up into the thread.
            ? .asymmetric(insertion: .offset(y: 56).combined(with: .scale(scale: 0.8, anchor: .bottomTrailing))
                .combined(with: .opacity), removal: .opacity)
            : .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
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

/// One quiet status line in the thread: not sent yet, the agent is asleep.
private struct QuietNote: View {
    let text: String
    let icon: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label(text, systemImage: icon)
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
            .accessibilityIdentifier("quiet-note")
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
    /// A starter tap sends it as your first message.
    var send: (String) -> Void = { _ in }
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
                Text(agent.liveness == .asleep ?
                        "\(agent.name) is asleep right now. Messages wait and arrive when its computer wakes." :
                        agent.liveness == .offline ?
                        "\(agent.name) is offline right now. Messages wait until it's back.\nTo wake it, run hermes gateway restart on its computer." :
                        "Same agent as everywhere else,\nnow with buttons.")
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(c.inkSoft)
                    .multilineTextAlignment(.center)
                HStack(spacing: theme.spacing.s) {
                    ForEach(["Hi!", "What can you show me?"], id: \.self) { text in
                        Button { send(text) } label: { Chip(text: text, color: c.surface, outline: c.outline) }
                            .buttonStyle(BounceButtonStyle())
                    }
                }
                .padding(.top, theme.spacing.s)
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
    /// Set: an outlined chip in the scheme's own ink (a tappable starter).
    var outline: Color? = nil
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(outline == nil ? Color(hex: theme.light.ink) : theme.swatch(scheme).ink)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(outline ?? .clear, lineWidth: 1.5))
    }
}

/// A new account: no agents yet. Says what Yui needs and the one next step.
private struct FirstRun: View {
    let loaded: Bool
    let error: String?
    let add: () -> Void
    let retry: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        if !loaded, error == nil {
            ProgressView().tint(c.inkSoft)
        } else if !loaded {
            VStack(spacing: theme.spacing.m) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .bold)).foregroundStyle(c.inkSoft)
                Text("Couldn't load your agents")
                    .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                Text("Check your connection, then try again.")
                    .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", action: retry)
            }
            .multilineTextAlignment(.center)
            .padding(theme.spacing.xl)
        } else {
            VStack(spacing: theme.spacing.l) {
                Spacer(minLength: 0)
                Wordmark(height: 90)
                Text("Let's connect your first agent")
                    .font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                Text("Yui is where your own agent answers you, with screens you can tap. It runs on your computer, like a Hermes profile, and connecting it takes about five minutes.")
                    .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    row(1, "Add an agent here and get a code")
                    row(2, "Run three commands on your computer")
                    row(3, "Say hi")
                }
                .padding(theme.spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
                PillButton(title: "Add your first agent", systemImage: "plus", action: add)
                GuideLink()
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.center)
            .padding(theme.spacing.xl)
        }
    }

    private func row(_ n: Int, _ text: String) -> some View {
        let c = theme.swatch(scheme)
        return HStack(spacing: theme.spacing.m) {
            Text("\(n)")
                .font(theme.font(theme.type.caption, .black)).foregroundStyle(c.onAccent)
                .frame(width: 24, height: 24)
                .background(c.accent, in: Circle())
            Text(text).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                .multilineTextAlignment(.leading)
        }
    }
}

/// The reply is late: after 45 seconds, say what usually fixes it.
private struct SlowReplyHint: View {
    var agent: YuiAgent?
    var since: Date?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            if let since, ctx.date.timeIntervalSince(since) > 45 {
                let name = agent?.name ?? "Your agent"
                Label("\(name) is taking a while. If it stays quiet, run hermes gateway restart on its computer.",
                      systemImage: "hourglass")
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(theme.swatch(scheme).inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}
