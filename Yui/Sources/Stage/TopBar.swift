import SwiftUI

// The top bar (YUI-122). Chris, TestFlight AJq7CcQS8fyM: "Keep the agents in the
// top left. In the top right, the chat history ... find room on the top left
// hamburger tab for the settings themselves, maybe to the left of the selector
// for the agents." The same on the stage and in the record: the menu (the
// drawer, which holds Settings), then who you are talking to; the record, or the
// way back to the full screen, top right.

/// Who you are talking to, top left, as a plain title: no dropdown, no tap to switch. The drawer
/// (the menu beside it) is the one agent picker (YUI-194); feedback AJw_G3S2.
struct AgentTitle: View {
    let agent: YuiAgent?
    /// The open chat's title, under the name (YUI-169).
    var title: String? = nil
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            if let agent { AgentBadge(agent: agent, size: 26) } else { YuiAvatar(size: 26) }
            VStack(alignment: .leading, spacing: 0) {
                Text(agent?.name ?? "Yui")
                    .font(theme.font(theme.type.body, theme.strong))
                    .foregroundStyle(c.ink)
                    .lineLimit(1)
                if let title {
                    Text(title)
                        .font(theme.font(12, .semibold))
                        .foregroundStyle(c.inkSoft)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .leading)
                }
            }
            if let agent {
                Circle().fill(Self.liveness(agent, c)).frame(width: 8, height: 8)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.map { "Talking to \($0.name), \($0.liveness.spoken)" } ?? "Talking to Yui")
        .accessibilityValue(title ?? "")
        .accessibilityIdentifier("record-title")
    }

    /// Online mint, asleep lavender, not listening yet butter, gone grey.
    static func liveness(_ agent: YuiAgent, _ c: Swatch) -> Color {
        switch agent.liveness {
        case .online: c.mint
        case .asleep: c.lavender
        case .notListening: c.butter
        default: c.outline
        }
    }
}

/// Hugs its content up to `cap` points wide. (`.frame(maxWidth:)` stretches a short name out to the cap.)
private struct CappedWidth: ViewModifier {
    let cap: CGFloat
    private struct Cap: Layout {
        let cap: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews[0].sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
    func body(content: Content) -> some View { Cap(cap: cap) { content } }
}

/// The menu as one pill (feedback ANG8AA-7k6WmMJEx633zmMg, Chris: "I don't actually know where I am ... the hamburger on
/// the left, the name of the agent on the right ... the whole button just opens the drawer"): the menu icon, the
/// agent's chip and its name. A long name truncates; `compact` (screen pills share the bar) drops the chip.
struct MenuPill: View {
    let agent: YuiAgent?
    var compact = false
    let id: String
    var label = "Menu"
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let name = agent?.name ?? "Yui"
        Button(action: action) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .bold))
                if !compact {
                    if let agent { AgentBadge(agent: agent, size: 24) } else { YuiAvatar(size: 24) }
                }
                Text(name)
                    .font(theme.font(theme.type.caption, .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(CappedWidth(cap: compact ? 72 : 132))
            }
            .foregroundStyle(c.ink)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("\(label), \(name)")
        .accessibilityIdentifier(id)
    }
}

/// Something waiting on you puts a small dot on the menu button, no number
/// (feedback AI3Pbaid); it goes the moment the last one is answered.
struct WaitingDot: ViewModifier {
    let waiting: Bool
    let reduceMotion: Bool
    var x: CGFloat = 6, y: CGFloat = -5
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            Circle()
                .fill(theme.swatch(scheme).accent)
                .frame(width: 8, height: 8)
                .offset(x: x, y: y)
                .scaleEffect(waiting ? 1 : 0.2)
                .opacity(waiting ? 1 : 0)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: waiting)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
