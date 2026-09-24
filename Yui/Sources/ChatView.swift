import SwiftUI

/// Phase 1 shell: the chat screen every agent starts from.
/// Agent replies in Yui Lines render inline as presets.
struct ChatView: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var store = ChatStore(messages: ChatView.seed)
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    @State private var settingsDetent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-yuiSettingsLarge") ? .large : .medium
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("-yuiAgents")
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            Group {
                if store.messages.isEmpty {
                    EmptyChat()
                } else {
                    ScrollView {
                        // Not Lazy: LazyVStack drops preset cards from the accessibility tree (iOS 26/27),
                        // so VoiceOver and UI tests saw only the plain bubbles.
                        VStack(spacing: theme.spacing.m) {
                            ForEach(store.messages) { m in
                                if let yl = m.yl { YLReply(screen: yl) } else { Bubble(message: m) }
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
                    Wordmark(height: 26)
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
                    .presentationDetents([.medium])
                    .presentationCornerRadius(theme.radius.card)
            }
        }
        .environment(\.ylEmit, store.emit)
        .onAppear { store.spring = theme.spring }
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
                    .foregroundStyle(c.userInk)
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
private struct YLReply: View {
    let screen: YLScreen
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            YuiAvatar(size: 34)
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                ForEach(screen.components) { PresetView(component: $0) }
                ForEach(Array(screen.errors.enumerated()), id: \.offset) { YLErrorRow(node: $1) }
            }
        }
        .transition(.opacity)
    }
}

private struct Bubble: View {
    let message: ChatMessage
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
            if message.fromUser { Spacer(minLength: 48) } else { YuiAvatar(size: 34) }
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

private struct EmptyChat: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.l) {
            Wordmark(height: 110)
                .phaseAnimator([false, true]) { view, up in
                    view.offset(y: up ? -6 : 0)
                } animation: { _ in .easeInOut(duration: 1.1) }
            Text("is here, and happy to see you!")
                .font(theme.font(theme.type.display, .heavy))
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
