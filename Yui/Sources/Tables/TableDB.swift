import Foundation
import SQLite3
import YuiLines

/// One agent's tables in one SQLite file (spec TABLES.md section 4, YUI-89). The file lives in
/// the app's own Application Support: never a `yui_` table, never in a push, never on the relay.
///
///   tbl(name, cols, next, pos)        one row per table, `cols` is JSON, `pos` is the order made
///   row(tbl, key, pos, vals)          one row per table row, `vals` is JSON, `pos` the order written
///   applied(id, at)                   reply ids whose lines were already written, so a reply that
///                                     loads twice (history, a second device read) writes once
final class TableDB {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 2000)
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS tbl(name TEXT PRIMARY KEY, cols TEXT NOT NULL, next INTEGER NOT NULL, pos INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS row(tbl TEXT NOT NULL, key TEXT NOT NULL, pos INTEGER NOT NULL, vals TEXT NOT NULL, PRIMARY KEY(tbl, key));
        CREATE INDEX IF NOT EXISTS row_pos ON row(tbl, pos);
        CREATE TABLE IF NOT EXISTS applied(id TEXT PRIMARY KEY, at REAL NOT NULL);
        """)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func run(_ sql: String, _ args: [Bind] = [], each: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            switch a {
            case .text(let s): sqlite3_bind_text(st, Int32(i + 1), s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(st, Int32(i + 1), Int64(n))
            case .real(let d): sqlite3_bind_double(st, Int32(i + 1), d)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { each?(st) }
    }

    private enum Bind { case text(String), int(Int), real(Double) }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    private static func json(_ v: YLValue) -> String { v.jsonString }

    // MARK: Read

    func load() -> YLTables {
        var store = YLTables()
        run("SELECT name, cols, next FROM tbl ORDER BY pos") { st in
            let name = Self.text(st, 0)
            let cols = ((try? YLValue.parseJSON(Self.text(st, 1)))?.array ?? []).map {
                YLTableCol(name: $0["name"]?.string ?? "", type: $0["type"]?.string ?? "text", unit: $0["unit"]?.string)
            }
            store.tables[name] = YLTable(name: name, cols: cols, next: Int(sqlite3_column_int64(st, 2)))
            store.names.append(name)
        }
        run("SELECT tbl, key, vals FROM row ORDER BY tbl, pos") { st in
            let t = Self.text(st, 0), k = Self.text(st, 1)
            guard store.tables[t] != nil else { return }
            store.tables[t]!.rows[k] = (try? YLValue.parseJSON(Self.text(st, 2)))?.object ?? [:]
            store.tables[t]!.order.append(k)
        }
        return store
    }

    func wasApplied(_ id: String) -> Bool {
        var found = false
        run("SELECT 1 FROM applied WHERE id = ?", [.text(id)]) { _ in found = true }
        return found
    }

    // MARK: Write

    func markApplied(_ id: String) {
        run("INSERT OR IGNORE INTO applied(id, at) VALUES (?, ?)", [.text(id), .real(Date().timeIntervalSince1970)])
        // Keep the newest 2,000: a reply older than that is not loaded again.
        run("DELETE FROM applied WHERE id NOT IN (SELECT id FROM applied ORDER BY at DESC LIMIT 2000)")
    }

    /// A table made or changed: its meta and every row, in one transaction.
    func save(_ t: YLTable, pos: Int) {
        exec("BEGIN")
        run("INSERT OR REPLACE INTO tbl(name, cols, next, pos) VALUES (?, ?, ?, ?)",
            [.text(t.name), .text(Self.json(.array(t.cols.map(\.value)))), .int(t.next), .int(pos)])
        run("DELETE FROM row WHERE tbl = ?", [.text(t.name)])
        for (i, k) in t.order.enumerated() {
            run("INSERT INTO row(tbl, key, pos, vals) VALUES (?, ?, ?, ?)",
                [.text(t.name), .text(k), .int(i), .text(Self.json(.object(t.rows[k] ?? [:])))])
        }
        exec("COMMIT")
    }

    /// One row written (or, with `values` nil, taken out), and the table's key counter.
    func saveRow(_ table: String, key: String, values: [String: YLValue]?, next: Int) {
        exec("BEGIN")
        if let values {
            // An update keeps its place; a new row goes after the last one written.
            var pos = 0
            var had = false
            run("SELECT pos FROM row WHERE tbl = ? AND key = ?", [.text(table), .text(key)]) { st in
                pos = Int(sqlite3_column_int64(st, 0)); had = true
            }
            if !had { run("SELECT COALESCE(MAX(pos), -1) + 1 FROM row WHERE tbl = ?", [.text(table)]) { pos = Int(sqlite3_column_int64($0, 0)) } }
            run("INSERT OR REPLACE INTO row(tbl, key, pos, vals) VALUES (?, ?, ?, ?)",
                [.text(table), .text(key), .int(pos), .text(Self.json(.object(values)))])
        } else {
            run("DELETE FROM row WHERE tbl = ? AND key = ?", [.text(table), .text(key)])
        }
        run("UPDATE tbl SET next = ? WHERE name = ?", [.int(next), .text(table)])
        exec("COMMIT")
    }
}
