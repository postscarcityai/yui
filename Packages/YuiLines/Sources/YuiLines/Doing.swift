// `doing` (yuigui spec/YL.md section 5, The working row; YUI-63): a few words on
// what the agent is doing, and a thin bar when a last bare `n/m` says how far
// along it is. `doing off` puts the working word back. Words and a step only:
// keys and flags are errors. Same rules as doingLine in yl.mjs.

/// The working row's words and step: what `YuiLines.doing(of:)` gives.
public struct YLDoing: Equatable, Sendable {
    public var text: String?
    public var step: Int?
    public var of: Int?

    public init(text: String? = nil, step: Int? = nil, of: Int? = nil) {
        self.text = text
        self.step = step
        self.of = of
    }

    /// The bar's fill, 0...1, when there is a step.
    public var progress: Double? {
        guard let step, let of, of > 0 else { return nil }
        return Double(step) / Double(of)
    }
}

extension YuiLines {
    /// One `doing` line after `doing`.
    static func doingLine(screen: String, tokens: [Token], line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: "doing: \(m)", line: line) }
        if tokens.count == 1, !tokens[0].quoted, tokens[0].raw == "off" {
            return YLNode(op: .doing, screen: screen, props: ["off": .bool(true)], line: line)
        }
        if tokens.contains(where: { $0.key != nil || (!$0.quoted && $0.parts == nil && isFlag($0.raw)) }) {
            return bad("takes words and a step like 2/5, no keys or flags")
        }
        var words = tokens[...]
        var step: (Int, Int)?
        if let last = tokens.last, !last.quoted, last.parts == nil, let s = stepOf(last.raw) {
            step = s
            words = words.dropLast()
        }
        let text = words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        if text.isEmpty && step == nil { return bad("needs words, a step like 2/5, or off") }
        var props: [String: YLValue] = [:]
        if !text.isEmpty { props["text"] = .string(text) }
        if let (n, m) = step {
            if m < 1 || n > m { return bad("the step is n/m with n from 0 to m") }
            props["step"] = .number(Double(n))
            props["of"] = .number(Double(m))
        }
        return YLNode(op: .doing, screen: screen, props: props, line: line)
    }

    /// `^(\d+)\/(\d+)$`
    private static func stepOf(_ raw: String) -> (Int, Int)? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let n = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (n, m)
    }

    /// The working row after these nodes: the newest doing, or nil when there
    /// is none or the last one was `doing off`. Like `doingOf` in yl.mjs.
    public static func doing(of nodes: some Sequence<YLNode>) -> YLDoing? {
        var now: YLDoing?
        for n in nodes where n.op == .doing {
            let p = n.props ?? [:]
            now = p["off"]?.bool == true ? nil : YLDoing(
                text: p["text"]?.string,
                step: p["step"]?.number.map { Int($0) },
                of: p["of"]?.number.map { Int($0) })
        }
        return now
    }
}
