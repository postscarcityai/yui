import XCTest

/// YUI-231: on a real account (chat first, no demo, no -yuiStageFirst) Open on Yui's card lands on
/// Arnold's first question within 4 s, and switching to Arnold by the agent bar shows it too.
/// Driven by scripts/open_real_account.py, which makes the throwaway account and passes its session
/// in TEST_RUNNER_YUI_RT / _USER / _SHOTS. Skips without them.
final class OpenRealAccountTests: XCTestCase {
    private var shots = URL(fileURLWithPath: "/tmp")
    private var tag = "dark"

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(tag)-\(name).png"))
    }

    func testOpenLandsOnArnoldsFirstQuestion() throws {
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
        let question = "What are we training for?"

        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", tag]
        app.launch()
        XCTAssertTrue(any("crew-pick-title").waitForExistence(timeout: 60), "no picker")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }

        // Pick Arnold, Basil and Penny, Start.
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

        // Get fit: Yui points at Arnold with an Open card (always, not model luck).
        app.buttons["Get fit"].firstMatch.tap()
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open Arnold'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 90), "no Open Arnold card after Get fit")
        shot("1-open-card")

        // 1. Open lands on the first question within 4 s.
        open.tap()
        let t0 = Date()
        let landed = text(question).waitForExistence(timeout: 4)
        shot("2-after-open")
        XCTAssertTrue(landed, "Open did not land on Arnold's first question within 4 s")
        print("open-to-question \(Date().timeIntervalSince(t0))s")

        // 2. Away to Yui and back by the agent bar: the question is on screen again within 4 s.
        func switchTo(_ name: String) {
            let menu = app.buttons["Agent menu"].firstMatch
            if menu.waitForExistence(timeout: 5) { menu.tap() } else { app.swipeRight() }
            let bar = any("drawer-agent-bar")
            XCTAssertTrue(bar.waitForExistence(timeout: 8), "no agent bar")
            bar.tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8), "\(name) not in the switcher")
            row.tap()
        }
        // The plan sits over the chat: closing it leaves the record, Skip card under the chip.
        let close = app.buttons["Close full screen"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap(); sleep(1) }
        shot("2b-closed")
        switchTo("Yui")
        sleep(2)
        switchTo("Arnold")
        let shown = text(question).waitForExistence(timeout: 4)
        shot("3-after-switch")
        XCTAssertTrue(shown, "agent bar switch did not show Arnold's first question within 4 s")
    }
}
