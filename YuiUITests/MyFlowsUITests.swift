import XCTest

/// My flows (YUI-238): from the agent's drawer, see the saved flows (a variant under its base),
/// run one on the stage, and remove a variant. Demo account, no network. `YUI_SHOTS=<dir>` saves screenshots.
final class MyFlowsUITests: XCTestCase {
    private var appearance = "light"

    private func shot(_ name: String) {
        usleep(900_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "myflows-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "myflows-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoHome", "-yuiAgent", "arnold", "-yuiDrawer", "-appearance", appearance,
                               "-yuiRunnerReset", "-yuiFlowsReset"]
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitFor(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), what)
    }

    func testMyFlowsLight() throws { try myFlows("light") }
    func testMyFlowsDark() throws { try myFlows("dark") }

    private func myFlows(_ look: String) throws {
        appearance = look
        let app = launch()
        let open = el(app, "drawer-my-flows")
        waitFor(open, "the drawer has no My flows row")
        open.tap()

        // The list: a starter, and the hub's variant under its base.
        let base = el(app, "my-flows-row-website-intake")
        let variant = el(app, "my-flows-row-restaurant-intake")
        waitFor(base, "no website-intake row")
        waitFor(variant, "no restaurant-intake row")
        XCTAssertTrue(base.label.contains("steps"), "a row says its step count: \(base.label)")
        XCTAssertLessThan(base.frame.minY, variant.frame.minY, "the variant sits under its base")
        shot("1-list")

        // Remove a variant: swipe, Remove, the confirm. A starter has no Remove.
        variant.swipeLeft()
        let remove = el(app, "my-flows-remove-restaurant-intake")
        waitFor(remove, "swiping a variant shows no Remove")
        shot("2-confirm-prep")
        remove.tap()
        let confirm = app.alerts.firstMatch.buttons["Remove"].firstMatch
        waitFor(confirm, "no remove confirm")
        shot("3-confirm")
        confirm.tap()
        let end = Date().addingTimeInterval(10)
        while variant.exists, Date() < end { usleep(300_000) }
        XCTAssertFalse(variant.exists, "the variant is still listed after Remove")
        waitFor(base, "the base went with its variant")

        // Run one: it opens on the stage, step 1.
        let run = el(app, "my-flows-row-first-plan")
        waitFor(run, "no first-plan row")
        run.tap()
        let goal = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "Get stronger", "Get stronger"))
        XCTAssertTrue(goal.firstMatch.waitForExistence(timeout: 20), "the flow never opened on the stage")
        let progress = app.staticTexts.matching(identifier: "flow-progress").allElementsBoundByIndex.first { $0.isHittable }?.label
        XCTAssertEqual(progress, "Step 1 of 5")
        shot("4-run")
    }
}
