import SwiftUI
import YuiLines

/// `query <table> [where= sort= limit= cols= group= sum= ...] [as table|list|chart|stat|send]`
/// (TABLES.md, YUI-89). It reads the open agent's tables on the phone and draws the rows with the
/// table, list, chart and stat presets. Live: a `put`, from this reply or a later one, or a tick,
/// changes the store, and this runs the query again.
struct QueryPreset: View {
    let c: YLComponent
    @Environment(\.ylAgent) private var agent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let store = AgentTables.shared.store(agent)
        let title = c.string("title") ?? Self.human(c.string("table") ?? "Query")
        switch store.query(c.props) {
        case .missing(let name): QueryNote(title: title, text: "No table called \(name) yet.")
        case .error(let message): QueryNote(title: title, text: message)
        case .rows(let r):
            switch c.string("as") ?? "table" {
            case "list": QueryList(c: c, r: r, title: title)
            case "chart": QueryChart(c: c, r: r)
            case "stat": QueryStat(c: c, r: r, title: title)
            case "send": QuerySend(c: c, r: r)
            default: QueryTable(c: c, r: r, title: title)
            }
        }
    }

    static func human(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

// MARK: Shared pieces

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

enum QueryShow {
    /// Dates show short, in the reader's words: "Sep 26", "Sep 26, 12:30", with the year only when
    /// it is not this one. Events keep the stored YYYY-MM-DD.
    static func day(_ v: String, now: Date = Date()) -> String {
        let p = v.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" }).compactMap { Int($0) }
        guard p.count >= 3, (1...12).contains(p[1]) else { return v }
        let thisYear = Calendar.current.component(.year, from: now)
        let year = p[0] == thisYear ? "" : " \(p[0])"
        let time = p.count >= 5 ? String(format: ", %02d:%02d", p[3], p[4]) : ""
        return "\(months[p[1] - 1]) \(p[2])\(year)\(time)"
    }

    static func text(_ v: YLValue, _ type: String) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "yes" : "no"
        case .number(let n): return YLComponent.format(n)
        case .string(let s): return type == "date" ? day(s) : s
        default: return ""
        }
    }

    /// A cell for the table preset: numbers stay numbers, the rest is shown text.
    static func cell(_ v: YLValue, _ type: String) -> YLValue {
        if case .number = v { return v }
        return .string(text(v, type))
    }
}

private struct QueryNote: View {
    let title: String
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            PresetTitle(text: title)
            Text(text).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
        }
    }
}

private struct QueryFoot: View {
    let r: YLTableResult
    let table: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let more = r.count > r.rows.count ? "\(r.rows.count) of \(r.count) rows" : "\(r.count) row\(r.count == 1 ? "" : "s")"
        Text("\(more) · \(table) · on this phone")
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .padding(.horizontal, theme.spacing.s)
    }
}

// MARK: as table

private struct QueryTable: View {
    let c: YLComponent
    let r: YLTableResult
    let title: String
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        // Headers always sort on tap: `sort=` is the query's own order.
        let t = YLComponent(serial: c.serial, ylID: c.ylID, preset: "table", screen: c.screen, props: [
            "name": .string(title),
            "cols": .array(r.cols.map { .string($0.name) }),
            "rows": .array(r.rows.map { row in .array(row.enumerated().map { QueryShow.cell($1, r.cols[$0].type) }) }),
            "units": .array(r.cols.map { .string($0.unit ?? "") }),
            "sort": .bool(true),
        ], line: c.line, inGroup: c.inGroup, saved: c.saved)
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if r.rows.isEmpty { QueryNote(title: title, text: "Nothing here yet.") } else { TablePreset(c: t) }
            QueryFoot(r: r, table: c.string("table") ?? "")
        }
    }
}

// MARK: as list

/// One item per row, its cells joined with " · ". `check=Col` makes a bool column the checkbox:
/// a tap writes the row on the phone and tells the agent (TABLES.md section 3, event 2).
private struct QueryList: View {
    let c: YLComponent
    let r: YLTableResult
    let title: String
    @Environment(\.ylAgent) private var agent
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let table = c.string("table") ?? ""
        let ci = c.string("check").flatMap { want in r.cols.firstIndex { $0.name.lowercased() == want.lowercased() && $0.type == "bool" } }
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            PresetCard {
                PresetTitle(text: title)
                if r.rows.isEmpty {
                    Text("Nothing here yet.").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
                }
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    ForEach(Array(r.rows.enumerated()), id: \.offset) { i, row in
                        let on = ci.map { row[$0] == .bool(true) } ?? false
                        let words = row.enumerated().filter { $0.offset != ci }
                            .map { QueryShow.text($0.element, r.cols[$0.offset].type) }.filter { !$0.isEmpty }.joined(separator: " · ")
                        let line = HStack(alignment: .firstTextBaseline, spacing: theme.spacing.m) {
                            if ci != nil {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(theme.font(theme.type.title, .bold))
                                    .foregroundStyle(on ? s.mint : s.inkSoft)
                                    .symbolEffect(.bounce, value: on)
                            } else {
                                Circle().fill(s.candy[i % 4]).frame(width: 10, height: 10)
                            }
                            Text(words)
                                .font(theme.font(theme.type.body, .medium))
                                .foregroundStyle(on ? s.inkSoft : s.ink)
                                .strikethrough(on, color: s.inkSoft)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        if let ci, let key = r.keys[i] {
                            Button {
                                let col = r.cols[ci].name
                                withAnimation(theme.spring) { AgentTables.shared.store(agent).set(table: table, key: key, values: [col: .bool(!on)]) }
                                emit(c.event(["op": .string("row"), "table": .string(table), "key": .string(key),
                                              "values": .object([col: .bool(!on)])]))
                            } label: { line.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        } else {
                            line
                        }
                    }
                }
            }
            QueryFoot(r: r, table: table)
        }
    }
}

// MARK: as chart

/// The chart preset over the rows: the result becomes a table the chart binds to.
private struct QueryChart: View {
    let c: YLComponent
    let r: YLTableResult
    @Environment(\.ylComponents) private var all
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        let alias = c.string("table") ?? "query"
        let t = YLComponent(serial: -2, ylID: alias, preset: "table", screen: c.screen, props: [
            "name": .string(alias),
            "cols": .array(r.cols.map { .string($0.name) }),
            "rows": .array(r.rows.map { row in .array(row.enumerated().map { QueryShow.cell($1, r.cols[$0].type) }) }),
            "units": .array(r.cols.map { .string($0.unit ?? "") }),
        ], line: c.line)
        let p = ["title", "x", "y", "unit", "min", "max", "stack", "names", "color", "xlabel", "dots"]
            .reduce(into: ["type": YLValue.string(c.string("type") ?? "line"), "data": .string(alias)]) { o, k in
                if let v = c.props[k] { o[k] = v }
            }
        let chart = YLComponent(serial: c.serial, ylID: c.ylID, preset: "chart", screen: c.screen, props: p, line: c.line,
                                inGroup: c.inGroup, saved: c.saved)
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            ChartPreset(c: chart).environment(\.ylComponents, all + [t])
            QueryFoot(r: r, table: c.string("table") ?? "")
        }
    }
}

// MARK: as stat

/// One number: the last row's, with the change since the row before and a spark line of the
/// column when there are two or more rows.
private struct QueryStat: View {
    let c: YLComponent
    let r: YLTableResult
    let title: String

    /// The stat preset over the column: the last value, its change and spark, or why there is none.
    private func stat() -> (YLComponent?, String) {
        let want = c.strings("y")?.first?.lowercased()
        let yi = want.flatMap { w in r.cols.firstIndex { $0.name.lowercased() == w } } ?? r.cols.firstIndex { $0.type == "number" }
        guard let yi else { return (nil, "No number column to show.") }
        let vals = r.rows.compactMap { $0[yi].number }
        guard let last = vals.last else { return (nil, "Nothing here yet.") }
        var p: [String: YLValue] = [
            "value": .number(last),
            "label": .string(c.string("label") ?? c.string("title") ?? r.cols[yi].name),
            "good": .string(c.string("good") ?? "up"),
        ]
        if let u = r.cols[yi].unit { p["unit"] = .string(u) }
        if vals.count > 1 {
            p["delta"] = .number(((last - vals[vals.count - 2]) * 1e6).rounded() / 1e6)
            p["spark"] = .array(vals.map(YLValue.number))
        }
        if let sub = c.string("sub") { p["sub"] = .string(sub) }
        return (YLComponent(serial: c.serial, ylID: c.ylID, preset: "stat", screen: c.screen, props: p, line: c.line,
                            inGroup: c.inGroup, saved: c.saved), "")
    }

    var body: some View {
        let (tile, why) = stat()
        if let tile { StatPreset(c: tile) } else { QueryNote(title: title, text: why) }
    }
}

// MARK: as send

/// A card the person taps to hand the rows to the agent. Nothing leaves the phone until they do
/// (TABLES.md section 4): the event carries the columns, up to 200 rows and how many matched.
private struct QuerySend: View {
    let c: YLComponent
    let r: YLTableResult
    @State private var sent = false
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let table = c.string("table") ?? ""
        let n = min(r.rows.count, YLTableLimits.send)
        PresetCard {
            Text("\(table) · on this phone").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            PresetTitle(text: c.string("title") ?? "Send \(n) row\(n == 1 ? "" : "s") from \(table)?")
            Text("\(r.cols.map(\.name).joined(separator: ", ")). Only these rows go, and only when you tap.")
                .font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
            OptionPill(text: sent ? "Sent" : n > 0 ? "Send" : "Nothing to send", fill: s.accent, ink: s.onAccent,
                       on: !sent && n > 0, dim: sent, grow: true) {
                guard !sent, n > 0 else { return }
                withAnimation(theme.spring) { sent = true }
                emit(c.event(["op": .string("query"), "table": .string(table), "cols": .array(r.cols.map { .string($0.name) }),
                              "rows": .array(r.rows.prefix(YLTableLimits.send).map { .array($0) }),
                              "count": .number(Double(r.count))], echo: "Sent \(n) row\(n == 1 ? "" : "s") from \(table)"))
            }
        }
        .onChange(of: answers(scope, c.ylID) != nil, initial: true) { _, done in if done { sent = true } }
    }
}
