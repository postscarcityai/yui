import XCTest
import YuiLines
@testable import Yui

/// The shader blob's shape (YUI-232, yuigui site/lib/visual/action.test.mjs, spec/SHADER.md):
/// the doing words pick the action, the turn picks the rest, and the weights morph, never snap.
final class StageActionTests: XCTestCase {
    func testTheDoingWordsPickTheShape() {
        XCTAssertEqual(StageAction.of(doing: nil), .thinking, "no doing thinks")
        XCTAssertEqual(StageAction.of(doing: ""), .thinking)
        XCTAssertEqual(StageAction.of(doing: "Reading your calendar"), .reading)
        XCTAssertEqual(StageAction.of(doing: "Reviewing the draft"), .reading)
        XCTAssertEqual(StageAction.of(doing: "Running the tests"), .running)
        XCTAssertEqual(StageAction.of(doing: "Building the site"), .running)
        XCTAssertEqual(StageAction.of(doing: "Searching the web"), .searching)
        XCTAssertEqual(StageAction.of(doing: "Looking up flights"), .searching, "look up is a search")
        XCTAssertEqual(StageAction.of(doing: "Looking at your plate"), .reading, "look at is reading")
        XCTAssertEqual(StageAction.of(doing: "Pondering"), .thinking, "no clue thinks")
    }

    func testTheTurnPicksTheRest() {
        XCTAssertEqual(StageMotion.action(StageFacts()), .idle)
        XCTAssertEqual(StageMotion.action(StageFacts(sent: true)), .thinking)
        XCTAssertEqual(StageMotion.action(StageFacts(doing: "Checking TestFlight", sent: true)), .reading)
        XCTAssertEqual(StageMotion.action(StageFacts(doing: "Deploying", sent: true)), .running)
        XCTAssertEqual(StageMotion.action(StageFacts(listening: true)), .talking, "the mic open is talking")
        XCTAssertEqual(StageMotion.action(StageFacts(arrived: true, doing: "Reading", sent: true)), .done, "the reply's beat")
        XCTAssertEqual(StageMotion.action(StageFacts(chunk: 0, sent: true)), .idle)
        XCTAssertEqual(StageMotion.action(StageFacts(failed: true, sent: true)), .idle)
    }

    func testTheWeightsMorphAndSettle() {
        var w = BlobWeights()
        XCTAssertEqual(w[.idle], 1)
        var once = w
        once.ease(toward: .reading, dt: 0.016)
        XCTAssertLessThan(once[.reading], 0.1, "a mix, never a snap")
        for _ in 0..<20 { w.ease(toward: .reading, dt: 0.05) }
        XCTAssertGreaterThan(w[.reading], 0.6)
        XCTAssertLessThan(w[.idle], 0.3)
        XCTAssertEqual(StageAction.allCases.reduce(0) { $0 + w[$1] }, 1, accuracy: 1e-9)
        XCTAssertEqual(BlobWeights(.running)[.running], 1, "a still frame is all one shape")
    }

    func testThePlanCarriesTheShape() {
        let p = VisualPlan(YLVisualStub.orb, accent: "#FF7E8A", ground: "#231D33", ink: "#F6EEF7", motion: .characters["calm"]!, action: .searching)!
        XCTAssertEqual(p.action, .searching)
        XCTAssertEqual(VisualPlan(YLVisualStub.orb, accent: "#FF7E8A", ground: "#231D33", ink: "#F6EEF7", motion: .characters["calm"]!)!.action, .idle)
    }

    func testTheShaderHasEveryShapeAndNoMarkIsLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let metal = try String(contentsOf: root.appendingPathComponent("Yui/Sources/Stage/Visual.metal"), encoding: .utf8)
        for w in ["think * dThink", "read * dRead", "run * dRun", "search * dSearch", "talk * dTalk", "done * dDone"] {
            XCTAssertTrue(metal.contains(w), w)
        }
        let stage = try String(contentsOf: root.appendingPathComponent("Yui/Sources/Stage/StageFirst.swift"), encoding: .utf8)
        let motion = try String(contentsOf: root.appendingPathComponent("Yui/Sources/Stage/StageMotion.swift"), encoding: .utf8)
        XCTAssertFalse(stage.contains("StageMark"), "only the shader draws the agent")
        XCTAssertFalse(motion.contains("struct StageMark"))
    }
}

private enum YLVisualStub { static let orb = YLVisual(look: "orb") }
