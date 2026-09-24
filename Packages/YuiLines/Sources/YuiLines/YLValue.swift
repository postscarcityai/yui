import Foundation

/// A JSON-shaped value: prop values, form fields, `custom` specs.
public enum YLValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([YLValue])
    case object([String: YLValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [YLValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: YLValue]? { if case .object(let o) = self { o } else { nil } }

    public subscript(key: String) -> YLValue? { object?[key] }
}

extension YLValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([YLValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: YLValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Strict JSON

public struct YLJSONError: Error, CustomStringConvertible, Sendable {
    public let offset: Int
    public let reason: String
    public var description: String { "\(reason) at \(offset)" }
}

extension YLValue {
    /// Parses one JSON value with the same rules as JavaScript's `JSON.parse`:
    /// any top-level value, no comments, no trailing commas, no trailing text.
    public static func parseJSON(_ text: String) throws -> YLValue {
        var p = JSONReader(Array(text.unicodeScalars))
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        guard p.i == p.s.count else { throw p.fail("unexpected text after JSON") }
        return v
    }
}

private struct JSONReader {
    let s: [Unicode.Scalar]
    var i = 0
    init(_ s: [Unicode.Scalar]) { self.s = s }

    func fail(_ reason: String) -> YLJSONError { YLJSONError(offset: i, reason: reason) }
    var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

    mutating func skipSpace() {
        while let c = peek, c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
    }

    mutating func expect(_ word: String) throws {
        for c in word.unicodeScalars {
            guard peek == c else { throw fail("bad literal") }
            i += 1
        }
    }

    mutating func value() throws -> YLValue {
        guard let c = peek else { throw fail("unexpected end of JSON") }
        switch c {
        case "{": return try object()
        case "[": return try array()
        case "\"": return .string(try string())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return try number()
        }
    }

    mutating func object() throws -> YLValue {
        i += 1
        var o: [String: YLValue] = [:]
        skipSpace()
        if peek == "}" { i += 1; return .object(o) }
        while true {
            skipSpace()
            guard peek == "\"" else { throw fail("expected a key") }
            let k = try string()
            skipSpace()
            guard peek == ":" else { throw fail("expected ':'") }
            i += 1
            skipSpace()
            o[k] = try value()
            skipSpace()
            if peek == "," { i += 1; continue }
            if peek == "}" { i += 1; return .object(o) }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func array() throws -> YLValue {
        i += 1
        var a: [YLValue] = []
        skipSpace()
        if peek == "]" { i += 1; return .array(a) }
        while true {
            skipSpace()
            a.append(try value())
            skipSpace()
            if peek == "," { i += 1; continue }
            if peek == "]" { i += 1; return .array(a) }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count, let v = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else {
            throw fail("bad \\u escape")
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek else { throw fail("unterminated string") }
            i += 1
            if c == "\"" { return String(out) }
            if c.value < 0x20 { throw fail("control character in string") }
            guard c == "\\" else { out.append(c); continue }
            guard let e = peek else { throw fail("unterminated string") }
            i += 1
            switch e {
            case "\"", "\\", "/": out.append(e)
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                var v = try hex4()
                if (0xD800...0xDBFF).contains(v), peek == "\\", i + 1 < s.count, s[i + 1] == "u" {
                    let save = i
                    i += 2
                    let lo = try hex4()
                    if (0xDC00...0xDFFF).contains(lo) { v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                }
                out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            default: throw fail("bad escape")
            }
        }
    }

    mutating func number() throws -> YLValue {
        let start = i
        func digits(_ r: inout JSONReader) -> Int {
            var n = 0
            while let c = r.peek, ("0"..."9").contains(c) { r.i += 1; n += 1 }
            return n
        }
        if peek == "-" { i += 1 }
        if peek == "0" { i += 1 } else if digits(&self) == 0 { throw fail("unexpected character") }
        if peek == "." {
            i += 1
            guard digits(&self) > 0 else { throw fail("bad number") }
        }
        if peek == "e" || peek == "E" {
            i += 1
            if peek == "+" || peek == "-" { i += 1 }
            guard digits(&self) > 0 else { throw fail("bad number") }
        }
        guard let d = Double(String(String.UnicodeScalarView(s[start..<i]))) else { throw fail("bad number") }
        return .number(d)
    }
}
