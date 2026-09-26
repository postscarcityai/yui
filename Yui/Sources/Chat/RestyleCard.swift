import SwiftUI
import YuiLines

/// A `theme app` line in a reply (YUI-43, spec: yuigui/spec/RESTYLE.md section 3):
/// Yui as it is now beside the look offered, light or dark, then Use <set> or
/// Keep mine. Nothing changes before the tap; after it, one line and Undo.
struct RestyleCard: View {
    let props: [String: String]
    /// The reply it is in: its outcome is kept by this.
    let scope: String
    /// The agent that offered it (`via` on the saved look).
    var agent: YuiAgent?
    @Environment(AppLookStore.self) private var looks
    @Environment(\.restyleNewest) private var newest
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var mode: ColorScheme?

    private var label: String { AppLook.label(props) }
    private var name: String? { props["name"]?.lowercased() }

    var body: some View {
        let c = theme.swatch(scheme)
        Group {
            switch looks.cards[scope] {
            case "applied":
                note(name == "reset" ? "Yui wears its own look again." : "Yui is \(label) now.",
                     undo: looks.undoCard == scope)
            case "undone": note("Put back the look from before.")
            case "kept": note("Kept your look.")
            default:
                if let newest, newest != scope {
                    note("A newer look was offered below.")
                } else if name == "reset", looks.state.look == nil {
                    note("Yui already wears its own look.")
                } else {
                    preview(c)
                }
            }
        }
    }

    // MARK: The preview

    private func preview(_ c: Swatch) -> some View {
        let now = looks.state.look
        let offered = AppLook.offered(props, on: now)
        let shown = mode ?? scheme
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            Label("A new look for Yui", systemImage: "paintpalette.fill")
                .font(theme.font(theme.type.body, theme.strong))
                .foregroundStyle(c.ink)
            HStack(alignment: .top, spacing: theme.spacing.m) {
                MiniYui(theme: AppLook.theme(now), title: "Now", scheme: shown)
                MiniYui(theme: AppLook.theme(offered), title: name == "reset" ? "Yui's own" : label.capitalized, scheme: shown)
            }
            .frame(maxWidth: .infinity)
            ModeSwitch(mode: shown) { m in withAnimation(reduceMotion ? nil : theme.spring) { mode = m } }
            if let words = AppLook.guardNote(offered, props: props) {
                Text(words)
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("restyle-guard")
            }
            HStack(spacing: theme.spacing.s) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                        looks.apply(props, card: scope, via: agent?.name)
                    }
                    send("apply", echo: name == "reset" ? "Back to Yui's look" : "Use \(label)")
                } label: {
                    Text(name == "reset" ? "Use Yui's look" : "Use \(label)")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(c.onAccent)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(c.accent, in: .rect(cornerRadius: theme.radius.pill))
                }
                .accessibilityIdentifier("restyle-apply")
                Button {
                    looks.keep(card: scope)
                    send("keep", echo: "Keep mine")
                } label: {
                    Text("Keep mine")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(c.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(c.background, in: .rect(cornerRadius: theme.radius.pill))
                        .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(c.outline, lineWidth: 1.5))
                }
                .accessibilityIdentifier("restyle-keep")
            }
            .buttonStyle(BounceButtonStyle())
        }
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
    }

    // MARK: After a tap

    private func note(_ words: String, undo: Bool = false) -> some View {
        let c = theme.swatch(scheme)
        return HStack(spacing: theme.spacing.m) {
            Label(words, systemImage: "paintbrush.pointed.fill")
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(c.inkSoft)
            if undo {
                Button("Undo") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { looks.undo(card: scope) }
                    send("undo", echo: "Undo")
                }
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(c.accent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("restyle-undo")
            }
        }
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, undo ? 0 : theme.spacing.s)
        .background(c.surface, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
    }

    /// The agent hears every tap, like any other (RESTYLE.md section 3).
    private func send(_ choice: String, echo: String) {
        var value: [String: YLValue] = ["scope": .string("app"), "choice": .string(choice)]
        if let name { value["name"] = .string(name) }
        emit(YLEvent(id: "restyle", preset: "theme", value: value, echo: echo))
    }

    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }
}

/// A small phone wearing a look: the header, two rows of the agent list, a bubble
/// each way, a button and the tab bar. Enough to see the look, not a screenshot.
private struct MiniYui: View {
    let theme: YuiTheme
    let title: String
    let scheme: ColorScheme
    @Environment(\.yuiTheme) private var host
    @Environment(\.colorScheme) private var hostScheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: host.spacing.xs) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Wordmark(height: 13)
                    Spacer(minLength: 0)
                    Circle().fill(c.inkSoft).frame(width: 7, height: 7)
                }
                ForEach(["Coach", "Luna"], id: \.self) { n in
                    HStack(spacing: 6) {
                        Text(n.prefix(1))
                            .font(.system(size: 8, weight: theme.strong, design: theme.fontDesign))
                            .foregroundStyle(c.onAccent)
                            .frame(width: 16, height: 16)
                            .background(n == "Coach" ? c.accent : c.lavender,
                                        in: .rect(cornerRadius: min(8, theme.radius.avatar / 2.2)))
                        Text(n).font(.system(size: 9, weight: theme.strong, design: theme.fontDesign)).foregroundStyle(c.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                    .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble / 2.5))
                }
                Text("Ready when you are.")
                    .font(.system(size: 8, design: theme.fontDesign)).foregroundStyle(c.agentInk)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(c.agentBubble, in: .rect(cornerRadius: theme.radius.bubble / 2.5))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble / 2.5).stroke(c.outline, lineWidth: 0.5))
                HStack {
                    Spacer(minLength: 0)
                    Text("Let's go")
                        .font(.system(size: 8, design: theme.fontDesign)).foregroundStyle(c.userInk)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(c.userBubble, in: .rect(cornerRadius: theme.radius.bubble / 2.5))
                }
                Text("Start")
                    .font(.system(size: 8, weight: .bold, design: theme.fontDesign)).foregroundStyle(c.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(c.accent, in: .rect(cornerRadius: theme.radius.pill / 2.5))
                HStack(spacing: 5) {
                    Capsule().fill(c.accent).frame(width: 12, height: 5)
                    Circle().fill(c.outline).frame(width: 5, height: 5)
                    Circle().fill(c.outline).frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(9)
            .frame(maxWidth: 150)
            .background(c.background, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(host.swatch(hostScheme).outline, lineWidth: 1))
            .environment(\.yuiTheme, theme)
            .environment(\.colorScheme, scheme)
            Text(title)
                .font(host.font(host.type.caption, .bold))
                .foregroundStyle(host.swatch(hostScheme).inkSoft)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(scheme == .dark ? "dark" : "light")")
    }
}

/// Light / Dark on the card: both phones flip, so both modes are seen before choosing.
private struct ModeSwitch: View {
    let mode: ColorScheme
    let pick: (ColorScheme) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.xs) {
            ForEach([(ColorScheme.light, "Light", "sun.max.fill"), (.dark, "Dark", "moon.fill")], id: \.1) { m, title, icon in
                Button { pick(m) } label: {
                    Label(title, systemImage: icon)
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(mode == m ? c.onAccent : c.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(mode == m ? c.accent : .clear, in: Capsule())
                }
                .accessibilityAddTraits(mode == m ? .isSelected : [])
                .accessibilityIdentifier("restyle-\(title.lowercased())")
            }
        }
        .padding(3)
        .background(c.background, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
    }
}

/// The reply holding the thread's newest `theme app` line: older cards retire.
private struct RestyleNewestKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var restyleNewest: String? {
        get { self[RestyleNewestKey.self] }
        set { self[RestyleNewestKey.self] = newValue }
    }
}
