import XCTest

/// YUI-101. Chris, Sep 25: "I am not getting ultra smoothness when I click around.
/// Things feel delayed. Very efficient like Telegram." On a 500-row thread (text,
/// markdown, long answers that fold, cards, two screens), walk the paths he uses:
/// scroll far up and back, swipe to the screens, open the drawer, switch threads,
/// tap a choose, react, send, open a card full screen. Demo account, no network.
///
/// With `-yuiSpeed YES` the app logs every PERF.md interval, each tap (`tap`) and
/// each late frame (`hitch`). `scripts/smoothness.sh` streams that log around this
/// test, cuts it at the `SMOOTH` marks printed here, and prints the table.
/// SMOOTH_ROWS (TEST_RUNNER_SMOOTH_ROWS) is the rows file the script writes.
/// Screenshots go to `YUI_SHOTS` when set.
final class SmoothnessTests: XCTestCase {
    func testClickingAroundALongThread() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rows = env["SMOOTH_ROWS"] else { throw XCTSkip("run through scripts/smoothness.sh") }
        let shots = env["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        let appearance = env["SMOOTH_APPEARANCE"] ?? "light"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "smooth-\(appearance)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "smooth-\(appearance)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        // SMOOTH_ONLY=swipe,open: just those steps after the launch (for a profile).
        let only = env["SMOOTH_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        func want(_ step: String) -> Bool { only?.contains(step) ?? true }
        func mark(_ phase: String, _ edge: String) {
            print("SMOOTH \(phase) \(edge) \(String(format: "%.3f", Date().timeIntervalSince1970))")
        }

        let app = XCUIApplication()
        app.launchArguments = (want("auto") ? ["-yuiAutoScroll"] : []) + ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiThreadRows", rows, "-yuiSpeed", "YES",
                               "-yuiBodyLog", "-yuiDemoReply", "say Got it.", "-appearance", appearance]
        mark("launch", "begin")
        app.launch()
        let newest = app.staticTexts["The newest answer, at the bottom of a long thread."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "the long thread did not load")
        sleep(2)
        mark("launch", "end")
        shot("1-thread")

        // Drags from the left margin: over a card they would scroll the card.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.25))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.8))

        if want("auto") {
            // The app scrolls itself 90 rows up and back (-yuiAutoScroll, 4 s after it
            // loads): frames timed with nothing from the test in the way.
            mark("auto", "begin")
            sleep(16)
            mark("auto", "end")
        }

        if want("scroll") {
            // Scroll: far up in quick flicks, a pause, then back down the same way.
            mark("scroll", "begin")
            for _ in 0..<8 { top.press(forDuration: 0.01, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0) }
            sleep(1)
            shot("2-scrolled-up")
            for _ in 0..<4 { bottom.press(forDuration: 0.01, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0) }
            sleep(1)
            mark("scroll", "end")
        }

        if want("jump") {
            // The arrow back to the newest message.
            mark("jump", "begin")
            let jump = app.buttons["Jump to newest"]
            if jump.waitForExistence(timeout: 3) { jump.tap() }
            XCTAssertTrue(newest.waitForExistence(timeout: 5), "the arrow did not bring the newest message back")
            sleep(1)
            mark("jump", "end")
        }

        if want("swipe") {
            // Screens 2 and 3 by their tabs, then swiped back. (A swipe left on the chat
            // lands on a message and starts a reply, so forward goes by tab.)
            mark("swipe", "begin")
            let tab2 = app.buttons["page-tab-2"]
            XCTAssertTrue(tab2.waitForExistence(timeout: 5), "no screen 2 tab")
            tab2.tap()
            sleep(1)
            shot("3-screen-2")
            app.buttons["page-tab-3"].tap()
            sleep(1)
            app.swipeRight()
            sleep(1)
            app.swipeRight()
            sleep(1)
            XCTAssertTrue(newest.waitForExistence(timeout: 5), "not back on the chat")
            mark("swipe", "end")
        }

        if want("open") {
            // The drawer, then another thread and back: each a warm open of 500 rows.
            mark("drawer", "begin")
            let menu = app.buttons["Agent menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            let bar = app.buttons["drawer-agent-bar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "the drawer did not open")
            sleep(1)
            shot("4-drawer")
            mark("drawer", "end")
            mark("open", "begin")
            bar.tap()
            let coach = app.buttons["switch-Coach"]
            XCTAssertTrue(coach.waitForExistence(timeout: 5), "no Coach in the switcher")
            coach.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 10), "Coach's thread did not open")
            sleep(1)
            menu.tap()
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            bar.tap()
            let yui = app.buttons["switch-Yui"]
            XCTAssertTrue(yui.waitForExistence(timeout: 5), "no Yui in the switcher")
            yui.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 10), "Yui's thread did not open")
            sleep(1)
            mark("open", "end")
        }

        if want("choose") {
            // A choose, answered, and changed.
            mark("choose", "begin")
            let pull = app.buttons["Pull"].firstMatch
            XCTAssertTrue(pull.waitForExistence(timeout: 5), "no choose near the bottom")
            pull.tap()
            sleep(1)
            app.buttons["Legs"].firstMatch.tap()
            sleep(1)
            shot("5-chose")
            mark("choose", "end")
        }

        if want("react") {
            // React: hold the newest answer, tap a reaction.
            mark("react", "begin")
            newest.press(forDuration: 0.6)
            let love = app.buttons["react-love it"]
            XCTAssertTrue(love.waitForExistence(timeout: 5), "no reaction bar")
            love.tap()
            sleep(2)
            shot("6-reacted")
            mark("react", "end")
        }

        if want("send") {
            // Send: the bubble goes up on the tap, the demo agent answers.
            mark("send", "begin")
            let field = app.descendants(matching: .any)["composer"].firstMatch
            field.tap()
            sleep(1)
            field.typeText("Hi there")
            app.buttons.matching(identifier: "Send").firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Hi there"].waitForExistence(timeout: 5), "the sent bubble did not show")
            sleep(3)
            shot("7-sent")
            mark("send", "end")
        }

        if want("full") {
            // A card full screen, and closed.
            mark("full", "begin")
            app.swipeDown()  // keyboard away
            let pill = app.buttons["Open Tabata full screen"].firstMatch
            for _ in 0..<3 where !pill.isHittable { top.press(forDuration: 0.01, thenDragTo: bottom) }
            XCTAssertTrue(pill.waitForExistence(timeout: 5), "no full-screen pill")
            pill.tap()
            let close = app.buttons["Close full screen"]
            XCTAssertTrue(close.waitForExistence(timeout: 5), "the stage did not open")
            sleep(1)
            shot("8-full")
            close.tap()
            sleep(1)
            mark("full", "end")
        }
    }
}
