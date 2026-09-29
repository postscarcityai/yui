import SwiftUI

// The top bar (YUI-122). Chris, TestFlight AJq7CcQS8fyM: "Keep the agents in the
// top left. In the top right, the chat history ... find room on the top left
// hamburger tab for the settings themselves, maybe to the left of the selector
// for the agents." The same on the stage and in the record: the menu (the
// drawer, which holds Settings), then who you are talking to; the record, or the
// way back to the full screen, top right.

/// Who you are talking to, top left: tap to switch. The stage draws its own
/// capsule; in the record the nav bar's glass is the capsule.
struct AgentPicker: View {
    let agent: YuiAgent?
    let agents: [YuiAgent]
    var framed = true
    /// Shared agents gone since the app opened (YUI-97): one quiet line each.
    var unshared: [String] = []
    let pick: (String) -> Void
    /// Nil for an invited account, which starts with what it was given (YUI-97).
    var add: (() -> Void)? = nil
    let manage: () -> Void
    /// The open chat's title, under the name (YUI-169). With `openDrawer`, the name and title open
    /// the drawer with the chats; the chevron keeps the agent list.
    var title: String? = nil
    var openDrawer: (() -> Void)? = nil
    /// The id the agent list carries (`stage-agents`, `record-agents`).
    var menuID = ""
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let openDrawer, let agent {
            split(agent, openDrawer)
        } else {
            menu.accessibilityIdentifier(menuID)
        }
    }

    /// Name and chat title open the drawer; the dot and chevron open the agent list.
    private func split(_ agent: YuiAgent, _ openDrawer: @escaping () -> Void) -> some View {
        let c = theme.swatch(scheme)
        return HStack(spacing: 0) {
            Button(action: openDrawer) {
                HStack(spacing: theme.spacing.s) {
                    AgentBadge(agent: agent, size: framed ? 30 : 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agent.name)
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
                }
                .padding(.leading, framed ? 5 : 0)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chats with \(agent.name)")
            .accessibilityValue(title ?? "")
            .accessibilityHint("Opens the chat list")
            .accessibilityIdentifier("chat-header")
            Menu {
                rows
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Self.liveness(agent, c)).frame(width: 8, height: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(c.inkSoft)
                }
                .padding(.horizontal, theme.spacing.s)
                .padding(.trailing, framed ? 4 : 0)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .accessibilityLabel("Talking to \(agent.name), \(agent.liveness.spoken)")
            .accessibilityHint("Switch agent")
            .accessibilityIdentifier(menuID)
        }
        .background { if framed { Capsule().fill(c.surface) } }
        .overlay { if framed { Capsule().stroke(c.outline, lineWidth: 1.5) } }
    }

    /// The agent list: each agent, then add and manage.
    @ViewBuilder private var rows: some View {
        // The one agent picker (YUI-167: the drawer lost its own). Each row says what the
        // agent does under its name, when it says (a native agent's tagline).
        ForEach(agents) { a in
            Button { pick(a.id) } label: {
                // A menu row reads its first Text as the title, the next as the line under it.
                if a.id == agent?.id { Image(systemName: "checkmark") }
                Text(a.name)
                if let line = a.line { Text(line) }
            }
            .accessibilityIdentifier("pick-\(a.handle)")
        }
        ForEach(unshared, id: \.self) { name in
            Text(AgentStore.unsharedLine(name))
        }
        Divider()
        if let add { Button(action: add) { Label("Add an agent", systemImage: "plus") } }
        Button(action: manage) { Label("Manage agents", systemImage: "person.2") }
    }

    private var menu: some View {
        let c = theme.swatch(scheme)
        return Menu {
            rows
        } label: {
            HStack(spacing: theme.spacing.s) {
                if let agent { AgentBadge(agent: agent, size: framed ? 30 : 26) } else { YuiAvatar(size: framed ? 30 : 26) }
                Text(agent?.name ?? "Yui")
                    .font(theme.font(theme.type.body, theme.strong))
                    .foregroundStyle(c.ink)
                    .lineLimit(1)
                if let agent {
                    Circle().fill(Self.liveness(agent, c)).frame(width: 8, height: 8)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(c.inkSoft)
            }
            .padding(.leading, framed ? 5 : 0)
            .padding(.trailing, framed ? theme.spacing.m : 0)
            .frame(height: framed ? 44 : nil)
            .background { if framed { Capsule().fill(c.surface) } }
            .overlay { if framed { Capsule().stroke(c.outline, lineWidth: 1.5) } }
            .contentShape(Capsule())
        }
        .accessibilityLabel(agent.map { "Talking to \($0.name), \($0.liveness.spoken)" } ?? "Talking to Yui")
        .accessibilityHint("Switch agent")
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
