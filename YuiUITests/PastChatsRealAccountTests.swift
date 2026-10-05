import XCTest

/// YUI-254: past chats show in the drawer on a real account. Driven by scripts/past_chats_real_account.py,
/// which seeds a throwaway account the way a long-time account looks: an old first chat with 130 rows,
/// "Tuesday groceries" and an untitled chat about protein. Newest first under New chat, each with title,
/// last line and when; the old one reads "Earlier"; a tap opens it and the thread scrolls back to its
/// very first message, past the 100 a chat opens on. Skips without the driver's environment.
final class PastChatsRealAccountTests: XCTestCase {
    private var shots = URL(fileURLWithPath: "/tmp")
    private var tag = "dark"

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(tag)-\(name).png"))
    }

    func testPastChatsListAndScrollBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else { throw XCTSkip("driver only") }
        shots = URL(fileURLWithPath: dir)
        tag = env["YUI_APPEARANCE"] ?? "dark"
        continueAfterFailure = false
        let app = XCUIApplication()
        func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func openDrawer() {
            let menu = app.buttons["Agent menu"].firstMatch
            if menu.waitForExistence(timeout: 5) { menu.tap() } else { app.swipeRight() }
            XCTAssertTrue(any("drawer-agent-bar").waitForExistence(timeout: 8), "no drawer")
        }

        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", tag,
                              "-selectedAgent", env["YUI_AGENT"] ?? "", "-yuiStageFirst", "NO"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        // The thread opens on the newest chat.
        let opened = text("1.6 grams per kilo").waitForExistence(timeout: 60)
        shot("0-launch")
        if !opened { print(app.debugDescription.prefix(6000)) }
        XCTAssertTrue(opened, "the newest chat did not open")
        sleep(2)

        // The drawer: New chat, then the three chats, newest first.
        openDrawer()
        let protein = app.buttons.matching(NSPredicate(format: "label CONTAINS 'How much protein'")).firstMatch
        let groceries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tuesday groceries'")).firstMatch
        let earlier = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Earlier'")).firstMatch
        XCTAssertTrue(protein.waitForExistence(timeout: 10), "newest chat missing from the drawer")
        XCTAssertTrue(groceries.exists, "the named chat is missing from the drawer")
        XCTAssertTrue(earlier.exists, "the old chat is not called Earlier")
        XCTAssertTrue(groceries.label.contains("What should I buy") || groceries.label.contains("Eggs"), "no last line: \(groceries.label)")
        XCTAssertLessThan(protein.frame.minY, groceries.frame.minY, "not newest first")
        XCTAssertLessThan(groceries.frame.minY, earlier.frame.minY, "Earlier is not last")
        shot("1-drawer")

        // Open Earlier: its newest rows, then back to its first message.
        earlier.tap()
        XCTAssertTrue(text("Old answer 65").waitForExistence(timeout: 20), "Earlier did not open on its newest rows")
        shot("2-earlier-open")
        var tries = 0
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "^Old question 1([^0-9].*)?$")).firstMatch
        while !first.exists, tries < 150 { app.swipeDown(velocity: .fast); tries += 1; if tries % 4 == 0 { sleep(1) } }
        shot("3-top-try")
        XCTAssertTrue(first.waitForExistence(timeout: 20), "never reached the first message after \(tries) swipes")
        shot("3-earlier-top")
        print("scroll-back swipes \(tries)")
    }
}
