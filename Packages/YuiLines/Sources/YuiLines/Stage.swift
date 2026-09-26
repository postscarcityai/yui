/// The stage (spec `yuigui/spec/YL.md` section 5, "The stage"): a full-screen
/// layer over the chat for moments that deserve the whole phone.
extension YuiLines {
    /// Presets that open on the stage unless they say `+inline`.
    public static let stagePresets: Set<String> = ["timer", "camera", "mic", "deck", "plan", "game"]

    /// A timer with rounds or rest. Workouts always open on the stage.
    public static func isWorkout(preset: String, props: [String: YLValue]) -> Bool {
        guard preset == "timer", props["up"]?.bool != true else { return false }
        return (props["rounds"]?.number ?? 1) > 1 || (props["rest"]?.number ?? 0) > 0
    }

    /// Whether an added component opens on the stage. `style` is the agent's
    /// style profile (`screen=chat|full`, `gallery=...`). Mirrors `onStage`
    /// in the JS reference parser.
    public static func opensOnStage(preset: String, screen: String, props: [String: YLValue],
                                    style: [String: String] = [:]) -> Bool {
        if screen == "full" { return true }
        if isWorkout(preset: preset, props: props) { return true }
        // A route to a page beats the stage defaults (spec section 5, Pages).
        if page(of: screen) != 1 { return false }
        if props["inline"]?.bool == true { return false }
        if style["screen"] == "chat" { return false }
        if style["screen"] == "full" { return true }
        if stagePresets.contains(preset) { return true }
        return preset == "gallery" && (props["layout"]?.string ?? style["gallery"]) == "row3d"
    }

    /// `opensOnStage` for a parsed node: only adds can open on the stage.
    public static func opensOnStage(_ node: YLNode, style: [String: String] = [:]) -> Bool {
        guard node.op == .add, let preset = node.preset else { return false }
        return opensOnStage(preset: preset, screen: node.screen, props: node.props ?? [:], style: style)
    }
}

/// Pages (spec `yuigui/spec/YL.md` section 5, "Pages"): the chat, then up to
/// eleven screens beside it, `2` through `12`. A page exists while something is on it.
extension YuiLines {
    /// The most pages an agent's thread has: the chat plus screens 2 to 12.
    public static let maxPage = 12

    /// The page a screen lives on: `2` to `12` are pages beside the chat; every
    /// other screen (`1`, `chat`, `full`, `stats-view`, `13`, `02`) renders in the chat, page 1.
    /// Mirrors `pageOf` in the JS reference parser.
    public static func page(of screen: String) -> Int {
        guard let n = Int(screen), String(n) == screen, (2...maxPage).contains(n) else { return 1 }
        return n
    }

    /// Chat with a screen: the pages whose composer is on after these nodes, in
    /// number order. `talk` turns it on, `talk off` and `clear` take it away; only
    /// pages 2 to 12 have one to turn on. Mirrors `talking` in the JS reference parser.
    public static func talking(_ nodes: [YLNode]) -> [Int] {
        var on = Set<Int>()
        for n in nodes {
            let p = page(of: n.screen)
            guard p != 1 else { continue }
            if n.op == .talk, n.props?["on"]?.bool == true { on.insert(p) }
            else if n.op == .clear || n.op == .talk { on.remove(p) }
        }
        return on.sorted()
    }

    /// What the person typed on a page, as the agent reads it (spec section 7):
    /// a `[yui] screen=2` line, then the words. Anywhere else the words as they are.
    public static func typedBody(screen: String, words: String) -> String {
        page(of: screen) == 1 ? words : "[yui] screen=\(screen)\n" + words
    }

    /// The other way: the screen and words of a message typed on a page, else nil.
    public static func readTyped(_ body: String) -> (screen: String, words: String)? {
        guard body.hasPrefix("[yui] screen="), let nl = body.firstIndex(of: "\n") else { return nil }
        var screen = body[body.index(body.startIndex, offsetBy: 13)..<nl]
        if screen.hasSuffix("\r") { screen = screen.dropLast() }
        guard !screen.isEmpty, !screen.contains(where: \.isWhitespace), page(of: String(screen)) != 1 else { return nil }
        return (String(screen), String(body[body.index(after: nl)...]))
    }

    /// Talk about this (spec TALK-ABOUT.md): a `[yui] attach section= id= rev=`
    /// line naming one Controls item, then the words. Not an item: the words as they are.
    public static func attachBody(section: String, id: String, rev: String, words: String) -> String {
        guard isAttachItem(section: section, id: id, rev: rev) else { return words }
        return "[yui] attach section=\(section) id=\(id) rev=\(rev)\n" + words
    }

    /// The other way: the item and words of a message about an item, else nil.
    public static func readAttach(_ body: String) -> (section: String, id: String, rev: String, words: String)? {
        let head = "[yui] attach "
        guard body.hasPrefix(head), let nl = body.firstIndex(of: "\n") else { return nil }
        var line = body[body.index(body.startIndex, offsetBy: head.count)..<nl]
        if line.hasSuffix("\r") { line = line.dropLast() }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("section="), parts[1].hasPrefix("id="), parts[2].hasPrefix("rev=")
        else { return nil }
        let section = String(parts[0].dropFirst(8)), id = String(parts[1].dropFirst(3)), rev = String(parts[2].dropFirst(4))
        guard isAttachItem(section: section, id: id, rev: rev) else { return nil }
        return (section, id, rev, String(body[body.index(after: nl)...]))
    }

    static func isAttachItem(section: String, id: String, rev: String) -> Bool {
        section.range(of: #"^[a-z]{1,20}$"#, options: .regularExpression) != nil
            && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
            && !id.contains("..")
            && rev.range(of: #"^[A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil
    }
}
