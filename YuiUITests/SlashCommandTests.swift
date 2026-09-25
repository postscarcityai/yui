import XCTest

/// Slash commands in the composer (YUI-61): typing / shows the commands the
/// agent's host accepts, typing filters them, a tap fills the composer and Send
/// passes the command through bare.
///
/// The demo test needs nothing: demo agents report no commands, so no popover.
/// The live test needs a real session with a Hermes agent whose gateway reported
/// its list (hermes-plugin/yui/commands.py). One FRESH refresh token per launch
/// (a spent one signs out every device); it runs light, then dark:
///
///   TEST_RUNNER_YUI_RTS=<rt1>,<rt2> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/SlashCommandTests
///
/// The live run sends `/status` (harmless: the gateway answers it with no model
/// turn) and waits for the answer. `/new` is filled, never sent: it would reset
/// the agent's session.
final class SlashCommandTests: XCTestCase {
    private let placeholder = "Say something nice"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["composer"].firstMatch
    }

    private func shown(_ e: XCUIElement) -> String {
        let v = (e.value as? String) ?? ""
        return v == placeholder ? "" : v
    }

    private func clear(_ e: XCUIElement) {
        let n = shown(e).count
        if n > 0 { e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n)) }
    }

    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["slash-\(name)"].firstMatch
    }

    func testDemoAgentShowsNoSuggestions() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", "light"]
        app.launch()
        let input = field(app)
        XCTAssertTrue(input.waitForExistence(timeout: 20), "no composer")
        input.tap()
        input.typeText("/")
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["slash"].exists, "a demo agent has no command list")
        shot("slash-demo-none")
    }

    func testLiveCommandsLightThenDark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RTS (two refresh tokens) and TEST_RUNNER_YUI_USER to run live")
        }
        try walk(rt: rts[0], user: user, appearance: "light", send: true)
        try walk(rt: rts[1], user: user, appearance: "dark", send: false)
    }

    private func walk(rt: String, user: String, appearance: String, send: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", appearance]
        app.launch()
        let input = field(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30), "no composer")
        sleep(2)  // the agent list, with its commands, loads after sign-in
        input.tap()

        // A slash alone: the host's commands, with their descriptions.
        input.typeText("/")
        let popover = app.descendants(matching: .any)["slash"].firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 10), "no suggestions for /")
        let new = row(app, "new")
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        XCTAssertTrue(new.label.hasPrefix("/new, Start a new session"), new.label)
        XCTAssertFalse(row(app, "sethome").exists, "a gateway-ops command is hidden")
        XCTAssertFalse(row(app, "yolo").exists)
        shot("slash-\(appearance)-01-all")

        // Typing filters.
        input.typeText("mo")
        XCTAssertTrue(row(app, "model").waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, "new").exists, "/mo leaves /new out")
        shot("slash-\(appearance)-02-filtered")

        // A tap fills the composer: /new takes a name, so a space follows.
        clear(input)
        input.typeText("/ne")
        XCTAssertTrue(row(app, "new").waitForExistence(timeout: 5))
        row(app, "new").tap()
        XCTAssertEqual(shown(input), "/new ")
        XCTAssertFalse(popover.exists, "the popover closes once the name is done")
        shot("slash-\(appearance)-03-filled")
        clear(input)
        guard send else { return }

        // Send goes out bare, and the gateway answers it.
        let before = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "session")).count
        input.typeText("/sta")
        XCTAssertTrue(row(app, "status").waitForExistence(timeout: 5))
        row(app, "status").tap()
        XCTAssertEqual(shown(input), "/status")
        app.buttons["Send"].tap()
        XCTAssertEqual(shown(input), "", "sent")
        let deadline = Date.now.addingTimeInterval(90)
        while app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "session")).count <= before,
              Date.now < deadline { sleep(2) }
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "session")).count,
                             before, "the gateway never answered /status")
        sleep(1)
        shot("slash-\(appearance)-04-status-answered")
    }
}
