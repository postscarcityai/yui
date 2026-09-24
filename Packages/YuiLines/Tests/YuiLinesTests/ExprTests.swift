import Foundation
import Testing
@testable import YuiLines

// calc's expression engine against the JS reference (site/lib/yl/expr.mjs):
// each row is (formula, variables, value, TeX, names) as expr.mjs returns them.
let exprCases: [(String, [String: Double], Double, String, [String])] = [
    ("v^2*sin(2*a)/g", ["v": 20, "a": 0.7, "g": 9.81], 40.18143649290357, "\\frac{v^{2}\\,\\sin\\left(2a\\right)}{g}", ["a", "g", "v"]),
    ("2*pi*sqrt(L/g)", ["L": 1, "g": 9.81], 2.0060666807106475, "2\\pi\\,\\sqrt{\\frac{L}{g}}", ["L", "g", "pi"]),
    ("N0*exp(-ln(2)*t/h)", ["N0": 100, "t": 5730, "h": 5730], 50, "N_{0}\\,\\exp\\left(\\frac{-\\ln\\left(2\\right)\\,t}{h}\\right)", ["N0", "h", "t"]),
    ("-x^2", ["x": 3], -9, "-x^{2}", ["x"]),
    ("2^3^2", [:], 512, "2^{3^{2}}", []),
    ("2**3", [:], 8, "2^{3}", []),
    (".5e1+3.", [:], 8, "5 + 3", []),
    ("min(1,2,3)+max(4,5)", [:], 6, "\\min\\left(1, 2, 3\\right) + \\max\\left(4, 5\\right)", []),
    ("round(2.5)+round(-2.5)", [:], 1, "\\operatorname{round}\\left(2.5\\right) + \\operatorname{round}\\left(-2.5\\right)", []),
    ("log(1000)+abs(-2)", [:], 5, "\\log\\left(1000\\right) + \\left|-2\\right|", []),
    ("e", [:], 2.718281828459045, "e", ["e"]),
    ("e", ["e": 2], 2, "e", ["e"]),
    ("(a+b)*(a-b)", ["a": 5, "b": 2], 21, "\\left(a + b\\right)\\,\\left(a - b\\right)", ["a", "b"]),
    ("1/(1+exp(-x))", ["x": 1], 0.7310585786300049, "\\frac{1}{1 + e^{-x}}", ["x"]),
    ("x_max*v0", ["x_max": 2, "v0": 3], 6, "x_{max}\\,v_{0}", ["v0", "x_max"]),
]

@Test func exprMatchesReference() throws {
    for (f, vars, value, tex, names) in exprCases {
        let ast = try YLExpr.parse(f)
        #expect(abs(try ast.eval(vars) - value) < 1e-9, "\(f)")
        #expect(ast.tex == tex, "\(f): \(ast.tex)")
        #expect(ast.names.sorted() == names, "\(f)")
    }
}

@Test func exprRejectsWhatReferenceRejects() {
    for bad in ["2*", "foo(1)", "(1", "1 2", "$"] {
        #expect(throws: YLExprError.self, "\(bad)") { try YLExpr.parse(bad) }
    }
    #expect(throws: YLExprError.self) { try YLExpr.parse("x + 1").eval([:]) }
}

@Test func formulaSplitsOnFirstEquals() {
    #expect(YLExpr.splitFormula("R = v^2") == ("R", " v^2"))
    #expect(YLExpr.splitFormula("v^2") == ("", "v^2"))
    #expect(YLExpr.splitFormula(" T=2*pi") == ("T", "2*pi"))
}
