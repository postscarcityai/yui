import SwiftUI

@main
struct YuiApp: App {
    @UIApplicationDelegateAdaptor(YuiAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: Account
    @State private var agents: AgentStore

    init() {
        let account = Account()
        _account = State(initialValue: account)
        _agents = State(initialValue: AgentStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            AgentThemed {
                if account.isSignedIn { ChatView() } else { SignInView() }
            }
            .animation(.default, value: account.isSignedIn)
            .environment(account)
            .environment(agents)
            .onChange(of: account.isSignedIn) { agents.reset() }
            .preferredColorScheme(appearance.colorScheme)
            .environment(PushCenter.shared)
            .task { await account.checkAppleCredential() }
            // Signed in with an agent: register for pushes. Sign out unregisters (Account.willSignOut).
            // A new account asks for notifications once its first agent exists, not on the first screen.
            .task(id: "\(account.session?.userID ?? "")|\(agents.agents.isEmpty)") {
                // The demo account (screenshots) never asks for notifications.
                guard account.isSignedIn, account.session?.userID != "demo", !agents.agents.isEmpty else { return }
                account.willSignOut = { await PushCenter.shared.stop() }
                await PushCenter.shared.start(account: account)
            }
            .onOpenURL { PushCenter.shared.open($0) }
            // Open on a thread: its answers show there, no push (YUI-24).
            .onChange(of: scenePhase, initial: true) { PushCenter.shared.setForeground(scenePhase == .active) }
        }
    }
}

/// The whole app wears the look of the agent you are talking to (YUI-20):
/// open a coach agent's thread and everything, sheets included, turns coach.
/// No agent (signed out, the demo chat): Yui's own look.
struct AgentThemed<Content: View>: View {
    @Environment(AgentStore.self) private var agents
    @Environment(Account.self) private var account
    @ViewBuilder var content: Content

    var body: some View {
        let theme = account.isSignedIn ? agents.selected?.yuiTheme ?? .yui : .yui
        content
            .environment(\.yuiTheme, theme)
            .environment(\.agentStyle, account.isSignedIn ? agents.selected?.theme?.style ?? [:] : [:])
            .animation(.easeInOut(duration: 0.45), value: theme)
    }
}

/// The open agent's style profile (`theme.style`): the screens it prefers.
/// Renderers read it for their defaults, e.g. `buttons=stack` lays ask and
/// choose options out one per line. Spec: yuigui/spec/YL.md, "theme".
private struct AgentStyleKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var agentStyle: [String: String] {
        get { self[AgentStyleKey.self] }
        set { self[AgentStyleKey.self] = newValue }
    }
}
