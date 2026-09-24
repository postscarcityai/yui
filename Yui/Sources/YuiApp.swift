import SwiftUI

@main
struct YuiApp: App {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var account: Account
    @State private var agents: AgentStore

    init() {
        let account = Account()
        _account = State(initialValue: account)
        _agents = State(initialValue: AgentStore(account: account))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if account.isSignedIn { ChatView() } else { SignInView() }
            }
            .animation(.default, value: account.isSignedIn)
            .environment(account)
            .environment(agents)
            .onChange(of: account.isSignedIn) { agents.reset() }
            .environment(\.yuiTheme, .yui)
            .preferredColorScheme(appearance.colorScheme)
            .task { await account.checkAppleCredential() }
        }
    }
}
