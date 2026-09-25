import XCTest

/// The chat never gets stuck shrunk (YUI-80, TestFlight AFaeNewCPfYfPseXB1jvNq8):
/// the chat steps back (scale 0.92 in a rounded mask) only while the stage is on
/// screen. Whenever no stage shows, the top bar sits where it did at launch.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` and the result bundle.
final class StuckStageTests: XCTestCase {
    private var app: XCUIApplication!
    private var tag = ""
    private var home: CGRect = .zero

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ tag: String, agent: String, appearance: String, reply: [String], extra: [String] = []) {
        self.tag = tag
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", agent, "-appearance", appearance,
                               "-yuiThemeDemo", reply.joined(separator: "\\n")] + extra
        app.launch()
        let agents = app.buttons["Agent menu"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        home = agents.frame
    }

    /// Full size: the top-left button is where it was at launch (0.92 moves it ~16 pt in).
    private func assertFullSize(_ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let agents = app.buttons["Agent menu"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "no agents button: \(why)", file: file, line: line)
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { [home] e, _ in abs((e as! XCUIElement).frame.minX - home.minX) < 1.5
                && abs((e as! XCUIElement).frame.minY - home.minY) < 1.5 }, object: agents)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed,
                       "chat still shrunk \(why): button at \(agents.frame), launch \(home)", file: file, line: line)
    }

    private var close: XCUIElement { app.buttons["Close full screen"] }

    /// Coach puts the whole reply on the stage (style screen=full). A new look then
    /// says screen=chat: nothing is staged any more. Before YUI-80 the stage vanished
    /// and the chat stayed stepped back with nothing to tap.
    func testANewLookThatUnstagesTheReplyLeavesTheChatFullSize() {
        let reply = [#"choose "Split today?" Push|Pull|Legs"#] + Array(repeating: "", count: 16) + ["theme screen=chat"]
        launch("1-look-light", agent: "coach", appearance: "light", reply: reply,
               extra: ["-yuiDemoPrompt", "Leg day?", "-yuiDemoDelay", "3"])
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the stage never opened")
        sleep(1)
        shot("1-on-stage")
        // The look lands: the stage goes and the chat is full size again.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 12), .completed, "the stage never went")
        assertFullSize("after screen=chat")
        XCTAssertTrue(app.buttons["Legs"].waitForExistence(timeout: 3), "the question is not in the chat")
        sleep(1)
        shot("2-back-in-chat")
        // Still usable: a tap on the answer lands in the chat.
        app.buttons["Legs"].tap()
        assertFullSize("after a tap")
    }

    /// The card's walk (dark): war room from the shelf, the drawer, switch agent
    /// and back. Full size whenever no stage shows.
    func testWarRoomAgentsSheetAndSwitchNeverLeaveItShrunk() {
        let room = [">2", "clear", #"stat 2 "Needs you" sub="cards waiting on your answer""#,
                    #"card "APP lane" sub="Idle""#, #"card "WEB lane" sub="Idle""#, "save war room"]
        launch("2-walk-dark", agent: "wizard", appearance: "dark", reply: room)
        let chip = app.buttons["Open war room"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "no war room on the shelf")
        // The screen went to page 2: back to the chat first.
        if !chip.isHittable { app.swipeRight() }
        sleep(1)
        assertFullSize("at rest")
        shot("1-shelf")

        // Shelf chip: the war room on stage, the chat stepped back under it.
        chip.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the shelf did not open the stage")
        sleep(1)
        shot("2-war-room-on-stage")
        close.tap()
        assertFullSize("after the X")

        // The top-left button: the agent's drawer (YUI-54), closed by its X, then by a tap on the chat beside it.
        app.buttons["Agent menu"].tap()
        let shut = app.buttons["drawer-close"]
        XCTAssertTrue(shut.waitForExistence(timeout: 5))
        sleep(1)
        shot("3-drawer")
        shut.tap()
        assertFullSize("after the drawer")

        app.buttons["Agent menu"].tap()
        XCTAssertTrue(shut.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        sleep(1)
        shot("4-drawer-closed-by-tap")
        assertFullSize("after a tap beside the drawer")

        // Switch agent and back, from the drawer's switcher.
        for name in ["Coach", "Wizard"] {
            app.buttons["Agent menu"].tap()
            XCTAssertTrue(shut.waitForExistence(timeout: 5))
            app.buttons["drawer-agent-bar"].tap()
            let row = app.buttons["switch-\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            assertFullSize("after switching to \(name)")
        }

        // War room again, swiped away this time.
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        assertFullSize("after swiping the stage away")
        sleep(1)
        shot("5-back-in-chat")
    }
}
