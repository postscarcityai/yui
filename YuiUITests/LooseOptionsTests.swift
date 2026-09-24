import XCTest

/// Parser tolerance (YL.md sections 4 and 5): options written as separate quoted
/// strings still come out as buttons, and `~card@week` patches the card instead of
/// failing. Before the change the choose showed one long question with nothing to
/// tap, the ask fell back to Yes/No, and the patch was an error line. Runs on the
/// demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class LooseOptionsTests: XCTestCase {
    static let reply = [
        "choose \"Where should it go?\" \"Camera roll\" \"Drafts\"",
        "ask \"Send the invite now?\" \"Yes, send\" \"Not yet\"",
        "card@week \"This week\" body=\"Mon legs, Thu pull\"",
        "~card@week body=\"Mon legs, Thu rest\"",
    ].joined(separator: "\\n")

    func testLooseOptionsAndPresetAtIdPatch() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "loose-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "loose-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        let log = ProcessInfo.processInfo.environment["YUI_EVENTS"]
            ?? FileManager.default.temporaryDirectory.appending(path: "loose-events.jsonl").path
        try? FileManager.default.removeItem(atPath: log)

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiThemeDemo", Self.reply, "-yuiEventLog", log]
        app.launch()

        let drafts = app.buttons["Drafts"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 15), "the loose choose options never became buttons")
        XCTAssertTrue(app.buttons["Camera roll"].exists)
        XCTAssertTrue(app.buttons["Not yet"].waitForExistence(timeout: 5), "the loose ask options never became buttons")
        XCTAssertFalse(app.buttons["No"].exists, "the ask fell back to Yes/No")
        XCTAssertTrue(app.staticTexts["Mon legs, Thu rest"].waitForExistence(timeout: 5), "~card@week did not patch the card")
        XCTAssertFalse(app.staticTexts["Mon legs, Thu pull"].exists, "the card kept its old body")
        sleep(1)
        shot("1-arrived")

        drafts.tap()
        let notYet = app.buttons["Not yet"]
        if !notYet.isHittable { app.swipeUp() }
        notYet.tap()
        sleep(1)
        shot("2-answered")

        let events = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(events, [
            #"{"choice":"Drafts","id":"n1","preset":"choose"}"#,
            #"{"answer":"Not yet","id":"n2","preset":"ask"}"#,
        ])
    }
}
