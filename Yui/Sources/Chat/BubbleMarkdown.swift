import Foundation

/// The markdown hosts send in an agent's words (YUI-76): a slash command's answer
/// ("**Model:** `claude-...`"), a status update with lists. Drawn, not shown as
/// raw marks: bold, italic, strikethrough, inline code, code blocks, bullet and
/// numbered lists, headings as bold lines, and links (https only). Anything it
/// can't read stays as written. A ```yui fence is never touched.
enum BubbleMarkdown {
    /// The words as styled text. SwiftUI's Text draws the emphasis and code
    /// intents in the bubble's own font, so Dynamic Type still applies.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var first = true
        func add(_ line: AttributedString) {
            if !first { out.append(AttributedString("\n")) }
            out.append(line)
            first = false
        }
        while i < lines.count {
            let line = lines[i]
            if let lang = fenceLanguage(line), let end = lines[(i + 1)...].firstIndex(where: { fenceLanguage($0) == "" }) {
                let body = lines[(i + 1)..<end].joined(separator: "\n")
                if lang.lowercased() == "yui" {
                    // Yui Lines are the app's, not markdown: word for word.
                    add(AttributedString(lines[i...end].joined(separator: "\n")))
                } else {
                    var code = AttributedString(body)
                    code.inlinePresentationIntent = .code
                    add(code)
                }
                i = end + 1
                continue
            }
            add(block(line))
            i += 1
        }
        return out
    }

    /// The words with the marks taken off: what Copy, Select text, VoiceOver and
    /// the long-answer pages get.
    static func plain(_ text: String) -> String {
        String(attributed(text).characters)
    }

    // MARK: Lines

    /// "```", "```swift": the fence's language ("" for none). nil: not a fence.
    static func fenceLanguage(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return nil }
        let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return lang.contains("`") ? nil : lang
    }

    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.*)$"#)
    private static let number = try! NSRegularExpression(pattern: #"^(\s*)(\d{1,3})[.)]\s+(.*)$"#)
    private static let heading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$"#)

    /// One line: a list item keeps its marker (a dot for a bullet), a heading reads bold.
    private static func block(_ line: String) -> AttributedString {
        if let m = match(bullet, line) {
            var a = AttributedString(indent(m[0]) + "•  ")
            a.append(inline(m[1]))
            return a
        }
        if let m = match(number, line) {
            var a = AttributedString(indent(m[0]) + m[1] + ".  ")
            a.append(inline(m[2]))
            return a
        }
        if let m = match(heading, line) {
            var a = inline(m[0])
            for run in a.runs {
                a[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
            return a
        }
        return inline(line)
    }

    /// Nested items step in by a few spaces, whatever the host used.
    private static func indent(_ s: String) -> String {
        String(repeating: "   ", count: min(3, s.count / 2))
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    // MARK: Inline

    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible)

    /// Emphasis, code and links in one line. Malformed: the line as written.
    /// A link that isn't https keeps its words and loses the tap.
    static func inline(_ s: String) -> AttributedString {
        guard s.contains(where: { "*_`[~<\\".contains($0) }),
              var a = try? AttributedString(markdown: s, options: options) else { return AttributedString(s) }
        for run in a.runs {
            if let url = run.link, url.scheme?.lowercased() != "https" { a[run.range].link = nil }
        }
        return a
    }
}
