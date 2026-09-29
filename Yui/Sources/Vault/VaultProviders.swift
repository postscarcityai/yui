import Foundation

/// The providers a vault key can be for (spec/VAULT.md section 2). OpenRouter stays the server-side
/// model key of YUI-139, so it is not here.
enum VaultProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case fal, replicate, elevenlabs, anthropic, openai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fal: "fal"
        case .replicate: "Replicate"
        case .elevenlabs: "ElevenLabs"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    var usedFor: String {
        switch self {
        case .fal: "Images, video, audio"
        case .replicate: "Open models, images"
        case .elevenlabs: "Voices and audio"
        case .anthropic: "Claude"
        case .openai: "GPT, images"
        }
    }

    /// The provider's own key page: you sign in there, not in Yui.
    var keyPage: URL {
        switch self {
        case .fal: URL(string: "https://fal.ai/dashboard/keys")!
        case .replicate: URL(string: "https://replicate.com/account/api-tokens")!
        case .elevenlabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Where to put a spend limit at the provider, the backstop under Yui's own cap.
    var limitPage: URL {
        switch self {
        case .fal: URL(string: "https://fal.ai/dashboard/billing")!
        case .replicate: URL(string: "https://replicate.com/account/billing")!
        case .elevenlabs: URL(string: "https://elevenlabs.io/app/subscription")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/limits")!
        case .openai: URL(string: "https://platform.openai.com/settings/organization/limits")!
        }
    }

    /// The connector keeps a price table for this provider. One without an entry can't be granted until
    /// the owner confirms a limit set at the provider itself (contract decision 5).
    var hasPriceEntry: Bool { self != .elevenlabs }

    /// "That doesn't look like a fal key."
    var wrongShape: String { "That doesn't look like a \(label) key." }

    private var pattern: String {
        switch self {
        case .fal: #"^[A-Za-z0-9-]{8,}:[A-Za-z0-9]{16,}$"#
        case .replicate: #"^r8_[A-Za-z0-9]{20,}$"#
        case .elevenlabs: #"^sk_[A-Za-z0-9]{32,}$"#
        case .anthropic: #"^sk-ant-[A-Za-z0-9_-]{16,}$"#
        case .openai: #"^sk-(?!ant-|or-)[A-Za-z0-9_-]{20,}$"#
        }
    }

    /// The shape check: right prefix and length for this provider.
    func matches(_ key: String) -> Bool {
        key.range(of: pattern, options: .regularExpression) != nil
    }

    /// The provider a key's shape says, if it is one of ours.
    static func detect(_ key: String) -> VaultProvider? { allCases.first { $0.matches(key) } }

    /// The last four characters, the only part the app keeps to show.
    static func last4(_ key: String) -> String { String(key.suffix(4)) }
}

/// Text that looks like a key (spec/VAULT.md section 2). Checked before a send leaves the phone.
enum KeyShape: Equatable {
    /// A known provider's shape: no Send anyway.
    case provider(VaultProvider, key: String)
    /// OpenRouter's, the YUI-139 model key: it goes in Settings > Your model key, and is never sent.
    case openRouter(key: String)
    /// Merely looks like a key: Send anyway is allowed.
    case lookalike(key: String)

    var isKnown: Bool {
        if case .lookalike = self { return false }
        return true
    }

    var key: String {
        switch self {
        case .provider(_, let k), .openRouter(let k), .lookalike(let k): k
        }
    }

    static let held = "That looks like a key. Keys go in Settings > Keys, where agents can't read them."

    /// The first key-shaped word in `text`, a known provider's shape before a lookalike.
    static func find(in text: String) -> KeyShape? {
        var like: KeyShape?
        for word in words(text) {
            if let p = VaultProvider.detect(word) { return .provider(p, key: word) }
            if word.range(of: #"^sk-or-[A-Za-z0-9_-]{16,}$"#, options: .regularExpression) != nil { return .openRouter(key: word) }
            if like == nil, lookalike(word) { like = .lookalike(key: word) }
        }
        return like
    }

    /// The words of `text` a key could be: split on spaces and brackets, quotes and `KEY=` stripped.
    static func words(_ text: String) -> [String] {
        let trim = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019},;()<>[]{}")
        return text.split(whereSeparator: { $0.isWhitespace }).map { raw in
            var w = String(raw)
            if let eq = w.lastIndex(of: "=") { w = String(w[w.index(after: eq)...]) }
            w = w.trimmingCharacters(in: trim)
            if w.hasSuffix(".") { w.removeLast() }
            return w
        }.filter { $0.count >= 20 }
    }

    private static func lookalike(_ w: String) -> Bool {
        for p in ["ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "AIza", "sk_live_", "sk_test_", "hf_", "pk_live_"] where w.hasPrefix(p) && w.count >= 20 {
            return true
        }
        guard w.count >= 32, w.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return false }
        return w.contains { $0.isNumber } && w.contains { $0.isLetter }
    }
}
