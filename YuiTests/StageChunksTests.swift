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
        // Three ideas share one page (VIS-4), and the question follows.
        XCTAssertEqual(t.chunks.count, 1)
        XCTAssertEqual(t.chunks[0].blocks.map(\.line), ["Yes.", "Build 160.", "Update the iPad."])
        XCTAssertEqual(t.chunks[0].blocks.map(\.scope), ["a1", "a1", "a2"])
        XCTAssertEqual(t.questions.map(\.c.ylID), ["n3"])
        XCTAssertEqual(t.pages, 2)
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
        // One and Two share page 0; Three has a timer, which keeps a page of its own.
        XCTAssertEqual(model.at, 1)
        XCTAssertTrue(model.show(reply: "a1", in: messages))
        XCTAssertEqual(model.at, 0)
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

    // VIS-4: up to 3 ideas on a page (mirror of packPages in chunks.test.mjs).
    private func pages(_ yl: String) -> [Int] {
        StageChunks.pack(StageChunks.of(YLScreen(yl), scope: "r").chunks).map { $0.blocks.count }
    }

    func testThreeIdeasShareOnePage() {
        XCTAssertEqual(pages("""
        say "Build is live."
        shapes
        shape box Build
        say "Keys ride along."
        sketch "In 0.3.2"
        row Keys +hi
        say "Chords next."
        sketch "Next"
        row Chords +hi
        """), [3])
    }

    func testAFourthIdeaStartsANewPage() {
        XCTAssertEqual(pages("""
        say "One."
        sketch
        row A +hi
        say "Two."
        sketch
        row B +hi
        say "Three."
        sketch
        row C +hi
        say "Four."
        sketch
        row D +hi
        """), [3, 1])
    }

    func testADeckPageStandsAlone() {
        XCTAssertEqual(pages("""
        say "Hi."
        deck "D"
        page "P"
        sketch
        row A +hi
        say "Bye."
        end
        """), [1, 1, 1])
    }

    // NOTE-42080, VALUES 9: one decision, one screen (mirror of askHere in yuigui site/lib/yl/askhere.test.mjs).
    private func asks(_ yl: String) -> [String?] {
        StageChunks.of(YLScreen(yl), scope: "r").chunks.filter(\.asks).map(\.line)
    }

    private func turn(_ yl: String) -> StageTurn {
        StageChunks.turn([ChatMessage(id: "u", text: "Go", fromUser: true),
                          ChatMessage(id: "r", text: "", fromUser: false, yl: YLScreen(yl))], ask: "u")
    }

    func testAChooseAfterAPlanPageAsksOnThatPage() {
        XCTAssertEqual(asks("""
        plan "Review"
        page "1 done today" body="2 still open."
        choose "Groceries" Done|Tomorrow|Drop
        end
        """), ["1 done today"])
    }

    func testAPickAndAnAskJoinToo() {
        XCTAssertEqual(asks("""
        plan "P"
        page "x"
        pick "Which?" A|B
        end
        """), ["x"])
        XCTAssertEqual(asks("""
        plan "P"
        page "y"
        ask "Go?"
        end
        """), ["y"])
    }

    func testASlideOrFormDoesNotJoinAPage() {
        XCTAssertEqual(asks("""
        plan "P"
        page "x"
        slide "How much?" 1-5
        end
        """), [])
        XCTAssertEqual(asks("""
        plan "P"
        page "x"
        form "About you" name:text
        choose "Then?" A|B
        end
        """), [], "the choose follows the form, not the page")
    }

    func testAPageWithItsPictureStillAsks() {
        XCTAssertEqual(asks("""
        plan "P"
        page "Look C: Chalk"
        sketch frame=bubble
        row "Chalk lines" +hi
        end
        choose "Which drawing look should Yui use?" A|B|C
        end
        """), ["Look C: Chalk"])
    }

    func testADeckPageDoesNotAsk() {
        XCTAssertEqual(asks("""
        deck "D"
        page "P"
        choose "Quiz?" A|B
        end
        """), [])
    }

    func testAQuestionWithNoPageBeforeItStaysAlone() {
        XCTAssertEqual(asks("""
        plan "P"
        choose "Q" A|B
        page "after"
        end
        """), [])
        // The release reply's plan has no page in it: nothing moves.
        let t = turn("""
        say "Keys ride along."
        sketch "In 0.3.2"
        row Keys +hi
        plan@before "Before I go"
        choose@ping "Ping you?" Yes|No
        end
        """)
        XCTAssertNil(t.lead)
        XCTAssertEqual(t.pages, 2)
    }

    /// The last page and its question share the questions screen: one page, not two.
    func testTheLastPageMovesOntoTheQuestionsScreen() {
        let t = turn("""
        say "Two things."
        plan "Before I go"
        page "Findings" body="The guide changes nothing for routing."
        choose "When do we ship?" Friday|Monday +other
        end
        """)
        XCTAssertEqual(t.lead?.line, "Findings")
        XCTAssertEqual(t.chunks.map(\.line), ["Two things."])
        XCTAssertEqual(t.questions.count, 1)
        XCTAssertEqual(t.pages, 2, "Two things., then Findings with its question")
    }

    /// Three looks, then the question: the last look heads the question, the first two stay pages to read.
    func testOnlyTheLastPageMoves() {
        let t = turn("""
        plan "Pick a look"
        page "Look A: Hand drawn"
        page "Look B: Clean lines"
        page "Look C: Chalk"
        choose "Which drawing look should Yui use?" A|B|C
        end
        """)
        XCTAssertEqual(t.chunks.map(\.line), ["Look A: Hand drawn", "Look B: Clean lines"])
        XCTAssertEqual(t.lead?.line, "Look C: Chalk")
        XCTAssertEqual(t.pages, 3)
    }

    /// A plan that is a page and its questions plays as one screen, and the record's pill opens it there.
    func testAPageAndItsQuestionsAreOneScreen() {
        let messages = [
            ChatMessage(id: "u1", text: "Review", fromUser: true),
            ChatMessage(id: "a1", text: "", fromUser: false, yl: YLScreen("""
            plan@review "Evening review" submit="Wrap up the day"
            page "1 done today" body="Nice. 2 still open." points="Pay the water bill"
            choose@r-groceries "Groceries" "Done"|"Tomorrow"|"Drop"
            choose@feel "How did today go?" "Great"|"Okay"|"Rough"
            end
            """)),
        ]
        let t = StageChunks.turn(messages, ask: "u1")
        XCTAssertTrue(t.chunks.isEmpty)
        XCTAssertEqual(t.lead?.line, "1 done today")
        XCTAssertEqual(t.pages, 1)
        let model = StageFirstModel()
        XCTAssertTrue(model.show(reply: "a1", in: messages))
        XCTAssertEqual(model.at, 0, "the pill opens on the questions screen")
    }
}
