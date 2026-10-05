import SwiftUI

// One mic for every text field (voice first: "any new text field ships with a mic"). Two cards
// built one each on the same day: `FieldMic` for a field of words (a form's answer, Type your own,
// what a photo edit should change) and `NameMic` for a name or a search (a group, an agent, a chat
// title). They were the same button with two looks and two engines. Now there is one: `FieldMic`
// does both jobs, and `NameMic` is the short way to ask for the naming kind.

/// Tap to talk into a field, tap again to stop. The words show in the field as they are heard, so
/// a person can talk, stop, fix a word and talk again. Speech stays on the phone (PushToTalk); the
/// listener is made on the first tap, not one per field on screen.
///
/// A field of words (the default): what is heard goes after what the field already holds.
/// `replaces` (a name, a title, a search): what is heard takes the place of what was there, and
/// loses its closing period.
struct FieldMic: View {
    @Binding var text: String
    /// What the field holds, for VoiceOver: "Talk to fill your answer".
    let label: String
    let id: String
    var replaces = false
    /// The whole of what VoiceOver says, when "Talk to fill ..." does not fit ("Say the name").
    var prompt: String? = nil
    /// Runs once the talking stops with words in the field (a rename saves itself, as on Return).
    var done: () -> Void = {}
    @State private var talk: PushToTalk?
    /// What the field held when the talking started.
    @State private var base = ""
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var listening: Bool { talk?.listening == true }
    private var denied: Bool { talk?.phase == .denied || talk?.phase == .failed }

    var body: some View {
        let s = theme.swatch(scheme)
        Button { toggle() } label: {
            Image(systemName: listening ? "stop.fill" : denied ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(listening ? s.onAccent : s.ink)
                .symbolEffect(.pulse, isActive: listening)
                .frame(width: 34, height: 34)
                .glassEffect(listening ? .regular.tint(s.accent).interactive() : .regular.interactive(), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: listening)
        .accessibilityLabel(listening ? "Stop talking" : prompt ?? "Talk to fill \(label)")
        .accessibilityHint(denied ? "The mic is off for Yui. Turn it on in Settings, or type." : "")
        .accessibilityIdentifier(id)
        .onChange(of: talk?.transcript ?? "") { _, heard in
            if listening { text = Self.fill(base, heard, replaces: replaces) }
        }
        .onDisappear { talk?.cancel() }
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
        if t.listening {
            Task {
                let heard = await t.stop()
                text = Self.fill(base, heard, replaces: replaces)
                if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { done() }
            }
        } else {
            base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await t.start() }
        }
    }

    /// What the field holds once `heard` is in it. Nothing heard leaves it as it was.
    static func fill(_ had: String, _ heard: String, replaces: Bool) -> String {
        guard replaces else { return join(had, heard) }
        var name = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = name.last, ".!?,".contains(last) { name.removeLast() }
        return name.isEmpty ? had : name
    }

    /// The words after what was there, as MicPreset joins a second talk: a full stop between them unless one is there,
    /// and a capital after it.
    static func join(_ had: String, _ heard: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return had }
        guard !had.isEmpty else { return heard }
        if had.last.map({ ".!?,".contains($0) }) == true { return had + " " + heard }
        return had + ". " + heard.prefix(1).uppercased() + heard.dropFirst()
    }
}

/// A mic for a name, a title or a search: say it and it is the field. `append` is for a comment,
/// where a second talk adds to the first.
struct NameMic: View {
    @Binding var text: String
    let id: String
    var label = "Say the name"
    var append = false
    /// Runs once the words are in the field (a rename saves itself, as on Return).
    var done: () -> Void = {}

    var body: some View {
        FieldMic(text: $text, label: label, id: id, replaces: !append, prompt: label, done: done)
    }
}
