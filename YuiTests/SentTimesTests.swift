import XCTest
@testable import Yui

/// When each message was sent (YUI-202): day dividers where the day changes, one quiet time per run.
final class SentTimesTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func msg(_ id: String, user: Bool, _ at: Date) -> ChatMessage {
        ChatMessage(id: id, text: id, fromUser: user, sentAt: at)
    }

    func testDayLabels() {
        let now = date(29, 11, 30)
        XCTAssertEqual(SentTimes.dayLabel(date(29, 7, 0), now: now, calendar: cal), "Today")
        XCTAssertEqual(SentTimes.dayLabel(date(28, 23, 59), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(SentTimes.dayLabel(date(26, 9, 0), now: now, calendar: cal), "Sat, Sep 26")
        XCTAssertTrue(SentTimes.dayLabel(date(26, 9, 0, year: 2025), now: now, calendar: cal).contains("2025"))
    }

    func testOneDividerPerDayAndOneTimePerRun() {
        let now = date(29, 12, 0)
        let list = [msg("a", user: true, date(27, 9, 0)), msg("b", user: false, date(27, 9, 1)),
                    msg("c", user: false, date(27, 9, 2)),
                    msg("d", user: true, date(29, 7, 0)), msg("e", user: false, date(29, 9, 30))]
        let m = SentTimes.marks(list, now: now, calendar: cal)
        XCTAssertEqual(m.day["a"], "Sun, Sep 27")
        XCTAssertNil(m.day["b"])
        XCTAssertEqual(m.day["d"], "Today")
        XCTAssertNil(m.day["e"])
        XCTAssertNotNil(m.time["a"], "b comes from the other side, so a's run ends")
        XCTAssertNil(m.time["b"], "b and c are one run: the time sits under c")
        XCTAssertNotNil(m.time["c"])
        XCTAssertNotNil(m.time["d"], "the day changes after d")
        XCTAssertNotNil(m.time["e"])
    }

    func testStoppedNotesDrawNothing() {
        var s = msg("s", user: false, date(29, 9, 0)); s.stopped = true
        let m = SentTimes.marks([msg("a", user: true, date(29, 8, 0)), s], now: date(29, 12, 0), calendar: cal)
        XCTAssertNil(m.day["s"]); XCTAssertNil(m.time["s"])
        XCTAssertNotNil(m.time["a"])
    }

    func testStageStamp() {
        let s = SentTimes.stamp(date(28, 16, 12), now: date(29, 12, 0), calendar: cal)
        XCTAssertTrue(s.hasPrefix("Yesterday, "), s)
    }
}
