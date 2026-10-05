import SwiftUI

// The working screen's words (Chris, TestFlight ADv4muh06N4PD2IA1sV2Fhc: "does the text really need
// to be that big? ... the label could just come down and not be so heavy ... put the seconds in a
// little bubble and have it float around ... is it possible to put the label in the shader ...
// affected by all the cool colors"). Two layouts were built for a pick (kanban t_01e1c6d4); this is
// the first of them, the one with no card on the stage: the orb is the hero, what the agent is
// doing sits under it in light type that the orb's color runs through, and the seconds float in a
// small piece of glass. The words themselves are the friendly ones (`WorkingWords`).

/// What the agent is doing, lit by its own color: a slow band of the accent runs through the words.
/// The stage gives each new word its own line (`.id`), so it fades in where the old one was and
/// starts its own band. Reduce Motion: plain ink, no band.
struct WorkingWordsLine: View {
    let text: String
    let ink: Color
    let accent: Color
    let still: Bool
    @State private var sweep = false
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.body + 2, .semibold))
            .foregroundStyle(still ? AnyShapeStyle(ink) : AnyShapeStyle(light))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: accent.opacity(still ? 0 : 0.45), radius: 12)
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { sweep = true }
            }
    }

    /// Ink with a band of the agent's color travelling left to right through it.
    private var light: LinearGradient {
        LinearGradient(stops: [.init(color: ink, location: 0), .init(color: ink, location: 0.35),
                               .init(color: accent, location: 0.5),
                               .init(color: ink, location: 0.65), .init(color: ink, location: 1)],
                       startPoint: UnitPoint(x: sweep ? 0.6 : -1.6, y: 0.5),
                       endPoint: UnitPoint(x: sweep ? 2.6 : 0.4, y: 0.5))
    }
}

/// The seconds, in a small piece of glass that drifts a little and is never quite still.
struct GlassSeconds: View {
    let text: String
    let ink: Color
    let still: Bool
    @State private var drift = false
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .semibold).monospacedDigit())
            .foregroundStyle(ink)
            .contentTransition(still ? .identity : .numericText())
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .glassEffect(.regular, in: .capsule)
            .offset(x: drift ? 9 : -9, y: drift ? -2 : 2)
            .animation(still ? nil : .easeOut(duration: 0.3), value: text)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { drift = true }
            }
            .accessibilityHidden(true)
    }
}
