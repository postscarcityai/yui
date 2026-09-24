import AuthenticationServices
import SwiftUI

/// First screen for a signed-out user: the coral wordmark, what Yui needs (your own agent), one button.
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    @State private var working = false
    @State private var askCode = false

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.xl) {
            Spacer()
            Wordmark(height: 120)
            VStack(spacing: theme.spacing.s) {
                Text("Your agents, in your pocket.")
                    .font(theme.font(theme.type.title, .bold))
                    .foregroundStyle(c.ink)
                Text("Connect the agent you already run, like Hermes. It answers here with screens you can tap.")
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
                                self.error = "Sign in didn't finish. Check your connection and try again."
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
                HStack(spacing: theme.spacing.l) {
                    Link("How it works", destination: YuiBackend.startGuide)
                    Link("Your data", destination: YuiBackend.privacyPolicy)
                    Button("Demo code") { askCode = true }
                }
                .font(theme.font(theme.type.caption, .semibold))
                .tint(c.inkSoft)
            }
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
        .sheet(isPresented: $askCode) {
            ReviewCodeSheet()
                .presentationDetents([.medium])
                .presentationCornerRadius(theme.radius.card)
        }
    }
}

/// App Review signs in here with the code from the review notes: one demo
/// account whose demo agent answers. Everyone else uses Sign in with Apple.
private struct ReviewCodeSheet: View {
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            Text("Demo code").font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
            Text("For App Review and demos. It opens a shared demo account with a demo agent. Everyone else signs in with Apple.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code)
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go).onSubmit(submit)
                .padding(theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1.5))
                .accessibilityIdentifier("reviewCode")
            if let error {
                Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.accent)
            }
            Spacer(minLength: 0)
            Button(action: submit) {
                Group {
                    if working { ProgressView().tint(c.onAccent) } else { Text("Sign in") }
                }
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                .background(c.accent, in: .rect(cornerRadius: theme.radius.pill))
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(working || code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await account.signIn(reviewCode: trimmed)
                dismiss()
            } catch AccountError.server("invalid_grant") {
                error = "That code didn't work. Check it and try again."
            } catch {
                self.error = "Sign in didn't finish. Check your connection and try again."
            }
        }
    }
}
