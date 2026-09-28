import XCTest
import YuiLines
@testable import Yui

/// Arnold's workout runner (YUI-182): the runtime's plan read as a workout, and
/// its place kept in UserDefaults, the real path a relaunch reads (Chris, Sep 28:
/// the 0.5.0 crash hid behind the demo account's memory). No demo store here.
@MainActor
final class WorkoutRunnerTests: XCTestCase {
    /// The runner as runtime/src/workouts.ts runnerLines sends it.
    static let lines = """
    plan@wk-20260928-mon "Upper" submit="Finish workout"
    page "Upper" body="2 moves, about 45 minutes. Rest about 75 seconds between sets." points="Bench press 3x8"|"Plank 3x30s"
    pick@e1-sets "Bench press: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="1 of 2" title="Bench press" body="Target 3 x 8 at 135 lb."
    slide@e1-reps "Bench press: reps per set" 1-30 value=8
    slide@e1-lb "Bench press: weight in lb" 0-300 value=135 step=5 unit=lb
    pick@e2-sets "Plank: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="2 of 2" title=Plank
    slide@e2-secs "Plank: seconds per set" 5-180 value=30 step=5
    choose@feel "How did it feel?" Easy|"Just right"|Hard
    end
    """

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "yui.tests.runner")
        defaults.removePersistentDomain(forName: "yui.tests.runner")
    }

    private func steps(_ yl: String = lines) -> [YLComponent] {
        let all = YLScreen(yl).components
        let head = all.first { $0.preset == "plan" }!
        return all.steps(of: head)
    }

    func testThePlanReadsAsMovesWithTheirNudges() throws {
        let r = try XCTUnwrap(RunnerPlan.of(steps()))
        XCTAssertEqual(r.moves.map(\.sets.ylID), ["e1-sets", "e2-sets"])
        XCTAssertEqual(r.moves[0].labels, ["Set 1", "Set 2", "Set 3"])
        XCTAssertEqual(r.moves[0].skip, "Skip")
        XCTAssertEqual(r.moves[0].nudges.map(\.ylID), ["e1-reps", "e1-lb"])
        XCTAssertEqual(r.moves[1].nudges.map(\.ylID), ["e2-secs"])
        XCTAssertEqual(r.absorbed, ["e1-reps", "e1-lb", "e2-secs"])
        XCTAssertEqual(r.rest, 75, "the rest comes from the first page")
    }

    func testOtherPlansAreNotWorkouts() {
        XCTAssertNil(RunnerPlan.of(steps("""
        plan "Your site"
        pick "Pages you want" About|Work|Contact
        slide "Budget" 1-10
        end
        """)))
        // A pick with sets but two ways out is a question, not a set list.
        XCTAssertNil(RunnerPlan.of(steps("""
        plan "Odd"
        pick "Which?" "Set 1"|Skip|Later
        end
        """)))
    }

    func testRestDefaultsToNinety() throws {
        let r = try XCTUnwrap(RunnerPlan.of(steps("""
        plan@wk-20260928-tue Legs
        pick@e1-sets "Squat: sets done" "Set 1"|"Set 2"
        end
        """)))
        XCTAssertEqual(r.rest, 90)
        XCTAssertTrue(r.moves[0].nudges.isEmpty)
        XCTAssertNil(r.moves[0].skip)
    }

    func testTicksSkipAndVoice() throws {
        let m = try XCTUnwrap(RunnerPlan.of(steps())).moves[0]
        var p = RunnerProgress()
        XCTAssertTrue(p.toggle("Set 2", m))
        XCTAssertTrue(p.toggle("Set 1", m))
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1", "Set 2"], "sets keep their order")
        XCTAssertFalse(p.toggle("Set 2", m), "a second tap takes it off")
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1"])
        // Skip stands alone; a set after it takes Skip off.
        XCTAssertTrue(p.toggle("Skip", m))
        XCTAssertEqual(p.ticked["e1-sets"], ["Skip"])
        XCTAssertTrue(p.toggle("Set 3", m))
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 3"])
        // "done" ticks the next one not ticked, until there are none.
        XCTAssertTrue(p.tickNext(m))
        XCTAssertTrue(p.tickNext(m))
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1", "Set 2", "Set 3"])
        XCTAssertFalse(p.tickNext(m))
    }

    func testVoiceCountsEachDone() {
        XCTAssertEqual(VoiceDone.count(""), 0)
        XCTAssertEqual(VoiceDone.count("Done"), 1)
        XCTAssertEqual(VoiceDone.count("okay done. done! Next set"), 3)
        XCTAssertEqual(VoiceDone.count("I'm undone, donut"), 0, "only the word")
    }

    func testAnswersAreWhatTheRuntimeReads() throws {
        let r = try XCTUnwrap(RunnerPlan.of(steps()))
        var p = RunnerProgress()
        // Untouched: every nudge at its value, no sets (the runtime counts them all done).
        XCTAssertEqual(p.answers(r), ["e1-reps": .number(8), "e1-lb": .number(135), "e2-secs": .number(30)])
        _ = p.toggle("Set 1", r.moves[0])
        _ = p.toggle("Set 2", r.moves[0])
        p.values["e1-lb"] = 140
        let a = p.answers(r)
        XCTAssertEqual(a["e1-sets"], .array([.string("Set 1"), .string("Set 2")]))
        XCTAssertEqual(a["e1-lb"], .number(140))
        XCTAssertNil(a["e2-sets"])
    }

    /// The real path: saved, read back by a fresh load (a relaunch), cleared on Send.
    func testProgressSurvivesARelaunchInUserDefaults() throws {
        let r = try XCTUnwrap(RunnerPlan.of(steps()))
        var p = RunnerProgress()
        p.at = 2
        _ = p.toggle("Set 1", r.moves[0])
        p.values["e1-reps"] = 10
        p.rest = .start(75, at: Date(timeIntervalSince1970: 1_000))
        p.save("wk-20260928-mon", in: defaults)

        // A new process reads the same suite from disk.
        let again = try XCTUnwrap(UserDefaults(suiteName: "yui.tests.runner"))
        let back = try XCTUnwrap(RunnerProgress.load("wk-20260928-mon", in: again))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.answers(r)["e1-reps"], .number(10))
        XCTAssertNil(RunnerProgress.load("wk-20260929-tue", in: again), "another day starts clean")

        RunnerProgress.clear("wk-20260928-mon", in: again)
        XCTAssertNil(RunnerProgress.load("wk-20260928-mon", in: defaults))
    }

    func testRestClock() {
        let t0 = Date(timeIntervalSince1970: 0)
        let r = RestClock.start(90, at: t0)
        XCTAssertEqual(r.left(at: t0), 90)
        XCTAssertEqual(r.left(at: t0.addingTimeInterval(30.2)), 60)
        XCTAssertFalse(r.over(at: t0.addingTimeInterval(89)))
        XCTAssertTrue(r.over(at: t0.addingTimeInterval(90)))
        XCTAssertEqual(r.left(at: t0.addingTimeInterval(200)), 0)
        XCTAssertEqual(r.progress(at: t0.addingTimeInterval(45)), 0.5, accuracy: 0.01)
        let more = r.adding(15, at: t0.addingTimeInterval(30))
        XCTAssertEqual(more.left(at: t0.addingTimeInterval(30)), 75)
        XCTAssertEqual(more.total, 105)
        // Over already: +15 counts from now.
        XCTAssertEqual(r.adding(15, at: t0.addingTimeInterval(120)).left(at: t0.addingTimeInterval(120)), 15)
        XCTAssertEqual(RestClock.label(75), "1:15")
        XCTAssertEqual(RestClock.label(5), "0:05")
    }
}
