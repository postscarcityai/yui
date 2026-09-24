import SwiftUI

/// Yui the cat, cropped to a circle on her pastel card.
struct MascotAvatar: View {
    var size: Double
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image("Mascot")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.swatch(scheme).outline, lineWidth: max(1, size / 24)))
            .accessibilityLabel("Yui")
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
