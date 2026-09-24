import SwiftUI

@main
struct YuiApp: App {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var account = Account()

    var body: some Scene {
        WindowGroup {
            Group {
                if account.isSignedIn { ChatView() } else { SignInView() }
            }
            .animation(.default, value: account.isSignedIn)
            .environment(account)
            .environment(\.yuiTheme, .yui)
            .preferredColorScheme(appearance.colorScheme)
            .task { await account.checkAppleCredential() }
        }
    }
}
