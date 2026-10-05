import XCTest
import YuiLines
@testable import Yui

/// Edits on the fly in the workout runner (feedback AMEDGjyb): a move swapped, its sets, reps and weight
/// changed, a move added after it, all mid-session. The schedule follows, the run stays on its set, and the
/// plan's answer says what changed. Pure: dates are passed in.
@MainActor
final class WorkoutEditsTests: XCTestCase {
    /// Today's Full body A, as the runtime sends it (the screenshot in the note).
    static let fullBody = """
    plan@wk-20261005-mon "Full body A" submit="Finish workout"
    page "Full body A" body="4 moves, about 40 minutes. Rest about 90 seconds between sets."
    pick@e1-sets "Goblet squat: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="1 of 4" title="Goblet squat" work=40
    slide@e1-reps "Goblet squat: reps per set" 1-30 value=10
    slide@e1-lb "Goblet squat: weight in lb" 0-200 value=20 step=5 unit=lb
    pick@e2-sets "Push-up: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="2 of 4" title="Push-up" work=30
    slide@e2-reps "Push-up: reps per set" 1-30 value=8
    pick@e3-sets "Dumbbell row: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="3 of 4" title="Dumbbell row" work=40
    slide@e3-reps "Dumbbell row: reps per set" 1-30 value=10
    slide@e3-lb "Dumbbell row: weight in lb" 0-200 value=20 step=5 unit=lb
    pick@e4-sets "Plank: sets done" "Set 1"|"Set 2"|"Set 3"|Skip tag="4 of 4" title=Plank work=30
    slide@e4-secs "Plank: seconds per set" 5-180 value=30 step=5
    choose@feel "How did it feel?" Easy|"Just right"|Hard
    end
    """

    private func runner() throws -> RunnerPlan {
        let all = YLScreen(Self.fullBody).components
        let head = all.first { $0.preset == "plan" }!
        return try XCTUnwrap(RunnerPlan.of(all.steps(of: head)))
    }

    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func started(_ r: RunnerPlan) -> RunnerProgress {
        var p = RunnerProgress()
        p.run = SessionEngine(r, fast: false).begin(at: t0)
        return p
    }

    func testNoEditsSaysNothingAndThePlanIsAsSent() throws {
        let r = try runner()
        let p = started(r)
        XCTAssertEqual(r.applying(p.edits), r)
        XCTAssertNil(p.answers(r)["edits"], "an untouched workout sends no edits line")
    }

    func testASwapRenamesTheMoveAndTheResultSaysSo() throws {
        let r = try runner()
        var p = started(r)
        p.edit(r, at: at(5), fast: false) { $0.swaps["e1"] = "Leg press" }
        let live = r.applying(p.edits)
        XCTAssertEqual(live.moves[0].name, "Leg press")
        XCTAssertEqual(live.moves[0].sets.ylID, "e1-sets", "a swap keeps the move's ids, so its sets still answer")
        XCTAssertEqual(p.run?.step, 0, "the set under way keeps going")
        XCTAssertEqual(p.run?.ends, at(40), "and keeps its clock")
        XCTAssertEqual(p.answers(r)["edits"], .array([.string("Swapped Goblet squat for Leg press")]))
    }

    func testMoreSetsGrowTheScheduleAndRepsAndWeightBecomeTheMovesNumbers() throws {
        let r = try runner()
        var p = started(r)
        let before = SessionEngine(r, fast: false).steps.count
        p.edit(r, fast: false) { $0.sets["e2"] = 4 }
        p.edit(r, fast: false) { $0.reps["e3"] = 12 }
        p.edit(r, fast: false) { $0.lb["e3"] = 25 }
        let live = r.applying(p.edits)
        XCTAssertEqual(live.moves[1].labels, ["Set 1", "Set 2", "Set 3", "Set 4"])
        XCTAssertEqual(SessionEngine(live, fast: false).steps.count, before + 3, "one more work, log and rest")
        XCTAssertEqual(SessionEngine(live, fast: false).target(live.moves[2], p), "Dumbbell row 3x12 at 25")
        let a = p.answers(r)
        XCTAssertEqual(a["e3-reps"], .number(12))
        XCTAssertEqual(a["e3-lb"], .number(25))
        XCTAssertEqual(a["edits"], .array([
            .string("Push-up: 4 sets (was 3)"),
            .string("Dumbbell row: 12 reps (was 10)"),
            .string("Dumbbell row: 25 lb (was 20 lb)"),
        ]))
    }

    func testUndoingAnEditToThePlansNumberLeavesNoChange() throws {
        let r = try runner()
        var p = started(r)
        p.edit(r, fast: false) { $0.reps["e1"] = 11 }
        p.edit(r, fast: false) { $0.reps["e1"] = nil }
        XCTAssertNil(p.edits)
        XCTAssertEqual(p.values["e1-reps"], 10, "back to the plan's own number")
        XCTAssertNil(p.answers(r)["edits"])
    }

    func testAnAddedMoveRunsAfterItsAnchorAndAnswersByItsOwnIds() throws {
        let r = try runner()
        var p = started(r)
        p.edit(r, fast: false) { $0.added.append(AddedMove(tag: $0.nextTag, name: "Lunge", sets: 2, reps: 12, lb: nil, after: "e1")) }
        let live = r.applying(p.edits)
        XCTAssertEqual(live.moves.map(\.name), ["Goblet squat", "Lunge", "Push-up", "Dumbbell row", "Plank"])
        XCTAssertEqual(live.moves[1].tag, "add1")
        XCTAssertEqual(live.moves[1].labels, ["Set 1", "Set 2"])
        XCTAssertEqual(p.run?.step, 0, "adding a move later never moves the set under way")
        // The session runs through it: squat sets, then the lunge.
        let e = SessionEngine(live, fast: false)
        let lunge = try XCTUnwrap(e.steps.firstIndex { $0.move == 1 })
        XCTAssertEqual(e.steps[lunge].kind, .work)
        XCTAssertEqual(e.steps[lunge - 1].kind, .rest, "a rest before it, like any move")
        p.ticked["add1-sets"] = ["Set 1", "Set 2"]
        let a = p.answers(r)
        XCTAssertEqual(a["add1-sets"], .array([.string("Set 1"), .string("Set 2")]))
        XCTAssertEqual(a["add1-reps"], .number(12))
        XCTAssertEqual(a["edits"], .array([.string("Added Lunge 2x12")]))
        // A second move added there comes after the first.
        p.edit(r, fast: false) { $0.added.append(AddedMove(tag: $0.nextTag, name: "Burpee", sets: 3, reps: 10, lb: nil, after: "e1")) }
        XCTAssertEqual(r.applying(p.edits).moves.map(\.tag), ["e1", "add1", "add2", "e2", "e3", "e4"])
    }

    func testCuttingTheSetUnderWayGoesOnToTheNextMove() throws {
        let r = try runner()
        let e = SessionEngine(r, fast: false)
        var p = started(r)
        // Into squat set 3.
        let set3 = try XCTUnwrap(e.steps.firstIndex { $0.move == 0 && $0.set == 3 && $0.kind == .work })
        p.ticked["e1-sets"] = ["Set 1", "Set 2"]
        p.run?.step = set3
        p.run?.ends = at(500)
        p.edit(r, at: at(400), fast: false) { $0.sets["e1"] = 2 }
        let live = SessionEngine(r.applying(p.edits), fast: false)
        let s = try XCTUnwrap(live.current(p.run!))
        XCTAssertEqual(s.move, 1, "on to the push-ups")
        XCTAssertEqual(s.set, 1)
        XCTAssertEqual(p.run?.ends, at(430), "its clock starts now")
        XCTAssertEqual(p.answers(r)["edits"], .array([.string("Goblet squat: 2 sets (was 3)")]))
    }

    func testCuttingSetsDropsTicksPastTheCut() throws {
        let r = try runner()
        var p = started(r)
        p.ticked["e2-sets"] = ["Set 1", "Set 2", "Set 3"]
        p.edit(r, fast: false) { $0.sets["e2"] = 2 }
        XCTAssertEqual(p.ticked["e2-sets"], ["Set 1", "Set 2"])
    }

    func testEditsSurviveARelaunch() throws {
        let r = try runner()
        var p = started(r)
        p.edit(r, fast: false) { $0.swaps["e4"] = "Dead bug"; $0.added.append(AddedMove(tag: "add1", name: "Curl", sets: 3, reps: 10, lb: 15, after: "e3")) }
        let d = try XCTUnwrap(UserDefaults(suiteName: "WorkoutEditsTests"))
        p.save("wk-edit", in: d)
        let back = try XCTUnwrap(d.data(forKey: RunnerProgress.key("wk-edit")).flatMap { try? JSONDecoder().decode(RunnerProgress.self, from: $0) })
        XCTAssertEqual(back.edits, p.edits)
        XCTAssertEqual(r.changes(back.edits, back), ["Added Curl 3x10 at 15 lb", "Swapped Plank for Dead bug"])
        d.removePersistentDomain(forName: "WorkoutEditsTests")
    }

    func testProgressSavedBeforeEditsExistedStillLoads() throws {
        let old = #"{"at":0,"ticked":{"e1-sets":["Set 1"]},"values":{}}"#
        let p = try JSONDecoder().decode(RunnerProgress.self, from: Data(old.utf8))
        XCTAssertNil(p.edits)
        XCTAssertEqual(p.ticked["e1-sets"], ["Set 1"])
    }

    func testSwapsOfferMovesLikeIt() {
        XCTAssertEqual(RunnerEdits.alternates("Goblet squat"), ["Leg press", "Split squat", "Box squat"])
        XCTAssertEqual(RunnerEdits.alternates("Dumbbell row").first, "Cable row")
        XCTAssertEqual(RunnerEdits.alternates("Plank").first, "Dead bug")
        XCTAssertFalse(RunnerEdits.alternates("Zercher carry").isEmpty, "an unknown move still gets options")
    }
}
