import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var fromUser: Bool
}

/// Phase 1 shell: the chat screen every agent starts from.
/// Presets render inline here once the Yui Lines parser lands.
struct ChatView: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var messages: [ChatMessage] = ProcessInfo.processInfo.arguments.contains("-yuiDemo")
        ? ChatView.demo : []
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            Group {
                if messages.isEmpty {
                    EmptyChat()
                } else {
                    ScrollView {
                        LazyVStack(spacing: theme.spacing.m) {
                            ForEach(messages) { Bubble(message: $0) }
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
                ToolbarItem(placement: .principal) {
                    HStack(spacing: theme.spacing.s) {
                        MascotAvatar(size: 30)
                        Wordmark(height: 24)
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
                    .presentationDetents([.medium])
                    .presentationCornerRadius(theme.radius.card)
            }
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
        withAnimation(theme.spring) { messages.append(ChatMessage(text: text, fromUser: true)) }
        draft = ""
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(theme.spring) {
                messages.append(ChatMessage(text: ChatView.replies.randomElement()!, fromUser: false))
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
        ChatMessage(text: "On it. Timer cards land here once my presets are ready. Stretch first!", fromUser: false),
    ]
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
            if message.fromUser { Spacer(minLength: 48) } else { MascotAvatar(size: 34) }
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
            MascotAvatar(size: 132)
                .phaseAnimator([false, true]) { view, up in
                    view.offset(y: up ? -8 : 0)
                } animation: { _ in .easeInOut(duration: 1.1) }
            HStack(alignment: .lastTextBaseline, spacing: theme.spacing.s) {
                Wordmark(height: 52)
                Text("is here!")
                    .font(theme.font(theme.type.display, .heavy))
                    .foregroundStyle(c.ink)
            }
            .accessibilityElement(children: .combine)
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
