import SwiftUI

/// The words on the key form (YUI-139 step 2e). Plain: no base URL, no model id, no "API" unless the provider says it.
enum ModelKeyWords {
    static let otherRoad = "Have a Claude or ChatGPT plan? Add Yui inside Claude or ChatGPT and your plan pays. Yui draws the screens."
    static let otherRoadURL = URL(string: "https://www.yuigui.com/developers/mcp")!
    static let locked = "Your key goes to Yui's server once and is kept locked away there. The app never shows it again."

    static func left(_ t: NativeStatus.Turns) -> String {
        "Yui and your crew have \(max(t.limit - t.used, 0)) of \(t.limit) free turns left this month. Add your own key to keep going with no limit."
    }

    /// The one line a plan holder needs: Claude Pro, ChatGPT Plus and the like can't pay for another app.
    static func plan(_ p: NativeStatus.Provider?) -> String? { p?.plan }
}

/// Every place a person adds their own model key shows this: the limit card's Settings link, Settings > Your model key,
/// Add agent (the quiet "Bring your own key") and Controls > Model. Provider, key, the plain line about plans,
/// where to make a key, and the other road (add Yui inside Claude or ChatGPT).
struct ModelKeyForm: View {
    let status: NativeStatus
    /// Called after the provider accepted the key and it is saved.
    var saved: () async -> Void = {}
    @Environment(AgentStore.self) private var store
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var provider = "openrouter"
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var working = false
    @State private var error: String?

    private var chosen: NativeStatus.Provider? { status.providers.first { $0.id == provider } }

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text(ModelKeyWords.left(status.turns))
                .font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("key-left")
            Picker("Provider", selection: $provider) {
                ForEach(status.providers) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu).tint(c.ink)
            .accessibilityIdentifier("key-provider")
            if let plan = ModelKeyWords.plan(chosen) {
                Text(plan).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("key-plan")
            }
            if let url = chosen?.keyUrl.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label("Make a key at \(url.host()?.replacingOccurrences(of: "www.", with: "") ?? "the provider")", systemImage: "arrow.up.right")
                        .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
                }
                .accessibilityIdentifier("key-make")
            }
            SecureField("Paste your key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(theme.spacing.m)
                .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
                .accessibilityIdentifier("key-field")
            if provider == "custom" {
                TextField("Server address, https://...", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
            }
            if chosen?.needsModel == true || provider == "custom" {
                TextField("Model name", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
            }
            Button {
                Task { await save() }
            } label: {
                Label(working ? "Checking the key" : "Save key", systemImage: "checkmark")
                    .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
                    .background(c.background, in: .rect(cornerRadius: theme.radius.bubble))
            }
            .buttonStyle(BounceButtonStyle())
            .disabled(working || key.isEmpty)
            .accessibilityIdentifier("key-save")
            Text(ModelKeyWords.locked)
                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(c.outline)
            Text(ModelKeyWords.otherRoad)
                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("key-other-road")
            Link(destination: ModelKeyWords.otherRoadURL) {
                Label("Add Yui in Claude or ChatGPT", systemImage: "arrow.up.right")
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.accent)
            }
            .accessibilityIdentifier("key-other-road-link")
            if let error { Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red) }
        }
    }

    private func save() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await store.setModelKey(provider: provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                        model: model.trimmingCharacters(in: .whitespaces),
                                        baseURL: baseURL.trimmingCharacters(in: .whitespaces))
            key = ""
            await saved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The key form on its own sheet, for the places that aren't Settings: Add agent and Controls > Model.
/// Once a key is saved it says so and closes.
struct ModelKeySheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var status: NativeStatus?
    @State private var error: String?

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    if let status {
                        if let k = status.key {
                            Label("\(status.providers.first { $0.id == k.provider }?.label ?? k.provider) key is on, ends in \(k.hint).",
                                  systemImage: "key.fill")
                                .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                            Text("Yui and your crew use it, with no monthly limit. Remove it any time in Settings.")
                                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        } else {
                            ModelKeyForm(status: status) { dismiss() }
                        }
                    } else if let error {
                        Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
                .padding(theme.spacing.xl)
            }
            .background(c.surface)
            .navigationTitle("Bring your own key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(c.accent) } }
        }
        .task {
            do { status = try await store.nativeStatus() } catch { self.error = error.localizedDescription }
        }
    }
}
