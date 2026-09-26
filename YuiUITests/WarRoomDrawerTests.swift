import XCTest

/// The war room lives in the drawer (YUI-126, feedback AGhvH8tM: "the left drawer should be
/// more of the war room"). The host sends it as `menu` lines only (yui_war_room.py): Review
/// holds what waits on the person, Home reads the status line, a row per busy lane, the queue
/// and the board. Nothing draws in the chat. A tap on a Review row goes back to the host,
/// which answers with that ask as one choose (hermes-plugin needs.opened, no agent turn).
/// Demo account, no network. Shots go to `YUI_SHOTS`.
final class WarRoomDrawerTests: XCTestCase {
    /// What `yui_war_room.py` sends, bottom row first (the drawer puts the newest on top).
    static let drawer = [
        #"menu review@need-t_63c96e7a "Measure how fast a pad sounds" sub="How should we measure it?""#,
        #"menu review@need-t_85ea7583 "ChatGPT adapter through the Yui MCP server" sub="How did it go?""#,
        #"menu backlog@links "The whole board" sub="Roadmap, builds and progress" url=https://www.yuigui.com/board"#,
        #"menu backlog@next-2 "Tuner and metronome in the app" sub=Queued url=https://www.yuigui.com/board"#,
        #"menu backlog@next-1 "Apple Watch: timer and quick answers on the wrist" sub=Queued url=https://www.yuigui.com/board"#,
        #"menu backlog@next-0 "MVP acceptance run: a stranger does the whole path" sub=Next url=https://www.yuigui.com/board"#,
        #"menu backlog@lane-SITE "Brand direction, one system from site to social" sub="Now · Site lane" url=https://www.yuigui.com/board"#,
        #"menu backlog@lane-APP "The war room moves into the drawer" sub="Now · App lane" url=https://www.yuigui.com/board"#,
        #"menu backlog@status "Build 176 on TestFlight" sub="4 changes on main · Yui 0.3.2 shipped, next not picked" url=https://www.yuigui.com/board"#,
    ]

    /// What the host answers a tap on the first Review row with (`yui_war_room.py --ask`).
    static let ask = #"choose@need-t_85ea7583 "How did it go?" Works|"Phone only"|Failed|"Not yet"|"You decide" title="ChatGPT adapter through the Yui MCP server" body="Yui is built as a ChatGPT connector too. The last check needs your browser: add Yui as a connector, then ask for a screen.""#

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ appearance: String) throws {
        let tag = "warroom-\(appearance)"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
            }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(tag)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", appearance,
                               "-yuiThemeDemo", (["say Hi Chris."] + Self.drawer).joined(separator: "\\n"),
                               "-yuiDemoPrompt", "Where are we?", "-yuiDemoReply", "say Here we go."]
        app.launch()

        XCTAssertTrue(app.staticTexts["Hi Chris."].waitForExistence(timeout: 20), "the reply never landed")
        XCTAssertFalse(app.staticTexts["Build 176 on TestFlight"].exists, "a menu line drew in the chat")
        let menu = app.buttons["Agent menu"]
        waitValue(menu, "2 waiting on you", "the asks are not counted")
        sleep(1)
        shot("0-chat")

        // Home: status on top, then the busy lanes, the queue and the board.
        menu.tap()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu button did not open the drawer")
        waitHittable(close, "the drawer did not settle open")
        XCTAssertTrue(app.buttons["drawer-next-up"].exists, "no next-up for the asks")
        let order = ["status", "lane-APP", "lane-SITE", "next-0", "next-1", "next-2", "links"].map { app.buttons["drawer-backlog-\($0)"] }
        for e in order { XCTAssertTrue(e.exists, "missing Home row \(e.identifier)") }
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(a.frame.minY, b.frame.minY, "\(a.identifier) should sit above \(b.identifier)")
        }
        sleep(1)
        shot("1-home")

        // Review: the asks, a tap goes back to the host and closes the drawer.
        app.buttons["drawer-tab-review"].tap()
        let row = app.buttons["review-menu-need-t_85ea7583"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no ask on Review")
        XCTAssertTrue(app.buttons["review-menu-need-t_63c96e7a"].exists, "the second ask is missing")
        XCTAssertLessThan(row.frame.minY, app.buttons["review-menu-need-t_63c96e7a"].frame.minY, "board order")
        sleep(1)
        shot("2-review")
        row.tap()
        waitGone(close, "a tap on the ask did not close the drawer")
        XCTAssertTrue(app.staticTexts["ChatGPT adapter through the Yui MCP server"].waitForExistence(timeout: 5),
                      "the tap did not go back to the host")
        app.terminate()

        // What the host answers the tap with: the ask as one choose, Not yet and You decide last.
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", appearance,
                               "-yuiThemeDemo", (Self.drawer + [Self.ask]).joined(separator: "\\n"),
                               "-yuiDemoPrompt", "ChatGPT adapter through the Yui MCP server", "-yuiDemoReply", "say Here we go."]
        app.launch()
        let decide = app.buttons["You decide"]
        XCTAssertTrue(decide.waitForExistence(timeout: 20), "the ask never landed")
        XCTAssertTrue(app.buttons["Not yet"].exists)
        sleep(1)
        shot("3-ask")
    }

    private func waitHittable(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }

    private func waitValue(_ e: XCUIElement, _ value: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 8), .completed, why, file: file, line: line)
    }

    private func waitGone(_ e: XCUIElement, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [x], timeout: 6), .completed, why, file: file, line: line)
    }
}
