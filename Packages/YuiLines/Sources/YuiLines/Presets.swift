// Positional rules per preset (spec section 4). Each returns only the props
// the line said; key/values and flags are merged on top in `parseArgs`.

typealias Props = [String: YLValue]

let presets: Set<String> = [
    "timer", "ask", "choose", "pick", "slide", "form",
    "list", "table", "card", "image", "camera", "mic",
]

private func joinText(_ toks: [Token]) -> String { toks.map(\.text).joined(separator: " ") }
private func strings(_ a: [String]) -> YLValue { .array(a.map(YLValue.string)) }

func parseArgs(_ preset: String, _ tokens: [Token]) -> Props {
    var kv: Props = [:]
    var flags: Props = [:]
    var pos: [Token] = []
    for t in tokens {
        if let key = t.key {
            let vals = zip(t.value, t.valueQuoted).map { $1 ? YLValue.string($0) : coerce($0) }
            kv[key] = vals.count > 1 ? .array(vals) : vals[0]
        } else if !t.quoted, t.parts == nil, isFlag(t.raw) {
            flags[String(t.raw.dropFirst())] = .bool(true)
        } else {
            pos.append(t)
        }
    }
    var o = positional(preset, pos)
    o.merge(flags) { $1 }
    o.merge(kv) { $1 }
    return o.filter { if case .array(let a) = $0.value { !a.isEmpty } else { true } }
}

/// `^\+[A-Za-z][\w-]*$`
private func isFlag(_ raw: String) -> Bool {
    let u = Scalars(raw.unicodeScalars)
    return u.count >= 2 && u[0] == "+" && isAlpha(u[1]) && u.dropFirst(2).allSatisfy(isWordish)
}

private func positional(_ preset: String, _ pos: [Token]) -> Props {
    var o: Props = [:]
    switch preset {
    case "timer":
        var rest: [Token] = []
        for t in pos {
            if !t.quoted, o["work"] == nil, let ts = parseTimespec(t.text) {
                o["work"] = .number(ts.work)
                if let r = ts.rest { o["rest"] = .number(r) }
                if let n = ts.rounds { o["rounds"] = .number(n) }
            } else { rest.append(t) }
        }
        if !rest.isEmpty { o["label"] = .string(joinText(rest)) }

    case "ask", "choose", "pick":
        var q: [Token] = []
        for t in pos {
            if let p = t.parts, o["options"] == nil { o["options"] = strings(p) } else { q.append(t) }
        }
        if !q.isEmpty { o["q"] = .string(joinText(q)) }

    case "slide":
        var label: [Token] = []
        for t in pos {
            if !t.quoted, o["min"] == nil, let (lo, hi) = parseRange(t.text) {
                o["min"] = .number(lo)
                o["max"] = .number(hi)
            } else if let p = t.parts, p.count == 2, (o["lo"]?.string ?? "").isEmpty {
                o["lo"] = .string(p[0])
                o["hi"] = .string(p[1])
            } else { label.append(t) }
        }
        if !label.isEmpty { o["label"] = .string(joinText(label)) }

    case "form":
        var fields: [YLValue] = []
        var title: [Token] = []
        for t in pos {
            if let f = field(t) { fields.append(f) } else { title.append(t) }
        }
        o["fields"] = .array(fields)
        if !title.isEmpty { o["title"] = .string(joinText(title)) }

    case "list":
        var items: [String] = []
        for t in pos {
            if o["title"] == nil, items.isEmpty, !t.quoted, t.parts == nil { o["title"] = .string(t.text); continue }
            items += t.parts ?? [t.text]
        }
        o["items"] = strings(items)

    case "table":
        var cols: [String]?
        var rows: [YLValue] = []
        for t in pos {
            if o["name"] == nil, cols == nil, t.parts == nil, !t.quoted { o["name"] = .string(t.text); continue }
            let cells = t.parts ?? t.text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if cols == nil { cols = cells } else { rows.append(.array(cells.map(coerce))) }
        }
        if let cols { o["cols"] = strings(cols) }
        o["rows"] = .array(rows)

    case "card":
        if let first = pos.first { o["title"] = .string(first.text) }
        if pos.count > 1 { o["body"] = .string(joinText(Array(pos.dropFirst()))) }

    case "image":
        var cap: [Token] = []
        for t in pos {
            let isURL = ["http://", "https://", "/", "data:"].contains { t.text.hasPrefix($0) }
            if o["src"] == nil, isURL { o["src"] = .string(t.text) } else { cap.append(t) }
        }
        if !cap.isEmpty { o[o["src"] == nil ? "prompt" : "caption"] = .string(joinText(cap)) }

    case "camera":
        var q: [Token] = []
        for t in pos {
            if !t.quoted, t.text == "front" || t.text == "back" { o["facing"] = .string(t.text) } else { q.append(t) }
        }
        if !q.isEmpty { o["prompt"] = .string(joinText(q)) }

    case "mic":
        if !pos.isEmpty { o["prompt"] = .string(joinText(pos)) }

    case "say":
        o["text"] = .string(joinText(pos))

    default:
        break
    }
    return o
}

// MARK: - Form fields

/// Field token: `key[:type][!]` or `"Label":type[!]`. A bare identifier is a
/// text field. Unknown types are kept as written (they render as text).
private func field(_ t: Token) -> YLValue? {
    if t.quoted { return nil } // a quoted token alone is the form title
    let u = Scalars(t.raw.unicodeScalars)
    var j = 0
    var key: String
    var label: String?
    if u.first == "\"" {
        // "((?:[^"\\]|\\.)*)" with \x unescaped to x
        var l = String.UnicodeScalarView()
        j = 1
        while j < u.count, u[j] != "\"" {
            if u[j] == "\\" {
                guard j + 1 < u.count else { return nil }
                l.append(u[j + 1])
                j += 2
            } else { l.append(u[j]); j += 1 }
        }
        guard j < u.count else { return nil }
        j += 1
        label = String(l)
        key = slug(label!)
    } else {
        guard let f = u.first, isAlpha(f) || f == "_" else { return nil }
        j = 1
        while j < u.count, isWordish(u[j]) { j += 1 }
        key = String(u[0..<j])
    }
    var type: String?
    var required = false
    let rest = u[j...]
    if rest.first == ":" {
        var body = Array(rest.dropFirst())
        if body.isEmpty { return nil }
        if body.count >= 2, body.last == "!" { required = true; body.removeLast() }
        type = String(body)
    } else if rest.count == 1, rest.first == "!" {
        required = true
    } else if !rest.isEmpty {
        return nil
    }
    if type == nil, label != nil { return nil } // "Title" without a type

    var f: [String: YLValue] = ["key": .string(key)]
    if let label, !label.isEmpty { f["label"] = .string(label) }
    if let type {
        if let (lo, hi) = parseRange(type) {
            f["type"] = "range"
            f["min"] = .number(lo)
            f["max"] = .number(hi)
        } else if type.contains("|") {
            f["type"] = "choice"
            f["options"] = .array(type.split(separator: "|", omittingEmptySubsequences: false).map { part in
                var s = Substring(part)
                if s.hasPrefix("\"") { s = s.dropFirst() }
                if s.hasSuffix("\"") { s = s.dropLast() }
                return .string(String(s))
            })
        } else {
            f["type"] = .string(type)
        }
    }
    if required { f["required"] = .bool(true) }
    return .object(f)
}

/// Lowercase, runs of anything but `[a-z0-9]` become `_`, one edge `_` trimmed.
private func slug(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    var inRun = false
    for c in s.lowercased().unicodeScalars {
        if ("a"..."z").contains(c) || isDigit(c) { out.append(c); inRun = false }
        else if !inRun { out.append("_"); inRun = true }
    }
    var r = Substring(String(out))
    if r.hasPrefix("_") { r = r.dropFirst() }
    if r.hasSuffix("_") { r = r.dropLast() }
    return String(r)
}

extension YLValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
