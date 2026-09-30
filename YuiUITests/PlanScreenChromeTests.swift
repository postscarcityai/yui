import XCTest

/// YUI-235: on a real account (chat first, no demo) the plan build lands the pager on Arnold's last screen,
/// where the nav bar is off. The person must still have a way out: the menu button opens the drawer with
/// "Add an agent", the chat button goes back to the record. Found by the 0.6.2 stranger run (4 of 4).
/// Driven by scripts/open_real_account.py --only PlanScreenChromeTests (throwaway account, YUI_RT/_USER/_SHOTS).
final class PlanScreenChromeTests: XCTestCase {
    private var shots = URL(fileURLWithPath: "/tmp")
    private var tag = "dark"

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(tag)-\(name).png"))
    }

    func testScreenKeepsItsWayOutAfterPlanBuild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else { throw XCTSkip("driver only") }
        shots = URL(fileURLWithPath: dir)
        tag = env["YUI_APPEARANCE"] ?? "dark"
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func b(_ id: String) -> XCUIElement {
            let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
            return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
        }
        func onScreen(_ e: XCUIElement) -> Bool {
            e.exists && e.isHittable && app.windows.firstMatch.frame.contains(e.frame)
        }

        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", tag]
        app.launch()
        XCTAssertTrue(any("crew-pick-title").waitForExistence(timeout: 60), "no picker")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }
        any("crew-more-arnold").tap()
        XCTAssertTrue(text("Try asking").waitForExistence(timeout: 10))
        any("crew-page-add").tap()
        XCTAssertTrue(app.buttons["Added. Tap to remove"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        any("crew-pick-basil").tap()
        any("crew-pick-penny").tap()
        any("crew-start").tap()
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 60), "Yui's hello never came")
        sleep(2)

        // Arnold by the agent bar (Yui's own pointer to him is model luck): his first question is up.
        let menu0 = app.buttons["Agent menu"].firstMatch
        XCTAssertTrue(menu0.waitForExistence(timeout: 10), "no menu on Yui's thread")
        menu0.tap()
        let bar = any("drawer-agent-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "no agent bar")
        bar.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Arnold'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Arnold not in the switcher")
        row.tap()
        XCTAssertTrue(text("What are we training for?").waitForExistence(timeout: 15), "no first question")

        // Intake, Build my week.
        for a in ["Lift heavy", "3", "45 min", "Dumbbells", "Some experience"] {
            let o = b(a)
            XCTAssertTrue(o.waitForExistence(timeout: 8), "no answer \(a)")
            if !o.isHittable { app.swipeUp() }
            b(a).tap()
            if a == "Dumbbells" { sleep(1); let nx = app.buttons["Next"].firstMatch; if nx.exists { nx.tap(); sleep(1) } }
        }
        let send = app.buttons["Build my week"].firstMatch
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no Build my week")
        send.tap()
        XCTAssertTrue(text("Your week is built").waitForExistence(timeout: 120), "the week was not built")

        // Notifications ask, once: Yes, then the system Allow.
        let nudge = text("Want a nudge when Arnold checks in?")
        if nudge.waitForExistence(timeout: 15) {
            b("Yes").tap()
            if springboard.buttons["Allow"].waitForExistence(timeout: 10) { springboard.buttons["Allow"].tap() }
            sleep(1)
        }
        sleep(2)
        shot("plan-built")

        // The header controls are on screen wherever the plan left the pager: the stage's X, the
        // record's Agent menu, or a screen's own menu.
        let menu = app.buttons.matching(NSPredicate(format: "identifier == 'screen-menu' OR label == 'Agent menu'")).firstMatch
        let close = app.buttons["Close full screen"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8) || close.exists, "no header control after the plan was built")
        XCTAssertTrue(onScreen(menu) || onScreen(close), "the header controls are off screen or unhittable after the plan was built")

        // The drawer shows Add an agent.
        if onScreen(close) { close.tap(); sleep(1) }
        let opener = app.buttons.matching(NSPredicate(format: "identifier == 'screen-menu' OR label == 'Agent menu'")).firstMatch
        XCTAssertTrue(onScreen(opener), "no menu button to open the drawer")
        opener.tap()
        let add = app.buttons["drawer-add-agent"]
        XCTAssertTrue(add.waitForExistence(timeout: 10) && add.isHittable, "no Add an agent in the drawer")
        XCTAssertTrue(app.staticTexts["Add an agent"].exists || add.label.contains("Add an agent"), "the drawer row is not named Add an agent")
        shot("drawer")
    }
}
