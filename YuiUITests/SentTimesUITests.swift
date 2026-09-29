import XCTest

/// Every message shows when it was sent, grouped by day (YUI-202, TestFlight AB6Bae6I).
/// A thread seeded across three days shows all three dividers and a quiet time under each run.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class SentTimesUITests: XCTestCase {
    func testDividersLight() throws { try run("light") }
    func testDividersDark() throws { try run("dark") }

    private func run(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoDays", "-appearance", appearance]
        app.launch()

        let dividers = app.descendants(matching: .any).matching(identifier: "day-divider")
        XCTAssertTrue(dividers.firstMatch.waitForExistence(timeout: 15), "no day divider")
        XCTAssertEqual(dividers.count, 3, "three days, three dividers")
        XCTAssertTrue(app.descendants(matching: .any)["Today"].exists, "no Today divider")
        XCTAssertTrue(app.descendants(matching: .any)["Yesterday"].exists, "no Yesterday divider")
        let times = app.descendants(matching: .any).matching(identifier: "sent-time")
        XCTAssertEqual(times.count, 6, "one quiet time under each of the six messages")

        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "day-dividers-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "day-dividers-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
