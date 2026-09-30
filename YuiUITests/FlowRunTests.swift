import XCTest

/// The app runs flows (YUI-115, FLOW-1 app half). A saved flow the agent sends by name
/// (`flow first-plan`) runs one step at a time on the stage; the app is killed mid-flow and comes
/// back on the same step with its answers; then the review, one Send, and the one `{flow, path}`
/// event the agent reads. A second run takes a branch (an inline chart) and Back walks the path
/// taken. Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class FlowRunTests: XCTestCase {
    /// No apostrophes (launch arguments are plists).
    static let saved = "say Here is your first plan.\\nflow first-plan"
    static let branching = [
        "say One quick question.",
        "flow@brew Coffee submit=\"Send my order\"",
        "flowchart TD",
        "  %% kind: choose \"Coffee or tea?\" Coffee|Tea",
        "  kind --> strength",
        "  kind -->|Tea| tea",
        "  %% strength: slide \"How strong?\" 1-5",
        "  strength --> done",
        "  %% tea: choose \"Which tea?\" Green|Black",
        "  tea --> done",
        "  %% done: ask \"Anything else?\" No|Milk",
        "end",
    ].joined(separator: "\\n")

    private var appearance = "light"

    private func shot(_ name: String) {
        usleep(900_000)  // let the step change finish: no half-faded frames
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "flow-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "flow-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ reply: String, log: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold", "-appearance", appearance,
                               "-yuiThemeDemo", reply, "-yuiStableMessageIds", "-yuiEventLog", log]
            + (fresh ? ["-yuiRunnerReset"] : [])
        app.launch()
        return app
    }

    /// The one on screen: the chat keeps its own copy under the full screen.
    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func progress(_ app: XCUIApplication) -> String {
        app.staticTexts.matching(identifier: "flow-progress").allElementsBoundByIndex.first { $0.isHittable }?.label ?? ""
    }

    private func wait(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let e = b(app, id)
            if e.exists, e.isHittable { return true }
            usleep(300_000)
        }
        return false
    }

    private func events(_ log: String) -> [[String: Any]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testStarterLight() throws { try starter("light") }
    func testStarterDark() throws { try starter("dark") }
    func testBranchLight() throws { try branch("light") }

    private func starter(_ look: String) throws {
        appearance = look
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-flow-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        var app = launch(Self.saved, log: log, fresh: true)

        // Step 1 of 5: a choose moves on by itself after the tap.
        XCTAssertTrue(wait(app, "Get stronger"), "the flow never opened")
        XCTAssertEqual(progress(app), "Step 1 of 5")
        shot("1-step")
        b(app, "Get stronger").tap()
        // Step 2: a pick, Next at the bottom.
        XCTAssertTrue(wait(app, "Wed"), "the days step never came")
        XCTAssertEqual(progress(app), "Step 2 of 5")
        b(app, "Mon").tap()
        b(app, "Wed").tap()
        b(app, "flow-next").tap()
        XCTAssertTrue(wait(app, "30 minutes"), "the time step never came")
        XCTAssertEqual(progress(app), "Step 3 of 5")

        // Back walks the path, and the pick is still picked.
        b(app, "flow-back").tap()
        XCTAssertTrue(wait(app, "Wed"), "Back did not return to the days step")
        shot("2-back")
        b(app, "flow-next").tap()
        XCTAssertTrue(wait(app, "30 minutes"))

        // Killed mid-flow: back on the same step.
        app.terminate()
        app = launch(Self.saved, log: log, fresh: false)
        XCTAssertTrue(wait(app, "30 minutes", timeout: 25), "the relaunch did not come back to the time step")
        XCTAssertEqual(progress(app), "Step 3 of 5", "the step was lost on relaunch")
        shot("3-resumed")

        b(app, "30 minutes").tap()
        XCTAssertTrue(wait(app, "Dumbbells"), "the gear step never came")
        b(app, "Dumbbells").tap()
        b(app, "flow-next").tap()
        XCTAssertTrue(wait(app, "On and off"), "the experience step never came")
        b(app, "On and off").tap()

        // The review lists the answers, with Edit; one Send.
        XCTAssertTrue(wait(app, "Build my week"), "no review with the flow's own submit")
        shot("4-review")
        XCTAssertTrue(app.staticTexts["Get stronger"].exists, "the review lost the goal")
        b(app, "Build my week").tap()
        sleep(1)
        shot("5-sent")

        let sent = events(log).filter { $0["preset"] as? String == "flow" }
        XCTAssertEqual(sent.count, 1, "the flow must send exactly once: \(sent)")
        let e = try XCTUnwrap(sent.last)
        let flow = try XCTUnwrap(e["flow"] as? [String: Any])
        XCTAssertEqual(flow["goal"] as? String, "Get stronger")
        XCTAssertEqual(flow["days"] as? [String], ["Mon", "Wed"])
        XCTAssertEqual(flow["time"] as? String, "30 minutes")
        XCTAssertEqual(flow["gear"] as? [String], ["Dumbbells"])
        XCTAssertEqual(flow["experience"] as? String, "On and off")
        XCTAssertEqual(e["path"] as? [String], ["goal", "days", "time", "gear", "experience"])
        XCTAssertEqual(e["id"] as? String, "n2")
    }

    private func branch(_ look: String) throws {
        appearance = look
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-flow-branch-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = launch(Self.branching, log: log, fresh: true)
        XCTAssertTrue(wait(app, "Tea"), "the flow never opened")
        b(app, "Tea").tap()
        // The Tea branch: its own question, not the slider.
        XCTAssertTrue(wait(app, "Green"), "the tea branch never came")
        shot("1-tea")
        b(app, "Green").tap()
        XCTAssertTrue(wait(app, "Milk"), "the last question never came")
        // Back walks the path taken: tea, not the slider.
        b(app, "flow-back").tap()
        XCTAssertTrue(wait(app, "Green"), "Back skipped the branch it was on")
        b(app, "flow-back").tap()
        XCTAssertTrue(wait(app, "Coffee"), "Back did not reach the first question")
        // Changing the answer drops the tea branch: coffee asks how strong.
        b(app, "Coffee").tap()
        XCTAssertTrue(wait(app, "flow-next"), "the strength step never came")
        shot("2-coffee")
        b(app, "flow-next").tap()
        XCTAssertTrue(wait(app, "Milk"))
        b(app, "Milk").tap()
        XCTAssertTrue(wait(app, "Send my order"), "no review")
        b(app, "Send my order").tap()
        sleep(1)
        let e = try XCTUnwrap(events(log).last { $0["preset"] as? String == "flow" })
        let flow = try XCTUnwrap(e["flow"] as? [String: Any])
        XCTAssertEqual(flow["kind"] as? String, "Coffee")
        XCTAssertNil(flow["tea"], "the old branch's answer must not be sent")
        XCTAssertEqual(e["path"] as? [String], ["kind", "strength", "done"])
    }
}
