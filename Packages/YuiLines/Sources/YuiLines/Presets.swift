import Foundation

// Positional rules per preset (spec section 4). Each returns only the props
// the line said; key/values and flags are merged on top in `parseArgs`.

typealias Props = [String: YLValue]

let presets: Set<String> = [
    "timer", "ask", "choose", "pick", "slide", "form",
    "list", "table", "card", "image", "camera", "mic",
    "gallery", "video", "compare", "storyboard",
    "chart", "stat", "math", "step", "calc",
    "deck", "page", "plan", "project", "narrate",
]

/// Groups (spec section 6): a head collects the member lines that follow it on
/// the same screen. Only a narrate can hold another group (a deck).
let groups: [String: Set<String>] = [
    "deck": ["page", "ask", "choose", "pick"],
    "plan": ["page", "ask", "choose", "pick", "slide", "form", "mic", "camera"],
    "narrate": ["page", "compare", "image", "video", "card", "stat", "chart", "math", "storyboard", "gallery", "deck"],
]

let chartTypes: Set<String> = ["line", "bar", "area", "scatter", "pie", "donut"]

/// Keys whose values are never typed: a quiz answer is compared with option
/// text, so answer=4 and answer=on stay "4" and "on".
private let textKeys: Set<String> = ["answer"]

private func joinText(_ toks: [Token]) -> String { toks.map(\.text).joined(separator: " ") }
private func strings(_ a: [String]) -> YLValue { .array(a.map(YLValue.string)) }

/// Media: a URL is a token starting http://, https://, / or data:.
private func isURL(_ s: String) -> Bool {
    ["http://", "https://", "/", "data:"].contains { s.hasPrefix($0) }
}

func parseArgs(_ preset: String, _ tokens: [Token]) -> Props {
    var kv: Props = [:]
    var flags: Props = [:]
    var pos: [Token] = []
    for t in tokens {
        if let key = t.key {
            let vals = textKeys.contains(key) ? t.value.map(YLValue.string)
                : zip(t.value, t.valueQuoted).map { $1 ? YLValue.string($0) : coerce($0) }
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
    normalize(preset, &o)
    return o.filter { if case .array(let a) = $0.value { !a.isEmpty } else { true } }
}

// MARK: - Normalizing

/// Props that are always lists. A plain value, quoted or not, is split on "|",
/// so notes="Hook|Problem|CTA" and notes=Hook|Problem|CTA are the same.
private let listProps: [String: [String]] = [
    "gallery": ["items", "caps"],
    "storyboard": ["frames", "notes"],
    "compare": ["notes", "labels"],
    "chart": ["names", "color"],
    "table": ["units"],
    "page": ["points"],
    "project": ["facts", "next"],
    "pick": ["answer"],
]

private func asList(_ v: YLValue) -> YLValue {
    if case .array(let a) = v { return .array(a.map { .string(jsString($0)) }) }
    return strings(jsString(v).split(separator: "|", omittingEmptySubsequences: false).map(String.init))
}

private let calcProps: Set<String> = ["title", "f", "plot", "unit", "digits"]

private func normalize(_ preset: String, _ o: inout Props) {
    for k in listProps[preset] ?? [] {
        if let v = o[k], v != .bool(true) { o[k] = asList(v) }
    }
    switch preset {
    case "compare": if let v = o["hl"] { o["hl"] = boxes(v) }
    case "chart": chartSeries(&o)
    case "stat": if let v = o["spark"], v.array == nil { o["spark"] = .array([v]) }
    case "step": if let v = o["time"], let s = seconds(jsString(v)) { o["time"] = .number(s) }
    case "calc":
        for (k, v) in o where !calcProps.contains(k) {
            if let c = calcVar(v) { o[k] = c }
        }
    default: break
    }
}

/// `seconds()` in the reference: `\d+(:\d{1,2})?(\.\d+)?[smh]?`, whole string.
private func seconds(_ s: String) -> Double? {
    let u = Scalars(s.unicodeScalars)
    guard let (v, j) = readDuration(u, 0), j == u.count else { return nil }
    return v
}

/// Highlight boxes: hl=x,y,w,h|x,y,w,h in percent of the image. A box that is
/// not four numbers is dropped.
private func boxes(_ v: YLValue) -> YLValue {
    let list = v.array ?? jsString(v).split(separator: "|", omittingEmptySubsequences: false).map { .string(String($0)) }
    return .array(list.compactMap { b in
        let n = jsString(b).split(separator: ",", omittingEmptySubsequences: false)
            .map { String(trimJS(Scalars($0.unicodeScalars))) }
        guard n.count == 4, n.allSatisfy(isNumber) else { return nil }
        return .array(n.map { .number(Double($0)!) })
    })
}

/// A y value with an error: 12.5±0.4 or 12.5+-0.4.
private let pmRE = JSRegex(#"^(-?[0-9]+(?:\.[0-9]+)?)(?:±|\+-)([0-9]+(?:\.[0-9]+)?)\z"#)
private let seriesKeyRE = JSRegex(#"^(y|err)([0-9]*)\z"#)

/// Chart series: x is a list of labels or numbers. y, y2, y3 ... are lists;
/// a part written 12.5±0.4 becomes 12.5 with an error of 0.4, collected into
/// err, err2, ... unless the line set that err list itself.
private func chartSeries(_ o: inout Props) {
    // Values were already typed by the tokenizer, so a lone value is only wrapped.
    if let x = o["x"], x.array == nil { o["x"] = .array([x]) }
    for k in o.keys {
        guard let m = seriesKeyRE.match(k) else { continue }
        let list = o[k]!.array ?? [o[k]!]
        if m[1] == "err" { o[k] = .array(list); continue }
        var errs: [Double] = []
        o[k] = .array(list.map { v in
            guard let s = v.string, let pm = pmRE.match(s) else { errs.append(0); return v }
            errs.append(Double(pm[2]!)!)
            return .number(Double(pm[1]!)!)
        })
        let ek = "err" + (m[2] ?? "")
        if errs.contains(where: { $0 != 0 }), o[ek] == nil { o[ek] = .array(errs.map(YLValue.number)) }
    }
}

/// Quantity: a number with an optional unit stuck to it. 72.5kg, 9.81m/s^2,
/// 12%, 3e8m/s, $40. A unit starts with a non-digit. The currency signs
/// $ € £ ¥ may lead instead. Returns (value, unit) or nil.
private let qtyRE = JSRegex(#"^([$€£¥])?(-?[0-9]+(?:\.[0-9]+)?(?:[eE]-?[0-9]+)?)["# + JSWS + #"]*([^0-9"# + JSWS + #".,+\-|=][^"# + JSWS + #"]*)?\z"#)

func quantity(_ s: String) -> (value: Double, unit: String?)? {
    guard let m = qtyRE.match(s), !(m[1] != nil && m[3] != nil) else { return nil }
    return (Double(m[2]!)!, m[1] ?? m[3])
}

/// calc variable: min-max[@value][unit] is a slider, a quantity is a constant.
private let varRangeRE = JSRegex(#"^(-?[0-9]+(?:\.[0-9]+)?)-(-?[0-9]+(?:\.[0-9]+)?)(?:@(-?[0-9]+(?:\.[0-9]+)?))?["# + JSWS + #"]*([^0-9"# + JSWS + #"][^"# + JSWS + #"]*)?\z"#)

private func calcVar(_ v: YLValue) -> YLValue? {
    if let n = v.number { return .object(["value": .number(n)]) }
    guard let raw = v.string else { return nil }
    let s = String(trimJS(Scalars(raw.unicodeScalars)))
    if let r = varRangeRE.match(s) {
        let lo = Double(r[1]!)!, hi = Double(r[2]!)!
        var o: [String: YLValue] = ["min": .number(lo), "max": .number(hi),
                                    "value": .number(r[3].map { Double($0)! } ?? (lo + hi) / 2)]
        if let u = r[4] { o["unit"] = .string(u) }
        return .object(o)
    }
    guard let q = quantity(s) else { return nil }
    var o: [String: YLValue] = ["value": .number(q.value)]
    if let u = q.unit { o["unit"] = .string(u) }
    return .object(o)
}

// MARK: - Raw TeX lines

/// math: the rest of the line is TeX, verbatim, after any leading caption= /
/// size= props; one wrapping pair of quotes is dropped. step: a lone "$" token
/// starts the TeX part, which runs to the end of the line. Backslashes, quotes
/// and "#" in TeX are never escapes or comments.
let rawPresets: Set<String> = ["math", "step"]

private let mathPropRE = JSRegex(#"^(caption|size)=("(?:[^"\\]|\\.)*"|[^"# + JSWS + #"]*)(?:["# + JSWS + #"]+|\z)"#)
private let wrappedRE = JSRegex(#"^"[^"]*"\z"#)
private let unescapeRE = try! NSRegularExpression(pattern: #"\\(.)"#)
private let dollarRE = JSRegex(#"(^|["# + JSWS + #"])\$(["# + JSWS + #"]|\z)"#)

private func trimmed(_ s: String) -> String { String(trimJS(Scalars(s.unicodeScalars))) }

func rawArgs(_ preset: String, _ rest: String) -> Props {
    var o: Props = [:]
    if preset == "math" {
        var r = trimmed(rest)
        while let m = mathPropRE.match(r) {
            let v = m[2]!
            if v.hasPrefix("\"") {
                let inner = String(v.dropFirst().dropLast())
                o[m[1]!] = .string(unescapeRE.stringByReplacingMatches(
                    in: inner, range: NSRange(location: 0, length: (inner as NSString).length), withTemplate: "$1"))
            } else {
                o[m[1]!] = .string(v)
            }
            r = (r as NSString).substring(from: (m[0]! as NSString).length)
        }
        r = trimmed(r)
        if wrappedRE.match(r) != nil { r = String(r.dropFirst().dropLast()) }
        if !r.isEmpty { o["tex"] = .string(r) }
        return o
    }
    let ns = rest as NSString
    let m = dollarRE.range(in: rest)
    let head = m.map { ns.substring(to: $0.location) } ?? rest
    o = parseArgs("step", tokenize(Scalars(head.unicodeScalars)))
    if let m {
        let tex = trimmed(ns.substring(from: m.location + m.length))
        if !tex.isEmpty { o["tex"] = .string(tex) }
    }
    return o
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
        // Loose options (spec section 4, ask): with no options token, two or more
        // quoted tokens at the end, after at least one question token, are the options.
        if o["options"] == nil {
            var k = q.count
            while k > 1, q[k - 1].quoted { k -= 1 }
            if q.count - k >= 2 {
                o["options"] = strings(q[k...].map(\.text))
                q.removeSubrange(k...)
            }
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

    case "image", "video":
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

    case "theme":
        // theme [named set] key=value...: the positional text is the set's name.
        if !pos.isEmpty { o["name"] = .string(joinText(pos)) }

    case "gallery": o = mediaSet(pos, "items", "caps")
    case "storyboard": o = mediaSet(pos, "frames", "notes")

    case "compare":
        var title: [Token] = []
        for t in pos {
            if o["after"] == nil, t.parts == nil, isURL(t.text) { o[o["before"] == nil ? "before" : "after"] = .string(t.text) }
            else { title.append(t) }
        }
        if !title.isEmpty { o["title"] = .string(joinText(title)) }

    case "chart":
        // chart [type] [title...]: the first bare chart type is the type.
        var title: [Token] = []
        for t in pos {
            if o["type"] == nil, !t.quoted, t.parts == nil, chartTypes.contains(t.text) { o["type"] = .string(t.text) }
            else { title.append(t) }
        }
        if !title.isEmpty { o["title"] = .string(joinText(title)) }

    case "stat":
        // stat VALUE [label...]: the first quantity is the value and its unit;
        // with no quantity the first token is the value as text.
        var label: [Token] = []
        for t in pos {
            if o["value"] == nil, !t.quoted, t.parts == nil, let q = quantity(t.text) {
                o["value"] = .number(q.value)
                if let u = q.unit { o["unit"] = .string(u) }
            } else { label.append(t) }
        }
        if o["value"] == nil, !label.isEmpty { o["value"] = .string(label.removeFirst().text) }
        if !label.isEmpty { o["label"] = .string(joinText(label)) }

    case "step", "page":
        // step text... / page title [body...]: the first URL is img.
        var text: [Token] = []
        for t in pos {
            if o["img"] == nil, t.parts == nil, isURL(t.text) { o["img"] = .string(t.text) } else { text.append(t) }
        }
        if preset == "step" {
            if !text.isEmpty { o["text"] = .string(joinText(text)) }
        } else {
            if let first = text.first { o["title"] = .string(first.text) }
            if text.count > 1 { o["body"] = .string(joinText(Array(text.dropFirst()))) }
        }

    case "calc", "deck", "plan", "narrate":
        if !pos.isEmpty { o["title"] = .string(joinText(pos)) }

    case "project":
        if let first = pos.first { o["title"] = .string(first.text) }
        if pos.count > 1 { o["body"] = .string(joinText(Array(pos.dropFirst()))) }

    default:
        break
    }
    return o
}

/// A media token is a URL with an optional caption after the first "|":
/// /a.jpg, /a.jpg|Caption, "/a.jpg|Two words" or /a.jpg|"Two words".
private func mediaToken(_ t: Token) -> (src: String, caption: String)? {
    let segs = t.parts ?? [t.text]
    guard isURL(segs[0]) else { return nil }
    if let bar = segs[0].firstIndex(of: "|"), bar != segs[0].startIndex {
        return (String(segs[0][..<bar]), String(segs[0][segs[0].index(after: bar)...]))
    }
    return (segs[0], segs.dropFirst().joined(separator: "|"))
}

/// Positionals of a media set: URLs become items, any other text is the title.
private func mediaSet(_ pos: [Token], _ itemsKey: String, _ capsKey: String) -> Props {
    var o: Props = [:]
    var items: [String] = []
    var caps: [String] = []
    var title: [Token] = []
    for t in pos {
        if let m = mediaToken(t) { items.append(m.src); caps.append(m.caption) } else { title.append(t) }
    }
    if !title.isEmpty { o["title"] = .string(joinText(title)) }
    if !items.isEmpty { o[itemsKey] = strings(items) }
    if caps.contains(where: { !$0.isEmpty }) { o[capsKey] = strings(caps) }
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
