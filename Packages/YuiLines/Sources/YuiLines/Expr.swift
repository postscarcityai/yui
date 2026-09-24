import Foundation

// Tiny, safe math expression engine for the `calc` preset (spec YL.md, calc).
// Mirrors `yuigui/site/lib/yl/expr.mjs`. No eval. Grammar:
//   expr   := term (("+" | "-") term)*
//   term   := unary (("*" | "/") unary)*
//   unary  := "-" unary | "+" unary | power
//   power  := atom ("^" unary)?          right associative: 2^3^2 = 2^9
//   atom   := number | name | name "(" expr ("," expr)* ")" | "(" expr ")"
// Functions: sin cos tan asin acos atan sqrt abs exp ln log (base 10) min max
// floor ceil round. Constants: pi, e (a variable of the same name wins).

public indirect enum YLExpr: Sendable, Equatable {
    case num(Double)
    case name(String)
    case paren(YLExpr)
    case neg(YLExpr)
    case fn(String, [YLExpr])
    case op(Character, YLExpr, YLExpr)
}

public struct YLExprError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ d: String) { description = d }
}

extension YLExpr {
    static let functions: [String: @Sendable ([Double]) -> Double] = [
        "sin": { sin($0[0]) }, "cos": { cos($0[0]) }, "tan": { tan($0[0]) },
        "asin": { asin($0[0]) }, "acos": { acos($0[0]) }, "atan": { atan($0[0]) },
        "sqrt": { sqrt($0[0]) }, "abs": { abs($0[0]) }, "exp": { exp($0[0]) },
        "ln": { log($0[0]) }, "log": { log10($0[0]) },
        "min": { $0.min() ?? .infinity }, "max": { $0.max() ?? -.infinity },
        "floor": { floor($0[0]) }, "ceil": { ceil($0[0]) },
        // Math.round: halves go up.
        "round": { floor($0[0] + 0.5) },
    ]
    static let constants: [String: Double] = ["pi": .pi, "e": M_E]

    private enum Tok: Equatable { case num(Double), name(String), op(String) }

    private static func lex(_ src: String) throws -> [Tok] {
        let u = Array(src.unicodeScalars)
        var out: [Tok] = []
        var i = 0
        func digit(_ j: Int) -> Bool { j < u.count && ("0"..."9").contains(u[j]) }
        while i < u.count {
            if isSpace(u[i]) { i += 1; continue }
            let c = u[i]
            if digit(i) || (c == "." && digit(i + 1)) {
                let start = i
                while digit(i) { i += 1 }
                if i < u.count, u[i] == "." { i += 1; while digit(i) { i += 1 } }
                if i < u.count, u[i] == "e" || u[i] == "E" {
                    var j = i + 1
                    if j < u.count, u[j] == "-" || u[j] == "+" { j += 1 }
                    if digit(j) { i = j; while digit(i) { i += 1 } }
                }
                out.append(.num(Double(String(u[start..<i])) ?? .nan))
            } else if isAlpha(c) || c == "_" {
                let start = i
                while i < u.count, isAlpha(u[i]) || isDigit(u[i]) || u[i] == "_" { i += 1 }
                out.append(.name(String(u[start..<i])))
            } else if c == "*", i + 1 < u.count, u[i + 1] == "*" {
                out.append(.op("^")); i += 2
            } else if "+-*/^(),".unicodeScalars.contains(c) {
                out.append(.op(String(c))); i += 1
            } else {
                throw YLExprError("unexpected \"\(Character(c))\"")
            }
        }
        return out
    }

    /// Parses a formula body (`v^2*sin(2*a)/g`).
    public static func parse(_ src: String) throws -> YLExpr {
        let toks = try lex(src)
        var k = 0
        func eat(_ v: String) -> Bool {
            if k < toks.count, toks[k] == .op(v) { k += 1; return true }
            return false
        }
        func expr() throws -> YLExpr {
            var a = try term()
            while k < toks.count, case .op(let o) = toks[k], o == "+" || o == "-" {
                k += 1
                a = .op(Character(o), a, try term())
            }
            return a
        }
        func term() throws -> YLExpr {
            var a = try unary()
            while k < toks.count, case .op(let o) = toks[k], o == "*" || o == "/" {
                k += 1
                a = .op(Character(o), a, try unary())
            }
            return a
        }
        func unary() throws -> YLExpr {
            if eat("-") { return .neg(try unary()) }
            if eat("+") { return try unary() }
            let a = try atom()
            return eat("^") ? .op("^", a, try unary()) : a
        }
        func atom() throws -> YLExpr {
            guard k < toks.count else { throw YLExprError("unexpected end") }
            let t = toks[k]
            k += 1
            switch t {
            case .num(let n): return .num(n)
            case .name(let n):
                guard eat("(") else { return .name(n) }
                guard functions[n] != nil else { throw YLExprError("unknown function \"\(n)\"") }
                var args = [try expr()]
                while eat(",") { args.append(try expr()) }
                guard eat(")") else { throw YLExprError("expected \")\"") }
                return .fn(n, args)
            case .op("("):
                let e = try expr()
                guard eat(")") else { throw YLExprError("expected \")\"") }
                return .paren(e)
            case .op(let o): throw YLExprError("unexpected \"\(o)\"")
            }
        }
        let ast = try expr()
        if k < toks.count {
            let rest: String = switch toks[k] {
            case .num(let n): String(n)
            case .name(let n), .op(let n): n
            }
            throw YLExprError("unexpected \"\(rest)\"")
        }
        return ast
    }

    public func eval(_ vars: [String: Double]) throws -> Double {
        switch self {
        case .num(let n): return n
        case .name(let n):
            if let v = vars[n] ?? Self.constants[n] { return v }
            throw YLExprError("no value for \"\(n)\"")
        case .paren(let e): return try e.eval(vars)
        case .neg(let e): return -(try e.eval(vars))
        case .fn(let f, let args): return Self.functions[f]!(try args.map { try $0.eval(vars) })
        case .op(let o, let a, let b):
            let x = try a.eval(vars), y = try b.eval(vars)
            switch o {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/": return x / y
            default: return pow(x, y)
            }
        }
    }

    /// Every name the expression reads (variables and constants).
    public var names: Set<String> {
        switch self {
        case .num: return []
        case .name(let n): return [n]
        case .paren(let e), .neg(let e): return e.names
        case .fn(_, let args): return args.reduce(into: Set<String>()) { $0.formUnion($1.names) }
        case .op(_, let a, let b): return a.names.union(b.names)
        }
    }

    /// `R = v^2*sin(2*a)/g` -> ("R", "v^2*sin(2*a)/g"); no `name =` gives ("", f).
    public static func splitFormula(_ f: String) -> (out: String, expr: String) {
        let u = Array(f.unicodeScalars)
        var i = 0
        while i < u.count, isSpace(u[i]) { i += 1 }
        let start = i
        guard i < u.count, isAlpha(u[i]) || u[i] == "_" else { return ("", f) }
        while i < u.count, isAlpha(u[i]) || isDigit(u[i]) || u[i] == "_" { i += 1 }
        let name = String(u[start..<i])
        while i < u.count, isSpace(u[i]) { i += 1 }
        guard i < u.count, u[i] == "=" else { return ("", f) }
        return (name, String(u[(i + 1)...]))
    }

    // MARK: TeX

    private static let greek: Set<String> = ["alpha", "beta", "gamma", "delta", "theta", "lambda", "mu", "sigma",
                                             "omega", "phi", "rho", "tau", "pi"]

    public static func nameTeX(_ s: String) -> String {
        if greek.contains(s) { return "\\" + s }
        // v_0, N0 and x_max all get a subscript.
        let u = Array(s.unicodeScalars)
        var j = 0
        while j < u.count, isAlpha(u[j]) { j += 1 }
        if j > 0, j < u.count {
            let head = String(u[0..<j])
            if u[j] == "_", j + 1 < u.count, u[(j + 1)...].allSatisfy({ isAlpha($0) || isDigit($0) || $0 == "_" }) {
                return "\(nameTeX(head))_{\(String(u[(j + 1)...]))}"
            }
            if u[j...].allSatisfy(isDigit) { return "\(nameTeX(head))_{\(String(u[j...]))}" }
        }
        return u.count > 1 ? "\\mathit{\(s)}" : s
    }

    private static func num(_ n: Double) -> String {
        n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// TeX for display: fractions for "/", superscripts for "^", \sqrt, \sin ...
    public var tex: String { tex(parent: nil) }

    private var bare: YLExpr { if case .paren(let e) = self { e } else { self } }
    private var isAtomic: Bool {
        switch self {
        case .num, .name, .paren: true
        default: false
        }
    }

    private func tex(parent: String?) -> String {
        switch self {
        case .num(let n): return Self.num(n)
        case .name(let n): return Self.nameTeX(n)
        case .paren(let e):
            if case .op("/", _, _) = e { return e.tex(parent: nil) }
            return "\\left(\(e.tex(parent: nil))\\right)"
        case .neg(let e): return "-" + e.tex(parent: "neg")
        case .fn(let f, let args):
            let a = args.map { $0.tex(parent: nil) }
            if f == "sqrt" { return "\\sqrt{\(a[0])}" }
            if f == "abs" { return "\\left|\(a[0])\\right|" }
            if f == "exp", a.count == 1, !a[0].contains("\\frac") { return "e^{\(a[0])}" }
            let known = ["sin", "cos", "tan", "exp", "ln", "log", "min", "max"].contains(f)
            return "\(known ? "\\" + f : "\\operatorname{\(f)}")\\left(\(a.joined(separator: ", "))\\right)"
        case .op(let o, let a, let b):
            if o == "/" { return "\\frac{\(a.bare.tex(parent: nil))}{\(b.bare.tex(parent: nil))}" }
            if o == "^" {
                let base = a.isAtomic ? a.tex(parent: "^") : "\\left(\(a.tex(parent: nil))\\right)"
                return "\(base)^{\(b.bare.tex(parent: nil))}"
            }
            if o == "*" {
                let x = a.tex(parent: "*"), y = b.tex(parent: "*")
                if let f = y.unicodeScalars.first, isDigit(f) || f == "." || f == "-" { return "\(x) \\cdot \(y)" }
                if case .num = a { return x + y }
                return "\(x)\\,\(y)"
            }
            let s = "\(a.tex(parent: nil)) \(o) \(b.tex(parent: nil))"
            return parent == "*" || parent == "^" || parent == "neg" ? "\\left(\(s)\\right)" : s
        }
    }
}
