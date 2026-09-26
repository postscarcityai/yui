import SwiftUI
import YuiLines

// Talk about this (YUI-69, spec yuigui/spec/TALK-ABOUT.md). Every item screen in
// Controls has a Talk about this button. It closes the drawer, lands on screen 1
// and pins the item above the composer as a chip. What the person sends with the
// chip on is one ordinary text row in this thread:
//   body  [yui] attach section=soul id=SOUL.md rev=b41c09
//         <the words>
//   meta  {"about": {"section": "soul", "id": "SOUL.md", "title": "SOUL.md"}}
// The host puts the item's text in the agent's turn; the bubble shows "About SOUL.md".
// The chip stays for the whole talk: x takes it off, and so does an applied
// proposal for it or moving to another agent.

/// The item on the chip.
struct TalkItem: Equatable, Identifiable, Sendable {
    let section: ControlSection
    let itemID: String
    let rev: String
    /// "SOUL.md", a memory's first line, a skill's or schedule's name.
    let title: String
    /// Shown read only when the chip is tapped, as Controls shows it.
    var text: String?
    var id: String { "\(section.rawValue)/\(itemID)" }

    /// The chip's title for an item from Controls.
    static func title(_ section: ControlSection, _ item: ControlItem) -> String {
        switch section {
        case .soul: return "SOUL.md"
        case .memory:
            let line = (item.text ?? item.title ?? "").split(separator: "\n").first.map(String.init) ?? "A memory"
            return line.count > 40 ? String(line.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : line
        case .model: return "Model and tools"
        default: return item.title ?? item.id
        }
    }
}

enum TalkAbout {
    /// `[yui] attach section= id= rev=` then the words.
    static func body(_ words: String, about: TalkItem) -> String {
        YuiLines.attachBody(section: about.section.rawValue, id: about.itemID, rev: about.rev, words: words)
    }

    static func meta(_ base: YLValue?, about: TalkItem) -> YLValue {
        var o = base?.object ?? [:]
        o["about"] = .object(["section": .string(about.section.rawValue), "id": .string(about.itemID),
                              "title": .string(about.title)])
        return .object(o)
    }

    /// "SOUL.md" for a person's row sent about an item.
    static func title(meta: YLValue?) -> String? {
        meta?.object?["about"]?.object?["title"]?.string
    }

    /// The bubble's words: the attach line comes off.
    static func words(body: String, meta: YLValue?) -> String {
        guard title(meta: meta) != nil, let a = YuiLines.readAttach(body) else { return body }
        return a.words
    }

    /// An agent row saying a proposal was applied: the item it changed.
    static func applied(meta: YLValue?) -> String? {
        guard let a = meta?.object?["talk"]?.object?["applied"]?.object,
              let s = a["section"]?.string, let id = a["id"]?.string else { return nil }
        return "\(s)/\(id)"
    }
}

extension EnvironmentValues {
    /// Set by the drawer: pins an item from Controls to the composer and closes everything.
    @Entry var talkAbout: ((TalkItem) -> Void)? = nil
}

/// Under an item in Controls.
struct TalkAboutButton: View {
    let item: TalkItem
    @Environment(\.talkAbout) private var talkAbout

    var body: some View {
        if let talkAbout {
            Button("Talk about this", systemImage: "bubble.left.and.text.bubble.right.fill") { talkAbout(item) }
                .buttonStyle(ControlsPill(filled: true))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Opens the chat with this pinned above the message field")
                .accessibilityIdentifier("controls-talk-about")
        }
    }
}

/// Above the composer: the item the words are about.
struct AboutChip: View {
    let item: TalkItem
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            Button(action: open) {
                HStack(spacing: theme.spacing.s) {
                    Image(systemName: item.section.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(c.accent)
                        .frame(width: 28, height: 28)
                        .background(c.accent.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title)
                            .font(theme.font(theme.type.caption, .heavy))
                            .foregroundStyle(c.ink)
                            .lineLimit(1)
                        Text(item.section.title)
                            .font(theme.font(11, .semibold))
                            .foregroundStyle(c.inkSoft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("About \(item.title), \(item.section.title)")
            .accessibilityHint("Shows it")
            .accessibilityIdentifier("about-chip")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(c.surface, c.inkSoft)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop talking about \(item.title)")
            .accessibilityIdentifier("about-chip-remove")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, theme.spacing.s)
        .padding(.vertical, theme.spacing.xs)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.bubbleTail + 6))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubbleTail + 6).stroke(c.accent.opacity(0.45), lineWidth: 1.5))
    }
}

/// Over a message sent about an item: "About SOUL.md".
struct AboutTag: View {
    let title: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label("About \(title)", systemImage: "pin.fill")
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .lineLimit(1)
            .accessibilityIdentifier("about-tag")
    }
}

/// The chip's item, read only, as Controls shows it.
struct AboutPreview: View {
    let item: TalkItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Label(item.section.title, systemImage: item.section.icon)
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.inkSoft)
                    Text(BubbleMarkdown.attributed(Self.withoutFrontmatter(item.text ?? "")))
                        .font(theme.font(16))
                        .foregroundStyle(c.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.spacing.l)
                        .background(c.surface, in: .rect(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
                        .accessibilityIdentifier("about-preview-text")
                }
                .padding(theme.spacing.l)
            }
            .background(c.background)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("about-preview-close")
                }
            }
        }
        .tint(c.accent)
    }

    static func withoutFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) else { return s }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
