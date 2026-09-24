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

/// Any agent's avatar: its initial in heavy rounded type on a pastel chip.
/// Pure data in, so per-agent themes can restyle it later.
struct AgentAvatar: View {
    var name: String
    /// A palette token name ("mint", "lavender", ...). Nil falls back to the theme's `agents` map.
    var colorToken: String? = nil
    var size: Double
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let token = colorToken ?? theme.agentColorToken(for: name)
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: theme.light.ink))
            .frame(width: size, height: size)
            .background(c.color(token: token), in: .rect(cornerRadius: size * 0.36))
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
