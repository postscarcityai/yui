import Foundation

// Agent tables (yuigui spec/TABLES.md, YUI-33 / YUI-89). Two halves, both pure:
//   the parser side: `table create` and `put` lines, and the `query` preset
//   (Presets.swift);
//   the store: `YLTables`, a value type that applies those ops and runs a query.
// The store mirrors site/lib/yl/tables.mjs rule for rule; the app keeps it in
// SQLite (Yui/Tables) and loads it into this type. Every function returns a
// new store and never changes the one it was given.

let queryViews: Set<String> = ["table", "list", "chart", "stat", "send"]
let tableTypes: Set<String> = ["text", "number", "date", "bool"]

// MARK: - Parser

extension YuiLines {
    /// `^[A-Za-z][\w-]*$`
    static func isTableName(_ s: String) -> Bool {
        let u = Scalars(s.unicodeScalars)
        guard let f = u.first, isAlpha(f) else { return false }
        return u.dropFirst().allSatisfy(isWordish)
    }

    /// `table create <name> col:type ...` (a number column may carry a unit: `Cal:number:kcal`).
    static func tableCreateLine(screen: String, tokens: [Token], line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: "table create: \(m)", line: line) }
        guard let nameTok = tokens.first, !nameTok.quoted, nameTok.parts == nil, nameTok.key == nil,
              isTableName(nameTok.raw) else { return bad("needs a name, then col:type ...") }
        let rest = tokens.dropFirst()
        if rest.isEmpty { return bad("needs at least one col:type") }
        var cols: [YLValue] = []
        for t in rest {
            // ^([A-Za-z_][\w-]*):([a-z]+)(?::(\S+))?$
            let parts = t.quoted || t.key != nil ? [] : t.raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, isIdent(Scalars(parts[0].unicodeScalars)),
                  !parts[1].isEmpty, parts[1].unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }),
                  parts.count == 2 || (!parts[2].isEmpty && !parts[2].unicodeScalars.contains(where: isSpace)) else {
                return bad("\"\(t.raw)\" is not col:type")
            }
            guard tableTypes.contains(parts[1]) else { return bad("\"\(parts[1])\" is not text, number, date or bool") }
            if parts.count == 3, parts[1] != "number" { return bad("only number columns take a unit (\"\(t.raw)\")") }
            var c: [String: YLValue] = ["name": .string(parts[0]), "type": .string(parts[1])]
            if parts.count == 3 { c["unit"] = .string(parts[2]) }
            cols.append(.object(c))
        }
        return YLNode(op: .table, screen: screen, name: nameTok.raw, props: ["cols": .array(cols)], line: line)
    }

    /// `put <table> [key] col=value ... [+delete]`. Other flags set a bool column: `+Done` is `Done=on`.
    static func putLine(screen: String, tokens: [Token], line: String) -> YLNode {
        func bad(_ m: String) -> YLNode { YLNode(op: .error, screen: screen, message: "put: \(m)", line: line) }
        var kv: [String: YLValue] = [:]
        var flags: [String: YLValue] = [:]
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
        guard let tableTok = pos.first, !tableTok.quoted, tableTok.parts == nil, isTableName(tableTok.raw) else {
            return bad("needs a table name")
        }
        if pos.count > 2 { return bad("one key, then col=value ...") }
        let keyTok = pos.count > 1 ? pos[1] : nil
        if let k = keyTok, k.parts != nil { return bad("a key has no |") }
        let del = flags.removeValue(forKey: "delete") != nil
        let values = flags.merging(kv) { $1 }
        var props: [String: YLValue] = ["table": .string(tableTok.raw)]
        if let k = keyTok { props["key"] = .string(k.text) }
        if del {
            if keyTok == nil { return bad("+delete needs a key") }
            if !values.isEmpty { return bad("+delete takes no values") }
            props["values"] = .object([:])
            props["delete"] = .bool(true)
            return YLNode(op: .put, screen: screen, props: props, line: line)
        }
        if values.isEmpty { return bad("needs at least one col=value") }
        props["values"] = .object(values)
        return YLNode(op: .put, screen: screen, props: props, line: line)
    }
}

// MARK: - Store

public enum YLTableLimits {
    public static let tables = 20
    public static let cols = 12
    public static let rows = 5000
    public static let text = 1000
    public static let key = 64
    public static let name = 32
    public static let limit = 50
    public static let maxLimit = 500
    public static let send = 200
}

/// The phone's date and time for `today`, `today-7` and `now`, in its own time zone.
public struct YLTableContext: Sendable, Equatable {
    public var today: String
    public var now: String
    public init(today: String, now: String) { self.today = today; self.now = now }

    public init(date: Date = Date(), calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        self.init(today: day, now: day + String(format: "T%02d:%02d", c.hour ?? 0, c.minute ?? 0))
    }
}

public struct YLTableCol: Sendable, Equatable, Hashable {
    public var name: String
    public var type: String
    public var unit: String?
    public init(name: String, type: String, unit: String? = nil) { self.name = name; self.type = type; self.unit = unit }
    var value: YLValue {
        var o: [String: YLValue] = ["name": .string(name), "type": .string(type)]
        if let unit { o["unit"] = .string(unit) }
        return .object(o)
    }
}

public struct YLTable: Sendable, Equatable {
    public var name: String
    public var cols: [YLTableCol]
    /// key -> column -> value. A column with no value is absent.
    public var rows: [String: [String: YLValue]]
    /// Keys in the order the rows were first written.
    public var order: [String]
    public var next: Int
    public init(name: String, cols: [YLTableCol], rows: [String: [String: YLValue]] = [:], order: [String] = [], next: Int = 1) {
        self.name = name; self.cols = cols; self.rows = rows; self.order = order; self.next = next
    }
}

public struct YLTableResult: Sendable, Equatable {
    public var cols: [YLTableCol]
    public var rows: [[YLValue]]
    /// The row key of each row; nil for a totals row.
    public var keys: [String?]
    /// Rows matched before `limit`.
    public var count: Int
}

public enum YLQueryOutcome: Sendable, Equatable {
    case rows(YLTableResult)
    case missing(String)
    case error(String)
}

public struct YLTables: Sendable, Equatable {
    public var tables: [String: YLTable] = [:]
    /// Table names in the order they were made (the dictionary has none).
    public var names: [String] = []
    public init() {}

    public enum Write: Sendable, Equatable {
        /// `key` is the row that changed (a put), nil for a table change.
        case ok(key: String?)
        case refused(String)
    }

    // MARK: cells

    private static func shiftDay(_ day: String, _ n: Int) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              let t = cal.date(byAdding: .day, value: n, to: d) else { return day }
        let c = cal.dateComponents([.year, .month, .day], from: t)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func digits(_ u: [Unicode.Scalar], _ range: Range<Int>) -> Bool {
        range.allSatisfy { $0 < u.count && isDigit(u[$0]) }
    }

    /// `^\d{4}-\d{2}-\d{2}$` and a real calendar day.
    private static func isDay(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count == 10, digits(u, 0..<4), u[4] == "-", digits(u, 5..<7), u[7] == "-", digits(u, 8..<10) else { return false }
        return realDate(u)
    }

    /// `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$` and a real calendar day.
    private static func isStamp(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count == 16, digits(u, 0..<4), u[4] == "-", digits(u, 5..<7), u[7] == "-", digits(u, 8..<10),
              u[10] == "T", digits(u, 11..<13), u[13] == ":", digits(u, 14..<16) else { return false }
        return realDate(u)
    }

    private static func realDate(_ u: [Unicode.Scalar]) -> Bool {
        let y = Int(String(String.UnicodeScalarView(u[0..<4])))!
        let m = Int(String(String.UnicodeScalarView(u[5..<7])))!
        let d = Int(String(String.UnicodeScalarView(u[8..<10])))!
        guard (1...12).contains(m), d >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= days
    }

    /// `^today(?:([+-])(\d{1,4}))?$`, any case. Returns the day shift.
    private static func relative(_ s: String) -> Int? {
        let u = Array(s.lowercased().unicodeScalars)
        let word = Array("today".unicodeScalars)
        guard u.count >= 5, Array(u[0..<5]) == word else { return nil }
        if u.count == 5 { return 0 }
        guard u[5] == "+" || u[5] == "-", (1...4).contains(u.count - 6), digits(u, 6..<u.count) else { return nil }
        let n = Int(String(String.UnicodeScalarView(u[6...])))!
        return u[5] == "-" ? -n : n
    }

    /// One value into a column's type: the value (`.null` for an empty cell) or why it does not fit.
    public static func cell(_ type: String, _ raw: YLValue, _ ctx: YLTableContext) -> Result<YLValue, YLTableError> {
        var v = raw
        switch v {
        case .null: return .success(.null)
        case .string(let s) where s.isEmpty: return .success(.null)
        case .array(let a): v = .string(a.map(jsString).joined(separator: "|"))
        default: break
        }
        switch type {
        case "text":
            let s = jsString(v)
            if s.utf16.count > YLTableLimits.text { return .failure(.init("text over \(YLTableLimits.text) characters")) }
            return .success(.string(s))
        case "number":
            if case .number(let n) = v { return n.isFinite ? .success(v) : .failure(.init("not a number")) }
            if case .string(let s) = v {
                let t = String(trimJS(Scalars(s.unicodeScalars)))
                if isNumber(t), let n = Double(t) { return .success(.number(n)) }
            }
            return .failure(.init("\"\(jsString(v))\" is not a number"))
        case "date":
            let s = String(trimJS(Scalars(jsString(v).unicodeScalars)))
            if let n = relative(s) { return .success(.string(n == 0 ? ctx.today : shiftDay(ctx.today, n))) }
            if s.lowercased() == "now" { return .success(.string(ctx.now)) }
            if isDay(s) || isStamp(s) { return .success(.string(s)) }
            return .failure(.init("\"\(s)\" is not a date (YYYY-MM-DD, today, today-7, now)"))
        case "bool":
            if case .bool = v { return .success(v) }
            let s = jsString(v).lowercased()
            if ["on", "true", "yes", "1"].contains(s) { return .success(.bool(true)) }
            if ["off", "false", "no", "0"].contains(s) { return .success(.bool(false)) }
            return .failure(.init("\"\(jsString(v))\" is not on or off"))
        default:
            return .failure(.init("unknown type \(type)"))
        }
    }

    // MARK: writes

    /// Applies a `table` or `put` node. On a refusal the store is unchanged.
    public mutating func write(_ node: YLNode, _ ctx: YLTableContext) -> Write {
        switch node.op {
        case .table:
            let cols = (node.props?["cols"]?.array ?? []).map {
                YLTableCol(name: $0["name"]?.string ?? "", type: $0["type"]?.string ?? "", unit: $0["unit"]?.string)
            }
            return create(name: node.name ?? "", cols: cols, ctx)
        case .put:
            let p = node.props ?? [:]
            return put(table: p["table"]?.string ?? "", key: p["key"].map(jsString), values: p["values"]?.object ?? [:],
                       delete: p["delete"]?.bool ?? false, ctx)
        default:
            return .ok(key: nil)
        }
    }

    /// `table create`: make a table, or change an existing one's columns. Columns are matched by
    /// name: kept columns keep their values (a new type converts them and what does not fit is
    /// emptied), removed columns lose theirs, new columns start empty. Rows are never dropped.
    public mutating func create(name: String, cols: [YLTableCol], _ ctx: YLTableContext) -> Write {
        guard YuiLines.isTableName(name), name.count <= YLTableLimits.name else { return .refused("table: bad name \"\(name)\"") }
        if cols.isEmpty { return .refused("table create: needs at least one col:type") }
        if cols.count > YLTableLimits.cols { return .refused("table create: \(YLTableLimits.cols) columns at most") }
        var seen = Set<String>()
        for c in cols {
            if !isIdent(Scalars(c.name.unicodeScalars)) { return .refused("table create: bad column \"\(c.name)\"") }
            if c.name.lowercased() == "key" { return .refused("table create: key is the row key, not a column") }
            if seen.contains(c.name.lowercased()) { return .refused("table create: column \"\(c.name)\" twice") }
            if !tableTypes.contains(c.type) { return .refused("table create: \"\(c.type)\" is not text, number, date or bool") }
            seen.insert(c.name.lowercased())
        }
        guard var t = tables[name] else {
            if tables.count >= YLTableLimits.tables { return .refused("table: \(YLTableLimits.tables) tables per agent at most") }
            tables[name] = YLTable(name: name, cols: cols)
            names.append(name)
            return .ok(key: nil)
        }
        let prev = Dictionary(uniqueKeysWithValues: t.cols.map { ($0.name, $0) })
        for key in t.order {
            let row = t.rows[key] ?? [:]
            var next: [String: YLValue] = [:]
            for c in cols {
                guard let was = prev[c.name], let cur = row[c.name], cur != .null else { continue }
                let v: Result<YLValue, YLTableError> = was.type == c.type ? .success(cur) : Self.cell(c.type, cur, ctx)
                if case .success(let x) = v, x != .null { next[c.name] = x }
            }
            t.rows[key] = next
        }
        t.cols = cols
        tables[name] = t
        return .ok(key: nil)
    }

    /// `put`: upsert one row by key. With no key the store makes one (r1, r2 ...), so a log can
    /// just append. `delete` takes the row out. The whole put is refused when one value is wrong.
    public mutating func put(table: String, key: String?, values: [String: YLValue], delete: Bool, _ ctx: YLTableContext) -> Write {
        guard var t = tables[table] else { return .refused("put: no table \"\(table)\"") }
        if let k = key, k.isEmpty || k.count > YLTableLimits.key { return .refused("put: a key is 1 to \(YLTableLimits.key) characters") }
        if delete {
            guard let k = key else { return .refused("put +delete: needs a key") }
            guard t.rows[k] != nil else { return .ok(key: nil) }
            t.rows[k] = nil
            t.order.removeAll { $0 == k }
            tables[table] = t
            return .ok(key: k)
        }
        let byName = Dictionary(t.cols.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var vals: [(String, YLValue)] = []
        // Same column order the line wrote them in would be nicer, but a dictionary has none: sort for a stable error.
        for (k, v) in values.sorted(by: { $0.key < $1.key }) {
            guard let c = byName[k.lowercased()] else { return .refused("put: \(table) has no column \"\(k)\"") }
            switch Self.cell(c.type, v, ctx) {
            case .failure(let e): return .refused("put: \(c.name): \(e.message)")
            case .success(let x): vals.append((c.name, x))
            }
        }
        var k = key
        if k == nil {
            repeat { k = "r\(t.next)"; t.next += 1 } while t.rows[k!] != nil
        }
        let key = k!
        let had = t.rows[key] != nil
        if !had, t.order.count >= YLTableLimits.rows { return .refused("put: \(table) is full (\(YLTableLimits.rows) rows)") }
        var row = t.rows[key] ?? [:]
        for (c, v) in vals {
            if v == .null { row[c] = nil } else { row[c] = v }
        }
        t.rows[key] = row
        if !had { t.order.append(key) }
        tables[table] = t
        return .ok(key: key)
    }

    /// Replays a parsed reply's `table` and `put` nodes. Returns the line of every refused write
    /// with its reason, in order.
    @discardableResult
    public mutating func replay(_ nodes: [YLNode], _ ctx: YLTableContext) -> [(line: String, message: String)] {
        var refused: [(String, String)] = []
        for n in nodes where n.op == .table || n.op == .put {
            if case .refused(let m) = write(n, ctx) { refused.append((n.line, m)) }
        }
        return refused
    }

    // MARK: query

    private static let clauseOps = [">=", "<=", "!=", "=", ">", "<", "~"]

    /// `^([A-Za-z_][\w-]*)\s*(>=|<=|!=|=|>|<|~)\s*(.*)$` -> (col, op, rest)
    private static func clause(_ s: String) -> (String, String, String)? {
        let u = Scalars(s.unicodeScalars)
        guard let f = u.first, isAlpha(f) || f == "_" else { return nil }
        var i = 1
        while i < u.count, isWordish(u[i]) { i += 1 }
        let col = String(String.UnicodeScalarView(u[0..<i]))
        while i < u.count, isSpace(u[i]) { i += 1 }
        let rest = String(String.UnicodeScalarView(u[i...]))
        for op in clauseOps where rest.hasPrefix(op) {
            var j = i + op.unicodeScalars.count
            while j < u.count, isSpace(u[j]) { j += 1 }
            return (col, op, String(String.UnicodeScalarView(u[j...])))
        }
        return nil
    }

    private static func cmp(_ a: YLValue, _ b: YLValue) -> Int {
        switch (a, b) {
        case (.null, .null): return 0
        case (.null, _): return 1
        case (_, .null): return -1
        case (.number(let x), .number(let y)): return x < y ? -1 : x > y ? 1 : 0
        case (.bool(let x), .bool(let y)): return (x ? 1 : 0) - (y ? 1 : 0)
        default:
            switch jsString(a).compare(jsString(b), options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
    }

    private static func list(_ v: YLValue?) -> [String] {
        guard let v else { return [] }
        let items: [YLValue]
        switch v {
        case .bool: return []
        case .array(let a): items = a
        default: items = [v]
        }
        return items.map(jsString).filter { !$0.isEmpty }
    }

    private static func round6(_ n: Double) -> Double { (n * 1e6).rounded() / 1e6 }

    private struct Row {
        var key: String?
        var cells: [String: YLValue]
        func value(_ name: String) -> YLValue? { name == "key" && key != nil ? .string(key!) : cells[name] }
    }

    /// Runs a query's props against the store.
    public func query(_ props: [String: YLValue], _ ctx: YLTableContext) -> YLQueryOutcome {
        let name = props["table"]?.string ?? ""
        guard let t = tables[name] else { return .missing(name) }
        func colOf(_ n: String) -> YLTableCol? {
            if n.lowercased() == "key" { return YLTableCol(name: "key", type: "text") }
            return t.cols.first { $0.name.lowercased() == n.lowercased() }
        }
        // where: every clause must hold.
        var tests: [(Row) -> Bool] = []
        for w in Self.list(props["where"]) {
            guard let (cn, op, raw0) = Self.clause(w) else { return .error("where: cannot read \"\(w)\"") }
            guard let c = colOf(cn) else { return .error("where: no column \"\(cn)\"") }
            let raw = String(trimJS(Scalars(raw0.unicodeScalars)))
            if raw.isEmpty {
                if op != "=" && op != "!=" { return .error("where: \"\(w)\" needs a value") }
                tests.append { r in ((r.value(c.name) ?? .null) == .null) == (op == "=") }
                continue
            }
            var want: YLValue
            if op == "~" { want = .string(raw.lowercased()) } else {
                switch Self.cell(c.type, .string(raw), ctx) {
                case .failure(let e): return .error("where: \(c.name): \(e.message)")
                case .success(let x): want = x
                }
            }
            // A date with no time compares by day, so Day=today holds for a stamp at 12:30 today.
            let byDay = c.type == "date" && want.string?.count == 10
            tests.append { r in
                guard var v = r.value(c.name), v != .null else { return op == "!=" }
                if byDay { v = .string(String(jsString(v).prefix(10))) }
                if op == "~" { return jsString(v).lowercased().contains(want.string ?? "") }
                let d = Self.cmp(v, want)
                switch op {
                case "=": return d == 0
                case "!=": return d != 0
                case ">": return d > 0
                case "<": return d < 0
                case ">=": return d >= 0
                default: return d <= 0
                }
            }
        }
        var rows: [Row] = t.order.map { k in
            var cells = t.rows[k] ?? [:]
            cells["key"] = nil
            return Row(key: k, cells: cells)
        }.filter { r in tests.allSatisfy { $0(r) } }

        // Aggregates: group=Col and sum/avg/min/max=Col|Col, +count.
        var cols: [YLTableCol]
        var keyed = true
        var aggs: [(a: String, n: String)] = []
        for a in ["sum", "avg", "min", "max"] { aggs += Self.list(props[a]).map { (a, $0) } }
        let groupName = props["group"].map(jsString) ?? ""
        let wantsCount = (props["count"].map { v -> Bool in
            switch v { case .null: false; case .bool(let b): b; case .string(let s): !s.isEmpty; case .number(let n): n != 0; default: true }
        }) ?? false
        if !aggs.isEmpty || wantsCount || props["group"] != nil {
            keyed = false
            let g = groupName.isEmpty ? nil : colOf(groupName)
            if !groupName.isEmpty, g == nil { return .error("group: no column \"\(groupName)\"") }
            struct Out { var col: YLTableCol; var from: String?; var a: String? }
            var out: [Out] = []
            if let g { out.append(Out(col: g, from: g.name, a: nil)) }
            var used = Set(out.map { $0.col.name.lowercased() })
            for (a, n) in aggs {
                guard let c = colOf(n) else { return .error("\(a): no column \"\(n)\"") }
                if c.type != "number", a == "sum" || a == "avg" { return .error("\(a): \(c.name) is not a number column") }
                let label = used.contains(c.name.lowercased()) ? "\(a) \(c.name)" : c.name
                used.insert(label.lowercased())
                out.append(Out(col: YLTableCol(name: label, type: c.type, unit: c.unit), from: c.name, a: a))
            }
            if wantsCount { out.append(Out(col: YLTableCol(name: "Count", type: "number"), from: nil, a: "count")) }
            var groups: [[Row]] = []
            var index: [YLValue: Int] = [:]
            for r in rows {
                let gk: YLValue = g.map { r.value($0.name) ?? .null } ?? .null
                if let i = index[gk] { groups[i].append(r) } else { index[gk] = groups.count; groups.append([r]) }
            }
            if g == nil, groups.isEmpty { groups = [[]] }
            rows = groups.map { list in
                var cells: [String: YLValue] = [:]
                for o in out {
                    switch o.a {
                    case nil: cells[o.col.name] = list[0].value(o.from!) ?? .null
                    case "count": cells[o.col.name] = .number(Double(list.count))
                    default:
                        let vs = list.compactMap { r -> YLValue? in
                            guard let v = r.value(o.from!), v != .null else { return nil }
                            return v
                        }
                        if vs.isEmpty { cells[o.col.name] = o.a == "sum" ? .number(0) : .null; continue }
                        switch o.a {
                        case "sum": cells[o.col.name] = .number(Self.round6(vs.reduce(0) { $0 + ($1.number ?? 0) }))
                        case "avg": cells[o.col.name] = .number(Self.round6(vs.reduce(0) { $0 + ($1.number ?? 0) } / Double(vs.count)))
                        default:
                            let isMin = o.a == "min"
                            cells[o.col.name] = vs.dropFirst().reduce(vs[0]) { best, v in (isMin ? Self.cmp(v, best) < 0 : Self.cmp(v, best) > 0) ? v : best }
                        }
                    }
                }
                return Row(key: nil, cells: cells)
            }
            cols = out.map(\.col)
        } else {
            let pick = Self.list(props["cols"])
            if pick.isEmpty { cols = t.cols } else {
                cols = []
                for n in pick {
                    guard let c = colOf(n) else { return .error("cols: no column \"\(n)\"") }
                    cols.append(c)
                }
            }
        }

        // sort=Col|-Col: a minus sorts that column high to low. Empty cells go last.
        var sorts: [(name: String, desc: Bool)] = []
        for s in Self.list(props["sort"]) {
            let desc = s.hasPrefix("-")
            let n = desc ? String(s.dropFirst()) : s
            let c = keyed ? colOf(n) : cols.first { $0.name.lowercased() == n.lowercased() }
            guard let c else { return .error("sort: no column \"\(n)\"") }
            sorts.append((c.name, desc))
        }
        if !sorts.isEmpty {
            rows = rows.enumerated().sorted { x, y in
                for (n, desc) in sorts {
                    let a = x.element.value(n) ?? .null, b = y.element.value(n) ?? .null
                    if a == .null || b == .null {
                        if a == .null && b == .null { continue }
                        return b == .null
                    }
                    let d = Self.cmp(a, b)
                    if d != 0 { return desc ? d > 0 : d < 0 }
                }
                return x.offset < y.offset
            }.map(\.element)
        }
        let count = rows.count
        var lim = YLTableLimits.limit
        if let l = props["limit"], let n = Double(jsString(l)), jsString(l) != "", n.isFinite { lim = Int(n.rounded(.down)) }
        lim = max(0, min(YLTableLimits.maxLimit, lim))
        rows = Array(rows.prefix(lim))
        return .rows(YLTableResult(
            cols: cols,
            rows: rows.map { r in cols.map { r.value($0.name) ?? .null } },
            keys: rows.map { keyed ? $0.key : nil },
            count: count
        ))
    }

    /// The tables in the shape the table and chart renderers bind to (`table meals`,
    /// `chart data=meals`): cols, rows (an empty cell is ""), units.
    public func bound() -> [String: (cols: [String], rows: [[YLValue]], units: [String])] {
        var out: [String: (cols: [String], rows: [[YLValue]], units: [String])] = [:]
        for (name, t) in tables {
            out[name] = (t.cols.map(\.name),
                         t.order.map { k in t.cols.map { t.rows[k]?[$0.name] ?? .string("") } },
                         t.cols.map { $0.unit ?? "" })
        }
        return out
    }
}

public struct YLTableError: Error, Sendable, Equatable {
    public var message: String
    init(_ m: String) { message = m }
}
