import XCTest

/// Answers are kept (feedback AFeoOWB5ZWdBuf4yoBBL5Hw, 2026-10-02: "I filled this out and then got
/// sidetracked and then all my information is gone"). A form step in a flow or a plan holds what was
/// typed through Back, a kill and a relaunch, and the step is the same one. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class AnswersKeptTests: XCTestCase {
    /// No apostrophes (launch arguments are plists).
    static let flow = [
        "say Tell me about the business.",
        "flow@intake \"Client intake\" submit=\"Send the brief\"",
        "flowchart TD",
        "  %% kind: choose \"Which fits?\" Shop|Studio",
        "  kind --> about",
        "  %% about: form \"Your business\" name:text what:text",
        "  about --> size",
        "  %% size: choose \"How big?\" Small|Large",
        "end",
    ].joined(separator: "\\n")

    static let plan = [
        "say Tell me about the business.",
        "plan \"Client intake\" submit=\"Send the brief\"",
        "form \"Your business\" name:text what:text",
        "choose \"Which fits?\" Shop|Studio",
        "end",
    ].joined(separator: "\\n")

    private var appearance = "light"

    private func shot(_ name: String) {
        usleep(900_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "kept-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "kept-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ reply: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold", "-appearance", appearance,
                               "-yuiThemeDemo", reply, "-yuiStableMessageIds"]
            + (fresh ? ["-yuiRunnerReset"] : [])
        app.launch()
        return app
    }

    /// The one on screen: the chat keeps its own copy under the full screen.
    private func hittable(_ q: XCUIElementQuery) -> XCUIElement {
        q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch
    }

    private func field(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 20) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let f = hittable(app.textFields.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", label, label, label)))
            if f.exists, f.isHittable { return f }
            usleep(300_000)
        }
        shot("missing-\(label)")
        return nil
    }

    private func button(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
            let b = hittable(all)
            if b.exists, b.isHittable { return b }
            usleep(300_000)
        }
        shot("missing-\(id)")
        return nil
    }

    private func text(_ f: XCUIElement) -> String { (f.value as? String) ?? "" }

    func testFlowFormKeptLight() throws { try flowForm("light") }
    func testFlowFormKeptDark() throws { try flowForm("dark") }
    func testPlanFormKeptLight() throws { try planForm("light") }
    func testPlanFormKeptDark() throws { try planForm("dark") }

    private func flowForm(_ look: String) throws {
        appearance = look
        var app = launch(Self.flow, fresh: true)
        // Step 1 moves on by itself; step 2 is the form.
        try XCTUnwrap(button(app, "Shop"), "the flow never opened").tap()
        let name = try XCTUnwrap(field(app, "Name"), "the form never came")
        name.tap(); name.typeText("Basil Bakery")
        let what = try XCTUnwrap(field(app, "What"))
        what.tap(); what.typeText("Bread and cake")
        shot("1-typed")

        // Next, then Back: the fields are still filled in.
        try XCTUnwrap(button(app, "flow-next")).tap()
        _ = try XCTUnwrap(button(app, "Small"), "the third step never came")
        try XCTUnwrap(button(app, "flow-back")).tap()
        XCTAssertEqual(text(try XCTUnwrap(field(app, "Name"))), "Basil Bakery", "Back wiped the name")
        XCTAssertEqual(text(try XCTUnwrap(field(app, "What"))), "Bread and cake", "Back wiped the other field")

        // Killed with the form on screen: the same step, the same words.
        app.terminate()
        app = launch(Self.flow, fresh: false)
        XCTAssertEqual(text(try XCTUnwrap(field(app, "Name", timeout: 25), "no form after the relaunch")), "Basil Bakery",
                       "the relaunch lost the name")
        XCTAssertEqual(text(try XCTUnwrap(field(app, "What"))), "Bread and cake", "the relaunch lost the other field")
        shot("2-relaunched")
        // The next step still counts it: the form was not handed over empty.
        try XCTUnwrap(button(app, "flow-next")).tap()
        try XCTUnwrap(button(app, "Small")).tap()
        _ = try XCTUnwrap(button(app, "Send the brief"), "no review")
        shot("3-review")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Basil Bakery'")).count > 0,
                      "the review lost the form's answer")
    }

    private func planForm(_ look: String) throws {
        appearance = look
        var app = launch(Self.plan, fresh: true)
        let name = try XCTUnwrap(field(app, "Name"), "the plan never opened")
        name.tap(); name.typeText("Basil Bakery")
        try XCTUnwrap(field(app, "What")).tap()
        try XCTUnwrap(field(app, "What")).typeText("Bread and cake")
        shot("1-typed")
        try XCTUnwrap(button(app, "Next")).tap()
        try XCTUnwrap(button(app, "Shop"), "the second step never came").tap()
        shot("2-picked")

        app.terminate()
        app = launch(Self.plan, fresh: false)
        // Back on the screen it was left on: the review, with both answers listed.
        _ = try XCTUnwrap(button(app, "Send the brief", timeout: 25), "no review after the relaunch")
        shot("3-relaunched")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Basil Bakery'")).count > 0,
                      "the review lost the form's answer")
        XCTAssertTrue(app.staticTexts["Shop"].exists, "the review lost the pick")
        // Edit: the form is filled in, not empty.
        try XCTUnwrap(button(app, "Edit Your business")).tap()
        XCTAssertEqual(text(try XCTUnwrap(field(app, "Name"))), "Basil Bakery", "the relaunch lost the name")
        XCTAssertEqual(text(try XCTUnwrap(field(app, "What"))), "Bread and cake", "the relaunch lost the other field")
        shot("4-edit")
    }
}
