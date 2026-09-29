import SwiftUI

// The ask (spec/VAULT.md section 3): the app draws this sheet itself, as Yui's own chrome. It never comes from
// an agent's screen, so a screen an agent sends can't look like it. And Controls > Keys (drawer), per agent.

/// "Penny wants to use your fal key": Allow (Face ID), Allow once, Don't allow. No key for that provider yet: Add a fal key.
struct KeyAskSheet: View {
    let ask: KeyAsk
    let agent: YuiAgent?
    /// Sends the `key_answer` control row; the sheet closes after.
    let answer: (KeyAnswer) async -> Void
    @Environment(Account.self) private var account
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var vault = VaultModel.shared
    @State private var picked: UUID?
    @State private var adding = false
    @State private var working = false
    @State private var error: String?

    private var held: [VaultKeyMeta] { vault.keys.filter { $0.provider == ask.provider } }
    private var key: VaultKeyMeta? { held.first { $0.id == picked } ?? held.first }
    private var name: String { agent?.name ?? "An agent" }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    HStack(spacing: theme.spacing.m) {
                        if let agent { AgentBadge(agent: agent, size: 52) }
                        Text("\(name) wants to use your \(ask.provider.label) key")
                            .font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("key-ask-title")
                    }
                    Text(ask.purpose).font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                        .accessibilityIdentifier("key-ask-for")
                    if let est = ask.est { Text(est).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft) }
                    if let cap = ask.cap {
                        Text("Suggested cap: $\(cap) a month").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                            .accessibilityIdentifier("key-ask-cap")
                    }
                    if held.isEmpty {
                        Text("You don't have a \(ask.provider.label) key yet.").font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                            .accessibilityIdentifier("key-ask-nokey")
                        button("Add a \(ask.provider.label) key", "plus", fill: c.accent, ink: c.onAccent) { adding = true }
                            .accessibilityIdentifier("key-ask-add")
                    } else {
                        if held.count > 1 {
                            Picker("Key", selection: Binding(get: { key?.id ?? held[0].id }, set: { picked = $0 })) {
                                ForEach(held) { Text("\($0.name), ends in \($0.last4)").tag($0.id) }
                            }
                            .pickerStyle(.menu).tint(c.ink)
                            .accessibilityIdentifier("key-ask-pick")
                        } else if let key {
                            Text("\(key.name), ends in \(key.last4)").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                        }
                        if let key, !key.provider.hasPriceEntry, !key.providerLimitConfirmed {
                            Toggle("I set a spending limit at \(key.provider.label)", isOn: Binding(get: { false }, set: { on in
                                if on { vault.setLimitConfirmed(key.id, true) }
                            }))
                            .font(theme.font(theme.type.body)).tint(c.accent)
                            .accessibilityIdentifier("key-ask-limit")
                        }
                        let blocked = key.map { !$0.provider.hasPriceEntry && !$0.providerLimitConfirmed } ?? true
                        button("Allow", "faceid", fill: c.accent, ink: c.onAccent) { Task { await allow(once: false) } }
                            .disabled(working || blocked).accessibilityIdentifier("key-ask-allow")
                        button("Allow once", "1.circle", fill: c.surface, ink: c.ink) { Task { await allow(once: true) } }
                            .disabled(working || blocked).accessibilityIdentifier("key-ask-once")
                    }
                    button("Don't allow", "xmark", fill: c.surface, ink: c.ink) { Task { await deny() } }
                        .disabled(working).accessibilityIdentifier("key-ask-deny")
                    Text("\(name) never sees the key. Yui's connector uses it for the calls you allow.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red).accessibilityIdentifier("key-ask-error") }
                }
                .padding(theme.spacing.xl)
            }
            .background(c.background)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .task { vault.configure(account: account); await vault.reload() }
        .sheet(isPresented: $adding) {
            KeyAddSheet(provider: ask.provider) { _ in Task { await vault.reload() } }.environment(\.yuiTheme, theme)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("key-ask")
    }

    private func button(_ title: String, _ icon: String, fill: Color, ink: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(theme.font(theme.type.body, .bold)).foregroundStyle(ink)
                .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                .background(fill, in: .rect(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(theme.swatch(scheme).outline, lineWidth: 1))
        }
        .buttonStyle(BounceButtonStyle())
    }

    private func allow(once: Bool) async {
        guard let key, let agent else { return }
        working = true
        error = nil
        defer { working = false }
        let cap = min(ask.cap ?? key.capCents / 100, key.capCents / 100)
        do {
            let handle = try await vault.grant(key, agentID: agent.id, purpose: ask.purpose, capCents: cap * 100, once: once)
            await answer(KeyAnswer(req: ask.req, decision: once ? .once : .allow, provider: ask.provider.rawValue, handle: handle, cap: cap))
        } catch VaultModel.GrantError.refused {
            error = VaultAuth.refused
        } catch VaultModel.GrantError.needsLimit {
            error = "Confirm a spending limit at \(ask.provider.label) first."
        } catch {
            self.error = "Couldn't hand the key to Yui's connector. Try again."
        }
    }

    private func deny() async {
        working = true
        defer { working = false }
        await answer(KeyAnswer(req: ask.req, decision: .deny, provider: ask.provider.rawValue))
    }
}

/// Controls > Keys in an agent's drawer: each key it may use, what for, this month against its cap, and Revoke.
struct AgentKeysSheet: View {
    let agent: YuiAgent
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var vault = VaultModel.shared
    @State private var adding = false

    var body: some View {
        let c = theme.swatch(scheme)
        let grants = vault.grants(agent: agent.id)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    if grants.isEmpty {
                        Text("\(agent.name) can't use any of your keys. It asks first, and you say yes or no.")
                            .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                            .accessibilityIdentifier("agent-keys-empty")
                    }
                    ForEach(grants) { g in
                        let key = vault.key(forGrant: g)
                        VStack(alignment: .leading, spacing: theme.spacing.s) {
                            Text(key.map { "\($0.provider.label): \($0.name)" } ?? "A key that's no longer on this iPhone")
                                .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                            Text(g.purpose + (g.once ? " (once)" : "")).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            let cap = g.capCents ?? key?.capCents ?? 0
                            Text("\(Money.dollars(vault.spent(agent: agent.id, key: g.key))) of \(Money.dollars(cap)) this month")
                                .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                                .accessibilityIdentifier("agent-key-spend")
                            if let note = g.lapseNote() { Text(note).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft) }
                            Button(role: .destructive) { Task { _ = await vault.revoke(g) } } label: {
                                Label("Revoke", systemImage: "hand.raised.fill").font(theme.font(theme.type.caption, .bold))
                            }
                            .accessibilityIdentifier("vault-revoke-\(g.handle)")
                        }
                        .padding(theme.spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(c.surface, in: .rect(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("agent-key-\(g.handle)")
                    }
                    Text("Revoking takes effect on its next call. \(agent.name) is told.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    if let e = vault.error { Text(e).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red) }
                }
                .padding(theme.spacing.l)
            }
            .background(c.background)
            .navigationTitle("Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("agent-keys-close")
                }
            }
        }
        .tint(c.accent)
        .task { vault.configure(account: account); await vault.reload() }
        .accessibilityIdentifier("agent-keys")
    }
}
