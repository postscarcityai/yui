import XCTest

/// A form inside a plan is just fields: one Send for the whole screen (YUI-156,
/// TestFlight feedback AOTM4UtV, 2026-09-27: "I don't see a reason to have a send
/// button on about you section"). The stage drew the form's own Submit next to
/// its one Send; tapping it read "Sent" and sent nothing. A pick drew its own
/// Done the same way (YUI-159). Demo account, no network. `YUI_SHOTS=<dir>`
/// saves screenshots.
final class PlanFormOneSendTests: XCTestCase {
    /// The plan from the feedback, as the website-intake flow goes out to a phone.
    /// No apostrophes: a launch argument is read as a plist, and `'` quotes in one.
    static let brandSite = [
        "say \"Let us build your personal brand site. A few quick questions first.\"",
        "plan \"Your personal brand site\" submit=\"Build my brief\"",
        "page \"What this covers\" points=\"Who you are and who it is for\"|\"What the site should do\"|\"How it looks and sounds\"|\"Budget and timing\"",
        "form \"About you\" name:text role:text oneliner:text",
        "choose \"Who should land on it?\" Clients|Investors|Employers|Press|Community +other",
        "choose \"The one thing a visitor should do?\" \"Book a call\"|\"Join my list\"|\"Hire me\"|\"Read my work\" +other",
        "pick \"Pages you want\" About|Work|Writing|Speaking|Contact|Newsletter +other",
        "choose \"How should it feel?\" \"Calm and minimal\"|\"Bold and loud\"|\"Warm and personal\"|\"Sharp and technical\" +other",
        "choose \"Budget?\" \"Under 5k\"|\"5k to 15k\"|\"15k and up\"|\"Not sure\" +other",
        "end",
    ].joined(separator: "\\n")

    /// The stage: one Send, and Name, Role and Oneliner ride in the `{plan}` event.
    func testStagePlanHasOneSend() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-plan-form-events.jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", "dark", "-yuiDemoReply", Self.brandSite,
                               "-yuiDemoPickupAfter", "0.5", "-yuiDemoReplyAfter", "2", "-yuiEventLog", log]
        app.launch()

        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Interview me for a personal brand site.")
        app.buttons["stage-send-text"].tap()

        // Read through to the questions.
        let questions = app.descendants(matching: .any)["stage-questions"]
        for _ in 0..<6 where !questions.waitForExistence(timeout: 4) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(questions.exists, "no questions screen")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the form never showed")

        // One Send on the screen: the form has none of its own.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.exists)
        XCTAssertEqual(send.label, "Build my brief")
        for label in ["Submit", "Sent", "Done"] {
            XCTAssertFalse(app.buttons[label].exists, "a question still draws its own \(label)")
        }
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        shot("1-questions")

        // Typing in the form alone is an answer.
        name.tap(); name.typeText("Chris")
        XCTAssertTrue(send.isEnabled, "a filled form field did not count as an answer")
        app.textFields["Role"].tap(); app.textFields["Role"].typeText("Founder")
        app.textFields["Oneliner"].tap(); app.textFields["Oneliner"].typeText("I build agents")
        app.buttons["Clients"].tap()
        // The pick hands over its picks on every tap; taking one off takes it back.
        for page in ["About", "Work", "Contact"] { app.buttons[page].tap() }
        app.buttons["Contact"].tap()
        XCTAssertFalse(app.buttons["Done"].exists, "the pick still draws its own Done")
        shot("2-answered")
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sent. It'"))
            .firstMatch.waitForExistence(timeout: 5), "Send did not go")

        // One `{plan}` event, the form's fields inside it.
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let plans = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["plan"] != nil }
        XCTAssertEqual(plans.count, 1, "want one plan event, got: \(events)")
        let answers = plans.first?["plan"] as? [String: Any] ?? [:]
        let form = answers.values.compactMap { $0 as? [String: Any] }.first ?? [:]
        XCTAssertEqual(form["name"] as? String, "Chris")
        XCTAssertEqual(form["role"] as? String, "Founder")
        XCTAssertEqual(form["oneliner"] as? String, "I build agents")
        XCTAssertTrue(answers.values.contains { $0 as? String == "Clients" }, "the choose answer is missing: \(answers)")
        XCTAssertTrue(answers.values.contains { $0 as? [String] == ["About", "Work"] }, "the picked pages are missing: \(answers)")
        XCTAssertFalse(events.contains("\"preset\":\"form\""), "the form sent an event of its own: \(events)")
        XCTAssertFalse(events.contains("\"preset\":\"pick\""), "the pick sent an event of its own: \(events)")
        shot("3-sent")
    }

    /// The paged plan: a form step moves on with Next, no Submit inside it.
    func testPagerFormMovesOnWithNext() throws {
        let reply = [
            "plan \"Quick intro\" review=false submit=\"Send it\"",
            "form \"About you\" name:text role:text",
            "choose \"Who is it for?\" Clients|Investors",
            "end",
        ].joined(separator: "\\n")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", "light", "-yuiThemeDemo", reply]
        app.launch()
        let close = app.buttons["Close full screen"]
        if !close.waitForExistence(timeout: 12) {
            let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open' AND label ENDSWITH 'full screen'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 5), "the plan never showed")
            open.tap()
        }
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5), "no form step")
        XCTAssertFalse(app.buttons["Submit"].exists, "the form step still has its own Submit")
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Chris")
        shot("4-pager-form")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].waitForExistence(timeout: 5), "Next did not move past the form")
    }

    /// The paged plan: a pick step has no Done, and Next carries its picks to the review.
    func testPagerPickMovesOnWithNext() throws {
        let reply = [
            "plan \"Your site\"",
            "pick \"Pages you want\" About|Work|Contact",
            "choose \"Who is it for?\" Clients|Investors",
            "end",
        ].joined(separator: "\\n")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", "light", "-yuiThemeDemo", reply]
        app.launch()
        let close = app.buttons["Close full screen"]
        if !close.waitForExistence(timeout: 12) {
            let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open' AND label ENDSWITH 'full screen'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 5), "the plan never showed")
            open.tap()
        }
        XCTAssertTrue(app.staticTexts["Step 1 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["About"].waitForExistence(timeout: 5), "no pick step")
        XCTAssertFalse(app.buttons["Done"].exists, "the pick step still has its own Done")
        app.buttons["About"].tap(); app.buttons["Contact"].tap()
        shot("6-pager-pick")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 2"].waitForExistence(timeout: 5), "Next did not move past the pick")
        app.buttons["Clients"].tap()
        XCTAssertTrue(app.staticTexts["About, Contact"].waitForExistence(timeout: 5), "the review lost the picks")
        shot("7-pager-review")
    }

    /// On its own in the chat, a pick keeps its Done.
    func testStandalonePickKeepsDone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", "light", "-yuiThemeDemo", "pick \"Pages you want\" About|Work|Contact"]
        app.launch()
        XCTAssertTrue(app.buttons["About"].waitForExistence(timeout: 12), "no pick")
        XCTAssertTrue(app.buttons["Done"].exists, "a pick on its own lost its Done")
        shot("8-standalone-pick")
    }

    /// On its own in the chat, a form keeps its Submit.
    func testStandaloneFormKeepsSubmit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", "light", "-yuiThemeDemo", "form \"About you\" name:text role:text"]
        app.launch()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 12), "no form")
        XCTAssertTrue(app.buttons["Submit"].exists, "a form on its own lost its Submit")
        shot("5-standalone")
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "plan-form-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "plan-form-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
