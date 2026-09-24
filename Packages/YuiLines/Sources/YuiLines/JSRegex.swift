import Foundation

// The reference parser's newer rules (quantities, series, calc variables, raw
// TeX) are regexes. They run here through NSRegularExpression, which indexes
// UTF-16 like JavaScript. Classes are spelled in ASCII (`[0-9]`, `JSWS`) since
// ICU's \d and \s are Unicode, and `\z` stands in for JS `$`.

/// JavaScript's `\s` set, for use inside a character class.
let JSWS = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

struct JSRegex: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String) { re = try! NSRegularExpression(pattern: pattern) }

    /// Capture groups of the first match (index 0 is the whole match); nil groups did not take part.
    func match(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// UTF-16 range of the first match.
    func range(in s: String) -> NSRange? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
    }
}

/// `String(n)` in JavaScript, for the values a list prop re-reads as text.
func jsString(_ v: YLValue) -> String {
    switch v {
    case .string(let s): return s
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    case .null: return "null"
    case .array(let a): return a.map(jsString).joined(separator: ",")
    case .object: return "[object Object]"
    }
}
