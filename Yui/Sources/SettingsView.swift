import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.xl) {
            VStack(spacing: theme.spacing.s) {
                Wordmark(height: 56)
                Text("Make Yui feel like yours.").font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.inkSoft)
            }
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text("Appearance").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                HStack(spacing: theme.spacing.s) {
                    ForEach(Appearance.allCases) { option in
                        AppearanceOption(option: option, selected: option == appearance) {
                            withAnimation(theme.spring) { appearance = option }
                        }
                    }
                }
            }
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text("Your agents").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                HStack(spacing: theme.spacing.l) {
                    ForEach(["Urza", "Arnold"], id: \.self) { name in
                        HStack(spacing: theme.spacing.s) {
                            AgentAvatar(name: name, size: 36)
                            Text(name).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.background)
    }
}

private struct AppearanceOption: View {
    let option: Appearance
    let selected: Bool
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var icon: String {
        switch option {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            VStack(spacing: theme.spacing.xs) {
                Image(systemName: icon).font(theme.font(theme.type.title, .bold))
                Text(option.label).font(theme.font(theme.type.caption, .bold))
            }
            .foregroundStyle(selected ? c.userInk : c.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacing.m)
            .background(selected ? c.accent : c.background, in: .rect(cornerRadius: theme.radius.bubble))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
