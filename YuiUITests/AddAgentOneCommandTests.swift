import XCTest

/// A stranger finds Add an agent in the drawer, and pairing is one command (YUI-229).
/// Stranger run Sep 30: the row hid behind the agent bar's switcher, and the sheet
/// listed three commands. Demo account, no backend. Shots to YUI_SHOTS when set.
final class AddAgentOneCommandTests: XCTestCase {
    func testDrawerRowOpensAddSheetDark() { drawer("dark") }
    func testDrawerRowOpensAddSheetLight() { drawer("light") }
    func testPairingIsOneCommandDark() { pairing("dark") }
    func testPairingIsOneCommandLight() { pairing("light") }

    private func shooter(_ appearance: String) -> (String) -> Void {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(appearance).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }
        return shot
    }

    private func drawer(_ appearance: String) {
        let shot = shooter(appearance)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiDrawer", "-appearance", appearance]
        app.launch()

        XCTAssertTrue(app.buttons["drawer-agent-bar"].waitForExistence(timeout: 20), "no drawer")
        sleep(1)
        shot("01-drawer")
        // The last row of the agent switcher, not a button in the drawer.
        XCTAssertFalse(app.buttons["drawer-add-agent"].exists, "Add an agent is still a drawer button")
        app.buttons["drawer-agent-bar"].tap()
        let row = app.buttons["switch-add"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Add an agent row in the switcher")
        XCTAssertTrue(row.isHittable, "Add an agent is not in view")
        row.tap()

        let get = app.buttons["Get a pairing code"]
        XCTAssertTrue(get.waitForExistence(timeout: 10), "the drawer row did not open the add sheet")
    }

    private func pairing(_ appearance: String) {
        let shot = shooter(appearance)
        let app = XCUIApplication()
        // The sheet opens named, and asks for its code at once.
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgents", "-yuiAddAgent", "-yuiAddAgentCode",
                               "-appearance", appearance]
        app.launch()
        let command = app.descendants(matching: .any)["pair-command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10), "no pairing command")
        sleep(1)
        shot("02-pairing")

        // One command: all three steps joined, the code inside.
        let text = command.label
        XCTAssertTrue(text.contains("hermes plugins install"), text)
        XCTAssertTrue(text.contains("&& hermes yui pair "), text)
        XCTAssertTrue(text.hasSuffix("&& hermes gateway restart"), text)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy")).count, 1, "more than one Copy")

        let copy = app.buttons["pair-copy"]
        XCTAssertTrue(copy.isHittable)
        // The test runner may not read the pasteboard; YuiTests/PairingCommandTests pins what Copy writes.
        copy.tap()
        sleep(1)
        shot("03-copied")
    }
}
