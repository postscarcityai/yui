// The drawer's `menu` word (spec yuigui/spec/YL.md section 5, The drawer).
// `menu review@dana "Invite Dana?" sub="requested yesterday"` puts an item in
// one of three drawer sections; `menu done dana` takes it out. No @id counter,
// no screen routing. Mirrors `menuLine` and `menuOf` in the JS reference.

/// One item in the agent's drawer.
public struct YLMenuItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// A quieter line under the label.
    public var sub: String?
    /// What a shortcut sends as the person's message (the label when nil).
    public var say: String?
    /// A saved screen's name: a tap opens it on the stage with no turn.
    public var show: String?
    /// A link a tap opens in the browser.
    public var url: String?

    public init(id: String, label: String, sub: String? = nil, say: String? = nil, show: String? = nil, url: String? = nil) {
        self.id = id
        self.label = label
        self.sub = sub
        self.say = say
        self.show = show
        self.url = url
    }
}

/// The three sections an agent fills, each newest first.
public struct YLMenu: Codable, Equatable, Sendable {
    public var review: [YLMenuItem] = []
    public var backlog: [YLMenuItem] = []
    public var shortcut: [YLMenuItem] = []

    public init(review: [YLMenuItem] = [], backlog: [YLMenuItem] = [], shortcut: [YLMenuItem] = []) {
        self.review = review
        self.backlog = backlog
        self.shortcut = shortcut
    }

    public var isEmpty: Bool { review.isEmpty && backlog.isEmpty && shortcut.isEmpty }

    public subscript(bucket: String) -> [YLMenuItem] {
        get {
            switch bucket {
            case "review": review
            case "backlog": backlog
            default: shortcut
            }
        }
        set {
            switch bucket {
            case "review": review = newValue
            case "backlog": backlog = newValue
            default: shortcut = newValue
            }
        }
    }

    /// The section an item is in, if any.
    public func bucket(of id: String) -> String? {
        YuiLines.menuBuckets.first { self[$0].contains { $0.id == id } }
    }

    /// Applies one `menu` node: an add replaces the id wherever it was, `done` removes it.
    public mutating func apply(_ node: YLNode) {
        guard node.op == .menu, let id = node.id else { return }
        for b in YuiLines.menuBuckets { self[b].removeAll { $0.id == id } }
        let p = node.props ?? [:]
        guard p["done"]?.bool != true, let bucket = p["bucket"]?.string, let label = p["label"]?.string else { return }
        let item = YLMenuItem(id: id, label: YuiLines.cutMenuLabel(label), sub: p["sub"]?.string,
                              say: p["say"]?.string, show: p["show"]?.string, url: p["url"]?.string)
        self[bucket] = Array(([item] + self[bucket]).prefix(YuiLines.menuMax))
    }
}

extension YuiLines {
    public static let menuBuckets = ["review", "backlog", "shortcut"]
    static let menuKeys: Set<String> = ["sub", "say", "show", "url"]
    public static let menuMax = 20
    public static let menuLabel = 60

    /// The drawer after these nodes, from `menu` (empty by default).
    public static func menu(_ nodes: [YLNode], into menu: YLMenu = YLMenu()) -> YLMenu {
        var m = menu
        for n in nodes { m.apply(n) }
        return m
    }

    /// An item with no @id is known by its label: lowercase, every run of other
    /// characters as one "-" (`Start today's workout` is `start-today-s-workout`).
    public static func menuId(_ label: String) -> String {
        var out = String.UnicodeScalarView()
        var dash = false
        for c in label.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || isDigit(c) {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.append(c)
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "item" : String(out)
    }

    /// Labels past 60 characters (Unicode scalars, as JS counts code points) are
    /// cut to 59 and an ellipsis.
    static func cutMenuLabel(_ label: String) -> String {
        let u = Scalars(label.unicodeScalars)
        guard u.count > menuLabel else { return label }
        var head = Array(u[0..<(menuLabel - 1)])
        while let last = head.last, isSpace(last) { head.removeLast() }
        return String(head) + "\u{2026}"
    }

    /// One `menu` line after its head.
    static func menuLine(screen: String, tokens: [Token], line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: m, line: line) }
        guard let first = tokens.first else { return bad("menu: needs review, backlog, shortcut or done") }
        // ^([a-z]+)(?:@([\w-]+))?$
        let h = Scalars(first.raw.unicodeScalars)
        var j = 0
        while j < h.count, ("a"..."z").contains(h[j]) { j += 1 }
        let word = String(h[0..<j])
        var id: String?
        if j < h.count, h[j] == "@", j + 1 < h.count, h[(j + 1)...].allSatisfy(isWordish) {
            id = String(h[(j + 1)...])
            j = h.count
        }
        guard j > 0, j == h.count, menuBuckets.contains(word) || (word == "done" && id == nil) else {
            return bad("menu: \"\(first.raw)\" is not review, backlog, shortcut or done")
        }
        let rest = tokens.dropFirst()
        if word == "done" {
            let name = rest.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { return bad("menu done: needs an id") }
            let plain = name.unicodeScalars.allSatisfy(isWordish)
            return YLNode(op: .menu, screen: screen, id: plain ? name : menuId(name), props: ["done": .bool(true)], line: line)
        }
        var props: [String: YLValue] = ["bucket": .string(word)]
        var words: [String] = []
        for t in rest {
            if let k = t.key {
                if menuKeys.contains(k) { props[k] = .string(t.value.joined(separator: "|")) }
            } else if !(!t.quoted && t.parts == nil && isFlag(t.raw)) {
                words.append(t.text)
            }
        }
        let label = words.filter { !$0.isEmpty }.joined(separator: " ")
        guard !label.isEmpty else { return bad("menu: needs a label") }
        props["label"] = .string(label)
        return YLNode(op: .menu, screen: screen, id: id ?? menuId(label), props: props, line: line)
    }
}
