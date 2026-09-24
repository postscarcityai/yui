import Charts
import SwiftMath
import SwiftUI
import YuiLines

// Data and science (YUI-19, spec yuigui/spec/YL.md "Data and science"):
// `chart`, `stat`, `math`, `step`, `calc`, plus `table` (units, +sort, the
// data source for `chart data=`) and `card`. Charts are Swift Charts, TeX is
// SwiftMath (native CoreText, no web view).

// MARK: - Colors, numbers, units

/// Chart series colors. Stepped per scheme and checked for color-blind
/// separation and contrast on the surface, the same slots the web uses.
enum ChartPalette {
    static let dark = ["#8b7cff", "#e8663a", "#199e8f", "#c98500", "#d55181", "#3987e5"].map(Color.init(hex:))
    static let light = ["#6a5ae0", "#d9541f", "#0f8a7a", "#b37600", "#d6457c", "#2a78d6"].map(Color.init(hex:))

    static func slots(_ scheme: ColorScheme) -> [Color] { scheme == .dark ? dark : light }
    static func good(_ scheme: ColorScheme) -> Color { Color(hex: scheme == .dark ? "#3fbf8a" : "#13875a") }
    static func bad(_ scheme: ColorScheme) -> Color { Color(hex: scheme == .dark ? "#ff7a6b" : "#c93c2c") }

    /// `color=` per series: accent, accent2, c1..c6, a #hex, else the slot.
    static func color(_ name: String?, slot i: Int, _ s: Swatch, _ scheme: ColorScheme) -> Color {
        let slots = slots(scheme)
        guard let name, !name.isEmpty else { return slots[i % slots.count] }
        if name == "accent" { return s.accent }
        if name == "accent2" { return slots[2] }
        if name.count == 2, name.hasPrefix("c"), let n = Int(name.dropFirst()), (1...6).contains(n) { return slots[n - 1] }
        if name.hasPrefix("#") { return Color(hex: name) }
        return slots[i % slots.count]
    }
}

enum YLNumber {
    private static let sup: [Character: String] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
                                                   "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻"]
    private static let currency: Set<String> = ["$", "€", "£", "¥"]

    private static func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// ASCII units the way a scientist writes them: m/s^2 -> m/s², degC -> °C, ohm -> Ω, * -> ·.
    static func prettyUnit(_ u: String?) -> String {
        guard var s = u, !s.isEmpty else { return "" }
        s = replace(s, #"\^(-?[0-9]+)"#) { m in m[1].map { sup[$0] ?? String($0) }.joined() }
        s = replace(s, #"degC\b"#) { _ in "°C" }
        s = replace(s, #"degF\b"#) { _ in "°F" }
        s = replace(s, #"\bdeg\b"#) { _ in "°" }
        s = replace(s, #"(?i)\bohm\b"#) { _ in "Ω" }
        s = replace(s, #"\bu(m|g|L|s|mol)\b"#) { m in "µ" + m[1] }
        return s.replacingOccurrences(of: "*", with: "·")
    }

    /// `digits` significant digits; huge and tiny numbers as a×10ⁿ.
    static func format(_ v: Double, digits: Int = 4) -> String {
        guard v.isFinite else { return "–" }
        let a = abs(v)
        if a != 0, a >= 1e6 || a < 1e-3 {
            let e = Int(floor(log10(a)))
            var m = v / pow(10, Double(e))
            if abs(m) >= 9.9999999 { m /= 10 }
            let f = NumberFormatter()
            f.maximumFractionDigits = max(0, digits - 1)
            f.minimumFractionDigits = 0
            let exp = String(e).map { sup[$0] ?? String($0) }.joined()
            return "\(f.string(from: m as NSNumber) ?? "\(m)")×10\(exp)"
        }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        if a >= 1000 {
            f.numberStyle = .decimal
            f.maximumFractionDigits = 2
        } else {
            f.usesSignificantDigits = true
            f.maximumSignificantDigits = max(1, digits)
            f.usesGroupingSeparator = false
        }
        return f.string(from: v as NSNumber) ?? YLComponent.format(v)
    }

    static func withUnit(_ v: Double, _ unit: String?, digits: Int = 4) -> String {
        let n = format(v, digits: digits)
        guard let unit, !unit.isEmpty else { return n }
        if currency.contains(unit) { return n.hasPrefix("-") ? "-\(unit)\(n.dropFirst())" : "\(unit)\(n)" }
        let u = prettyUnit(unit)
        return (u.hasPrefix("%") || u.hasPrefix("°")) && u != "°C" && u != "°F" ? n + u : "\(n) \(u)"
    }

    /// Display-only conversions offered by tapping a unit. Events keep the original.
    static let conversions: [String: (String, @Sendable (Double) -> Double)] = [
        "kg": ("lb", { $0 * 2.20462 }), "lb": ("kg", { $0 / 2.20462 }),
        "g": ("oz", { $0 / 28.3495 }), "oz": ("g", { $0 * 28.3495 }),
        "km": ("mi", { $0 / 1.60934 }), "mi": ("km", { $0 * 1.60934 }),
        "m": ("ft", { $0 * 3.28084 }), "ft": ("m", { $0 / 3.28084 }),
        "cm": ("in", { $0 / 2.54 }), "in": ("cm", { $0 * 2.54 }),
        "degC": ("degF", { $0 * 9 / 5 + 32 }), "degF": ("degC", { ($0 - 32) * 5 / 9 }),
        "L": ("gal", { $0 / 3.78541 }), "gal": ("L", { $0 * 3.78541 }),
        "kcal": ("kJ", { $0 * 4.184 }), "kJ": ("kcal", { $0 / 4.184 }),
        "km/h": ("mph", { $0 / 1.60934 }), "mph": ("km/h", { $0 * 1.60934 }),
    ]

    /// A round step that splits `range` into about `count` pieces.
    static func niceStep(_ range: Double, _ count: Double) -> Double {
        guard range > 0 else { return 1 }
        let raw = range / count
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * mag
    }

    /// `-2%` -> (-2, "%"): a delta may carry its own unit.
    static func quantity(_ v: YLValue?) -> (Double, String?)? {
        if let n = v?.number { return (n, nil) }
        guard let s = v?.string, let m = try? NSRegularExpression(pattern: #"^([$€£¥])?(-?[0-9]+(?:\.[0-9]+)?(?:[eE]-?[0-9]+)?)(.*)$"#)
            .firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        let g = { (i: Int) in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        guard let n = Double(g(2)) else { return nil }
        let unit = g(1).isEmpty ? g(3) : g(1)
        return (n, unit.isEmpty ? nil : unit)
    }
}

extension YLComponent {
    /// A list of numbers (`y=1|2|3`, `spark=`), non-numbers dropped to nil.
    func numbers(_ key: String) -> [Double?]? {
        props[key].map { v in (v.array ?? [v]).map { $0.number ?? $0.string.flatMap(Double.init) } }
    }
}

// MARK: - TeX

/// LaTeX, typeset natively. TeX that does not parse shows as its source.
struct TeXView: View {
    let tex: String
    var size: Double = 20
    var display = true
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        // SwiftMath knows \frac but not the sized variants agents often write.
        let tex = tex.replacingOccurrences(of: #"\\[tdc]frac(?![a-zA-Z])"#, with: #"\\frac"#, options: .regularExpression)
        var error: NSError?
        let ok = MTMathListBuilder.build(fromString: tex, error: &error) != nil && error == nil
        if ok {
            ScrollView(.horizontal, showsIndicators: false) {
                MathLabel(tex: tex, size: size, color: UIColor(s.ink), display: display)
                    .fixedSize()
                    .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .accessibilityElement()
            .accessibilityLabel(tex)
        } else {
            Text(tex)
                .font(.system(size: size * 0.8, design: .monospaced))
                .foregroundStyle(s.ink)
                .textSelection(.enabled)
        }
    }
}

private struct MathLabel: UIViewRepresentable {
    let tex: String
    let size: Double
    let color: UIColor
    let display: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        let l = MTMathUILabel()
        l.displayErrorInline = false
        l.backgroundColor = .clear
        return l
    }

    func updateUIView(_ l: MTMathUILabel, context: Context) {
        l.latex = tex
        l.fontSize = size
        l.textColor = color
        l.labelMode = display ? .display : .text
        l.textAlignment = .left
        l.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

// MARK: - math

/// `math [caption=] [size=sm|md|lg] TEX`.
struct MathPreset: View {
    let c: YLComponent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let size: Double = switch c.string("size") {
        case "sm": theme.type.body
        case "lg": theme.type.display
        default: theme.type.title + 2
        }
        PresetCard {
            TeXView(tex: c.string("tex") ?? "", size: size)
                .frame(maxWidth: .infinity, alignment: .center)
            if let cap = c.string("caption") {
                Text(cap).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - card

/// `card title [body] sub= tag= img= cta=`. The button emits `{cta}`.
struct CardPreset: View {
    let c: YLComponent
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            if let img = YLMediaURL.url(c.string("img")) {
                RemoteImage(src: img).frame(height: 170).frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: theme.radius.bubble))
            }
            if let tag = c.string("tag") {
                Text(tag).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.userInk)
                    .padding(.horizontal, theme.spacing.s).padding(.vertical, 3).background(s.butter, in: Capsule())
            }
            if let t = c.string("title") { PresetTitle(text: t) }
            if let sub = c.string("sub") {
                Text(sub).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            }
            if let b = c.string("body") {
                Text(b).font(theme.font(theme.type.body)).foregroundStyle(s.ink).fixedSize(horizontal: false, vertical: true)
            }
            if let cta = c.string("cta") {
                OptionPill(text: cta, fill: s.accent, ink: s.onAccent, grow: true) {
                    emit(c.event(["cta": .string(cta)], echo: cta))
                }
            }
        }
        .disabled(c.locked)
    }
}

// MARK: - table

/// `table [Name] Col|Col "cell|cell" ... units=|kcal +sort`, or `table name`
/// for an agent table (those live on the phone in a later build).
struct TablePreset: View {
    let c: YLComponent
    @State private var sort: (col: Int, asc: Bool)?
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let cols = c.strings("cols") ?? []
        let rows = (c.props["rows"]?.array ?? []).map { $0.array ?? [] }
        let units = c.strings("units") ?? []
        PresetCard {
            if let n = c.string("name") { PresetTitle(text: n) }
            if cols.isEmpty {
                Label("Agent tables arrive in a later build", systemImage: "tablecells")
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
            } else {
                let numeric = cols.indices.map { i in !rows.isEmpty && rows.allSatisfy { i < $0.count && $0[i].number != nil } }
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: theme.spacing.l, verticalSpacing: theme.spacing.s) {
                        GridRow {
                            ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                                header(col, unit: i < units.count ? units[i] : "", i: i, s)
                                    .gridColumnAlignment(numeric[i] ? .trailing : .leading)
                            }
                        }
                        Divider().overlay(s.outline)
                        ForEach(Array(sorted(rows).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(cols.indices, id: \.self) { i in
                                    Text(i < row.count ? cell(row[i]) : "")
                                        .font(theme.font(theme.type.body, .medium).monospacedDigit())
                                        .foregroundStyle(s.ink)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ v: YLValue) -> String {
        if let n = v.number { return YLNumber.format(n, digits: 6) }
        return v.string ?? v.bool.map { $0 ? "Yes" : "No" } ?? ""
    }

    private func header(_ col: String, unit: String, i: Int, _ s: Swatch) -> some View {
        let label = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(col).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.ink)
                if let sort, sort.col == i { Image(systemName: sort.asc ? "chevron.up" : "chevron.down").font(.caption2.bold()) }
            }
            if !unit.isEmpty {
                Text(YLNumber.prettyUnit(unit)).font(theme.font(theme.type.caption)).foregroundStyle(s.inkSoft)
            }
        }
        return Group {
            if c.flag("sort") {
                Button {
                    let asc = sort?.col == i ? !(sort?.asc ?? true) : true
                    withAnimation(theme.spring) { sort = (i, asc) }
                    emit(c.event(["sort": .string(col), "dir": .string(asc ? "asc" : "desc")]))
                } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(col)")
            } else {
                label
            }
        }
    }

    private func sorted(_ rows: [[YLValue]]) -> [[YLValue]] {
        guard let sort else { return rows }
        return rows.sorted { a, b in
            let x = sort.col < a.count ? a[sort.col] : .null, y = sort.col < b.count ? b[sort.col] : .null
            let lt: Bool = if let p = x.number, let q = y.number { p < q }
                else { (x.string ?? "").localizedStandardCompare(y.string ?? "") == .orderedAscending }
            return sort.asc ? lt : !lt && x != y
        }
    }
}

// MARK: - chart

private struct Series {
    var name: String
    var y: [Double?]
    var err: [Double]
    func errAt(_ i: Int) -> Double { err.count == 1 ? err[0] : i < err.count ? err[i] : 0 }
}

private struct ChartData {
    var x: [YLValue] = []
    var series: [Series] = []
    var unit = ""
    var bound: String?
    var xname: String?
    var missing: String?

    var numericX: Bool { !x.isEmpty && x.allSatisfy { $0.number != nil } }
    func label(_ i: Int) -> String {
        guard i < x.count else { return "\(i + 1)" }
        return x[i].number.map { YLNumber.format($0, digits: 6) } ?? x[i].string ?? ""
    }

    /// Chart props, inline (`x=`, `y=`, `y2=` ...) or bound to a table (`data=`).
    init(_ c: YLComponent, _ all: [YLComponent]) {
        let p = c.props
        let names = c.strings("names") ?? []
        if let data = p["data"] {
            let id = data.string ?? data.number.map(YLComponent.format) ?? ""
            guard let t = all.table(id) else { missing = id; return }
            let cols = t.strings("cols") ?? []
            let rows = (t.props["rows"]?.array ?? []).map { $0.array ?? [] }
            let units = t.strings("units") ?? []
            func col(_ n: String) -> Int? { cols.firstIndex { $0.lowercased() == n.lowercased() } }
            let xi = c.strings("x")?.first.flatMap(col) ?? 0
            let ys = (c.strings("y") ?? []).compactMap(col)
            let yCols = !ys.isEmpty ? ys : cols.indices.filter { i in
                i != xi && !rows.isEmpty && rows.allSatisfy { i < $0.count && $0[i].number != nil }
            }
            bound = id
            xname = xi < cols.count ? cols[xi] : nil
            x = rows.map { xi < $0.count ? $0[xi] : .null }
            unit = c.string("unit") ?? (yCols.count == 1 && yCols[0] < units.count ? units[yCols[0]] : "")
            series = yCols.enumerated().map { k, i in
                Series(name: k < names.count ? names[k] : cols[i],
                       y: rows.map { i < $0.count ? $0[i].number ?? $0[i].string.flatMap(Double.init) : nil }, err: [])
            }
            return
        }
        let keys = p.keys.filter { $0.range(of: #"^y[0-9]*$"#, options: .regularExpression) != nil }
            .sorted { (Int($0.dropFirst()) ?? 1) < (Int($1.dropFirst()) ?? 1) }
        series = keys.enumerated().map { k, key in
            let name = k < names.count ? names[k] : keys.count > 1 ? "Series \(k + 1)" : c.string("title") ?? "Value"
            return Series(name: name, y: c.numbers(key) ?? [], err: (c.numbers("err" + key.dropFirst()) ?? []).map { $0 ?? 0 })
        }
        let n = series.map(\.y.count).max() ?? 0
        x = p["x"]?.array ?? (0..<n).map { .number(Double($0 + 1)) }
        unit = c.string("unit") ?? ""
    }
}

private struct ChartPoint: Identifiable {
    let series: Int
    let name: String
    let index: Int
    let label: String
    let xNum: Double
    let y: Double
    let err: Double
    var id: String { "\(series)-\(index)" }
}

/// `chart [type] [title] x= y= y2= err= names= unit= xlabel= data= min= max= color= +stack +dots`.
/// Tapping a point, bar or slice emits `{point: {series, index, x, y, name?}}`.
struct ChartPreset: View {
    let c: YLComponent
    @State private var tab = "chart"
    @State private var hot: ChartPoint?
    @State private var angle: Double?
    @Environment(\.ylComponents) private var all
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var type: String { c.string("type") ?? "line" }

    var body: some View {
        let s = theme.swatch(scheme)
        let d = ChartData(c, all)
        PresetCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    let title = c.string("title") ?? (d.bound != nil ? "\(d.series.map(\.name).joined(separator: ", ")) by \(d.xname ?? "")" : nil)
                    if let title, !title.isEmpty { PresetTitle(text: title) }
                    if let b = d.bound {
                        Text("data: \(b)").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                    }
                }
                Spacer(minLength: theme.spacing.s)
                Picker("View", selection: $tab) {
                    Image(systemName: "chart.xyaxis.line").tag("chart").accessibilityLabel("Chart")
                    Image(systemName: "tablecells").tag("table").accessibilityLabel("Table")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if let m = d.missing {
                Text("No table called \"\(m)\" on this screen yet.")
                    .font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
            } else if tab == "table" {
                dataTable(d, s)
            } else if type == "pie" || type == "donut" {
                pie(d, s)
            } else {
                xy(d, s)
            }
            if let hot {
                Text("\(d.series.count > 1 ? hot.name + " · " : "")\(hot.label): \(YLNumber.withUnit(hot.y, d.unit))\(hot.err > 0 ? " ± " + YLNumber.format(hot.err) : "")")
                    .font(theme.font(theme.type.caption, .bold).monospacedDigit())
                    .foregroundStyle(s.ink)
                    .transition(.opacity)
            }
        }
    }

    private func points(_ d: ChartData) -> [ChartPoint] {
        d.series.enumerated().flatMap { k, se in
            se.y.enumerated().compactMap { i, y -> ChartPoint? in
                guard let y else { return nil }
                return ChartPoint(series: k, name: se.name, index: i, label: d.label(i),
                                  xNum: i < d.x.count ? d.x[i].number ?? Double(i + 1) : Double(i + 1), y: y, err: se.errAt(i))
            }
        }
    }

    private func colors(_ d: ChartData, _ s: Swatch) -> [Color] {
        let names = c.strings("color") ?? []
        return d.series.indices.map { ChartPalette.color($0 < names.count ? names[$0] : nil, slot: $0, s, scheme) }
    }

    @ViewBuilder
    private func xy(_ d: ChartData, _ s: Swatch) -> some View {
        let pts = points(d)
        let numeric = type == "scatter" || ((type == "line" || type == "area") && d.numericX)
        let dots = c.flag("dots") || (d.series.map(\.y.count).max() ?? 0) <= 24
        let stack = c.flag("stack")
        let multi = d.series.count > 1
        Chart(pts) { p in
            if numeric {
                marks(p, x: PlottableValue.value("x", p.xNum), dots: dots, stack: stack, multi: multi)
            } else {
                marks(p, x: PlottableValue.value("x", p.label), dots: dots, stack: stack, multi: multi)
            }
            if let hot, hot.id == p.id {
                if numeric { RuleMark(x: .value("x", p.xNum)).foregroundStyle(s.inkSoft.opacity(0.4)) }
                else { RuleMark(x: .value("x", p.label)).foregroundStyle(s.inkSoft.opacity(0.4)) }
            }
        }
        .chartForegroundStyleScale(domain: d.series.map(\.name), range: colors(d, s))
        .chartLegend(multi ? .visible : .hidden)
        .chartYScale(domain: yDomain(d, pts))
        .chartXAxisLabel(c.string("xlabel") ?? "")
        .chartYAxisLabel(YLNumber.prettyUnit(d.unit))
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(s.outline)
                AxisValueLabel().font(theme.font(theme.type.caption - 2, .semibold)).foregroundStyle(s.inkSoft)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(s.outline)
                AxisValueLabel().font(theme.font(theme.type.caption - 2, .semibold)).foregroundStyle(s.inkSoft)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(.rect)
                    .gesture(SpatialTapGesture().onEnded { v in
                        guard let frame = proxy.plotFrame else { return }
                        let at = CGPoint(x: v.location.x - geo[frame].origin.x, y: v.location.y - geo[frame].origin.y)
                        tap(nearest(at, proxy: proxy, pts: pts, numeric: numeric), d)
                    })
            }
        }
        .frame(height: 210)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("yl-chart")
        .accessibilityLabel(c.string("title") ?? "Chart")
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(_ p: ChartPoint, x: PlottableValue<X>, dots: Bool, stack: Bool, multi: Bool) -> some ChartContent {
        let y = PlottableValue.value("y", p.y)
        let group = PlottableValue.value("Series", p.name)
        switch type {
        case "bar":
            if multi && !stack {
                BarMark(x: x, y: y).foregroundStyle(by: group).position(by: group).cornerRadius(4)
            } else {
                BarMark(x: x, y: y).foregroundStyle(by: group).cornerRadius(4)
            }
        case "area":
            AreaMark(x: x, y: y, stacking: stack ? .standard : .unstacked)
                .foregroundStyle(by: group).opacity(multi && !stack ? 0.45 : 0.8).interpolationMethod(.monotone)
        case "scatter":
            PointMark(x: x, y: y).foregroundStyle(by: group).symbolSize(60)
        default:
            LineMark(x: x, y: y, series: group).foregroundStyle(by: group).interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            if dots { PointMark(x: x, y: y).foregroundStyle(by: group).symbolSize(28) }
        }
        if p.err > 0, type != "area" {
            RuleMark(x: x, yStart: .value("low", p.y - p.err), yEnd: .value("high", p.y + p.err))
                .foregroundStyle(by: group).lineStyle(StrokeStyle(lineWidth: 1.5))
        }
    }

    private func yDomain(_ d: ChartData, _ pts: [ChartPoint]) -> ClosedRange<Double> {
        var lo = pts.map { $0.y - $0.err }.min() ?? 0
        var hi = pts.map { $0.y + $0.err }.max() ?? 1
        if c.flag("stack") && (type == "bar" || type == "area") {
            let sums = Dictionary(grouping: pts, by: \.index).values.map { $0.map(\.y).reduce(0, +) }
            hi = max(hi, sums.max() ?? hi)
        }
        if type == "bar" || type == "area" { lo = min(0, lo); hi = max(0, hi) }
        if lo == hi { lo -= 1; hi += 1 }
        let pad = (type == "bar" || type == "area") ? 0 : (hi - lo) * 0.08
        lo = c.number("min") ?? (lo == 0 ? 0 : lo - pad)
        hi = c.number("max") ?? hi + pad
        return lo...max(hi, lo + 1e-9)
    }

    private func nearest(_ at: CGPoint, proxy: ChartProxy, pts: [ChartPoint], numeric: Bool) -> ChartPoint? {
        pts.min { a, b in
            dist(a, at, proxy, numeric) < dist(b, at, proxy, numeric)
        }
    }

    private func dist(_ p: ChartPoint, _ at: CGPoint, _ proxy: ChartProxy, _ numeric: Bool) -> Double {
        let px = numeric ? proxy.position(forX: p.xNum) : proxy.position(forX: p.label)
        let py = proxy.position(forY: p.y)
        guard let px, let py else { return .infinity }
        return type == "bar" ? abs(px - at.x) * 10 + abs(py - at.y) * 0.01 : hypot(px - at.x, py - at.y)
    }

    private func tap(_ p: ChartPoint?, _ d: ChartData) {
        guard let p else { return }
        withAnimation(theme.spring) { hot = p }
        var point: [String: YLValue] = ["series": .number(Double(p.series)), "index": .number(Double(p.index)),
                                        "x": p.index < d.x.count ? d.x[p.index] : .number(Double(p.index + 1)),
                                        "y": .number(p.y)]
        if d.series.count > 1 { point["name"] = .string(p.name) }
        emit(c.event(["point": .object(point)]))
    }

    @ViewBuilder
    private func pie(_ d: ChartData, _ s: Swatch) -> some View {
        let first = d.series.first
        let slices: [ChartPoint] = (first?.y ?? []).enumerated().compactMap { i, y in
            guard let y, y > 0 else { return nil }
            return ChartPoint(series: 0, name: first?.name ?? "", index: i, label: d.label(i), xNum: Double(i), y: y, err: 0)
        }
        let total = slices.map(\.y).reduce(0, +)
        let slots = ChartPalette.slots(scheme)
        Chart(slices) { p in
            SectorMark(angle: .value("y", p.y), innerRadius: .ratio(type == "donut" ? 0.62 : 0), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(by: .value("x", p.label))
                .opacity(hot == nil || hot?.index == p.index ? 1 : 0.45)
        }
        .chartForegroundStyleScale(domain: slices.map(\.label), range: slices.indices.map { slots[$0 % slots.count] })
        .chartAngleSelection(value: $angle)
        .onChange(of: angle) { _, a in
            guard let a else { return }
            var acc = 0.0
            for p in slices {
                acc += p.y
                if a <= acc { tap(p, d); break }
            }
        }
        .chartBackground { proxy in
            GeometryReader { geo in
                if type == "donut", let frame = proxy.plotFrame {
                    let r = geo[frame]
                    VStack(spacing: 0) {
                        Text(YLNumber.withUnit(total, d.unit)).font(theme.font(theme.type.title, .black)).foregroundStyle(s.ink)
                        Text("Total").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                    }
                    .position(x: r.midX, y: r.midY)
                }
            }
        }
        .frame(height: 230)
    }

    private func dataTable(_ d: ChartData, _ s: Swatch) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .trailing, horizontalSpacing: theme.spacing.l, verticalSpacing: theme.spacing.s) {
                GridRow {
                    Text(c.string("xlabel") ?? d.xname ?? "").gridColumnAlignment(.leading)
                    ForEach(Array(d.series.enumerated()), id: \.offset) { _, se in Text(se.name) }
                }
                .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.ink)
                Divider().overlay(s.outline)
                ForEach(0..<max(d.x.count, d.series.map(\.y.count).max() ?? 0), id: \.self) { i in
                    GridRow {
                        Text(d.label(i)).gridColumnAlignment(.leading)
                        ForEach(Array(d.series.enumerated()), id: \.offset) { _, se in
                            let y = i < se.y.count ? se.y[i] : nil
                            Text(y.map { YLNumber.format($0, digits: 6) + (se.errAt(i) > 0 ? " ± " + YLNumber.format(se.errAt(i)) : "") } ?? "")
                        }
                    }
                    .font(theme.font(theme.type.body, .medium).monospacedDigit()).foregroundStyle(s.ink)
                }
            }
        }
    }
}

// MARK: - stat

/// `stat VALUE [label] delta= spark= good=up|down sub= cta=`.
struct StatPreset: View {
    let c: YLComponent
    @State private var converted = false
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let tile = PresetCard {
            if let l = c.string("label") {
                Text(l).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
            }
            HStack(alignment: .bottom, spacing: theme.spacing.m) {
                value(s)
                Spacer(minLength: 0)
                if let spark = c.numbers("spark")?.compactMap({ $0 }), spark.count > 1 { sparkline(spark) }
            }
            HStack(spacing: theme.spacing.s) {
                delta(s)
                if let sub = c.string("sub") {
                    Text(sub).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                }
            }
            if let cta = c.string("cta") {
                Label(cta, systemImage: "arrow.right.circle.fill")
                    .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.ink)
            }
        }
        if let cta = c.string("cta") {
            Button { emit(c.event(["cta": .string(cta)], echo: cta)) } label: { tile }
                .buttonStyle(BounceButtonStyle())
                .disabled(c.locked)
        } else {
            tile
        }
    }

    @ViewBuilder
    private func value(_ s: Swatch) -> some View {
        let unit = c.string("unit")
        if let v = c.number("value") {
            let conv = unit.flatMap { YLNumber.conversions[$0] }
            let shownUnit = converted ? conv?.0 : unit
            let shown = converted ? conv.map { $0.1(v) } ?? v : v
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(YLNumber.withUnit(shown, shownUnit, digits: 5))
                    .font(theme.font(theme.type.display + 10, .black).monospacedDigit())
                    .foregroundStyle(s.ink)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if conv != nil {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
                        .padding(.leading, theme.spacing.xs)
                }
            }
            .contentShape(.rect)
            .onTapGesture { if conv != nil { withAnimation(theme.spring) { converted.toggle() } } }
            .accessibilityHint(conv != nil ? "Converts the unit" : "")
        } else {
            Text(c.string("value") ?? "")
                .font(theme.font(theme.type.display + 10, .black))
                .foregroundStyle(s.ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func delta(_ s: Swatch) -> some View {
        if let (d, own) = YLNumber.quantity(c.props["delta"]), d != 0 || c.props["delta"] != nil {
            let goodUp = c.string("good") != "down"
            let good = d == 0 ? nil : (d > 0) == goodUp
            let color = good == nil ? s.inkSoft : good! ? ChartPalette.good(scheme) : ChartPalette.bad(scheme)
            let unit = own ?? c.string("unit")
            Text("\(d > 0 ? "▲" : d < 0 ? "▼" : "•") \(YLNumber.withUnit(abs(d), unit))")
                .font(theme.font(theme.type.body, .heavy).monospacedDigit())
                .foregroundStyle(color)
                .accessibilityLabel("\(d > 0 ? "up" : "down") \(YLNumber.withUnit(abs(d), unit))")
        }
    }

    private func sparkline(_ v: [Double]) -> some View {
        let color = ChartPalette.slots(scheme)[0]
        return Chart(Array(v.enumerated()), id: \.offset) { i, y in
            AreaMark(x: .value("i", i), yStart: .value("lo", v.min()!), yEnd: .value("y", y))
                .foregroundStyle(color.opacity(0.14)).interpolationMethod(.monotone)
            LineMark(x: .value("i", i), y: .value("y", y))
                .foregroundStyle(color).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            if i == v.count - 1 { PointMark(x: .value("i", i), y: .value("y", y)).foregroundStyle(color).symbolSize(30) }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: v.min()!...max(v.max()!, v.min()! + 1e-9))
        .frame(width: 96, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - step

/// Consecutive `step` lines, one stepper. One step at a time with Back and
/// Next, or every step at once with `+all`. Passing a step emits
/// `{done: true, index, last?}` from that step's own id.
struct StepperPreset: View {
    let steps: [YLComponent]
    @State private var at = 0
    @State private var done: Set<Int> = []
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var all: Bool { steps.first?.flag("all") ?? false }
    private var finished: Bool { done.count >= steps.count && !steps.isEmpty }

    var body: some View {
        let s = theme.swatch(scheme)
        let current = min(at, max(steps.count - 1, 0))
        PresetCard {
            if let t = steps.first?.string("title") { PresetTitle(text: t) }
            if !all {
                ProgressView(value: Double(done.count), total: Double(max(steps.count, 1)))
                    .tint(s.accent)
                    .accessibilityLabel("\(done.count) of \(steps.count) steps done")
            }
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                ForEach(Array(steps.enumerated()), id: \.element.serial) { i, step in
                    if all || i <= current || done.contains(i) {
                        row(i, step, open: all || i == current && !finished, s)
                    }
                }
            }
            if !all, !finished {
                HStack(spacing: theme.spacing.s) {
                    OptionPill(text: "Back", fill: s.lavender, on: current > 0, grow: true) {
                        withAnimation(theme.spring) { at = max(0, current - 1) }
                    }
                    .disabled(current == 0)
                    OptionPill(text: current == steps.count - 1 ? "Done" : "Next", fill: s.accent, ink: s.onAccent, grow: true) {
                        pass(current)
                        withAnimation(theme.spring) { at = current + 1 }
                    }
                }
                if steps.count > current + 1 {
                    let more = steps.count - current - 1
                    Text("\(more) more step\(more == 1 ? "" : "s")")
                        .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                }
            }
        }
    }

    private func row(_ i: Int, _ step: YLComponent, open: Bool, _ s: Swatch) -> some View {
        let isDone = done.contains(i)
        return HStack(alignment: .top, spacing: theme.spacing.m) {
            ZStack {
                Circle().fill(isDone ? s.mint : open ? s.accent : s.background)
                Circle().stroke(s.outline, lineWidth: isDone || open ? 0 : 1.5)
                if isDone { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(s.userInk) }
                else { Text("\(i + 1)").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(open ? s.onAccent : s.inkSoft) }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                if let t = step.string("text") {
                    Text(t).font(theme.font(theme.type.body, open ? .bold : .medium))
                        .foregroundStyle(isDone && !open ? s.inkSoft : s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if open || all {
                    if let tex = step.string("tex") { TeXView(tex: tex, size: theme.type.title) }
                    if let img = YLMediaURL.url(step.string("img")) {
                        RemoteImage(src: img).frame(height: 160).frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: theme.radius.bubble / 2))
                    }
                    if let secs = step.number("time"), secs > 0 { StepTimer(seconds: secs) }
                } else if let tex = step.string("tex") {
                    TeXView(tex: tex, size: theme.type.body).opacity(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { if all, !isDone { pass(i) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(all && !isDone ? .isButton : [])
        .accessibilityValue(isDone ? "done" : "")
    }

    private func pass(_ i: Int) {
        guard i < steps.count, !done.contains(i) else { return }
        withAnimation(theme.spring) { _ = done.insert(i) }
        var v: [String: YLValue] = ["done": .bool(true), "index": .number(Double(i))]
        if i == steps.count - 1 { v["last"] = .bool(true) }
        emit(steps[i].event(v))
    }
}

/// A small countdown for a protocol step.
private struct StepTimer: View {
    let seconds: Double
    @State private var started: Date?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let left = max(0, seconds - (started.map { ctx.date.timeIntervalSince($0) } ?? 0))
            Button {
                started = started == nil || left == 0 ? .now : nil
            } label: {
                Label(left == 0 ? "Time's up" : TimerPreset.clock(left.rounded(.up), up: false),
                      systemImage: started == nil ? "play.fill" : left == 0 ? "bell.fill" : "stop.fill")
                    .font(theme.font(theme.type.caption, .heavy).monospacedDigit())
                    .foregroundStyle(s.userInk)
                    .padding(.horizontal, theme.spacing.m)
                    .padding(.vertical, theme.spacing.xs)
                    .background(left == 0 ? s.butter : s.mint, in: Capsule())
            }
            .buttonStyle(BounceButtonStyle())
        }
    }
}

// MARK: - calc

/// `calc [title] f="out = expr" name=min-max[@value][unit] ... plot= unit= digits=`.
/// Releasing a slider emits `{values: {name: value}, result}`.
struct CalcPreset: View {
    let c: YLComponent
    @State private var vals: [String: Double] = [:]
    @State private var sig = ""
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private static let reserved: Set<String> = ["title", "f", "plot", "unit", "digits", "color", "lock"]

    private struct Var {
        let name: String
        let min: Double?
        let max: Double?
        let value: Double
        let unit: String?
        var slider: Bool { min != nil && max != nil }
        var deg: Bool { unit == "deg" || unit == "°" }
    }

    private var defs: [Var] {
        c.props.keys.sorted().compactMap { k in
            guard !Self.reserved.contains(k), let o = c.props[k]?.object, let v = o["value"]?.number else { return nil }
            return Var(name: k, min: o["min"]?.number, max: o["max"]?.number, value: v, unit: o["unit"]?.string)
        }
    }

    var body: some View {
        let s = theme.swatch(scheme)
        let defs = self.defs
        let (out, exprText) = YLExpr.splitFormula(c.string("f") ?? "")
        let parsed = Result { try YLExpr.parse(exprText) }
        let digits = Int(c.number("digits") ?? 3)
        PresetCard {
            if let t = c.string("title") { PresetTitle(text: t) }
            switch parsed {
            case .failure(let e):
                Text("Formula: \(String(describing: e))").font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.accent)
            case .success(let ast):
                TeXView(tex: (out.isEmpty ? "" : YLExpr.nameTeX(out) + " = ") + ast.tex, size: theme.type.title)
                let missing = ast.names.filter { vals[$0] == nil && value(of: $0, defs) == nil && $0 != "pi" && $0 != "e" }.sorted()
                let result = missing.isEmpty ? calc(ast, defs, over: [:]) : .nan
                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                    Text((out.isEmpty ? "result" : out) + " =").font(theme.font(theme.type.body, .semibold)).foregroundStyle(s.inkSoft)
                    Text(result.isFinite ? YLNumber.withUnit(result, c.string("unit"), digits: digits)
                         : missing.isEmpty ? "undefined" : "needs \(missing.joined(separator: ", "))")
                        .font(theme.font(theme.type.display, .black).monospacedDigit())
                        .foregroundStyle(s.ink)
                        .contentTransition(.numericText())
                }
                if missing.isEmpty, let plot = plotVar(defs) { curve(ast, defs, plot, result: result, s) }
            }
            ForEach(defs.filter(\.slider), id: \.name) { v in slider(v, defs, parsed, s) }
            let consts = defs.filter { !$0.slider }
            if !consts.isEmpty {
                Text(consts.map { "\($0.name) = \(YLNumber.withUnit($0.value, $0.unit))" }.joined(separator: "   "))
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            }
        }
        .disabled(c.locked)
        .onAppear { reset(defs) }
        .onChange(of: signature(defs)) { reset(defs) }
    }

    private func signature(_ defs: [Var]) -> String {
        defs.map { "\($0.name):\($0.min ?? .nan):\($0.max ?? .nan):\($0.value)" }.joined(separator: ",")
    }

    private func reset(_ defs: [Var]) {
        vals = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0.value) })
    }

    private func value(of name: String, _ defs: [Var]) -> Double? { vals[name] ?? defs.first { $0.name == name }?.value }

    private func calc(_ ast: YLExpr, _ defs: [Var], over: [String: Double]) -> Double {
        var env: [String: Double] = [:]
        for d in defs {
            let v = over[d.name] ?? vals[d.name] ?? d.value
            env[d.name] = d.deg ? v * .pi / 180 : v
        }
        let r = (try? ast.eval(env)) ?? .nan
        return r.isFinite ? r : .nan
    }

    private func plotVar(_ defs: [Var]) -> Var? {
        if c.props["plot"]?.bool == false { return nil }
        let sliders = defs.filter(\.slider)
        return sliders.first { $0.name == c.string("plot") } ?? sliders.first
    }

    private func curve(_ ast: YLExpr, _ defs: [Var], _ v: Var, result: Double, _ s: Swatch) -> some View {
        let lo = v.min!, hi = v.max!
        let pts: [(Double, Double)] = (0...60).compactMap { i in
            let x = lo + (hi - lo) * Double(i) / 60
            let y = calc(ast, defs, over: [v.name: x])
            return y.isFinite ? (x, y) : nil
        }
        let color = ChartPalette.slots(scheme)[0]
        let now = vals[v.name] ?? v.value
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(v.name, p.0), y: .value("result", p.1))
                    .foregroundStyle(color).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if result.isFinite {
                PointMark(x: .value(v.name, now), y: .value("result", result)).foregroundStyle(color).symbolSize(80)
                RuleMark(x: .value(v.name, now)).foregroundStyle(s.inkSoft.opacity(0.35))
            }
        }
        .chartXAxisLabel("\(v.name)\(v.unit.map { " (\(YLNumber.prettyUnit($0)))" } ?? "")")
        .chartYAxisLabel(YLNumber.prettyUnit(c.string("unit")))
        .chartXScale(domain: lo...max(hi, lo + 1e-9))
        .frame(height: 160)
        .accessibilityHidden(true)
    }

    private func slider(_ v: Var, _ defs: [Var], _ parsed: Result<YLExpr, Error>, _ s: Swatch) -> some View {
        let lo = v.min!, hi = max(v.max!, v.min! + 1e-9)
        let step = YLNumber.niceStep(hi - lo, 200)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(v.name).font(theme.font(theme.type.body, .heavy).italic()).foregroundStyle(s.ink)
                Spacer()
                Text(YLNumber.withUnit(vals[v.name] ?? v.value, v.unit))
                    .font(theme.font(theme.type.body, .bold).monospacedDigit()).foregroundStyle(s.ink)
            }
            Slider(value: Binding(get: { min(max(vals[v.name] ?? v.value, lo), hi) },
                                  set: { vals[v.name] = ($0 / step).rounded() * step }),
                   in: lo...hi) { editing in
                guard !editing else { return }
                let r = (try? parsed.get()).map { calc($0, defs, over: [:]) } ?? .nan
                let values = defs.reduce(into: [String: YLValue]()) { $0[$1.name] = .number(vals[$1.name] ?? $1.value) }
                emit(c.event(["values": .object(values),
                              "result": r.isFinite ? .number(Double(String(format: "%.6g", r)) ?? r) : .null]))
            }
            .tint(s.accent)
            .accessibilityLabel(v.name)
        }
    }
}
