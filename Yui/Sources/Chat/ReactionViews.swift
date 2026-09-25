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
    /// An agent's words are markdown (YUI-76); the person's, and a folded excerpt
    /// (already plain), are drawn as written.
    var markdown: Bool? = nil
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
        styled(c)
            .font(theme.font(theme.type.body, .medium))
            .foregroundStyle(fromUser ? c.userInk : c.agentInk)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .background(fromUser ? c.userBubble : c.agentBubble, in: shape)
            .overlay(shape.stroke(fromUser ? .clear : c.outline, lineWidth: 1.5))
    }

    /// Bold and italic in the theme's own face (a rounded system font draws
    /// neither from the intents alone); code sits on a soft tint of the outline.
    private func styled(_ c: Swatch) -> Text {
        guard markdown ?? !fromUser else { return Text(text) }
        var a = BubbleMarkdown.attributed(text)
        let size = theme.type.body
        for run in a.runs {
            guard let i = run.inlinePresentationIntent else { continue }
            if i.contains(.code) {
                a[run.range].backgroundColor = c.outline.opacity(0.45)
            } else if i.contains(.stronglyEmphasized) {
                a[run.range].font = i.contains(.emphasized) ? theme.font(size, .heavy).italic() : theme.font(size, .heavy)
            } else if i.contains(.emphasized) {
                a[run.range].font = theme.font(size, .medium).italic()
            }
        }
        return Text(a)
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
/// above it and Reply, Copy, Select text and Share sit below (a tapback, the
/// Telegram and iMessage way). The person's own bubbles get the menu without the bar.
/// The bar is always above and the menu always below, both on screen: a message
/// too tall for the room between them lifts as a preview of its top with a soft
/// fade at the cut (TestFlight feedback AFduDX-JwEKyTFAt4pnYIPY, YUI-78).
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
    /// The menu as drawn (rows grow with Dynamic Type); an estimate until then.
    @State private var drawnMenu: CGFloat?

    private let item = CGSize(width: 48, height: 58)
    private var barSize: CGSize {
        reacts ? CGSize(width: item.width * CGFloat(Reaction.all.count) + 12, height: item.height + 12) : .zero
    }
    private let menuWidth: CGFloat = 220
    private let rowHeight: CGFloat = 48
    /// Between the bar, the preview and the menu, and from the window's edges.
    private let gap: CGFloat = 10
    private let edge: CGFloat = 8
    /// A preview is never cut shorter than this, and fades over its last `fade` points.
    private let minPreview: CGFloat = 72
    private let fade: CGFloat = 56

    /// Where each piece goes: bar on top, then the preview, then the menu, in a
    /// column that fits the window. `internal` for the layout tests.
    struct Layout: Equatable {
        var bar: CGRect
        var preview: CGRect
        var menu: CGRect
        /// The preview shows only the top of the message.
        var cut: Bool
    }

    static func layout(rect: CGRect, size: CGSize, bar: CGSize, menu: CGSize, reacts: Bool,
                       gap: CGFloat = 10, edge: CGFloat = 8, minPreview: CGFloat = 72) -> Layout {
        let top = edge + (reacts ? bar.height + gap : 0)
        let bottom = size.height - edge - menu.height - gap
        let height = min(rect.height, max(minPreview, bottom - top))
        // Stay where it was held when that fits; else slide just enough (a bubble at
        // the bottom lifts, one under the header comes down).
        let y = max(top, min(rect.minY, bottom - height))
        let preview = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        let barX = min(max(rect.minX - 6, edge), size.width - bar.width - edge)
        let barRect = CGRect(x: barX, y: y - gap - bar.height, width: bar.width, height: bar.height)
        // Under the bubble's leading edge; the person's own (on the right) under its trailing edge.
        let menuX = reacts || rect.width < menu.width
            ? min(max(rect.minX, edge), size.width - menu.width - edge)
            : min(max(rect.maxX - menu.width, edge), size.width - menu.width - edge)
        let menuRect = CGRect(x: menuX, y: preview.maxY + gap, width: menu.width, height: menu.height)
        return Layout(bar: barRect, preview: preview, menu: menuRect, cut: height < rect.height - 0.5)
    }

    var body: some View {
        let c = theme.swatch(scheme)
        let l = Self.layout(rect: rect, size: size, bar: barSize, menu: CGSize(width: menuWidth, height: menuHeight),
                            reacts: reacts, gap: gap, edge: edge, minPreview: minPreview)
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

            preview(l)
                .position(x: l.preview.midX, y: l.preview.midY)

            if reacts {
                bar(c)
                    .scaleEffect(up ? 1 : 0.4, anchor: .bottomLeading)
                    .opacity(up ? 1 : 0)
                    .position(x: l.bar.midX, y: l.bar.midY)
            }

            menu(c)
                .scaleEffect(up ? 1 : 0.6, anchor: .topLeading)
                .opacity(up ? 1 : 0)
                .frame(width: menuWidth)
                .position(x: l.menu.midX, y: l.menu.minY + menuHeight / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { up = true } }
        .sensoryFeedback(.selection, trigger: chosen)
    }

    /// The held message in place, or the top of it when it is taller than the room.
    /// Tapping it closes, like tapping the thread.
    private func preview(_ l: Layout) -> some View {
        lifted()
            .frame(width: rect.width, height: rect.height)
            .frame(width: l.preview.width, height: l.preview.height, alignment: .top)
            .clipped()
            .mask {
                if l.cut {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 1 - fade / l.preview.height),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let shown = chosen ?? current {
                    ReactionBadge(reaction: shown).offset(x: 10, y: l.cut ? 0 : 16).transition(.scale(scale: 0.2))
                }
            }
            // A small lift, never more than a few points, so it can't reach the bar or the menu.
            .scaleEffect(up ? 1 + min(0.03, 6 / max(l.preview.height, 1)) : 1)
            .shadow(color: .black.opacity(up && !l.cut ? 0.18 : 0), radius: 14, y: 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l.cut ? "Held message, shortened" : "Held message")
            .accessibilityIdentifier("reaction-preview")
    }

    /// Rows: Reply, Copy, Select text, Share, and Remove when there is a reaction.
    private var rows: Int { current == nil ? 4 : 5 }
    private var menuHeight: CGFloat { drawnMenu ?? rowHeight * CGFloat(rows) }

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
                    .contentShape(Rectangle())
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reaction-bar")
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
            Divider().overlay(c.outline)
            ShareLink(item: text) { rowLabel("Share", icon: "square.and.arrow.up", c) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("react-share")
            if let current {
                Divider().overlay(c.outline)
                menuRow("Remove \(current.emoji)", icon: "xmark.circle", c) { pick(nil) }
                    .accessibilityIdentifier("react-remove")
            }
        }
        .frame(width: menuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline.opacity(0.6), lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drawnMenu = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reaction-menu")
    }

    private func menuRow(_ title: String, icon: String, _ c: Swatch, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, icon: icon, c) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, icon: String, _ c: Swatch) -> some View {
        HStack {
            Text(title).font(theme.font(theme.type.body, .semibold))
            Spacer()
            // The theme's type is a fixed size; the icon keeps pace with it.
            Image(systemName: icon).font(.system(size: theme.type.body, weight: .medium))
        }
        .foregroundStyle(c.ink)
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, 6)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
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
