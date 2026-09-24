import AuthenticationServices
import SwiftUI

/// First screen for a signed-out user: the coral wordmark and one button.
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    @State private var working = false

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.xl) {
            Spacer()
            Wordmark(height: 120)
            VStack(spacing: theme.spacing.s) {
                Text("Your agents, in your pocket.")
                    .font(theme.font(theme.type.title, .bold))
                    .foregroundStyle(c.ink)
                Text("Chat with them, tap their little screens, hear back fast.")
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(c.inkSoft)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: theme.spacing.s) {
                ForEach(["mint", "lavender", "butter"], id: \.self) { token in
                    Circle().fill(c.color(token: token)).frame(width: 12, height: 12)
                }
            }
            Spacer()
            VStack(spacing: theme.spacing.m) {
                SignInWithAppleButton(.signIn) { request in
                    account.prepare(request)
                } onCompletion: { result in
                    working = true
                    Task {
                        defer { working = false }
                        do { try await account.complete(result) } catch {
                            if (error as? ASAuthorizationError)?.code != .canceled {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                // The button keeps its first style; rebuild it when the scheme flips.
                .id(scheme)
                .frame(height: 54)
                .clipShape(.rect(cornerRadius: theme.radius.pill))
                .disabled(working)
                .opacity(working ? 0.6 : 1)
                if let error {
                    Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.accent)
                        .multilineTextAlignment(.center)
                }
                Link("How Yui handles your data", destination: YuiBackend.privacyPolicy)
                    .font(theme.font(theme.type.caption, .semibold))
                    .tint(c.inkSoft)
            }
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
    }
}
