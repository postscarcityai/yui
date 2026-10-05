import XCTest

/// The drawer's Home is the chats and nothing else (Chris, TestFlight Oct 5, feedback AIfHO1cOmCQce0abL4a4zUQ:
/// "I just wanna keep the first screen just to the chats ... make it cleaner"). Flows, pinned screens, the
/// backlog sit in one short list under Agent > More; Next up, screens and shortcut rows are cut (chips and pills have them).
/// `YUI_SHOTS=<dir>` saves the shots.
final class HomeChatsOnlyTests: XCTestCase {
    static let lines = [
        #"menu backlog@status "Yui 0.6.2, build 451 on TestFlight" sub="TestFlight: 26 changes waiting" url=https://www.yuigui.com/board"#,
        #"menu shortcut "Start workout""#,
        #"menu shortcut "Log a meal" say="Log a meal: ""#,
        #"menu review@dana "Sunday, Oct 4" sub="Pick one""#,
    ]

    func testDark() { run("dark") }
    func testLight() { run("light") }

    private func run(_ appearance: String) {
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(appearance).png"))
            }
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui", "-appearance", appearance,
                               "-yuiThemeDemo", (["say Hi Chris."] + Self.lines).joined(separator: "\\n"),
                               "-yuiDemoPrompt", "Where are we?", "-yuiDemoReply", "say Here we go."]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hi Chris."].waitForExistence(timeout: 20), "the reply never landed")
        sleep(1)
        app.buttons["Agent menu"].tap()
        let close = app.buttons["drawer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the menu button did not open the drawer")
        sleep(2)
        shot("1-home")

        // Home: the chats, nothing else.
        let any = app.descendants(matching: .any)
        for id in ["drawer-my-flows", "drawer-next-up", "drawer-backlog-status", "drawer-more"] {
            XCTAssertFalse(any[id].exists, "\(id) is on Home")
        }
        for kind in ["drawer-shortcut-", "drawer-backlog-", "drawer-pin-", "drawer-screen-"] {
            XCTAssertEqual(any.matching(NSPredicate(format: "identifier BEGINSWITH %@", kind)).count, 0, "a \(kind) row on Home")
        }
        XCTAssertTrue(app.buttons["drawer-tab-review"].exists, "Review left its place")
        XCTAssertTrue(app.buttons["drawer-agent-bar"].exists, "the bar at the bottom left")

        // Agent > More: flows and the backlog, one short list. The shortcuts are cut: they are the chips over the bar.
        app.buttons["drawer-tab-agent"].tap()
        let more = any["drawer-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no More under Agent")
        for id in ["drawer-my-flows", "drawer-backlog-status"] {
            XCTAssertTrue(any[id].exists, "\(id) is not under Agent > More")
        }
        for kind in ["drawer-shortcut-", "drawer-screen-"] {
            XCTAssertEqual(any.matching(NSPredicate(format: "identifier BEGINSWITH %@", kind)).count, 0, "a \(kind) row under Agent")
        }
        if !more.isHittable { app.swipeUp() }
        sleep(1)
        shot("2-agent-more")
    }
}
