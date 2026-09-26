import SwiftUI

@main
struct YuiApp: App {
    @UIApplicationDelegateAdaptor(YuiAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: Account
    @State private var agents: AgentStore
    @State private var looks = AppLookStore.shared

    init() {
        let account = Account()
        _account = State(initialValue: account)
        _agents = State(initialValue: AgentStore(account: account))
        LiveTimer.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            AgentThemed {
                if account.isSignedIn { ChatView() } else { SignInView() }
            }
            .animation(.default, value: account.isSignedIn)
            // An invite that didn't work says so for a moment (YUI-56).
            .overlay(alignment: .top) { InviteNotice() }
            // An MCP client asking to connect (INT-19). Signed out, it waits for sign-in.
            .sheet(item: Binding(
                get: { account.isSignedIn ? agents.pendingConnect : nil },
                set: { agents.pendingConnect = $0 }
            )) { ConnectApprovalSheet(request: $0) }
            .environment(account)
            .environment(agents)
            .environment(looks)
            .onChange(of: account.isSignedIn) {
                agents.reset()
                if !account.isSignedIn { looks.clear() }
            }
            // Yui's own look lives on the account (RESTYLE.md section 6): fetched once
            // signed in, written on the person's taps only.
            .task(id: account.session?.userID ?? "") {
                guard account.isSignedIn, account.session?.userID != "demo" else { looks.save = nil; return }
                looks.save = { [account] state in await account.saveLook(state) }
                if let json = await account.fetchLook() { looks.loaded(json.value) }
            }
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
            // Messages that didn't make it out (no network, app killed) go now (YUI-28).
            .task(id: account.session?.userID ?? "") {
                guard account.isSignedIn, account.session?.userID != "demo" else { return }
                Outbox.shared.start(account: account)
            }
            .onOpenURL { url in
                if let connect = ConnectRequestID.parse(url) { agents.pendingConnect = connect }
                else if !account.open(url) { _ = PushCenter.shared.open(url) }
            }
            // Open on a thread: its answers show there, no push (YUI-24).
            .onChange(of: scenePhase, initial: true) {
                PushCenter.shared.setForeground(scenePhase == .active)
                if scenePhase == .active { Outbox.shared.kick() }
            }
        }
    }
}

/// An agent's thread wears that agent's look (YUI-20): that is how you know who
/// you are talking to. Everything else, and Yui's own thread, wears Yui's own
/// look, the one the person picked from a `theme app` card (YUI-43, RESTYLE.md).
/// With "Agents keep their own looks" off, every thread wears the app look too.
struct AgentThemed<Content: View>: View {
    @Environment(AgentStore.self) private var agents
    @Environment(Account.self) private var account
    @Environment(AppLookStore.self) private var looks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        let app = looks.theme
        let theme = account.isSignedIn ? agents.selected.map { Self.thread($0, app: app, looks: looks) } ?? app : app
        content
            .environment(\.yuiTheme, theme)
            .environment(\.appTheme, app)
            .environment(\.agentStyle, account.isSignedIn ? agents.selected?.theme?.style ?? [:] : [:])
            // Applying a look crossfades the chrome; none under Reduce Motion.
            .animation(reduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
                       ? nil : .easeInOut(duration: 0.45), value: theme)
    }

    /// What a thread wears. Yui's own follows the app look unless its look was set on its own.
    static func thread(_ agent: YuiAgent, app: YuiTheme, looks: AppLookStore) -> YuiTheme {
        if agent.isYui { return agent.theme?.isEmpty == false ? agent.yuiTheme : app }
        return looks.state.agentsKeepLooks ? agent.yuiTheme : app
    }
}

/// Yui's own look, for the chrome that is nobody's thread: sheets, Settings, the agent list.
private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = YuiTheme.yui
}

extension EnvironmentValues {
    var appTheme: YuiTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
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
