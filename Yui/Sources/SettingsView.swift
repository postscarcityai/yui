import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView {
            VStack(spacing: theme.spacing.xl) {
                VStack(spacing: theme.spacing.s) {
                    Wordmark(height: 56)
                    Text("Make Yui feel like yours.").font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.inkSoft)
                }
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Text("Appearance").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                    HStack(spacing: theme.spacing.s) {
                        ForEach(Appearance.allCases) { option in
                            AppearanceOption(option: option, selected: option == appearance) {
                                withAnimation(theme.spring) { appearance = option }
                            }
                        }
                    }
                }
                .padding(theme.spacing.l)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
                AgentAccessSection()
                HelpSection()
                AccountSection()
            }
            .padding(theme.spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
    }
}

/// Settings > Agent access: management tokens that let an agent (say, your chief of staff)
/// add and manage your agents for you. Shown once, stored hashed, revocable,
/// and they can never read your messages. Spec: yuigui/spec/AGENTS.md.
private struct AgentAccessSection: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var fresh: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Agent access").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            Text("Let one of your agents add and manage agents for you. It can't read your messages.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let fresh {
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    Text("Copy this now. Yui won't show it again.")
                        .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
                    HStack {
                        Text(fresh).font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(c.ink).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = fresh }
                            .labelStyle(.iconOnly).tint(c.inkSoft)
                    }
                    .padding(theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                }
            }
            ForEach(store.tokens) { token in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(c.inkSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.name).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        Text(token.lastUsedAt.map { "Used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    }
                    Spacer(minLength: 0)
                    Button("Revoke") { Task { await store.revokeToken(token) } }
                        .font(theme.font(theme.type.caption, .bold)).tint(.red)
                }
            }
            Button {
                Task {
                    working = true
                    do {
                        let t = try await store.createToken(name: "Agent access \(store.tokens.count + 1)")
                        withAnimation(theme.spring) { fresh = t }
                    } catch { self.error = error.localizedDescription }
                    working = false
                }
            } label: {
                Label("Create access token", systemImage: "plus")
                    .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(working)
            if let error {
                Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
            }
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
        .task { await store.refreshTokens() }
    }
}

/// Settings > Help and feedback: answers on yuigui.com/help, and a mail draft
/// that already names the build. TestFlight's own feedback still works too.
private struct HelpSection: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Help and feedback").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            Link(destination: YuiBackend.help) {
                Label("Help and questions", systemImage: "questionmark.circle.fill")
                    .font(theme.font(theme.type.body, .semibold))
            }
            Link(destination: YuiBackend.startGuide) {
                Label("Connect an agent", systemImage: "link")
                    .font(theme.font(theme.type.body, .semibold))
            }
            Link(destination: YuiBackend.feedbackMail()) {
                Label("Email us", systemImage: "envelope.fill")
                    .font(theme.font(theme.type.body, .semibold))
            }
        }
        .tint(c.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
    }
}

/// Who is signed in, sign out, privacy policy, and in-app account deletion.
private struct AccountSection: View {
    @Environment(Account.self) private var account
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var confirmDelete = ProcessInfo.processInfo.arguments.contains("-yuiConfirmDelete")
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Account").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            HStack(spacing: theme.spacing.s) {
                Image(systemName: account.isReviewAccount ? "sparkles" : "apple.logo")
                    .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isReviewAccount ? "Demo account" : "Signed in with Apple")
                        .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    if let email = account.session?.email {
                        Text(email).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            Link(destination: YuiBackend.privacyPolicy) {
                Label("Privacy policy", systemImage: "hand.raised.fill")
                    .font(theme.font(theme.type.body, .semibold))
            }
            .tint(c.ink)
            HStack(spacing: theme.spacing.s) {
                Button {
                    Task { working = true; await account.signOut(); working = false }
                } label: {
                    Text("Sign out").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                        .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                }
                .buttonStyle(BounceButtonStyle())
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("Delete account").font(theme.font(theme.type.body, .bold)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: theme.radius.bubble))
                }
                .buttonStyle(BounceButtonStyle())
            }
            .disabled(working)
            if let error {
                Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
            }
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
        .sheet(isPresented: $confirmDelete) {
            DeleteAccountSheet { try await account.deleteAccount() }
                .presentationDetents([.medium])
                .presentationCornerRadius(theme.radius.card)
        }
    }
}

/// The confirm step before deletion. Says exactly what goes away.
private struct DeleteAccountSheet: View {
    let delete: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            Text("Delete your Yui account?").font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
            Text("This permanently removes your account, your paired agents and devices, and every message stored on Yui's servers. Yui is also removed from your Apple ID. It can't be undone.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                working = true
                Task {
                    do { try await delete(); dismiss() } catch { self.error = error.localizedDescription }
                    working = false
                }
            } label: {
                Group {
                    if working { ProgressView().tint(.white) } else { Text("Delete my account") }
                }
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                .background(Color.red, in: .rect(cornerRadius: theme.radius.pill))
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(working)
            Button("Keep my account") { dismiss() }
                .font(theme.font(theme.type.body, .bold)).tint(c.ink)
                .frame(maxWidth: .infinity)
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
    }
}

private struct AppearanceOption: View {
    let option: Appearance
    let selected: Bool
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var icon: String {
        switch option {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            VStack(spacing: theme.spacing.xs) {
                Image(systemName: icon).font(theme.font(theme.type.title, .bold))
                Text(option.label).font(theme.font(theme.type.caption, .bold))
            }
            .foregroundStyle(selected ? c.onAccent : c.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacing.m)
            .background(selected ? c.accent : c.background, in: .rect(cornerRadius: theme.radius.bubble))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
