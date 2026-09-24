import XCTest
@testable import Yui

/// The timer on the lock screen (YUI-30): what the Live Activity shows for a
/// timer plan at a moment, and that it round-trips through ActivityKit's JSON.
@MainActor
final class LiveTimerTests: XCTestCase {
    typealias State = TimerActivityAttributes.ContentState
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tabata = TimerPlan(work: 20, rest: 10, rounds: 8, up: false)

    func testWorkPhaseWindow() {
        let s = State.make(plan: tabata, elapsed: 5, running: true, now: now)
        XCTAssertEqual(s.phase, .work)
        XCTAssertEqual(s.round, 1)
        XCTAssertEqual(s.start, now.addingTimeInterval(-5))
        XCTAssertEqual(s.end, now.addingTimeInterval(15))
        XCTAssertEqual(s.shown, 15)
        XCTAssertEqual(s.progress, 0.25, accuracy: 1e-9)
        // 8 x 20 work + 7 x 10 rest = 230s, 5 gone.
        XCTAssertEqual(s.finish, now.addingTimeInterval(225))
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.label, "Work")
    }

    func testRestAndLaterRounds() {
        let rest = State.make(plan: tabata, elapsed: 24, running: true, now: now)
        XCTAssertEqual(rest.phase, .rest)
        XCTAssertEqual(rest.round, 1)
        XCTAssertEqual(rest.start, now.addingTimeInterval(-4))
        XCTAssertEqual(rest.end, now.addingTimeInterval(6))

        let third = State.make(plan: tabata, elapsed: 61, running: true, now: now)
        XCTAssertEqual(third.phase, .work)
        XCTAssertEqual(third.round, 3)
        XCTAssertEqual(third.end, now.addingTimeInterval(19))

        // The last round has no rest after it.
        let last = State.make(plan: tabata, elapsed: 229, running: true, now: now)
        XCTAssertEqual(last.phase, .work)
        XCTAssertEqual(last.round, 8)
        XCTAssertEqual(last.end, now.addingTimeInterval(1))
    }

    func testPausedKeepsTheReading() {
        let s = State.make(plan: tabata, elapsed: 35, running: false, now: now)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.round, 2)
        XCTAssertEqual(s.shown, 15)
        XCTAssertEqual(s.progress, 0.25, accuracy: 1e-9)
        XCTAssertEqual(TimerActivityAttributes.clock(s.shown, up: false), "0:15")
    }

    func testDone() {
        let s = State.make(plan: tabata, elapsed: 230, running: true, now: now)
        XCTAssertEqual(s.phase, .done)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.round, 8)
        XCTAssertEqual(s.label, "Done!")
    }

    func testStopwatchCountsUpFromItsStart() {
        let s = State.make(plan: TimerPlan(work: 60, rest: 0, rounds: 1, up: true), elapsed: 75, running: true, now: now)
        XCTAssertEqual(s.phase, .up)
        XCTAssertEqual(s.start, now.addingTimeInterval(-75))
        XCTAssertGreaterThan(s.end, now.addingTimeInterval(3600))
        XCTAssertEqual(TimerActivityAttributes.clock(3725, up: true), "1:02:05")
        // work 0 is a stopwatch too, not a timer that is done before it starts.
        XCTAssertEqual(State.make(plan: TimerPlan(work: 0, rest: 0, rounds: 1, up: false), elapsed: 3, running: true, now: now).phase, .up)
    }

    func testAttributesRoundTripAndStaySmall() throws {
        let a = TimerActivityAttributes(id: "m1#3", label: "Tabata", rounds: 8, up: false,
                                        palette: YuiTheme.yui.dark, design: "rounded")
        let s = State.make(plan: tabata, elapsed: 5, running: true, now: now)
        let aData = try JSONEncoder().encode(a), sData = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: sData), s)
        let back = try JSONDecoder().decode(TimerActivityAttributes.self, from: aData)
        XCTAssertEqual(back.palette, YuiTheme.yui.dark)
        XCTAssertEqual(back.id, "m1#3")
        // ActivityKit caps attributes + state at 4 KB.
        XCTAssertLessThan(aData.count + sData.count, 4096)
    }

    func testBeepToneIsAValidWav() {
        let d = TimerAudio.wav(hz: 880, seconds: 0.1, volume: 0.5)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(d.count, 44 + 4410 * 2)
    }
}
