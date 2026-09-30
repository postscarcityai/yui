import SwiftUI

/// The shelf's "Pin as widget" (YUI-40, spec WIDGETS.md section 1). iOS only lets a person
/// add a widget themselves, so this shows the two steps with the saved screen already chosen.
struct PinName: Identifiable, Equatable { let id: String }

struct PinWidgetSheet: View {
    let name: String
    let agent: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            Text("Pin \(name) to your home screen")
                .font(theme.font(theme.type.title, .heavy))
                .foregroundStyle(c.ink)
            step(1, "Hold an empty spot on your home screen. Tap + and pick Yui.", c)
            step(2, "Add Saved screen. It opens on \(name) from \(agent), ready to go.", c)
            Text("\(agent) keeps it current. Tap the widget to open it in Yui.")
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(c.inkSoft)
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.background)
        .accessibilityIdentifier("pin-widget-sheet")
    }

    private func step(_ n: Int, _ text: String, _ c: Swatch) -> some View {
        HStack(alignment: .top, spacing: theme.spacing.m) {
            Text("\(n)")
                .font(theme.font(theme.type.body, .heavy))
                .foregroundStyle(c.onAccent)
                .frame(width: 28, height: 28)
                .background(c.accent, in: Circle())
            Text(text)
                .font(theme.font(theme.type.body, .semibold))
                .foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
