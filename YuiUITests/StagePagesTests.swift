import XCTest

/// The agent's screens live on the full screen, not in the chat (Chris, 2026-09-27: "The chat
/// is just the chat. So right now we have on the chat the little navigation. I want that
/// navigation on the full screen view."). With stage first, a reply that puts a timer on
/// screen 2 and a list on screen 3 shows its dots under the stage; a dot opens that screen
/// there. The chat underneath is one page: no dots, no sideways pages.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class StagePagesTests: XCTestCase {
    static let reply = [
        "say Timer on screen 2, your list on screen 3.",
        ">2 timer 25m Focus",
        ">3 list@shop Shopping Eggs|Spinach|Rice|Gochujang +check",
    ].joined(separator: "\\n")

    func testScreensAreOnTheStageNotTheChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", "light", "-yuiDemoReply", Self.reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cooking bibimbap, keep me on track")
        app.buttons["stage-send-text"].tap()

        // The screens are on the stage, with no dots (YUI-168); paging opens each one there.
        waitScreens(app, 3, "the stage has no screen 3")
        XCTAssertTrue(app.descendants(matching: .any)["stage-first"].exists)
        XCTAssertFalse(app.buttons["page-tab-2"].exists, "dots on the stage")
        app.goToScreen(2)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-2"].waitForExistence(timeout: 5), "screen 2 is not on the stage")
        app.goToScreen(3)
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-3"].waitForExistence(timeout: 5), "screen 3 is not on the stage")
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-3"].staticTexts["Eggs"].exists, "the list is not on screen 3")
        sleep(1)
        shot("stage-pages")

        // The chat: just the chat, no dots, no pages beside it.
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.buttons["back-to-stage"].waitForExistence(timeout: 10), "the chat did not open")
        XCTAssertFalse(app.pagePosition.exists, "the chat still pages to the screens")
        XCTAssertFalse(app.descendants(matching: .any)["page-2"].exists, "the chat still has a screen beside it")
        sleep(1)
        shot("chat-plain")

        // A screen's pill in the chat opens the stage on that screen.
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Go to screen 3")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no screen pill in the chat")
        pill.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-screen-3"].waitForExistence(timeout: 5), "the pill did not open screen 3 on the stage")
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
