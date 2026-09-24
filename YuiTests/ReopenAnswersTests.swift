import XCTest
import YuiLines
@testable import Yui

/// Reopening a thread (TestFlight: answered components came back blank). The
/// store rebuilds each component's answer from the thread's own event rows,
/// newest per id, filed under the reply that drew it.
@MainActor
final class ReopenAnswersTests: XCTestCase {
    static func agent(_ id: String, _ yl: String) -> ThreadRow {
        ThreadRow(id: id, sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: "")
    }

    static func event(_ id: String, _ yl: String, _ preset: String, _ value: [String: YLValue], echo: String?) -> ThreadRow {
        var meta: [String: YLValue] = ["id": .string(yl), "preset": .string(preset), "value": .object(value)]
        if let echo { meta["echo"] = .string(echo) }
        return ThreadRow(id: id, sender: "user", body: "[yui] \(yl) \(preset)", kind: "event", meta: .object(meta), createdAt: "")
    }

    /// Reply 1 draws choose/pick/slide/ask/form as n1..n5; reply 2 reuses `n1`.
    static let rows: [ThreadRow] = [
        agent("r1", """
        choose "Which split today?" Push|Pull|Legs
        pick "What gear do you have?" Dumbbells|Bench|Bands|Kettlebell
        slide "Energy" 1-5
        ask "Send the invite now?" "Yes, send"|"Not yet"
        form "Quick one" name! reps:number
        """),
        event("e1", "n1", "choose", ["choice": .string("Push")], echo: "Push"),
        event("e2", "n1", "choose", ["choice": .string("Pull"), "changed": .bool(true)], echo: "Pull"),
        event("e3", "n2", "pick", ["picked": .array([.string("Bench"), .string("Bands")])], echo: "Bench, Bands"),
        event("e4", "n3", "slide", ["value": .number(4)], echo: "4"),
        event("e5", "n4", "ask", ["answer": .string("Not yet")], echo: "Not yet"),
        event("e6", "n5", "form", ["form": .object(["name": .string("Chris"), "reps": .number(12)])], echo: "name: Chris"),
        agent("r2", #"choose "Coffee or tea?" Coffee|Tea"#),
        event("e7", "n1", "choose", ["choice": .string("Tea")], echo: "Tea"),
    ]

    func testReopenRestoresEveryAnswer() {
        // A fresh store is a reopened thread: nothing but the rows.
        let store = ChatStore()
        store.load(Self.rows)
        XCTAssertEqual(store.ylAnswers("r1#0", "n1")?["choice"], .string("Pull"), "newest choose answer wins")
        XCTAssertEqual(store.ylAnswers("r1#0", "n2")?["picked"], .array([.string("Bench"), .string("Bands")]))
        XCTAssertEqual(store.ylAnswers("r1#0", "n3")?["value"], .number(4))
        XCTAssertEqual(store.ylAnswers("r1#0", "n4")?["answer"], .string("Not yet"))
        XCTAssertEqual(store.ylAnswers("r1#0", "n5")?["form"]?.object?["reps"], .number(12))
    }

    func testRepeatedIDBelongsToTheReplyBeforeIt() {
        let store = ChatStore()
        store.load(Self.rows)
        // `n1` in reply 2 got Tea; reply 1's `n1` keeps Pull.
        XCTAssertEqual(store.ylAnswers("r2#0", "n1")?["choice"], .string("Tea"))
        XCTAssertEqual(store.ylAnswers("r1#0", "n1")?["choice"], .string("Pull"))
    }

    func testPollOverlapDoesNotReplayAnOldAnswer() {
        let store = ChatStore()
        store.load(Self.rows)
        // Polls overlap by 10 s: e1 (Push) comes round again and must not win.
        store.load([Self.rows[1]])
        XCTAssertEqual(store.ylAnswers("r1#0", "n1")?["choice"], .string("Pull"))
    }

    func testLiveTapsRecordAndQuietEventsDoNot() {
        let store = ChatStore()
        store.load(Array(Self.rows.prefix(1)))
        let n1 = store.messages[0].yl!.components[0]
        store.receive(n1.answer(["choice": .string("Legs")], echo: "Legs", changed: false))
        XCTAssertEqual(store.ylAnswers("r1#0", "n1")?["choice"], .string("Legs"))
        // A quiet event under the same id (a gallery `open`) is not an answer.
        store.receive(n1.event(["open": .bool(true)]))
        XCTAssertEqual(store.ylAnswers("r1#0", "n1")?["choice"], .string("Legs"))
    }

    func testUnansweredStaysBlank() {
        let store = ChatStore()
        store.load(Array(Self.rows.prefix(1)))
        XCTAssertNil(store.ylAnswers("r1#0", "n1"))
    }
}
