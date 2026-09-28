import SwiftUI
import YuiLines

/// `mic [prompt...] [+auto]` (YL.md): a big talk button, speech to text, `{transcript}`.
/// It falls back to typing, and the words can always be typed or fixed (YUI-185: Penny's
/// brain dump is "talk it out, or type"). Each talk adds to what is there, so a person
/// can talk, stop, think and talk again.
///
/// In a plan or the stage's questions the host has the one Send: every change hands it
/// `{transcript}` (nothing while the box is empty). On its own it sends once, with the
/// words as the person's reply.
struct MicPreset: View {
    let c: YLComponent
    @State private var text = ""
    @State private var sent = false
    /// Made on the first tap: an audio engine per mic on screen is too much to hold for nothing.
    @State private var talk: PushToTalk?
    @State private var restored = false
    @FocusState private var typing: Bool
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylHostedSubmit) private var hosted
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var listening: Bool { talk?.listening == true }

    var body: some View {
        let s = theme.swatch(scheme)
        let id = c.ylID
        PresetCard {
            PresetTitle(text: c.string("prompt") ?? "Tap and talk")
            HStack(spacing: theme.spacing.m) {
                Button { toggle() } label: {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(s.onAccent)
                        .frame(width: 64, height: 64)
                        .background(s.accent, in: Circle())
                        .overlay(Circle().stroke(s.accent.opacity(listening ? 0.35 : 0), lineWidth: 8).scaleEffect(1.18))
                        .contentShape(Circle())
                }
                .buttonStyle(BounceButtonStyle())
                .disabled(sent)
                .accessibilityLabel(listening ? "Stop talking" : "Talk")
                .accessibilityIdentifier("mic-talk-\(id)")
                .sensoryFeedback(.impact(weight: .light), trigger: listening)
                VStack(alignment: .leading, spacing: 2) {
                    Text(listening ? "Listening. Tap to stop." : text.isEmpty ? "Tap and talk" : "Tap to add more")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(s.ink)
                    Text(note)
                        .font(theme.font(theme.type.caption))
                        .foregroundStyle(s.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if listening, let heard = talk?.transcript, !heard.isEmpty {
                Text(heard)
                    .font(theme.font(theme.type.body, .medium))
                    .foregroundStyle(s.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mic-heard-\(id)")
            }
            TextField("Or type it here", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .font(theme.font(theme.type.body))
                .foregroundStyle(s.ink)
                .textInputAutocapitalization(.sentences)
                .focused($typing)
                .disabled(sent || listening)
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
                .background(s.background, in: .rect(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(typing ? s.accent : s.outline, lineWidth: 1.5))
                .accessibilityIdentifier("mic-text-\(id)")
            if !hosted {
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                OptionPill(text: sent ? "Sent" : c.string("submit") ?? "Send", fill: s.accent, ink: s.onAccent,
                           on: !words.isEmpty && !sent, grow: true) {
                    sent = true
                    typing = false
                    emit(c.event(["transcript": .string(words)], echo: words))
                }
                .disabled(words.isEmpty || sent)
                .accessibilityIdentifier("mic-send-\(id)")
            }
        }
        .onChange(of: text) {
            guard hosted, restored || !text.isEmpty else { return }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(words.isEmpty ? c.event([:]) : c.event(["transcript": .string(words)], echo: words))
        }
        // Reopened: a sent mic comes back with its words; in a plan, the plan's answer holds them.
        .onAppear(perform: restore)
        .onDisappear { talk?.cancel() }
        .task { if c.flag("auto"), !sent, text.isEmpty { toggle() } }
    }

    private var note: String {
        switch talk?.phase {
        case .denied: "The mic is off for Yui. Type it below, or turn it on in Settings."
        case .failed: "The mic isn't free right now. Type it below."
        default: listening ? "Say it the way you'd tell a friend." : "Or type it below. You can fix the words after."
        }
    }

    private func restore() {
        defer { restored = true }
        guard !restored, text.isEmpty else { return }
        if hosted, let g = c.inGroup, let v = answers(scope, g)?["plan"]?[c.ylID]?.string {
            text = v
        } else if !hosted, let v = answers(scope, c.ylID)?["transcript"]?.string {
            text = v
            sent = true
        }
    }

    private func toggle() {
        let t = talk ?? {
            let t = PushToTalk()
            #if DEBUG
            t.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
            #endif
            talk = t
            return t
        }()
        typing = false
        if t.listening {
            Task {
                let heard = await t.stop()
                guard !heard.isEmpty else { return }
                let had = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = had.isEmpty ? heard : had + (had.last.map { ".!?,".contains($0) } == true ? " " : ". ") + heard
            }
        } else {
            Task { await t.start() }
        }
    }
}
