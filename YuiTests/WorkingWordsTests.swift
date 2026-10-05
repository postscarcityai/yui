import XCTest
@testable import Yui

final class WorkingWordsTests: XCTestCase {
    func testToolWordsGetAFriendlyVoice() {
        XCTAssertEqual(WorkingWords.friendly("Running a command"), "Tinkering away")
        XCTAssertEqual(WorkingWords.friendly("Searching the web"), "Looking around the web")
        XCTAssertEqual(WorkingWords.friendly("Reading your calendar"), "Reading your calendar", "the agent's own words stay")
        XCTAssertEqual(WorkingWords.friendly("Pondering"), "Pondering")
    }

    /// The blob's shape reads the host's words, so the voice never feeds it: every plain word keeps its shape.
    func testVoiceDoesNotChangeTheBlob() {
        for (plain, _) in WorkingWords.voice {
            XCTAssertEqual(StageAction.of(doing: plain), StageAction.of(doing: plain))
        }
        XCTAssertEqual(StageAction.of(doing: "Running a command"), .running)
    }

    func testGistTrimsChrisAsk() {
        let ask = "No, I'm just saying that the first post was supposed to go out on December 25 and I wanna call your attention that you need to pay attention what today's date is because it's October 1, 2026"
        let g = WorkingWords.gist(ask)
        XCTAssertLessThanOrEqual(g.split(separator: " ").count, 12)
        XCTAssertGreaterThanOrEqual(g.split(separator: " ").count, 5)
        XCTAssertTrue(g.hasPrefix("The first post"), g)
        XCTAssertTrue(g.hasSuffix("…"))
    }

    func testGistLeavesShortAsksAlone() {
        XCTAssertEqual(WorkingWords.gist("show me my weight chart"), "Show me my weight chart")
        XCTAssertEqual(WorkingWords.gist("  What's on the board?  "), "What's on the board?")
    }

    func testGistTakesTheFirstSentenceAndDropsFiller() {
        XCTAssertEqual(WorkingWords.gist("Can you please move the launch post to Friday. Also check the copy."),
                       "Move the launch post to Friday")
        XCTAssertEqual(WorkingWords.gist("ok so how much protein on rest days"), "How much protein on rest days")
    }
}
