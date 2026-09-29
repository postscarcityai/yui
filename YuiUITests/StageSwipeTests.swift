import XCTest

/// Sideways on the full screen, like before the stage (Chris, TestFlight AC0r0OFGJiJOcbFdbXMgHms:
/// "we lost the left and right scroll functionality ... when I scroll with my thumb towards the
/// right, I wanna pull the drawer out to the left. When I dragged my thumb from the right or
/// left, I want to show the other screens"). On the stage a drag left shows the next screen and
/// a drag right the one before; on the answer a drag right pulls the drawer out. On the chat a
/// drag left opens the stage on the first screen. The bar (+, T, mic) is on every screen.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class StageSwipeTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// The empty stage in the screenshot (Basil, nothing asked yet): a drag right opens the drawer.
    func testDrawerFromTheGreeting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.swipeRight()
        XCTAssertTrue(app.buttons["drawer-close"].waitForExistence(timeout: 5), "a drag right on the greeting did not open the drawer")
        shot("swipe-greeting-drawer-dark")
    }

    private func run(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", StagePagesTests.reply,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cooking bibimbap, keep me on track")
        app.buttons["stage-send-text"].tap()
        waitScreens(app, 3, "the stage has no screen 3")
        XCTAssertTrue(app.buttons["screen-pill-3"].isHittable, "no screen pills on the stage")
        // The reply turns the stage to its last screen; start from the answer.
        let screen = { (n: Int) in app.descendants(matching: .any)["stage-screen-\(n)"] }
        XCTAssertTrue(screen(3).waitForExistence(timeout: 10), "the reply did not show screen 3")
        app.goToScreen(1)
        XCTAssertTrue(waitGone(screen(3)), "paging did not go back to the answer")
        sleep(1)
        func bar(_ where_: String) {
            XCTAssertTrue(app.buttons["stage-type"].exists, "no T on \(where_)")
            XCTAssertTrue(app.buttons["stage-attach"].exists || app.buttons["stage-mic"].exists, "no + or mic on \(where_)")
        }

        // Left: the answer, then screen 2, then screen 3.
        app.swipeLeft()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag left on the answer did not show screen 2")
        bar("screen 2")
        shot("swipe-\(appearance)-screen2")
        app.swipeLeft()
        XCTAssertTrue(screen(3).waitForExistence(timeout: 5), "a drag left on screen 2 did not show screen 3")
        bar("screen 3")
        shot("swipe-\(appearance)-screen3")

        // Right: back one screen at a time, and no drawer on the way.
        app.swipeRight()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag right on screen 3 did not go back to screen 2")
        XCTAssertFalse(app.buttons["drawer-close"].exists, "the drawer opened from screen 3")
        app.swipeRight()
        XCTAssertTrue(waitGone(screen(2)), "a drag right on screen 2 did not go back to the answer")
        XCTAssertFalse(app.buttons["drawer-close"].exists, "the drawer opened from screen 2")
        bar("the answer")

        // On the answer a drag right pulls the drawer out.
        app.swipeRight()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "a drag right on the answer did not open the drawer")
        sleep(1)
        shot("swipe-\(appearance)-drawer")
        close.tap()
        XCTAssertTrue(waitGone(close), "the drawer did not close")

        // The chat: a drag left opens the stage on screen 2.
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.buttons["back-to-stage"].waitForExistence(timeout: 10), "the chat did not open")
        sleep(1)
        app.swipeLeft()
        XCTAssertTrue(screen(2).waitForExistence(timeout: 5), "a drag left on the chat did not open screen 2 on the stage")
        bar("screen 2 from the chat")
    }

    // MARK: Screen pills (YUI-193)

    /// Chris Sep 28: "some pills for the screens ... kind of like tabs on an internet browser. If
    /// there are no screens we shouldn't have them ... They fade out to the right and I can slide
    /// them back and forth. And when I swipe left and right through the screens, it just shows me
    /// which screen I'm on with an active pill." Top bar, right of the menu; the dots are gone.
    func testNoScreensNoPills() throws {
        for appearance in ["light", "dark"] {
            let app = pillsApp(appearance, reply: nil)
            XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
            sleep(1)
            XCTAssertFalse(app.descendants(matching: .any)["screen-pills"].exists, "pills with no screens")
            XCTAssertFalse(app.buttons["screen-pill-1"].exists, "a Home pill with no screens")
            XCTAssertFalse(app.buttons["stage-agents"].exists, "the agent pill is still in the top bar")
            XCTAssertTrue(app.buttons["stage-menu"].exists && app.buttons["stage-record"].exists, "the bar lost a button")
            shot("pills-0-\(appearance)")
            app.terminate()
        }
    }

    func testOneScreen() throws {
        for appearance in ["light", "dark"] {
            let app = pillsApp(appearance, reply: ["say Your timer is on screen 2.", ">2 timer 25m Focus"].joined(separator: "\\n"))
            try sendCooking(app)
            waitScreens(app, 2, "the stage has no screen 2")
            let home = app.buttons["screen-pill-1"], two = app.buttons["screen-pill-2"]
            XCTAssertTrue(two.waitForExistence(timeout: 5) && home.exists, "Home and screen 2 have no pills")
            XCTAssertFalse(app.buttons["screen-pill-3"].exists, "a pill for a screen that is not there")
            XCTAssertLessThan(app.buttons["stage-menu"].frame.maxX, home.frame.minX, "the pills are not right of the menu")
            XCTAssertLessThan(home.frame.minY, 120, "the pills are not in the top bar")
            let on = app.screenShown ?? 1
            XCTAssertTrue((on == 2 ? two : home).isSelected && !(on == 2 ? home : two).isSelected, "the active pill is not screen \(on)")
            shot("pills-1-\(appearance)")
            if on != 2 {
                two.tap()
                waitScreen(app, 2, "a tap on the pill did not go to screen 2")
                XCTAssertTrue(two.isSelected && !home.isSelected, "the tap did not move the active pill")
            }
            home.tap()
            waitScreen(app, 1, "a tap on Home did not go home")
            XCTAssertTrue(home.isSelected && !two.isSelected, "Home's pill is not active")
            app.terminate()
        }
    }

    /// Eight screens: the row overflows and fades out at the right, a tap jumps, a swipe moves
    /// the active pill and scrolls it into view.
    func testEightScreensLight() throws { try eight("light") }
    func testEightScreensDark() throws { try eight("dark") }

    private func eight(_ appearance: String) throws {
        let lines = ["say Eight screens."] + (2...8).map { ">\($0) list@s\($0) \"Plan \($0)\" Eggs|Milk +check" }
        let app = pillsApp(appearance, reply: lines.joined(separator: "\\n"))
        try sendCooking(app)
        waitScreens(app, 8, "the stage has no screen 8")
        let pill = { (n: Int) in app.buttons["screen-pill-\(n)"] }
        let win = app.windows.firstMatch.frame
        XCTAssertTrue(pill(8).waitForExistence(timeout: 10), "no pill for screen 8")
        waitScreen(app, 8, "the reply did not turn to screen 8")
        XCTAssertTrue(pill(8).isSelected, "screen 8 is on show but its pill is not active")
        XCTAssertTrue(pill(8).isHittable, "the active pill did not scroll into view")
        XCTAssertLessThanOrEqual(pill(8).frame.maxX, win.maxX, "the active pill is off the right edge")
        sleep(1)
        shot("pills-8-\(appearance)-last")

        // Home first: the pills slid back, and the far ones are past the fade.
        app.goToScreen(1)
        waitScreen(app, 1, "did not get home")
        XCTAssertTrue(pill(1).isSelected, "Home is on show but its pill is not active")
        XCTAssertTrue(pill(1).isHittable, "the Home pill scrolled out of view")
        sleep(1)
        XCTAssertFalse(pill(8).isHittable, "eight pills fit with nothing to scroll or fade")
        shot("pills-8-\(appearance)-home")

        // A tap jumps.
        XCTAssertTrue(pill(3).isHittable, "the third pill is not reachable")
        pill(3).tap()
        waitScreen(app, 3, "a tap on the third pill did not go to screen 3")
        XCTAssertTrue(pill(3).isSelected && !pill(1).isSelected, "the tap did not move the active pill")

        // A swipe moves the active pill along.
        app.swipeLeft()
        waitScreen(app, 4, "a swipe left did not go to screen 4")
        XCTAssertTrue(pill(4).isSelected && !pill(3).isSelected, "the swipe did not move the active pill")
        app.swipeLeft(); app.swipeLeft(); app.swipeLeft()
        waitScreen(app, 7, "three swipes did not reach screen 7")
        XCTAssertTrue(pill(7).isSelected, "the active pill is not screen 7")
        XCTAssertTrue(pill(7).isHittable, "the active pill did not scroll into view on the swipe")
        app.swipeRight()
        waitScreen(app, 6, "a swipe right did not go back to screen 6")
        XCTAssertTrue(pill(6).isSelected, "the swipe back did not move the active pill")
        sleep(1)
        shot("pills-8-\(appearance)-swiped")

        // The pills scroll by hand too.
        let row = app.descendants(matching: .any)["screen-pills"]
        row.swipeLeft()
        sleep(1)
        XCTAssertTrue(pill(8).isHittable, "a swipe on the pills did not slide the row")
    }

    private func pillsApp(_ appearance: String, reply: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance]
            + (reply.map { ["-yuiDemoReply", $0, "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2"] } ?? [])
        app.launch()
        return app
    }

    private func sendCooking(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Cooking bibimbap, keep me on track")
        app.buttons["stage-send-text"].tap()
    }

    /// Two chunks (so the page arrows show) and two more screens.
    static let chunked = [
        "say \"Rice first, then the greens.\"",
        "shapes w=10 h=6 caption=\"Rice, then spinach.\"",
        "shape box Rice at=3,3 +fill",
        "shape box Spinach at=7,3 tone=mint",
        "say \"The egg goes on last.\"",
        "shapes w=10 h=6 caption=\"A fried egg on top.\"",
        "shape circle Egg at=5,3 +fill +grow",
        ">2 timer 25m Focus",
        ">3 list@shop Shopping Eggs|Spinach|Rice|Gochujang +check",
    ].joined(separator: "\\n")

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !e.exists { return true }; usleep(200_000) }
        return !e.exists
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
