import SwiftUI
import UIKit

/// The bounds of the bubble whose reaction bar is open, for the overlay.
struct ReactionAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// A chat bubble's words in its shape and colors. The thread and the lifted
/// copy in the reaction overlay draw the same thing.
struct BubbleText: View {
    let text: String
    let fromUser: Bool
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let r = theme.radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: r.bubble,
            bottomLeadingRadius: fromUser ? r.bubble : r.bubbleTail,
            bottomTrailingRadius: fromUser ? r.bubbleTail : r.bubble,
            topTrailingRadius: r.bubble)
        Text(text)
            .font(theme.font(theme.type.body, .medium))
            .foregroundStyle(fromUser ? c.userInk : c.agentInk)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .background(fromUser ? c.userBubble : c.agentBubble, in: shape)
            .overlay(shape.stroke(fromUser ? .clear : c.outline, lineWidth: 1.5))
    }
}

/// A bubble or card you can hold: the agent's get the reaction bar (or tap its
/// badge), every one gets Reply, Copy and Select text, also as named
/// accessibility actions. A reaction's emoji sits on its corner.
struct Reactable: ViewModifier {
    let text: String
    /// Only the agent's messages take reactions; the person's own get the menu alone.
    var reacts = true
    let reaction: Reaction?
    /// The bar is open on it: the overlay draws the lifted copy in its place.
    let lifted: Bool
    let open: () -> Void
    let react: (Reaction?) -> Void
    /// Opens the words read-only, to copy just a part.
    var select: () -> Void = {}
    /// Quotes it above the composer (YUI-68).
    var reply: () -> Void = {}
    /// A card is a container: accessibility modifiers on it would land on every
    /// button inside, so its named actions live beside it (`ReactActions`).
    var card = false

    func body(content: Content) -> some View {
        if card {
            gestures(content)
        } else {
            gestures(content)
                .accessibilityValue(reaction.map { "Reacted \($0.emoji), \($0.meaning)" } ?? "")
                .accessibilityActions {
                    ReactActions(text: text, reacts: reacts, reaction: reaction, react: react, select: select, reply: reply)
                }
        }
    }

    private func gestures(_ content: Content) -> some View {
        content
            .anchorPreference(key: ReactionAnchor.self, value: .bounds) { lifted ? $0 : nil }
            .overlay(alignment: .bottomTrailing) {
                if let reaction {
                    ReactionBadge(reaction: reaction)
                        .offset(x: 10, y: 16)
                        .onTapGesture(perform: open)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .opacity(lifted ? 0 : 1)
            .padding(.bottom, reaction == nil ? 0 : 14)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12, perform: open)
            .sensoryFeedback(.impact(weight: .medium), trigger: lifted) { _, now in now }
    }
}

/// The hold menu as named accessibility actions: Reply, the reactions, Copy, Select text.
struct ReactActions: View {
    let text: String
    var reacts = true
    let reaction: Reaction?
    let react: (Reaction?) -> Void
    let select: () -> Void
    let reply: () -> Void

    var body: some View {
        Button("Reply", action: reply)
        if reacts {
            ForEach(Reaction.all) { r in
                Button("React \(r.emoji) \(r.meaning)") { react(r) }
            }
        }
        if reaction != nil { Button("Remove reaction") { react(nil) } }
        Button("Copy") { UIPasteboard.general.string = text }
        Button("Select text", action: select)
    }
}

/// The small emoji on a reacted bubble's corner.
struct ReactionBadge: View {
    let reaction: Reaction
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Text(reaction.emoji)
            .font(.system(size: 15))
            .frame(width: 28, height: 28)
            .background(c.surface, in: Circle())
            .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .accessibilityIdentifier("reaction-badge")
    }
}

/// Held bubble: the thread dims, the bubble lifts, the six reactions float
/// above it and Reply, Copy and Select text sit below (a tapback, the Telegram
/// and iMessage way). The person's own bubbles get the menu without the bar.
struct ReactionOverlay<Lifted: View>: View {
    /// What Copy copies: a bubble's words, a card's lines.
    let text: String
    /// The agent's message: the reaction bar is there.
    var reacts = true
    /// The held bubble, in this view's space.
    let rect: CGRect
    let size: CGSize
    let current: Reaction?
    let pick: (Reaction?) -> Void
    let dismiss: () -> Void
    /// Select text: the words open read-only, to copy any part of them.
    var select: () -> Void = {}
    /// Reply: its quote goes above the composer.
    var reply: () -> Void = {}
    /// The held bubble or card, drawn again over the dimmed thread.
    @ViewBuilder let lifted: () -> Lifted
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var up = false
    @State private var chosen: Reaction?

    private let item = CGSize(width: 48, height: 58)
    private var barSize: CGSize {
        reacts ? CGSize(width: item.width * CGFloat(Reaction.all.count) + 12, height: item.height + 12) : .zero
    }
    private let menuSize = CGSize(width: 210, height: 48)

    var body: some View {
        let c = theme.swatch(scheme)
        // Above the bubble when there is room, else under it (a message at the very top).
        let above = rect.minY - barSize.height - 12 > 4
        // A bubble at the bottom lifts until the menu fits under it (the iMessage way),
        // never so far that the bar leaves the screen.
        let lift = above ? max(0, min(rect.maxY + 12 + menuHeight + 8 - size.height,
                                      rect.minY - barSize.height - 16)) : 0
        let rect = rect.offsetBy(dx: 0, dy: -lift)
        let barY = above ? rect.minY - 12 - barSize.height / 2 : rect.maxY + 12 + barSize.height / 2
        let barX = min(max(rect.minX - 6 + barSize.width / 2, barSize.width / 2 + 8), size.width - barSize.width / 2 - 8)
        let menuTop = above ? rect.maxY + 12 : barY + barSize.height / 2 + 10
        let menuY = min(menuTop + menuHeight / 2, size.height - menuHeight / 2 - 8)
        // Under the bubble's leading edge; the person's own (on the right) under its trailing edge.
        let menuX = reacts || rect.width < menuSize.width
            ? min(max(rect.minX + menuSize.width / 2, menuSize.width / 2 + 8), size.width - menuSize.width / 2 - 8)
            : min(rect.maxX - menuSize.width / 2, size.width - menuSize.width / 2 - 8)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(scheme == .dark ? 0.35 : 0.12))
                .ignoresSafeArea()
                .opacity(up ? 1 : 0)
                .onTapGesture(perform: dismiss)
                .accessibilityLabel("Close reactions")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("reaction-dismiss")

            lifted()
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .bottomTrailing) {
                    if let shown = chosen ?? current {
                        ReactionBadge(reaction: shown).offset(x: 10, y: 16).transition(.scale(scale: 0.2))
                    }
                }
                .scaleEffect(up ? 1.04 : 1, anchor: above ? .bottomLeading : .topLeading)
                .shadow(color: .black.opacity(up ? 0.18 : 0), radius: 14, y: 6)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityHidden(true)

            if reacts {
                bar(c)
                    .scaleEffect(up ? 1 : 0.4, anchor: above ? .bottomLeading : .topLeading)
                    .opacity(up ? 1 : 0)
                    .position(x: barX, y: barY)
            }

            menu(c)
                .scaleEffect(up ? 1 : 0.6, anchor: above ? .topLeading : .topLeading)
                .opacity(up ? 1 : 0)
                .position(x: menuX, y: menuY)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { up = true } }
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private var menuHeight: CGFloat { menuSize.height * (current == nil ? 3 : 4) }

    private func bar(_ c: Swatch) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Reaction.all.enumerated()), id: \.element.id) { i, r in
                let on = (chosen ?? current) == r
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { chosen = r }
                    pick(r)
                } label: {
                    VStack(spacing: 2) {
                        Text(r.emoji)
                            .font(.system(size: 28))
                            .scaleEffect(on ? 1.18 : 1)
                        Text(r.meaning)
                            .font(theme.font(10, .bold))
                            .foregroundStyle(on ? c.ink : c.inkSoft)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: item.width, height: item.height)
                    .background(on ? c.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .scaleEffect(up ? 1 : 0.3)
                .animation(.spring(response: 0.32, dampingFraction: 0.6).delay(Double(i) * 0.03), value: up)
                .accessibilityLabel("\(r.emoji) \(r.meaning)")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("react-\(r.meaning)")
            }
        }
        .padding(6)
        .frame(width: barSize.width, height: barSize.height)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().stroke(c.outline.opacity(0.6), lineWidth: 1))
    }

    private func menu(_ c: Swatch) -> some View {
        VStack(spacing: 0) {
            menuRow("Reply", icon: "arrowshape.turn.up.left", c, action: reply)
                .accessibilityIdentifier("react-reply")
            Divider().overlay(c.outline)
            menuRow("Copy", icon: "doc.on.doc", c) {
                UIPasteboard.general.string = text
                dismiss()
            }
            .accessibilityIdentifier("react-copy")
            Divider().overlay(c.outline)
            menuRow("Select text", icon: "text.cursor", c, action: select)
                .accessibilityIdentifier("react-select")
            if let current {
                Divider().overlay(c.outline)
                menuRow("Remove \(current.emoji)", icon: "xmark.circle", c) { pick(nil) }
                    .accessibilityIdentifier("react-remove")
            }
        }
        .frame(width: menuSize.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline.opacity(0.6), lineWidth: 1))
    }

    private func menuRow(_ title: String, icon: String, _ c: Swatch, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(theme.font(theme.type.body, .semibold))
                Spacer()
                Image(systemName: icon)
            }
            .foregroundStyle(c.ink)
            .padding(.horizontal, theme.spacing.l)
            .frame(height: menuSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A message's words, read-only, for copying any part of them (TestFlight
/// feedback AG9JzU4LeWl-TFeKWftiFIE). Drag to select, then Copy.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ReadOnlyText(text: text, font: theme.uiFont(theme.type.body), ink: UIColor(c.ink))
                .padding(.horizontal, theme.spacing.m)
                .background(c.background.ignoresSafeArea())
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy all", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = text
                            dismiss()
                        }
                    }
                }
                .toolbarBackground(c.background, for: .navigationBar)
        }
        .tint(c.ink)
    }
}

/// A UITextView you can select in but not type in: SwiftUI's Text only
/// selects the whole string on iOS.
struct ReadOnlyText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let ink: UIColor

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 16, left: 4, bottom: 24, right: 4)
        v.adjustsFontForContentSizeCategory = true
        v.dataDetectorTypes = [.link]
        v.accessibilityIdentifier = "select-text"
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        v.text = text
        v.font = font
        v.textColor = ink
    }
}

extension YuiTheme {
    /// `font(_:_:)` for UIKit text, in the theme's design, scaled with Dynamic Type.
    func uiFont(_ size: Double, _ weight: UIFont.Weight = .medium) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = switch type.design {
        case "serif": .serif
        case "monospaced": .monospaced
        case "default": .default
        default: .rounded
        }
        let font = base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }
}
