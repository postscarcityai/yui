import SwiftUI

/// Chris's bunny-ear Yui wordmark. A template image, so the theme's `brand` token sets its color.
struct Wordmark: View {
    var height: Double
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(theme.swatch(scheme).brand)
            .accessibilityLabel("Yui")
    }
}

/// Yui's own avatar: the wordmark's bunny-ear "Y" alone, in brand color on a round chip.
struct YuiAvatar: View {
    var size: Double
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Image("YuiMark")
            .resizable()
            .scaledToFit()
            .foregroundStyle(c.brand)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(c.surface, in: Circle())
            .overlay(Circle().stroke(c.outline, lineWidth: max(1, size / 24)))
            .accessibilityLabel("Yui")
    }
}

/// Any agent's avatar: its initial on a chip in the theme's accent, in the theme's
/// type. Wrap it in the agent's theme (`AgentBadge` does) and it wears that agent's look.
struct AgentAvatar: View {
    var name: String
    var size: Double
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        // The chip's corner follows the theme's shape: square looks get square chips.
        let corner = size * min(0.5, max(0.18, theme.radius.avatar / 50))
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: theme.strong, design: theme.fontDesign))
            .foregroundStyle(c.onAccent)
            .frame(width: size, height: size)
            .background(c.accent, in: .rect(cornerRadius: corner))
            .accessibilityLabel(name)
    }
}

/// Tap feedback: a quick spring pop, driven by the theme's motion tokens.
struct BounceButtonStyle: ButtonStyle {
    @Environment(\.yuiTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? theme.motion.bounceScale : 1)
            .animation(theme.spring, value: configuration.isPressed)
    }
}
