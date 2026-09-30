import XCTest
import YuiLines
@testable import Yui

/// The timed session's clock (YUI-220): a schedule of work sets and rests that moves on
/// by itself, the optional buttons, the failure set that waits for Stop, and a place
/// that survives a relaunch. Pure: dates are passed in, nothing waits.
@MainActor
final class WorkoutSessionTests: XCTestCase {
    /// As runtime/src/workouts.ts runnerLines sends it for a heavy lifter: cues, work seconds, +fail.
    static let heavy = """
    plan@wk-20260930-wed Upper submit="Finish workout"
    page "Upper" body="2 moves, about 45 minutes. Rest about 60 seconds between sets." points="Bench press 3x8"|"Plank 1x30s"
    pick@e1-sets "Bench press: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="1 of 2" title="Bench press" body="Target 3 x 8 at 135 lb." cue="Brace. Slow down." work=30 +fail
    slide@e1-reps "Bench press: reps per set" 1-30 value=8
    slide@e1-lb "Bench press: weight in lb" 0-300 value=135 step=5 unit=lb
    pick@e2-sets "Plank: sets done" "Set 1"|Skip tag="2 of 2" title=Plank cue="Straight line. Squeeze everything." work=30
    slide@e2-secs "Plank: seconds per set" 5-180 value=30 step=5
    choose@feel "How did it feel?" Easy|"Just right"|Hard
    end
    """

    private func runner(_ yl: String = heavy) throws -> RunnerPlan {
        let all = YLScreen(yl).components
        let head = all.first { $0.preset == "plan" }!
        return try XCTUnwrap(RunnerPlan.of(all.steps(of: head)))
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testThePlanCarriesTheCoachAndTheFailureSet() throws {
        let r = try runner()
        XCTAssertEqual(r.moves[0].cue, "Brace. Slow down.")
        XCTAssertEqual(r.moves[0].work, 30)
        XCTAssertTrue(r.moves[0].fail)
        XCTAssertFalse(r.moves[1].fail, "a plank never goes to failure")
        XCTAssertEqual(r.moves[0].tag, "e1")
        XCTAssertEqual(r.moves[0].name, "Bench press")
    }

    func testTheScheduleIsWorkThenRestThenTheNextSetThenTheNextMove() throws {
        let e = SessionEngine(try runner(), fast: false)
        XCTAssertEqual(e.steps.map { "\($0.kind)-\($0.move)-\($0.set)-\($0.seconds)" }, [
            "work-0-1-30", "rest-0-1-60", "work-0-2-30", "rest-0-2-60",
            "fail-0-3-0", "rest-0-3-60",        // the last set of the lift waits for Stop
            "work-1-1-30",                      // and no rest after the very last set
        ])
    }

    func testItRunsOnItsOwnFromStartToFinishWithNoTaps() throws {
        let r = try runner()
        let e = SessionEngine(r, fast: false)
        var p = RunnerProgress()
        p.run = e.begin(at: t0)
        // 30s in: still the first set. No tick yet.
        XCTAssertFalse(e.tick(&p, at: t0.addingTimeInterval(29)))
        XCTAssertEqual(p.run?.step, 0)
        // The set ends by itself: it ticks and the rest starts.
        XCTAssertTrue(e.tick(&p, at: t0.addingTimeInterval(31)))
        XCTAssertEqual(p.run?.step, 1)
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1"])
        // Away for a long while: the clock catches up from where each step ended, up to the failure set, which waits.
        XCTAssertTrue(e.tick(&p, at: t0.addingTimeInterval(5_000)))
        XCTAssertEqual(p.run?.step, 4, "stopped at the failure set")
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1", "Set 2"])
        XCTAssertFalse(e.tick(&p, at: t0.addingTimeInterval(50_000)), "it never ends on its own")
        // Stop logs the reps and the session goes on by itself to the plank, then finishes.
        let stopAt = t0.addingTimeInterval(200)
        e.stop(&p, reps: 11, at: stopAt)
        XCTAssertEqual(p.values["e1-fail"], 11)
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1", "Set 2", "Set 3"])
        XCTAssertEqual(p.run?.step, 5)
        XCTAssertTrue(e.tick(&p, at: stopAt.addingTimeInterval(61 + 31)))
        XCTAssertNotNil(p.run?.finished, "finished on its own")
        XCTAssertEqual(p.ticked["e2-sets"], ["Set 1"])
        XCTAssertEqual(e.setsDone(p).done, 4)
        XCTAssertEqual(e.setsDone(p).of, 4)
        XCTAssertEqual(p.answers(r)["e1-fail"], .number(11), "Send carries the failure reps")
    }

    func testNewLiftersNeverWaitOnAStop() throws {
        let yl = Self.heavy.replacingOccurrences(of: " +fail", with: "")
        let r = try runner(yl)
        let e = SessionEngine(r, fast: false)
        XCTAssertFalse(e.steps.contains { $0.kind == .fail })
        var p = RunnerProgress()
        p.run = e.begin(at: t0)
        XCTAssertTrue(e.tick(&p, at: t0.addingTimeInterval(100_000)))
        XCTAssertNotNil(p.run?.finished, "start to finish with no taps at all")
        XCTAssertNil(p.values["e1-fail"])
        XCTAssertNil(p.answers(r)["e1-fail"])
        XCTAssertEqual(e.setsDone(p).done, 4)
    }

    func testTheOptionalButtons() throws {
        let e = SessionEngine(try runner(), fast: false)
        var p = RunnerProgress()
        p.run = e.begin(at: t0)
        // Done early: the set ticks and the rest starts now.
        e.doneEarly(&p, at: t0.addingTimeInterval(10))
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1"])
        XCTAssertEqual(p.run?.step, 1)
        XCTAssertEqual(p.run?.left(at: t0.addingTimeInterval(10)), 60)
        // +15s on the rest.
        e.addTime(&p, at: t0.addingTimeInterval(20))
        XCTAssertEqual(p.run?.left(at: t0.addingTimeInterval(20)), 65, "60s rest from 10s, +15s, 10s gone")
        // Pause holds the seconds; time passing changes nothing; resume goes on from them.
        e.pause(&p, at: t0.addingTimeInterval(30))
        let held = p.run?.left(at: t0.addingTimeInterval(30))
        XCTAssertEqual(p.run?.left(at: t0.addingTimeInterval(9_000)), held)
        XCTAssertFalse(e.tick(&p, at: t0.addingTimeInterval(9_000)), "paused does not move")
        e.resume(&p, at: t0.addingTimeInterval(9_000))
        XCTAssertEqual(p.run?.left(at: t0.addingTimeInterval(9_000)), held)
        XCTAssertFalse(p.run?.isPaused ?? true)
        // Skip the move: what was ticked stays, the plank is next.
        e.skipMove(&p, at: t0.addingTimeInterval(9_001))
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1"])
        XCTAssertEqual(p.run?.step, 6)
        // Skipping the last move ends it.
        e.skipMove(&p, at: t0.addingTimeInterval(9_002))
        XCTAssertNotNil(p.run?.finished)
        XCTAssertEqual(p.ticked["e2-sets"], ["Skip"])
    }

    func testTheRestSaysWhatIsNextAndTheCoachHasAWord() throws {
        let r = try runner()
        let e = SessionEngine(r, fast: false)
        let p = RunnerProgress()
        XCTAssertEqual(e.nextLine(after: 1, p), "Next: Bench press, set 2 of 3")
        XCTAssertEqual(e.nextLine(after: 5, p), "Next: Plank 1x30s")
        XCTAssertEqual(e.target(r.moves[0], p), "Bench press 3x8 at 135")
        XCTAssertEqual(SessionEngine.cue(r.moves[0]), "Brace. Slow down.")
        // The app's own words when the runtime sent none (offline, or an older agent).
        let bare = try runner(Self.heavy.replacingOccurrences(of: " cue=\"Brace. Slow down.\"", with: ""))
        XCTAssertEqual(SessionEngine.cue(bare.moves[0]), "Brace. Slow down.", "a press has its own fallback")
        XCTAssertFalse(SessionEngine.cue(RunnerMove(sets: r.moves[0].sets, labels: [], skip: nil, nudges: [])).isEmpty)
    }

    func testFastTimersForTheUITests() throws {
        let e = SessionEngine(try runner(), fast: true)
        XCTAssertEqual(e.steps.first?.seconds, 6)
        XCTAssertEqual(e.steps[1].seconds, 5)
        XCTAssertEqual(e.steps.first { $0.kind == .fail }?.seconds, 0, "failure still waits")
    }

    func testAPausedPlaceSurvivesARelaunch() throws {
        let r = try runner()
        let e = SessionEngine(r, fast: false)
        var p = RunnerProgress()
        p.run = e.begin(at: t0)
        e.doneEarly(&p, at: t0.addingTimeInterval(5))
        e.pause(&p, at: t0.addingTimeInterval(15))
        let d = try XCTUnwrap(UserDefaults(suiteName: "yui.tests.session"))
        d.removePersistentDomain(forName: "yui.tests.session")
        p.save("wk-20260930-wed", in: d)
        let back = try XCTUnwrap(RunnerProgress.load("wk-20260930-wed", in: d))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.run?.paused, 50)
        XCTAssertEqual(back.ticked["e1-sets"], ["Set 1"])
        d.removePersistentDomain(forName: "yui.tests.session")
    }
}
