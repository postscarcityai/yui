import XCTest

/// Your $U in the left drawer (YUI-210): the coin and the number top right, a count up once when the total
/// grew since the person last saw it (the pill fades to green), a tap opens Your $U. Demo account, no network.
/// Shots go to `YUI_SHOTS`.
final class YourUTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }
    func testReduceMotion() throws { try run("light", reduceMotion: true) }

    private func run(_ appearance: String, reduceMotion: Bool = false) throws {
        let tag = "your-u-\(appearance)\(reduceMotion ? "-reduce" : "")"
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
        // The demo person last saw 1,202; the ledger says 1,284: it counts up once on opening.
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiDrawer", "-yuiEarnSeen", "1202"]
        if reduceMotion { app.launchArguments += ["-yuiReduceMotion"] }
        app.launch()

        let pill = app.buttons["drawer-u"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no $U in the drawer")
        XCTAssertTrue(app.buttons["drawer-settings"].exists, "no profile top left")
        XCTAssertFalse(app.buttons["Close"].exists, "the X is still there")
        if !reduceMotion {
            usleep(1_100_000)
            shot("0-climbing")
        }
        for _ in 0..<80 where (pill.value as? String) != "1,284" { usleep(100_000) }
        XCTAssertEqual(pill.value as? String, "1,284", "the number never reached the new total")
        sleep(1)
        shot("1-settled")

        pill.tap()
        XCTAssertTrue(app.staticTexts["u-note"].waitForExistence(timeout: 5), "Your $U did not open")
        XCTAssertEqual(app.staticTexts["u-total"].label, "1,284")
        XCTAssertTrue(app.staticTexts["No cash value. Not a token yet."].exists)
        sleep(1)
        shot("2-your-u")
    }
}
