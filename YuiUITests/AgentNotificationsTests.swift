import XCTest

/// Per-agent mute (YUI-24): the Notifications switch in an agent's settings.
/// Demo account, no backend. Turn it off, save, and the agent list shows the
/// muted bell. Screenshots to TEST_RUNNER_YUI_SHOTS when set.
final class AgentNotificationsTests: XCTestCase {
    func testMuteAnAgent() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgents", "-appearance", "light"]
        app.launch()

        let edit = app.buttons["Edit Coach"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()

        let toggle = app.switches["agent-notifications"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "notifications start on")
        shot("10-notifications-on")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Coach stays quiet. Its answers wait in the thread."].waitForExistence(timeout: 5))
        shot("11-notifications-off")
        app.buttons["Save"].tap()

        let bell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Notifications off")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "the list does not show Coach as muted")
        shot("12-agents-muted")
    }
}
