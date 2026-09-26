/// Yui Lines v0. Spec: `yuigui/spec/YL.md`. Conformance: `yuigui/spec/conformance`.
public enum YuiLines {
    /// Parses a whole reply. Blank and comment lines produce nothing. `known` is
    /// the ids that last from earlier replies (spec section 5), id -> preset.
    public static func parse(_ text: String, known: [String: String] = [:]) -> [YLNode] {
        var p = YLParser(known: known)
        return splitLines(Array(text.utf8)).compactMap { p.line($0) }
    }

    /// Nodes from a stream of text chunks (model tokens, socket frames), each
    /// emitted the moment its line's newline arrives. The tail is parsed when
    /// the stream ends.
    public static func nodes<S: AsyncSequence & Sendable>(from chunks: S) -> AsyncThrowingStream<YLNode, Error>
    where S.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                var s = YLStreamParser()
                do {
                    for try await chunk in chunks {
                        for node in s.push(chunk) { continuation.yield(node) }
                    }
                    for node in s.flush() { continuation.yield(node) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func splitLines(_ bytes: [UInt8]) -> [String] {
        bytes.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }
}

// `theme app [set] key=value...` (yuigui spec/YL.md, theme app; RESTYLE.md): a
// restyle of Yui's own chrome, not the agent's look. Stricter than an agent's
// theme: an unknown set, key or value is an error line, never quietly dropped,
// because the preview must be exactly what Apply does. Same tables as the JS
// reference (site/lib/yl/look.mjs) and AgentLook.
extension YuiLines {
    static let appSets: Set<String> = [
        "yui", "candy", "berry", "cherry", "coral", "sunset", "peach", "autumn", "honey",
        "lemon", "lime", "matcha", "forest", "mint", "teal", "sky", "ocean", "midnight",
        "lavender", "grape", "slate", "mono", "wizard", "coach", "zen", "studio", "night", "counsel",
    ]
    static let appPapers: Set<String> = ["cream", "paper", "white", "mist", "sand", "blush"]
    static let appStyleKeys: Set<String> = ["screen", "gallery", "chart", "buttons"]

    /// ^#[0-9a-f]{6}$ with the i flag
    static func isHex6(_ v: String) -> Bool {
        let u = Array(v.unicodeScalars)
        return u.count == 7 && u[0] == "#" && u[1...].allSatisfy { $0.isASCII && $0.properties.isASCIIHexDigit }
    }

    /// nil for a key the app does not take, else whether it takes this value.
    static func appValueOK(_ key: String, _ v: String) -> Bool? {
        switch key {
        case "accent": return isHex6(v) || appSets.contains(v)
        case "bg": return isHex6(v) || appPapers.contains(v)
        case "radius": return ["round", "soft", "square"].contains(v)
        case "font": return ["rounded", "default", "serif", "mono"].contains(v)
        case "weight": return ["regular", "bold", "heavy"].contains(v)
        case "motion": return ["bouncy", "calm", "snappy"].contains(v)
        default: return nil
        }
    }

    /// One `theme app` line after `theme app`: a theme node with `props.scope` "app".
    static func appTheme(screen: String, tokens: ArraySlice<Token>, line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: "theme app: \(m)", line: line) }
        var props: [String: YLValue] = ["scope": .string("app")]
        var words: [String] = []
        for t in tokens {
            if let k = t.key {
                let v = t.value.joined(separator: "|")
                if appStyleKeys.contains(k) { return bad("\(k)= is one agent's style, not the app's") }
                guard let ok = appValueOK(k, v) else { return bad("unknown key \(k)=") }
                guard ok else { return bad("\(k)=\(v) is not a value the app takes") }
                props[k] = .string(v)
            } else if !t.quoted, t.parts == nil, isFlag(t.raw) {
                return bad("\(t.raw) is not a flag here; the person always sees a preview first")
            } else {
                words.append(t.text)
            }
        }
        if words.count > 1 { return bad("one set name, not \"\(words.joined(separator: " "))\"") }
        if let name = words.first {
            if name == "reset" {
                if props.count > 1 { return bad("reset takes nothing else") }
            } else if !appSets.contains(name) {
                return bad("no set named \(name)")
            }
            props["name"] = .string(name)
        }
        if props.count == 1 { return bad("needs a set name, reset or keys") }
        return YLNode(op: .theme, screen: screen, props: props, line: line)
    }
}

/// Line-at-a-time parser. Stateful: it remembers the focused screen, the
/// auto-id counter and which preset each id belongs to, so `~hiit rounds=10`
/// knows to parse its args as a timer. Use one per reply. `known` is the ids
/// that last from earlier replies (spec section 5, Ids that last), id -> preset;
/// this reply's own ids shadow them.
public struct YLParser: Sendable {
    public private(set) var screen = "1"
    private var ids: [String: String]
    private var auto = 0
    /// Open groups, innermost last.
    private var open: [(id: String, preset: String, screen: String)] = []

    public init(known: [String: String] = [:]) { ids = known }

    /// Parses one line (no `\n`). Returns nil for blank and comment lines.
    public mutating func line(_ src: String) -> YLNode? { group(parseLine(src)) }

    /// Group bookkeeping for one parsed node. Errors (and nil) leave groups open.
    private mutating func group(_ node: YLNode?) -> YLNode? {
        // A theme line restyles the app and a menu line fills the drawer, not the
        // screen: they leave groups alone.
        guard var node, node.op != .error, node.op != .theme, node.op != .menu else { return node }
        // Closing the stage ends whatever group was open on it, like `>2` would.
        if node.op == .close { open = []; return node }
        if node.op == .end {
            guard let g = open.popLast() else {
                return YLNode(op: .error, screen: node.screen, message: "end: no open deck, plan, narrate, timeline or sketch", line: node.line)
            }
            node.target = g.id
            return node
        }
        func joins(_ g: (id: String, preset: String, screen: String)) -> Bool {
            node.op == .add && node.screen == g.screen && groups[g.preset]!.contains(node.preset ?? "")
        }
        while let g = open.last, !joins(g) { open.removeLast() }
        if let g = open.last { node.inGroup = g.id }
        if node.op == .add, let p = node.preset, groups[p] != nil, let id = node.id {
            open.append((id, p, node.screen))
        }
        return node
    }

    private mutating func parseLine(_ src: String) -> YLNode? {
        let line = src.hasSuffix("\r") ? String(src.unicodeScalars.dropLast()) : src
        var body = trimJS(Scalars(line.unicodeScalars))
        if body.isEmpty || isComment(body) { return nil }

        var screen = self.screen
        if body.first == ">" {
            var j = 1
            while j < body.count, isWordish(body[j]) { j += 1 }
            if j > 1, j == body.count || isSpace(body[j]) {
                // `chat` is screen 1 (spec section 1); a bare `>chat` closes the stage.
                let name = String(body[1..<j])
                screen = name == "chat" ? "1" : name
                while j < body.count, isSpace(body[j]) { j += 1 }
                body = Array(body[j...])
                if body.isEmpty || isComment(body) {
                    self.screen = screen
                    return name == "chat" ? YLNode(op: .close, screen: "full", line: line)
                        : YLNode(op: .focus, screen: screen, line: line)
                }
            }
        }

        // custom {json}: the rest of the line is JSON, not YL tokens.
        if let (id, json) = customLine(body) {
            do {
                let spec = try YLValue.parseJSON(json)
                let id = id ?? { auto += 1; return "c\(auto)" }()
                ids[id] = "custom"
                return YLNode(op: .add, screen: screen, preset: "custom", id: id, props: ["spec": spec], line: line)
            } catch {
                return YLNode(op: .error, screen: screen, message: "custom: bad JSON (\(error))", line: line)
            }
        }

        var tokens = tokenize(body)
        if tokens.isEmpty { return nil }
        let head = tokens.removeFirst().raw

        if head.hasPrefix("~") {
            var target = String(head.dropFirst())
            // ~preset@id (spec section 5): the id when this reply made it or it lasts, else the preset name.
            if let at = target.firstIndex(of: "@") {
                let name = String(target[..<at]), id = String(target[target.index(after: at)...])
                if name.range(of: "^[a-z]+$", options: .regularExpression) != nil,
                   id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                    guard presets.contains(name) || name == "say" || name == "custom" else {
                        return YLNode(op: .error, screen: screen, message: "patch: unknown preset \"\(name)\"", line: line)
                    }
                    if let known = ids[id], known != name {
                        return YLNode(op: .error, screen: screen, message: "patch: \"\(id)\" is a \(known), not a \(name)", line: line)
                    }
                    target = ids[id] != nil ? id : name
                }
            }
            guard let preset = presets.contains(target) || target == "say" ? target : ids[target] else {
                return YLNode(op: .error, screen: screen, message: "patch: nothing called \"\(target)\"", line: line)
            }
            if preset == "custom" {
                return YLNode(op: .error, screen: screen, message: "patch: custom blocks are replaced, not patched", line: line)
            }
            let props = rawPresets.contains(preset) ? rawArgs(preset, rest(body, head)) : parseArgs(preset, tokens)
            return YLNode(op: .patch, screen: screen, target: target, props: props, line: line)
        }

        if head == "save" || head == "show" || head == "forget" {
            // The name is the rest of the line: `save leg day` is "leg day".
            let name = tokens.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else {
                return YLNode(op: .error, screen: screen, message: "\(head): needs a name", line: line)
            }
            return YLNode(op: head == "save" ? .save : head == "show" ? .show : .forget, screen: screen, name: name, line: line)
        }
        if head == "menu" { return YuiLines.menuLine(screen: screen, tokens: tokens, line: line) }
        if head == "clear" { return YLNode(op: .clear, screen: screen, line: line) }
        if head == "end" { return YLNode(op: .end, screen: screen, line: line) }
        if head == "close" {
            guard tokens.isEmpty else {
                return YLNode(op: .error, screen: screen, message: "close: takes nothing else", line: line)
            }
            self.screen = "1"
            return YLNode(op: .close, screen: "full", line: line)
        }
        if head == "theme" {
            if let t0 = tokens.first, t0.key == nil, !t0.quoted, t0.parts == nil, t0.text == "app" {
                return YuiLines.appTheme(screen: screen, tokens: tokens.dropFirst(), line: line)
            }
            return YLNode(op: .theme, screen: screen, props: parseArgs("theme", tokens), line: line)
        }
        if head == "talk" {
            // `talk` or `talk on` turns the composer on for this page, `talk off` takes it away.
            let word = tokens.isEmpty ? "on" : tokens.count == 1 ? tokens[0].text : nil
            guard word == "on" || word == "off" else {
                return YLNode(op: .error, screen: screen, message: "talk: takes nothing, on or off", line: line)
            }
            return YLNode(op: .talk, screen: screen, props: ["on": .bool(word == "on")], line: line)
        }

        // ^([a-z]+)(?:@([\w-]+))?$
        let h = Scalars(head.unicodeScalars)
        var j = 0
        while j < h.count, ("a"..."z").contains(h[j]) { j += 1 }
        let preset = String(h[0..<j])
        var explicit: String?
        if j < h.count, h[j] == "@", j + 1 < h.count, h[(j + 1)...].allSatisfy(isWordish) {
            explicit = String(h[(j + 1)...])
            j = h.count
        }
        guard j > 0, j == h.count, presets.contains(preset) || preset == "say" else {
            return YLNode(op: .error, screen: screen, message: "unknown preset \"\(head)\"", line: line)
        }
        let id = explicit ?? { auto += 1; return "n\(auto)" }()
        ids[id] = preset
        let props = rawPresets.contains(preset) ? rawArgs(preset, rest(body, head)) : parseArgs(preset, tokens)
        return YLNode(op: .add, screen: screen, preset: preset, id: id, props: props, line: line)
    }

    /// The body after its head token, untokenized (raw TeX presets).
    private func rest(_ body: Scalars, _ head: String) -> String {
        String(body.dropFirst(head.unicodeScalars.count))
    }

    /// `^#(\s|$)`
    private func isComment(_ s: Scalars) -> Bool {
        s.first == "#" && (s.count == 1 || isSpace(s[1]))
    }

    /// `^custom(?:@([\w-]+))?\s+(.*)$` → (id, json text)
    private func customLine(_ s: Scalars) -> (String?, String)? {
        let head = Scalars("custom".unicodeScalars)
        guard s.count > head.count, Array(s[0..<head.count]) == head else { return nil }
        var j = head.count
        var id: String?
        if s[j] == "@" {
            let k = j + 1
            j = k
            while j < s.count, isWordish(s[j]) { j += 1 }
            if j == k { return nil }
            id = String(s[k..<j])
        }
        let k = j
        while j < s.count, isSpace(s[j]) { j += 1 }
        if j == k { return nil }
        let rest = s[j...]
        // JS "." does not match line terminators.
        if rest.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
        return (id, String(rest))
    }
}

/// Streaming parser: feed chunks as they arrive, get a node for every line
/// whose newline has landed. `flush()` parses a final line with no newline.
/// Buffers bytes, so a chunk may split a line (or a CRLF) anywhere.
public struct YLStreamParser: Sendable {
    private var buf: [UInt8] = []
    private var parser: YLParser

    public init(known: [String: String] = [:]) { parser = YLParser(known: known) }

    public mutating func push(_ chunk: String) -> [YLNode] { push(bytes: chunk.utf8) }

    /// Raw UTF-8 bytes; a chunk may end mid-character.
    public mutating func push(bytes: some Sequence<UInt8>) -> [YLNode] {
        buf.append(contentsOf: bytes)
        var out: [YLNode] = []
        var start = 0
        while let nl = buf[start...].firstIndex(of: 10) {
            if let node = parser.line(String(decoding: buf[start..<nl], as: UTF8.self)) { out.append(node) }
            start = nl + 1
        }
        buf.removeFirst(start)
        return out
    }

    public mutating func flush() -> [YLNode] {
        let rest = String(decoding: buf, as: UTF8.self)
        buf = []
        guard !trimJS(Scalars(rest.unicodeScalars)).isEmpty, let node = parser.line(rest) else { return [] }
        return [node]
    }
}
