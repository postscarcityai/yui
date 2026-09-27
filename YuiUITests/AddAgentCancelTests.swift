import XCTest

/// Add agent, then Cancel, crashed build 229 (feedback AGjOqLXN): the chat redrew
/// under the sheet and its view type ran the main stack out. Open and cancel it
/// twice, with stage first on and off, and the app is still up with its chat.
/// Demo account, no backend. Screenshots to TEST_RUNNER_YUI_SHOTS when set.
final class AddAgentCancelTests: XCTestCase {
    func testCancelAddAgentStageFirstOff() { run(stageFirst: false) }
    func testCancelAddAgentStageFirstOn() { run(stageFirst: true) }

    private func run(stageFirst: Bool) {
        let tag = stageFirst ? "stage" : "record"
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(tag).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(tag)"
            a.lifetime = .keepAlways
            add(a)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", stageFirst ? "YES" : "NO", "-yuiDemoAccount", "-yuiDemoAgents",
                               "-yuiAgents", "-appearance", "light"]
        app.launch()

        for round in 1...2 {
            // The list opens at medium height: Add agent is under the crew.
            XCTAssertTrue(app.navigationBars["Your agents"].waitForExistence(timeout: 15), "no agents list")
            let add = app.buttons["Add agent"].firstMatch
            for _ in 0..<4 where !(add.exists && add.isHittable) { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add agent (round \(round))")
            add.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Add agent did not open (round \(round))")
            if round == 1 { shot("01-add-agent") }
            cancel.tap()
            XCTAssertTrue(app.navigationBars["Your agents"].waitForExistence(timeout: 10), "back to the list (round \(round))")
            XCTAssertEqual(app.state, .runningForeground, "the app went down after Cancel (round \(round))")
        }
        shot("02-after-cancel")
        app.buttons["Done"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app went down closing the list")
        shot("03-chat")
    }
}
