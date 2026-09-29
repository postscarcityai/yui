import SwiftUI

// A real body text style (YUI-196, TestFlight feedback: "when you're using big
// text ... it should only be a one liner or a headline. We need to develop more
// of a body text for this app", "AI is always going to give us markdown").
// Two voices: a headline (big, heavy) for one short line, and a body (regular
// weight, open leading, a comfortable measure) for everything longer. Markdown
// is drawn in both, never shown as ** or #. The site mirrors the rule in
// yuigui site/lib/yl/typography.mjs.

enum ReadingType {
    enum Role { case headline, body }

    /// A headline is one short line: about a line or two at display size.
    static let headlineChars = 60
    static let headlineWords = 12
    /// The measure a body line reads at, in characters. A phone is narrower than
    /// this already; it caps a wide iPad or a landscape line.
    static let measureChars = 66

    /// Headline for one short plain line; body for a sentence, a paragraph, a
    /// list, a heading over words or a `Label: value` line. Judged on the words as
    /// drawn (the marks taken off).
    static func role(_ text: String) -> Role {
        let blocks = ReadingBlock.parse(text)
        guard blocks.count == 1, case .paragraph(let a) = blocks[0] else { return .body }
        let plain = String(a.characters)
        return plain.count <= headlineChars && LongText.wordCount(plain) <= headlineWords ? .headline : .body
    }
}

extension YuiTheme {
    /// The body's size: a step over the chat's 17 so a paragraph reads on a phone.
    var readSize: Double { type.body + 2 }
    /// Open leading for body: about 1.4 of the size.
    var readLeading: Double { readSize * 0.4 - 4 }
    /// The measure (~66 ch) in points, so a body never runs edge to edge on a wide screen.
    var readMeasure: Double { readSize * 0.52 * Double(ReadingType.measureChars) }
}

/// One block of a markdown answer.
enum ReadingBlock: Equatable {
    case heading(AttributedString, level: Int)
    case bullet(AttributedString, indent: Int)
    case number(String, AttributedString, indent: Int)
    /// `Label: value`: the part before the colon takes the accent.
    case label(String, AttributedString)
    case paragraph(AttributedString)
    case code(String)
    case gap

    /// The blocks of a text, one per line, a blank line a gap. A fence is one
    /// code block, a ```yui fence is left to the parser (never here).
    static func parse(_ text: String) -> [ReadingBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let sole = BubbleMarkdown.isSoleItem(lines)
        var out: [ReadingBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let _ = BubbleMarkdown.fenceLanguage(line), let end = lines[(i + 1)...].firstIndex(where: { BubbleMarkdown.fenceLanguage($0) == "" }) {
                out.append(.code(lines[(i + 1)..<end].joined(separator: "\n")))
                i = end + 1
                continue
            }
            i += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let last = out.last, last != .gap { out.append(.gap) }
                continue
            }
            out.append(block(line, sole: sole))
        }
        while out.last == .gap { out.removeLast() }
        return out
    }

    private static func block(_ line: String, sole: Bool) -> ReadingBlock {
        if let m = BubbleMarkdown.match(BubbleMarkdown.bullet, line) {
            if sole { return lead(m[1]) }
            let indent = min(3, m[0].count / 2)
            if case .label(let l, let v) = lead(m[1]) { return .bullet(labelled(l, v), indent: indent) }
            return .bullet(BubbleMarkdown.inline(m[1]), indent: indent)
        }
        if let m = BubbleMarkdown.match(BubbleMarkdown.number, line) {
            return .number(m[1], BubbleMarkdown.inline(m[2]), indent: min(3, m[0].count / 2))
        }
        if let m = BubbleMarkdown.match(BubbleMarkdown.heading, line) {
            let level = line.drop { $0 == " " }.prefix { $0 == "#" }.count
            return .heading(BubbleMarkdown.inline(m[0]), level: level)
        }
        return lead(line)
    }

    // `**Label:** rest`, `**Label**: rest`, or a plain `Label: rest`.
    private static let boldLead = try! NSRegularExpression(pattern: #"^\*\*(.{1,40}?):\*\*\s*(.*)$|^\*\*(.{1,40}?)\*\*:\s*(.*)$"#)
    private static let plainLead = try! NSRegularExpression(pattern: #"^([\p{L}\p{N}][^:\n.!?*_`\[\]]{0,30}?):\s+(\S.*)$"#)

    /// A line that opens with a short label. Not a label: a link, a time, a long clause.
    private static func lead(_ s: String) -> ReadingBlock {
        if let m = BubbleMarkdown.match(boldLead, s) {
            let label = m[0].isEmpty ? m[2] : m[0]
            let rest = m[0].isEmpty ? m[3] : m[1]
            return .label(label, BubbleMarkdown.inline(rest))
        }
        if let m = BubbleMarkdown.match(plainLead, s), LongText.wordCount(m[0]) <= 4 {
            return .label(m[0], BubbleMarkdown.inline(m[1]))
        }
        return .paragraph(BubbleMarkdown.inline(s))
    }

    /// The label and its words as one run of text, so a long value wraps under itself.
    static func labelled(_ label: String, _ value: AttributedString) -> AttributedString {
        var a = AttributedString(label + ":")
        a.inlinePresentationIntent = .stronglyEmphasized
        a.append(AttributedString(" "))
        a.append(value)
        return a
    }
}

/// A markdown answer in the new type: a headline when it is one short line,
/// body for everything else. Lists, headings, bold, italic, code, links and
/// `Label: value` lines are drawn; the label takes the accent.
struct ReadingText: View {
    let text: String
    /// The color of the words; the label and list marks take the accent.
    var ink: Color
    var soft: Color? = nil
    var accent: Color
    /// The headline's size when the text is one short line.
    var headlineSize: Double? = nil
    /// Lay a body out at a headline's weight only when it is one short line.
    var alignment: HorizontalAlignment = .leading
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        let blocks = ReadingBlock.parse(text)
        if ReadingType.role(text) == .headline, let size = headlineSize, case .paragraph(let a) = blocks[0] {
            Text(a)
                .font(theme.font(size, .heavy))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: alignment, spacing: theme.spacing.s + 2) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in row(b) }
            }
            // An ideal width under any phone: the measure is a cap, never what a parent sizes to.
            .frame(minWidth: 0, idealWidth: 280, maxWidth: theme.readMeasure, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    private var size: Double { theme.readSize }

    private func words(_ a: AttributedString, weight: Font.Weight = .regular, color: Color? = nil) -> some View {
        Text(a)
            .font(theme.font(size, weight))
            .foregroundStyle(color ?? ink)
            .lineSpacing(theme.readLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func row(_ b: ReadingBlock) -> some View {
        switch b {
        case .gap:
            Color.clear.frame(height: theme.spacing.xs)
        case .paragraph(let a):
            words(a)
        case .heading(let a, let level):
            Text(a)
                .font(theme.font(level <= 1 ? size + 5 : level == 2 ? size + 2 : size, theme.strong))
                .foregroundStyle(ink)
                .padding(.top, theme.spacing.xs)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let a, let indent):
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                Circle().fill(accent).frame(width: 6, height: 6).offset(y: -size * 0.16)
                words(a)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .number(let n, let a, let indent):
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                Text(n + ".").font(theme.font(size, .bold).monospacedDigit()).foregroundStyle(accent)
                words(a)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .label(let label, let value):
            (Text(label + ": ").font(theme.font(size, .bold)).foregroundStyle(accent)
                + Text(value).font(theme.font(size)).foregroundStyle(ink))
                .lineSpacing(theme.readLeading)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let s):
            Text(s)
                .font(.system(size: size - 3, design: .monospaced))
                .foregroundStyle(ink)
                .padding(theme.spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((soft ?? ink).opacity(0.12), in: .rect(cornerRadius: theme.radius.bubble / 2))
        }
    }
}
