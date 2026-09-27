// `visual` (yuigui spec/YL.md section 5, The visual; spec/VISUAL.md; YUI-124): a
// live shader behind the stage's chunks, or alone on it. One look at most,
// `tone=` (accent, a theme set name or #RRGGBB) and `react=` (voice, music, mic
// or off). `visual off` takes it away. Anything else is an error, so the line
// never draws something half right. Same rules as visualLine in yl.mjs.

/// What `YuiLines.visual(of:)` gives: the newest visual's words. Defaults are the renderer's.
public struct YLVisual: Equatable, Sendable {
    public var look: String?
    public var tone: String?
    public var react: String?

    public init(look: String? = nil, tone: String? = nil, react: String? = nil) {
        self.look = look
        self.tone = tone
        self.react = react
    }
}

extension YuiLines {
    public static let visualLooks = ["orb", "aurora", "waves", "grain", "bloom"]
    public static let visualReact = ["voice", "music", "mic", "off"]

    /// One `visual` line after `visual`.
    static func visualLine(screen: String, tokens: [Token], line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: "visual: \(m)", line: line) }
        if tokens.count == 1, !tokens[0].quoted, tokens[0].raw == "off" {
            return YLNode(op: .visual, screen: screen, props: ["off": .bool(true)], line: line)
        }
        var props: [String: YLValue] = [:]
        for t in tokens {
            if let key = t.key {
                guard key == "tone" || key == "react" else { return bad("takes a look, tone= and react=, nothing else") }
                if t.value.count > 1 { return bad("\(key)= takes one value") }
                let v = t.value.first ?? ""
                if key == "tone", !(v == "accent" || appSets.contains(v) || isHex6(v)) {
                    return bad("tone= is accent, a theme set name or #RRGGBB")
                }
                if key == "react", !visualReact.contains(v) { return bad("react= is voice, music, mic or off") }
                props[key] = .string(v)
                continue
            }
            if !t.quoted, t.parts == nil, isFlag(t.raw) { return bad("takes no flags") }
            if t.quoted || t.parts != nil || !visualLooks.contains(t.raw) {
                return bad("the look is one of \(visualLooks.joined(separator: ", "))")
            }
            if props["look"] != nil { return bad("one look at a time") }
            props["look"] = .string(t.raw)
        }
        return YLNode(op: .visual, screen: screen, props: props, line: line)
    }

    /// The visual after these nodes: the newest visual, or nil when there is
    /// none or the last one was `visual off`. Like `visualOf` in yl.mjs.
    public static func visual(of nodes: some Sequence<YLNode>) -> YLVisual? {
        var now: YLVisual?
        for n in nodes where n.op == .visual {
            let p = n.props ?? [:]
            now = p["off"]?.bool == true ? nil : YLVisual(look: p["look"]?.string, tone: p["tone"]?.string, react: p["react"]?.string)
        }
        return now
    }
}
