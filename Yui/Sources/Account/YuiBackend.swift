import Foundation

/// Yui's backend: the PROOF Supabase project. The publishable key is a public
/// client key; it only grants the anon role, which can't read any yui_ table.
enum YuiBackend {
    static let url = URL(string: "https://ewzzaoperdpxqxkshynx.supabase.co")!
    static let publishableKey = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS"
    static let privacyPolicy = URL(string: "https://www.yuigui.com/privacy")!
    /// Step-by-step: connect your own agent (the pairing screen follows the same steps).
    static let startGuide = URL(string: "https://www.yuigui.com/start")!
    /// Answers, and every way to send feedback. Also the support URL in App Store Connect.
    static let help = URL(string: "https://www.yuigui.com/help")!
    static let feedbackEmail = "chris@postscarcity.ai"

    /// A mail draft with the app version filled in, so a report says which build it is about.
    static func feedbackMail() -> URL {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = feedbackEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "Yui feedback, \(version)")]
        return c.url!
    }

    static func function(_ name: String) -> URL {
        url.appending(path: "functions/v1/\(name)")
    }
}
