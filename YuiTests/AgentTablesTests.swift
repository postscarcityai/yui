import XCTest
import YuiLines
@testable import Yui

/// Agent tables on the phone (YUI-89, spec TABLES.md): the store behind `table create`, `put` and
/// `query`, kept in one SQLite file per agent. The parser and query rules are the shared vectors
/// (Packages/YuiLines, 30-tables.json); these cover what is the phone's own: the file, the limits,
/// one write per reply, and delete.
@MainActor
final class AgentTablesTests: XCTestCase {
    private var dir: URL!
    private let ctx = YLTableContext(today: "2026-10-01", now: "2026-10-01T09:30")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("yui-tables-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func hub() -> AgentTables { AgentTables(directory: dir) }

    private func lines(_ text: String) -> [YLNode] { YuiLines.parse(text) }

    private func rows(_ s: AgentTableStore, _ q: String) -> [[YLValue]] {
        guard let node = lines(q).first, case .rows(let r) = s.query(node.props ?? [:]) else { return [] }
        return r.rows
    }

    func testRowsSurviveAKillAndRelaunch() {
        let a = hub().store("arnold")
        a.apply(lines("""
        table create lifts Day:date Lift:text Weight:number:lb Done:bool
        put lifts squat Day=today Lift=Squat Weight=235 +Done
        put lifts Lift=Bench Weight=185
        """), ctx: ctx)
        // A second hub on the same directory is a fresh launch: nothing in memory.
        let b = hub().store("arnold")
        XCTAssertEqual(rows(b, "query lifts"), [
            [.string("2026-10-01"), .string("Squat"), .number(235), .bool(true)],
            [.null, .string("Bench"), .number(185), .null],
        ])
        XCTAssertEqual(b.summary.map(\.name), ["lifts"])
        XCTAssertEqual(b.summary.first?.rows, 2)
        // Keyless puts keep counting after a relaunch: r1 was taken, so the next is r2.
        b.apply(lines("put lifts Lift=Row Weight=135"), ctx: ctx)
        XCTAssertEqual(hub().store("arnold").tables.tables["lifts"]?.order, ["squat", "r1", "r2"])
    }

    func testDeleteAndSchemaChangePersist() {
        let a = hub().store("basil")
        a.apply(lines("""
        table create meals Food:text Cal:number
        put meals a Food=Oats Cal=300
        put meals b Food=Eggs Cal=140
        put meals a +delete
        table create meals Food:text Cal:text Fat:number
        """), ctx: ctx)
        let b = hub().store("basil")
        XCTAssertEqual(rows(b, "query meals"), [[.string("Eggs"), .string("140"), .null]])
    }

    func testAReplyWritesOnce() {
        let s = hub().store("arnold")
        let nodes = lines("table create log Note:text\nput log Note=one")
        s.apply(nodes, reply: "row1#0", ctx: ctx)
        s.apply(nodes, reply: "row1#0", ctx: ctx)
        XCTAssertEqual(rows(s, "query log").count, 1)
        // And after a relaunch the same reply (the thread loads again) still writes nothing.
        let again = hub().store("arnold")
        again.apply(nodes, reply: "row1#0", ctx: ctx)
        XCTAssertEqual(rows(again, "query log").count, 1)
        again.apply(lines("put log Note=two"), reply: "row2#0", ctx: ctx)
        XCTAssertEqual(rows(again, "query log").count, 2)
    }

    func testARefusedLineIsReportedAndWritesNothing() {
        let s = hub().store("arnold")
        let refused = s.apply(lines("""
        table create meals Food:text Cal:number
        put meals x Food=Soup Cal=lots
        put nope Food=Soup
        """), ctx: ctx)
        XCTAssertEqual(refused.map(\.line), ["put meals x Food=Soup Cal=lots", "put nope Food=Soup"])
        XCTAssertEqual(refused.first?.key, "x")
        XCTAssertEqual(refused.first?.table, "meals")
        XCTAssertTrue(rows(s, "query meals").isEmpty)
    }

    func testLimits() {
        let s = hub().store("arnold")
        // 20 tables per agent
        for i in 1...20 { XCTAssertTrue(s.apply(lines("table create t\(i) A:text"), ctx: ctx).isEmpty) }
        XCTAssertEqual(s.apply(lines("table create t21 A:text"), ctx: ctx).count, 1)
        // 12 columns per table
        let wide = (1...13).map { "C\($0):text" }.joined(separator: " ")
        XCTAssertEqual(s.apply(lines("table create wide \(wide)"), ctx: ctx).count, 1)
        // 64-character keys, 1,000-character cells
        XCTAssertEqual(s.apply(lines("put t1 \(String(repeating: "k", count: 65)) A=x"), ctx: ctx).count, 1)
        XCTAssertEqual(s.apply(lines("put t1 k A=\(String(repeating: "x", count: 1001))"), ctx: ctx).count, 1)
        XCTAssertTrue(s.apply(lines("put t1 k A=\(String(repeating: "x", count: 1000))"), ctx: ctx).isEmpty)
        // 5,000 rows per table
        var store = s.tables
        for i in 0..<YLTableLimits.rows {
            _ = store.put(table: "t2", key: "k\(i)", values: ["A": .string("x")], delete: false, ctx)
        }
        XCTAssertEqual(store.tables["t2"]?.order.count, 5000)
        guard case .refused = store.put(table: "t2", key: "over", values: ["A": .string("x")], delete: false, ctx) else {
            return XCTFail("the 5,001st row was written")
        }
        // A query shows 50 rows unless it asks, and never more than 500.
        guard case .rows(let r) = store.query(["table": .string("t2")], ctx), case .rows(let big) = store.query(["table": .string("t2"), "limit": .number(9000)], ctx)
        else { return XCTFail("no rows") }
        XCTAssertEqual(r.rows.count, 50)
        XCTAssertEqual(r.count, 5000)
        XCTAssertEqual(big.rows.count, 500)
    }

    func testRemovingAnAgentRemovesItsTables() {
        let h = hub()
        h.store("arnold").apply(lines("table create a A:text\nput a A=1"), ctx: ctx)
        h.store("basil").apply(lines("table create b A:text"), ctx: ctx)
        h.remove("arnold")
        XCTAssertTrue(hub().store("arnold").tables.tables.isEmpty)
        XCTAssertEqual(hub().store("basil").summary.map(\.name), ["b"])
        h.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(hub().store("basil").tables.tables.isEmpty)
    }

    func testATickWritesTheRowOnThePhone() {
        let s = hub().store("arnold")
        s.apply(lines("table create todo Task:text Done:bool\nput todo t1 Task=Squat Done=off"), ctx: ctx)
        s.set(table: "todo", key: "t1", values: ["Done": .bool(true)])
        XCTAssertEqual(rows(hub().store("arnold"), "query todo where=Done=on cols=Task"), [[.string("Squat")]])
    }

    func testBoundTablesDrawFromTheStore() {
        let h = hub()
        h.store("arnold").apply(lines("table create meals Day:date Cal:number:kcal\nput meals Day=2026-10-01 Cal=300"), ctx: ctx)
        let t = h.bound("meals", agent: "arnold")
        XCTAssertEqual(t?.strings("cols"), ["Day", "Cal"])
        XCTAssertEqual(t?.strings("units"), ["", "kcal"])
        XCTAssertEqual(t?.props["rows"], .array([.array([.string("2026-10-01"), .number(300)])]))
        XCTAssertNil(h.bound("ghosts", agent: "arnold"))
    }

    func testShortDates() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026
        XCTAssertEqual(QueryShow.day("2026-09-26", now: now), "Sep 26")
        XCTAssertEqual(QueryShow.day("2026-09-26T12:30", now: now), "Sep 26, 12:30")
        XCTAssertEqual(QueryShow.day("2025-01-05", now: now), "Jan 5 2025")
        XCTAssertEqual(QueryShow.day("soon", now: now), "soon")
    }
}
