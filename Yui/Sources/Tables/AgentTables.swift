import Foundation
import Observation
import YuiLines

/// An agent's tables on the phone (TABLES.md, YUI-89): the pure store from YuiLines, kept in
/// memory and written through to one SQLite file. Views read `tables`, so a put redraws every
/// query on screen.
@Observable @MainActor
final class AgentTableStore {
    let agentID: String
    private(set) var tables = YLTables()
    @ObservationIgnored private let db: TableDB?

    init(agentID: String, file: URL?) {
        self.agentID = agentID
        db = file.flatMap { TableDB(url: $0) }
        if let db { tables = db.load() }
    }

    /// A refused write, to tell the agent once (TABLES.md section 3, event 1).
    struct Refusal: Equatable { let line: String; let message: String; let table: String; let key: String? }

    /// Writes a reply's `table create` and `put` lines. `reply` is the message id: a reply whose lines
    /// already landed (a thread that loads twice) writes nothing again. Returns what was refused.
    @discardableResult
    func apply(_ nodes: [YLNode], reply: String? = nil, ctx: YLTableContext = YLTableContext()) -> [Refusal] {
        let writes = nodes.filter { $0.op == .table || $0.op == .put }
        guard !writes.isEmpty else { return [] }
        if let reply, let db {
            if db.wasApplied(reply) { return [] }
            db.markApplied(reply)
        }
        var out: [Refusal] = []
        for n in writes {
            if case .refused(let m) = write(n, ctx: ctx) {
                out.append(Refusal(line: n.line, message: m, table: n.props?["table"]?.string ?? n.name ?? "",
                                   key: n.props?["key"].map(jsText)))
            }
        }
        return out
    }

    /// One write, kept on disk when it lands.
    @discardableResult
    func write(_ node: YLNode, ctx: YLTableContext = YLTableContext()) -> YLTables.Write {
        let r = tables.write(node, ctx)
        guard case .ok(let key) = r else { return r }
        if node.op == .table {
            if let t = tables.tables[node.name ?? ""], let pos = tables.names.firstIndex(of: t.name) { db?.save(t, pos: pos) }
        } else if let table = node.props?["table"]?.string, let t = tables.tables[table], let key {
            db?.saveRow(table, key: key, values: t.rows[key], next: t.next)
        }
        return r
    }

    /// The person changed a row in a view (a tick): written the way a `put` would, with no reply.
    func set(table: String, key: String, values: [String: YLValue]) {
        let node = YLNode(op: .put, screen: "1", props: ["table": .string(table), "key": .string(key), "values": .object(values)],
                          line: "put \(table) \(key)")
        write(node)
    }

    /// Tables with their row counts, for the agent's settings.
    var summary: [(name: String, rows: Int, cols: Int)] {
        tables.names.compactMap { n in tables.tables[n].map { (n, $0.order.count, $0.cols.count) } }
    }

    func query(_ props: [String: YLValue]) -> YLQueryOutcome { tables.query(props, YLTableContext()) }

    private func jsText(_ v: YLValue) -> String { v.string ?? v.number.map(YLComponent.format) ?? "" }
}

/// Every agent's table store, one file each in Application Support (never on the relay).
@MainActor
final class AgentTables {
    static let shared = AgentTables(directory: defaultDirectory)

    private let directory: URL?
    private var stores: [String: AgentTableStore] = [:]

    init(directory: URL?) { self.directory = directory }

    nonisolated static var defaultDirectory: URL? {
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "yuiTablesDir") { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YuiTables", isDirectory: true)
    }

    private func file(_ agent: String) -> URL? {
        let safe = agent.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return directory?.appendingPathComponent("\(safe).sqlite")
    }

    /// An agent with no id (a paste box, a preview) gets a store that lives only in memory.
    func store(_ agent: String) -> AgentTableStore {
        if let s = stores[agent] { return s }
        let s = AgentTableStore(agentID: agent, file: agent.isEmpty ? nil : file(agent))
        stores[agent] = s
        return s
    }

    /// Removing an agent removes its tables (TABLES.md section 4).
    func remove(_ agent: String) {
        stores[agent] = nil
        guard let f = file(agent) else { return }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.path + suffix) }
    }

    /// Deleting the account removes every agent's tables.
    func removeAll() {
        stores = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// An agent's table as the component the table and chart presets bind to (`table meals`,
    /// `chart data=meals`), or nil when the agent has no such table.
    func bound(_ name: String, agent: String) -> YLComponent? {
        let s = store(agent)
        guard let t = s.tables.tables[name] else { return nil }
        let rows: [YLValue] = t.order.map { k in .array(t.cols.map { t.rows[k]?[$0.name] ?? .string("") }) }
        return YLComponent(serial: -1, ylID: name, preset: "table", screen: "1", props: [
            "name": .string(name),
            "cols": .array(t.cols.map { .string($0.name) }),
            "rows": .array(rows),
            "units": .array(t.cols.map { .string($0.unit ?? "") }),
        ], line: "table \(name)")
    }
}
