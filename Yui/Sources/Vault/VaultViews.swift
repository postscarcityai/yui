import SwiftUI
import VisionKit

// Settings > Keys (spec/VAULT.md sections 1, 2, 8). A key goes in through one door: the add sheet.
// Never shown again, never copied; Face ID on add, replace, remove and every grant.

/// The surface the vault's cards share with Settings.
private struct VaultCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) { content }
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
    }
}

/// Settings > Keys: every key by provider, name and last four, when it was last used and this month against its cap.
/// The YUI-139 model key sits in the same list and says it lives on Yui's server.
struct KeysSection: View {
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var vault = VaultModel.shared
    @State private var status: NativeStatus?
    @State private var adding = false
    @State private var open: VaultKeyMeta?

    var body: some View {
        let c = theme.swatch(scheme)
        VaultCard {
            Text("Keys").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            Text("Keys for the things an agent pays for. They stay on your iPhone and no agent ever sees one.")
                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if let k = status?.key {
                let label = status?.providers.first { $0.id == k.provider }?.label ?? k.provider
                HStack(spacing: theme.spacing.m) {
                    Image(systemName: "key.fill").foregroundStyle(c.inkSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(label) model key").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        Text("Ends in \(k.hint)").font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        Text("On Yui's server, locked away. Runs your Yui agents.")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("vault-model-key")
            }
            ForEach(vault.keys) { k in
                Button { open = k } label: {
                    HStack(spacing: theme.spacing.m) {
                        Image(systemName: "key.horizontal.fill").foregroundStyle(c.inkSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                            Text("\(k.provider.label), ends in \(k.last4)").font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            Text("\(vault.lastUsedLine(k)). \(Money.dollars(vault.spent(k))) of \(Money.dollars(k.capCents)) this month.")
                                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            Text(VaultModel.lives(k)).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(theme.font(13, .bold)).foregroundStyle(c.inkSoft)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("vault-key-\(k.last4)")
            }
            if vault.keys.isEmpty {
                Text("No keys yet.").font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                    .accessibilityIdentifier("vault-empty")
            }
            Button { adding = true } label: {
                Label("Add a key", systemImage: "plus")
                    .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("vault-add")
            if let e = vault.error { Text(e).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red) }
        }
        .task {
            vault.configure(account: account)
            await vault.reload()
            if agents.agents.contains(where: { $0.kind == "hosted" }) { status = try? await agents.nativeStatus() }
        }
        .sheet(isPresented: $adding) {
            KeyAddSheet { _ in Task { await vault.reload() } }
                .environment(\.yuiTheme, theme)
        }
        .sheet(item: $open) { k in
            KeyDetailSheet(key: k)
                .environment(\.yuiTheme, theme)
        }
    }
}

// MARK: Add a key

/// The one door in. Pick the provider, Get a key opens the provider's own page, paste (secure field) or scan,
/// name it, set a monthly cap, save with Face ID. `replacing`: paste a new key over an existing one.
struct KeyAddSheet: View {
    var provider: VaultProvider = .fal
    /// Text moved here from the composer or a form.
    var prefill: String = ""
    var replacing: VaultKeyMeta?
    var saved: (VaultKeyMeta?) -> Void = { _ in }
    @Environment(Account.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var vault = VaultModel.shared
    @State private var chosen: VaultProvider
    @State private var secret: String
    @State private var name: String
    @State private var cap = "10"
    @State private var icloud = false
    @State private var limitConfirmed = false
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    init(provider: VaultProvider = .fal, prefill: String = "", replacing: VaultKeyMeta? = nil, saved: @escaping (VaultKeyMeta?) -> Void = { _ in }) {
        let p = replacing?.provider ?? VaultProvider.detect(prefill.trimmingCharacters(in: .whitespacesAndNewlines)) ?? provider
        self.provider = p
        self.prefill = prefill
        self.replacing = replacing
        self.saved = saved
        _chosen = State(initialValue: p)
        _secret = State(initialValue: prefill.trimmingCharacters(in: .whitespacesAndNewlines))
        _name = State(initialValue: "Personal \(p.label)")
    }

    private var capCents: Int? { Int(cap.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 * 100 : nil } }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    if replacing == nil {
                        Picker("Provider", selection: $chosen) {
                            ForEach(VaultProvider.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu).tint(c.ink)
                        .accessibilityIdentifier("vault-provider")
                        .onChange(of: chosen) { old, new in if name == "Personal \(old.label)" { name = "Personal \(new.label)" } }
                        Text(chosen.usedFor).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    } else {
                        Text("Paste a new \(chosen.label) key over \(replacing?.name ?? "this one"). The old one is forgotten.")
                            .font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                    }
                    Link(destination: chosen.keyPage) {
                        Label("Get a key at \(chosen.keyPage.host()?.replacingOccurrences(of: "www.", with: "") ?? chosen.label)", systemImage: "arrow.up.right")
                            .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
                    }
                    .accessibilityIdentifier("vault-get-key")
                    // No autocorrect, no predictive bar; a secure field is hidden in screenshots and the app switcher.
                    SecureField("Paste your key", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.none)
                        .padding(theme.spacing.m)
                        .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                        .accessibilityIdentifier("vault-key-field")
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: {
                            Label("Scan it off your computer screen", systemImage: "camera.viewfinder")
                                .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
                        }
                        .accessibilityIdentifier("vault-scan")
                    }
                    if replacing == nil {
                        TextField("Name", text: $name)
                            .padding(theme.spacing.m)
                            .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                            .accessibilityIdentifier("vault-name")
                        HStack {
                            Text("Monthly cap, dollars").font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                            Spacer()
                            TextField("10", text: $cap).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                                .padding(theme.spacing.s)
                                .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                                .accessibilityIdentifier("vault-cap")
                        }
                        Toggle("Also on my other Apple devices", isOn: $icloud)
                            .font(theme.font(theme.type.body)).tint(c.accent)
                            .accessibilityIdentifier("vault-icloud")
                        Text(icloud ? "Kept in iCloud Keychain, which Apple encrypts. Yui never sees that copy."
                             : "Off: this key never leaves this iPhone.")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        if !chosen.hasPriceEntry {
                            Toggle("I set a spending limit at \(chosen.label)", isOn: $limitConfirmed)
                                .font(theme.font(theme.type.body)).tint(c.accent)
                                .accessibilityIdentifier("vault-limit-confirm")
                            Text("Yui can't price \(chosen.label) calls yet, so a limit at \(chosen.label) has to hold the spend.")
                                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        }
                        Link(destination: chosen.limitPage) {
                            Label("Set a spending limit at \(chosen.label) too", systemImage: "arrow.up.right")
                                .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
                        }
                    }
                    Button { Task { await save() } } label: {
                        Label(working ? "Saving" : replacing == nil ? "Save key" : "Replace key", systemImage: "faceid")
                            .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                            .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                    }
                    .buttonStyle(BounceButtonStyle())
                    .disabled(working || secret.isEmpty)
                    .accessibilityIdentifier("vault-save")
                    Text("Yui's connector uses this key for the calls you allow. Keys are never shown again, and never copied out.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
                            .accessibilityIdentifier("vault-error")
                    }
                }
                .padding(theme.spacing.xl)
            }
            .background(c.surface)
            .navigationTitle(replacing == nil ? "Add a key" : "Replace key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(c.accent).accessibilityIdentifier("vault-cancel") } }
        }
        .task { vault.configure(account: account) }
        .fullScreenCover(isPresented: $scanning) {
            KeyScanner(found: { text in secret = text; if let p = VaultProvider.detect(text), replacing == nil { chosen = p }; scanning = false },
                       cancel: { scanning = false })
        }
    }

    private func save() async {
        working = true
        error = nil
        defer { working = false }
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chosen.matches(key) else { error = chosen.wrongShape; return }
        if let replacing {
            guard await vault.replace(replacing.id, with: key) else { error = vault.error; return }
            secret = ""
            saved(vault.store.meta(replacing.id))
            dismiss()
            return
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give the key a name."; return }
        guard let cents = capCents else { error = "Set a monthly cap of $1 or more."; return }
        guard let m = await vault.add(key, provider: chosen, name: name.trimmingCharacters(in: .whitespaces), capCents: cents,
                                      icloud: icloud, limitConfirmed: limitConfirmed) else { error = vault.error; return }
        secret = ""
        saved(m)
        dismiss()
    }
}

/// VisionKit text recognition, on the phone: the camera reads the key off a screen; the picture is never saved or sent.
struct KeyScanner: View {
    let found: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScannerRepresentable(found: found).ignoresSafeArea()
            Button("Cancel", action: cancel).buttonStyle(.borderedProminent).padding()
        }
    }

    private struct ScannerRepresentable: UIViewControllerRepresentable {
        let found: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let v = DataScannerViewController(recognizedDataTypes: [.text()], qualityLevel: .accurate, recognizesMultipleItems: true,
                                              isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true,
                                              isHighlightingEnabled: true)
            v.delegate = context.coordinator
            try? v.startScanning()
            return v
        }
        func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator(found) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let found: (String) -> Void
            init(_ found: @escaping (String) -> Void) { self.found = found }

            /// The first word that has a provider's key shape; a tap picks any word.
            private func scan(_ items: [RecognizedItem]) {
                for case .text(let t) in items {
                    for w in KeyShape.words(t.transcript) where VaultProvider.detect(w) != nil { found(w); return }
                }
            }
            func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) { scan(items) }
            func dataScanner(_ s: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) { scan(items) }
            func dataScanner(_ s: DataScannerViewController, didTapOn item: RecognizedItem) {
                if case .text(let t) = item { found(t.transcript.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
    }
}

// MARK: One key

/// A key's page: where it lives, the iCloud switch, who uses it, Replace and Remove. No reveal, no copy.
struct KeyDetailSheet: View {
    let key: VaultKeyMeta
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(AgentStore.self) private var agents
    @State private var vault = VaultModel.shared
    @State private var replacing = false
    @State private var confirmRemove = false
    @State private var busy = false

    private var now: VaultKeyMeta { vault.keys.first { $0.id == key.id } ?? key }

    var body: some View {
        let c = theme.swatch(scheme)
        let k = now
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    VaultCard {
                        Text(k.name).font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                        Text("\(k.provider.label), ends in \(k.last4)").font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                        Text("\(vault.lastUsedLine(k)). \(Money.dollars(vault.spent(k))) of \(Money.dollars(k.capCents)) this month.")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        Text(VaultModel.lives(k)).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                            .accessibilityIdentifier("vault-lives")
                        Toggle("Also on my other Apple devices", isOn: Binding(get: { k.icloud }, set: { on in
                            Task { busy = true; _ = await vault.setICloud(k.id, on); busy = false }
                        }))
                        .font(theme.font(theme.type.body)).tint(c.accent).disabled(busy)
                        .accessibilityIdentifier("vault-icloud")
                    }
                    let used = vault.grants(for: k)
                    if !used.isEmpty {
                        let names = used.map { g in agents.agents.first { $0.id == g.agentID }?.name ?? "An agent" }
                        Text("Used by \(Array(Set(names)).sorted().joined(separator: ", "))")
                            .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                            .accessibilityIdentifier("vault-used-by")
                    }
                    Button { replacing = true } label: { row("Replace key", "arrow.triangle.2.circlepath", c.ink, c) }
                        .buttonStyle(BounceButtonStyle()).accessibilityIdentifier("vault-replace")
                    Button { confirmRemove = true } label: { row("Remove key", "trash", .red, c) }
                        .buttonStyle(BounceButtonStyle()).accessibilityIdentifier("vault-remove")
                    if let e = vault.error { Text(e).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red) }
                }
                .padding(theme.spacing.xl)
            }
            .background(c.background)
            .navigationTitle("Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(c.accent) } }
        }
        .sheet(isPresented: $replacing) { KeyAddSheet(replacing: k) { _ in Task { await vault.reload() } }.environment(\.yuiTheme, theme) }
        .alert("Remove \(k.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { if await vault.remove(k.id) { dismiss() } } }
            Button("Revoke it at \(k.provider.label)") { UIApplication.shared.open(k.provider.keyPage) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents that used it lose access. The key still works at \(k.provider.label) until you revoke it there.")
        }
    }

    private func row(_ title: String, _ icon: String, _ tint: Color, _ c: Swatch) -> some View {
        Label(title, systemImage: icon).font(theme.font(theme.type.body, .bold)).foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
    }
}

// MARK: The hold on key-shaped sends

/// "That looks like a key." Over the composer or a form: Move it to Keys, and Send anyway only for text that
/// merely looks like a key (a known provider's shape has no Send anyway).
struct KeyHoldBanner: View {
    let shape: KeyShape
    let move: () -> Void
    let sendAnyway: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text(KeyShape.held).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("key-hold-text")
            HStack(spacing: theme.spacing.s) {
                Button(action: move) {
                    Text("Move it to Keys").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.onAccent)
                        .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
                        .background(c.accent, in: Capsule())
                }
                .accessibilityIdentifier("key-hold-move")
                if !shape.isKnown {
                    Button(action: sendAnyway) {
                        Text("Send anyway").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.ink)
                            .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
                            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
                    }
                    .accessibilityIdentifier("key-hold-send")
                }
            }
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.butter.opacity(0.4), in: .rect(cornerRadius: theme.radius.bubble))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("key-hold")
    }
}

/// The add sheet a held send moves its key to: presented over the composer or a form.
struct KeyMoveSheet: View {
    let text: String
    let moved: () -> Void
    var body: some View {
        // Only the key's own word goes into the field, not the sentence around it.
        KeyAddSheet(prefill: KeyShape.find(in: text)?.key ?? text) { m in if m != nil { moved() } }
    }
}

/// Clears the hold when the words that tripped it are gone. Reads the draft here, so a key redraws this and not the chat.
struct KeyHoldWatch: View {
    let composer: ComposerModel
    @Binding var held: KeyShape?

    var body: some View {
        Color.clear.frame(height: 0)
            .onChange(of: composer.draft) {
                if let h = held, !composer.draft.contains(h.key) { held = nil }
            }
    }
}

extension KeyShape: Identifiable {
    var id: String { key }
}
