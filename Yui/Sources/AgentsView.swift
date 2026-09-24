import SwiftUI

/// The agent switcher behind the top-left nav button. Yui is here now; Hermes agents
/// show as placeholders until the Hermes channel (YUI-7) connects them.
struct AgentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private static let hermes = ["Urza", "Arnold"]

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Text("Who do you want to talk to?")
                        .font(theme.font(theme.type.body, .semibold))
                        .foregroundStyle(c.inkSoft)
                    AgentRow(name: "Yui", status: "Here now", selected: true) { YuiAvatar(size: 44) }
                        .onTapGesture { dismiss() }
                    ForEach(Self.hermes, id: \.self) { name in
                        AgentRow(name: name, status: "Connect Hermes to start", selected: false) {
                            AgentAvatar(name: name, size: 44)
                        }
                        .opacity(0.6)
                    }
                }
                .padding(theme.spacing.xl)
            }
            .background(c.background)
            .navigationTitle("Your agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(c.accent) }
            }
        }
    }
}

private struct AgentRow<Avatar: View>: View {
    let name: String
    let status: String
    let selected: Bool
    @ViewBuilder let avatar: () -> Avatar
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.m) {
            avatar()
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                Text(status).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.font(theme.type.title, .bold))
                    .foregroundStyle(c.accent)
            }
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card)
            .stroke(selected ? c.accent : c.outline, lineWidth: selected ? 2 : 1.5))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
