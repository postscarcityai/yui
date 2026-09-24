import SwiftUI

@main
struct YuiApp: App {
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(\.yuiTheme, .yui)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
