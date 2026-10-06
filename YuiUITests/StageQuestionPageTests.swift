import XCTest

/// A question sits on the page it asks about (feedback AAY2aTG4, Oct 5: "the question and the answers are on
/// the next page and neither page is too full ... I don't want clicks for no reason"). A short line and its
/// choose are ONE screen: no Next between them. Fails on the old stage, which played the line first.
/// Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class StageQuestionPageTests: XCTestCase {
    func testALineAndItsQuestionShareOneScreenLight() throws { try oneScreen("light") }
    func testALineAndItsQuestionShareOneScreenDark() throws { try oneScreen("dark") }

    private func oneScreen(_ appearance: String) throws {
        let reply = [
            "say \"I just sent you the kid version. Want a grown-up take, or was that one enough?\"",
            "choose \"Grown-up take?\" \"Yes, grown-up\"|\"Kid one was enough\"",
        ].joined(separator: "\\n")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "6"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Explain string theory to me")
        app.buttons["stage-send-text"].tap()
        // No tap on Next: the line and the question arrive together.
        let questions = app.descendants(matching: .any)["stage-questions"]
        let arrived = questions.waitForExistence(timeout: 20)
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "stage-question-page-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "stage-question-page-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        XCTAssertTrue(arrived, "the question is not on the first page")
        XCTAssertTrue(app.descendants(matching: .any)["stage-questions-lead"].exists, "the line is not above its question")
        XCTAssertTrue(app.buttons["Yes, grown-up"].exists, "no answer on the same screen")
        XCTAssertFalse(app.buttons["stage-next"].exists, "a Next stands between the line and its question")
    }
}
