import Foundation

/// Yui's backend: the PROOF Supabase project. The publishable key is a public
/// client key; it only grants the anon role, which can't read any yui_ table.
enum YuiBackend {
    static let url = URL(string: "https://ewzzaoperdpxqxkshynx.supabase.co")!
    static let publishableKey = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS"
    static let privacyPolicy = URL(string: "https://www.yuigui.com/privacy")!

    static func function(_ name: String) -> URL {
        url.appending(path: "functions/v1/\(name)")
    }
}
