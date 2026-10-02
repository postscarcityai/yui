// Free drawing: `draw [title] [caption=] [ratio=]`, then markup up to `end`.
//
// The head is an add (preset "draw", props title?, caption?, ratio?). Every line
// after it, up to a line that is only `end`, is the drawing's own markup (SVG,
// with CSS or a script to move it) and not YL, as a `diagram` reads Mermaid. The
// `end` (or the end of the reply) gives one patch on the draw with
// `source`: the markup as written. If the first line after the head does not
// open a tag, the draw stays empty and that line is read as YL.
//
// The parser does not read the markup. A renderer draws it in a sandbox with no
// network and gives it the agent's colors as CSS variables.

struct YLDrawReader: Sendable {
    /// A drawing longer than this is cut: the rest of its lines are dropped, the `end` still closes it.
    static let mostLines = 600
    static let mostChars = 60_000

    var id: String
    var screen: String
    var src: [String] = []
    var chars = 0
}

extension YLParser {
    /// One line of an open draw. Nil when no draw is open, or this line shows there is no markup
    /// (it is then read as YL); `.some(nil)` for a line taken, `.some(node)` for the patch at `end`.
    mutating func drawLine(_ src: String) -> YLNode?? {
        guard var d = drw else { return nil }
        let line = src.hasSuffix("\r") ? String(src.dropLast()) : src
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "end" { return .some(drawDone(line: line)) }
        if d.src.isEmpty {
            if t.isEmpty { return .some(nil) }
            if !t.hasPrefix("<") { drw = nil; return nil }
        }
        if d.src.count < YLDrawReader.mostLines, d.chars + line.count <= YLDrawReader.mostChars {
            d.src.append(line)
            d.chars += line.count + 1
        }
        drw = d
        return .some(nil)
    }

    /// The patch an open draw gives at its end (or at the end of input).
    mutating func drawDone(line: String) -> YLNode? {
        guard let d = drw else { return nil }
        drw = nil
        guard !d.src.isEmpty else { return nil }
        return YLNode(op: .patch, screen: d.screen, target: d.id,
                      props: ["source": .string(d.src.joined(separator: "\n"))], line: line)
    }
}
