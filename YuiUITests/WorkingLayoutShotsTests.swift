import XCTest

/// The working screen, two layouts (Chris, TestFlight ADv4muh06N4PD2IA1sV2Fhc): A keeps the words in the
/// blob's light with the seconds floating in glass; B puts both in one glass card. The ask up top is a
/// 5 to 12 word gist, and the tool words are in the friendly voice. Shots go to `YUI_SHOTS`.
final class WorkingLayoutShotsTests: XCTestCase {
    static let ask = "No, I'm just saying that the first post was supposed to go out on December 25 and I wanna call your attention that you need to pay attention what today's date is because it's October 1, 2026"

    func testLayoutADark() throws { try run("A", "dark") }
    func testLayoutBDark() throws { try run("B", "dark") }
    func testLayoutALight() throws { try run("A", "light") }
    func testLayoutBLight() throws { try run("B", "light") }

    private func run(_ layout: String, _ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiWorkingLayout", layout,
                               "-yuiDemoReply", "say \"Done.\"", "-yuiDemoDoing", "Running a command 1/2|Searching the web 2/2",
                               "-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", "60"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 20), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(Self.ask)
        app.buttons["stage-send-text"].tap()
        let working = app.descendants(matching: .any)["stage-working"]
        XCTAssertTrue(working.waitForExistence(timeout: 5), "no working state after send")
        let first = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Tinkering away'"), object: working)
        XCTAssertEqual(XCTWaiter.wait(for: [first], timeout: 30), .completed, "friendly verb missing: \(working.label)")
        XCTAssertFalse(working.label.contains("Running a command"), "the ominous words are still shown")
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.exists)
        Thread.sleep(forTimeInterval: 2)
        shot("1-tinkering", layout, appearance)
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Looking around the web'"), object: working)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 30), .completed, "no second verb: \(working.label)")
        Thread.sleep(forTimeInterval: 1.5)
        shot("2-searching", layout, appearance)
    }

    private func shot(_ name: String, _ layout: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "working-\(layout)-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "working-\(layout)-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
