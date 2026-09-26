import SwiftUI

// Typing keeps up (YUI-99). Chris on build 96: holding backspace went slow and a
// double space was slow to make the period. The draft lived on ChatView, so every
// key re-evaluated the whole chat, the thread's rows included. Now the words live
// here and only the composer's own views read them: a key redraws the field and
// its hints, and the send button swaps on the first word and the last delete.
// The chat's body reads none of it.

/// The words in the composer.
@MainActor @Observable
final class ComposerModel {
    var draft = "" {
        didSet {
            let has = draft.contains { !$0.isWhitespace }
            if has != hasWords { hasWords = has }
        }
    }
    /// Something to send besides spaces. Set only when it flips, so `SendOrMic` isn't told per key.
    private(set) var hasWords = false
    /// Bumped on every send: a fresh text field. Clearing `draft` alone can leave
    /// the sent words drawn in the field (TestFlight feedback APthnqcdHvqEP).
    var fieldID = 0

    /// The word under the cursor end: everything after the last space or newline.
    /// Walks back from the end, so a long draft costs one word, not its length.
    nonisolated static func lastWord(_ text: String) -> Substring {
        var i = text.endIndex
        while i > text.startIndex {
            let before = text.index(before: i)
            if text[before].isWhitespace { break }
            i = before
        }
        return text[i...]
    }
}

/// The text field. Reads the draft itself, so a key redraws only this.
struct ComposerField: View {
    let composer: ComposerModel
    let prompt: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let _ = BodyLog.hit("ComposerField")
        // The field sets the same text twice per key: act on a real change only, so
        // watchers are told once and keystroke_render counts each key once.
        TextField(prompt, text: Binding(get: { composer.draft },
                                        set: { if $0 != composer.draft { composer.draft = $0; Perf.shared.span(.keystrokeRender) } }),
                  axis: .vertical)
            .font(theme.font(theme.type.body))
            .foregroundStyle(c.ink)
            .lineLimit(1...5)
            .focused(focused)
            .accessibilityIdentifier("composer")
            .onSubmit(submit)
            .id(composer.fieldID)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .frame(minHeight: 46)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.pill))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(c.outline, lineWidth: 1.5))
    }
}

/// The / and @ suggestions and who an @ goes to, over the composer. They follow the
/// words, so they read the draft here and nowhere in the chat.
struct ComposerHints: View {
    let composer: ComposerModel
    /// The agent's / commands; nil or empty shows none (YUI-61).
    let commands: [AgentCommand]?
    /// @ suggestions and the mention bar are on (YUI-44).
    let mentions: Bool
    let agents: [YuiAgent]
    let current: String?
    /// Hold to talk is listening: no suggestions.
    let listening: Bool
    let reduceMotion: Bool
    var focused: FocusState<Bool>.Binding
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        let _ = BodyLog.hit("ComposerHints")
        let draft = composer.draft
        // Only a last word that starts with @, or a draft that starts with /, can suggest anything.
        let at = mentions && !listening && ComposerModel.lastWord(draft).hasPrefix("@")
        let found = at ? Mentions.suggestions(draft, agents: agents, current: current) : []
        let suggestions = !found.isEmpty ? found
            : !listening && draft.hasPrefix("/") ? SlashCommands.suggestions(draft, in: commands) : []
        let to = found.isEmpty && mentions && !draft.hasPrefix("/") && draft.contains("@")
            ? Mentions.target(draft, agents: agents, current: current) : nil
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !suggestions.isEmpty {
                SuggestionPopover(items: suggestions, pick: { composer.draft = $0.fill; focused.wrappedValue = true },
                                  identifier: found.isEmpty ? "slash" : "mention")
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if let to {
                MentionBar(agent: to)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : theme.spring, value: suggestions.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: to?.id)
    }
}

/// Send when there are words (or photos, or a send under way), else the mic. The
/// chat builds both; only this reads `hasWords`, so the first key and the last
/// delete swap the button without redrawing the thread.
struct SendOrMic<Send: View, Mic: View>: View {
    let composer: ComposerModel
    /// Photos wait, or a send is under way: Send whatever the words.
    let send: Bool
    @ViewBuilder let sendButton: Send
    @ViewBuilder let mic: Mic

    var body: some View {
        if send || composer.hasWords { sendButton } else { mic }
    }
}
