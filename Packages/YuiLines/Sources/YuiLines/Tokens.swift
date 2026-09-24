// Tokenizer and character classes. Every class is spelled out in ASCII so the
// Swift parser matches the JS reference exactly (Swift's \w and \d are Unicode).

typealias Scalars = [Unicode.Scalar]

/// JavaScript's `\s` set, which also drives `String.prototype.trim`.
func isSpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
}

func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
func isAlpha(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
/// `[\w-]`
func isWordish(_ c: Unicode.Scalar) -> Bool { isAlpha(c) || isDigit(c) || c == "_" || c == "-" }

/// `^[A-Za-z_][\w-]*$`
func isIdent<S: Collection<Unicode.Scalar>>(_ s: S) -> Bool {
    guard let f = s.first, isAlpha(f) || f == "_" else { return false }
    return s.dropFirst().allSatisfy(isWordish)
}

func trimJS(_ s: Scalars) -> Scalars {
    var lo = 0, hi = s.count
    while lo < hi, isSpace(s[lo]) { lo += 1 }
    while hi > lo, isSpace(s[hi - 1]) { hi -= 1 }
    return Array(s[lo..<hi])
}

extension String {
    init(_ s: some Sequence<Unicode.Scalar>) {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        self = String(v)
    }
}

struct Token {
    /// Exact source text.
    var raw: String
    /// Text with quotes removed.
    var text: String
    /// The whole token was one quoted string.
    var quoted: Bool
    /// Segments split on `|` outside quotes; nil without a `|`.
    var parts: [String]?
    /// Set for `key=value`.
    var key: String?
    /// Value parts after `=` (one unless it had a `|`).
    var value: [String] = []
    /// Per value part: it held a quoted string, so it stays text.
    var valueQuoted: [Bool] = []
}

func tokenize(_ line: Scalars) -> [Token] {
    var tokens: [Token] = []
    var i = 0
    let n = line.count
    while i < n {
        while i < n, isSpace(line[i]) { i += 1 }
        if i >= n { break }
        // Comment: a "#" that starts a token and is followed by space or EOL.
        if line[i] == "#", i + 1 >= n || isSpace(line[i + 1]) { break }
        let start = i
        var segs: [Scalars] = [[]]
        var segQ = [false]
        var anyQuote = false
        var wholeQuoted = line[i] == "\""
        var eqAt = -1
        while i < n, !isSpace(line[i]) {
            let c = line[i]
            if c == "\"" {
                anyQuote = true
                segQ[segQ.count - 1] = true
                i += 1
                while i < n, line[i] != "\"" {
                    if line[i] == "\\", i + 1 < n { segs[segs.count - 1].append(line[i + 1]); i += 2; continue }
                    segs[segs.count - 1].append(line[i])
                    i += 1
                }
                i += 1 // closing quote, or past the end for an unterminated string
                if i < n, !isSpace(line[i]) { wholeQuoted = false }
                continue
            }
            if c == "|" { segs.append([]); segQ.append(false); wholeQuoted = false; i += 1; continue }
            if c == "=", eqAt < 0, segs.count == 1, !anyQuote, isIdent(segs[0]) { eqAt = segs[0].count }
            segs[segs.count - 1].append(c)
            i += 1
        }
        let strs = segs.map { String($0) }
        var t = Token(
            raw: String(line[start..<min(i, n)]),
            text: strs.joined(separator: "|"),
            quoted: wholeQuoted && segs.count == 1,
            parts: segs.count > 1 ? strs : nil
        )
        if eqAt >= 0 {
            t.key = String(segs[0][..<eqAt])
            t.value = [String(segs[0][(eqAt + 1)...])] + strs.dropFirst()
            t.valueQuoted = segQ
            t.parts = nil
        }
        tokens.append(t)
    }
    return tokens
}

// MARK: - Values

/// `^-?\d+(\.\d+)?$`
func isNumber(_ s: String) -> Bool {
    var u = Scalars(s.unicodeScalars)[...]
    if u.first == "-" { u = u.dropFirst() }
    let int = u.prefix(while: isDigit)
    guard !int.isEmpty else { return false }
    u = u.dropFirst(int.count)
    if u.isEmpty { return true }
    guard u.first == "." else { return false }
    u = u.dropFirst()
    return !u.isEmpty && u.allSatisfy(isDigit)
}

func coerce(_ s: String) -> YLValue {
    if isNumber(s), let d = Double(s) { return .number(d) }
    switch s {
    case "on", "true": return .bool(true)
    case "off", "false": return .bool(false)
    default: return .string(s)
    }
}

/// `^(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)$`
func parseRange(_ s: String) -> (Double, Double)? {
    let u = Scalars(s.unicodeScalars)
    func num(_ from: Int) -> Int? {
        var j = from
        if j < u.count, u[j] == "-" { j += 1 }
        let d0 = j
        while j < u.count, isDigit(u[j]) { j += 1 }
        if j == d0 { return nil }
        if j < u.count, u[j] == ".", j + 1 < u.count, isDigit(u[j + 1]) {
            j += 1
            while j < u.count, isDigit(u[j]) { j += 1 }
        }
        return j
    }
    guard let a = num(0), a < u.count, u[a] == "-", let b = num(a + 1), b == u.count,
          let lo = Double(String(u[0..<a])), let hi = Double(String(u[(a + 1)..<b])) else { return nil }
    return (lo, hi)
}

/// One duration: `\d+(?::\d{1,2})?(?:\.\d+)?[smh]?`, read from `from`.
/// Returns the seconds and the index after it.
func readDuration(_ u: Scalars, _ from: Int) -> (Double, Int)? {
    var j = from
    let i0 = j
    while j < u.count, isDigit(u[j]) { j += 1 }
    if j == i0 { return nil }
    let whole = String(u[i0..<j])
    var mss: String?
    if j < u.count, u[j] == ":", j + 1 < u.count, isDigit(u[j + 1]) {
        let k = j + 1
        j = k + 1
        if j < u.count, isDigit(u[j]) { j += 1 }
        mss = String(u[k..<j])
    }
    var frac = ""
    if j < u.count, u[j] == ".", j + 1 < u.count, isDigit(u[j + 1]) {
        let k = j
        j += 1
        while j < u.count, isDigit(u[j]) { j += 1 }
        frac = String(u[k..<j])
    }
    var unit: Unicode.Scalar?
    if j < u.count, u[j] == "s" || u[j] == "m" || u[j] == "h" { unit = u[j]; j += 1 }
    // m:ss ignores any fraction and unit, as the reference does.
    if let mss { return (Double(whole)! * 60 + Double(mss)!, j) }
    let v = Double(whole + frac)!
    return (unit == "m" ? v * 60 : unit == "h" ? v * 3600 : v, j)
}

/// `work[/rest][xRounds]`
func parseTimespec(_ s: String) -> (work: Double, rest: Double?, rounds: Double?)? {
    let u = Scalars(s.unicodeScalars)
    guard let (work, a) = readDuration(u, 0) else { return nil }
    var j = a
    var rest: Double?
    var rounds: Double?
    if j < u.count, u[j] == "/" {
        guard let (r, b) = readDuration(u, j + 1) else { return nil }
        rest = r
        j = b
    }
    if j < u.count, u[j] == "x" {
        let k = j + 1
        j = k
        while j < u.count, isDigit(u[j]) { j += 1 }
        if j == k { return nil }
        rounds = Double(String(u[k..<j]))
    }
    return j == u.count ? (work, rest, rounds) : nil
}
