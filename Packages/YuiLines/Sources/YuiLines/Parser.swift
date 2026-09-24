/// Yui Lines v0. Spec: `yuigui/spec/YL.md`. Conformance: `yuigui/spec/conformance`.
public enum YuiLines {
    /// Parses a whole reply. Blank and comment lines produce nothing.
    public static func parse(_ text: String) -> [YLNode] {
        var p = YLParser()
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

/// Line-at-a-time parser. Stateful: it remembers the focused screen, the
/// auto-id counter and which preset each id belongs to, so `~hiit rounds=10`
/// knows to parse its args as a timer. Use one per reply.
public struct YLParser: Sendable {
    public private(set) var screen = "1"
    private var ids: [String: String] = [:]
    private var auto = 0

    public init() {}

    /// Parses one line (no `\n`). Returns nil for blank and comment lines.
    public mutating func line(_ src: String) -> YLNode? {
        let line = src.hasSuffix("\r") ? String(src.unicodeScalars.dropLast()) : src
        var body = trimJS(Scalars(line.unicodeScalars))
        if body.isEmpty || isComment(body) { return nil }

        var screen = self.screen
        if body.first == ">" {
            var j = 1
            while j < body.count, isWordish(body[j]) { j += 1 }
            if j > 1, j == body.count || isSpace(body[j]) {
                screen = String(body[1..<j])
                while j < body.count, isSpace(body[j]) { j += 1 }
                body = Array(body[j...])
                if body.isEmpty || isComment(body) {
                    self.screen = screen
                    return YLNode(op: .focus, screen: screen, line: line)
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
            let target = String(head.dropFirst())
            guard let preset = presets.contains(target) || target == "say" ? target : ids[target] else {
                return YLNode(op: .error, screen: screen, message: "patch: nothing called \"\(target)\"", line: line)
            }
            if preset == "custom" {
                return YLNode(op: .error, screen: screen, message: "patch: custom blocks are replaced, not patched", line: line)
            }
            return YLNode(op: .patch, screen: screen, target: target, props: parseArgs(preset, tokens), line: line)
        }

        if head == "save" || head == "show" {
            guard let name = tokens.first?.text, !name.isEmpty else {
                return YLNode(op: .error, screen: screen, message: "\(head): needs a name", line: line)
            }
            return YLNode(op: head == "save" ? .save : .show, screen: screen, name: name, line: line)
        }
        if head == "clear" { return YLNode(op: .clear, screen: screen, line: line) }

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
        return YLNode(op: .add, screen: screen, preset: preset, id: id, props: parseArgs(preset, tokens), line: line)
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
    private var parser = YLParser()

    public init() {}

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
