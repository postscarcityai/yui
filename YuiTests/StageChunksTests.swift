import XCTest
import YuiLines
@testable import Yui

/// Stage first (YUI-119): a reply splits into chunks the same way the web
/// reference does. These are yuigui site/lib/yl/chunks.test.mjs's cases, one for one.
@MainActor
final class StageChunksTests: XCTestCase {
    private func view(_ yl: String) -> (chunks: [[String?]], questions: [String], plan: String?) {
        let r = StageChunks.of(YLScreen(yl), scope: "r")
        return (r.chunks.map { [$0.line, $0.pic?.preset] }, r.questions.map(\.c.ylID), r.plan?.ylID)
    }

    func testAStatusAnswerIsOneChunk() {
        let r = view("""
        say "Yes. Build 160, the newest."
        shapes caption="Your iPad is on 135."
        shape box "iPhone 160"
        shape box "iPad 135"
        """)
        XCTAssertEqual(r.chunks, [["Yes. Build 160, the newest.", "shapes"]])
        XCTAssertEqual(r.questions, [])
        XCTAssertNil(r.plan)
    }

    func testEachSayTakesThePictureAfterItAndPlanQuestionsGoLast() {
        let r = view("""
        say "0.3.2 is building."
        shapes
        shape box Build
        say "Keys ride along."
        sketch "In 0.3.2"
        row Keys +hi
        plan@before "Before I go"
        choose@ping "Ping you?" Yes|No
        choose@try "Try first?" Keys|Chords
        end
        """)
        XCTAssertEqual(r.chunks, [["0.3.2 is building.", "shapes"], ["Keys ride along.", "sketch"]])
        XCTAssertEqual(r.questions, ["ping", "try"])
        XCTAssertEqual(r.plan, "before")
    }

    func testAPictureWithNoLineIsItsOwnChunk() {
        let r = view("""
        sketch "Bar" frame=phone
        row Mic +button
        say "Talk first."
        """)
        XCTAssertEqual(r.chunks, [[nil, "sketch"], ["Talk first.", nil]])
    }

    func testAPageIsAChunkWithItsPicture() {
        let r = view("""
        deck "What changed"
        page "Plain words" body="Cards say what they are."
        sketch frame=bubble
        row "Parked YUI-83" +x
        page "One idea a page"
        end
        """)
        XCTAssertEqual(r.chunks, [["Plain words", "sketch"], ["One idea a page", nil]])
    }

    func testLooseQuestionsWaitForTheEndToo() {
        let r = view("""
        ask "Log it?"
        say "Done."
        stat 3 Sets
        """)
        XCTAssertEqual(r.chunks, [["Done.", "stat"]])
        XCTAssertEqual(r.questions, ["n1"])
        XCTAssertNil(r.plan)
    }

    func testATimerIsItsOwnChunk() {
        let r = view("""
        say "Tabata."
        card "Eight rounds"
        timer 20/10x8 Tabata
        """)
        XCTAssertEqual(r.chunks, [["Tabata.", "card"], [nil, "timer"]])
    }

    func testTextIsOneChunkPerParagraph() {
        XCTAssertEqual(StageChunks.text("One.\n\nTwo."), ["One.", "Two."])
    }

    func testALongParagraphSplitsEveryTwoSentences() {
        let long = (1...6).map { "Sentence \($0) has quite a few words in it to make it long." }.joined(separator: " ")
        XCTAssertEqual(StageChunks.text(long).count, 3)
    }

    /// A turn is what the person said and every reply after it, up to what they said next.
    func testATurnTakesEveryReplyUntilThePersonTalksAgain() {
        let messages = [
            ChatMessage(id: "u1", text: "Am I on the latest build?", fromUser: true),
            ChatMessage(id: "a1", text: "Yes.\n\nBuild 160.", fromUser: false),
            ChatMessage(id: "a2", text: "", fromUser: false, yl: YLScreen("say \"Update the iPad.\"\nstat 135 iPad\nask \"Ping you?\"")),
            ChatMessage(id: "u2", text: "Release it", fromUser: true),
            ChatMessage(id: "a3", text: "On it.", fromUser: false),
        ]
        let t = StageChunks.turn(messages, ask: "u1")
        XCTAssertEqual(t.ask?.id, "u1")
        XCTAssertEqual(t.chunks.map(\.line), ["Yes.", "Build 160.", "Update the iPad."])
        XCTAssertEqual(t.chunks.map(\.scope), ["a1", "a1", "a2"])
        XCTAssertEqual(t.questions.map(\.c.ylID), ["n3"])
        XCTAssertEqual(t.pages, 4)
        // Nil is the newest thing the person said.
        XCTAssertEqual(StageChunks.turn(messages, ask: nil).chunks.map(\.line), ["On it."])
        XCTAssertNil(StageChunks.turn([ChatMessage(text: "Hi", fromUser: false)], ask: nil).ask)
    }

    /// A pill in the record opens the stage at that reply's chunk.
    func testShowOpensTheStageAtTheRepliesChunk() {
        let messages = [
            ChatMessage(id: "u1", text: "Go", fromUser: true),
            ChatMessage(id: "a1", text: "One.\n\nTwo.", fromUser: false),
            ChatMessage(id: "a2", text: "", fromUser: false, yl: YLScreen("say Three\ntimer 5m Focus")),
        ]
        let model = StageFirstModel()
        model.open = false
        XCTAssertTrue(model.show(reply: "a2", in: messages))
        XCTAssertEqual(model.ask, "u1")
        XCTAssertEqual(model.at, 2)
        XCTAssertTrue(model.open)
        XCTAssertFalse(model.show(reply: "nope", in: messages))
    }

    /// Test and screenshot launches keep the chat first unless they ask for the stage.
    func testUITestLaunchesKeepTheChatFirst() {
        // This process was launched by the test runner with no -yui arguments.
        let yuiArgs = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-yui") }
        XCTAssertEqual(StageFirstModel.enabled(stored: true), !yuiArgs)
        XCTAssertFalse(StageFirstModel.enabled(stored: false))
    }
}
