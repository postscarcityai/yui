import XCTest

/// The top bar is for a signed-in person only (feedback AFFVLA66, build 229). Deleting Yui
/// leaves the session in the keychain, so a reinstall used to open signed in to the old
/// account: menu, agent pill and full screen button over the first run, before any
/// sign-in. A new install now starts at Sign in with nothing above it; signed in, the top
/// bar is as before. No network. `YUI_SHOTS=<dir>` saves screenshots.
final class TopBarGateTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private func run(_ appearance: String) throws {
        let app = XCUIApplication()
        let bar = ["stage-menu", "stage-agents", "stage-record"]
        func topBarGone(_ why: String) {
            for id in bar { XCTAssertFalse(app.buttons[id].exists, "\(id) shows \(why)") }
            XCTAssertFalse(app.buttons["Agent menu"].exists, "the menu shows \(why)")
            XCTAssertFalse(app.buttons["Full screen"].exists, "the full screen button shows \(why)")
        }
        let signIn = app.staticTexts["Your agents, in your pocket."]

        // 1. Reinstalled over an old session: Sign in, nothing that says you have an account.
        launch(app, appearance, ["-yuiReinstalled"])
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "a reinstall opened signed in")
        sleep(2)
        topBarGone("on a new install")
        shot("1-reinstalled", appearance)

        // 2. Signed out: the same.
        launch(app, appearance, ["-yuiSignedOut"])
        XCTAssertTrue(signIn.waitForExistence(timeout: 15), "signed out is not the sign-in screen")
        topBarGone("signed out")

        // 3. Signed in: the top bar is back, menu and agent top left, the record top right.
        launch(app, appearance, ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui"])
        XCTAssertTrue(app.buttons["stage-menu"].waitForExistence(timeout: 15), "signed in has no top bar")
        for id in bar { XCTAssertTrue(app.buttons[id].exists, "\(id) is missing signed in") }
        XCTAssertFalse(signIn.exists, "signed in still shows Sign in")
        sleep(1)
        shot("2-signed-in", appearance)
    }

    private func launch(_ app: XCUIApplication, _ appearance: String, _ extra: [String]) {
        app.terminate()
        app.launchArguments = ["-appearance", appearance] + extra
        app.launch()
    }

    private func shot(_ name: String, _ tag: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "gate-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
