import XCTest

/// Basil reads a meal (YUI-141, yuigui spec/MEAL.md): a meal photo goes out, the answer
/// comes back with the four macro tiles, a line on how sure it is, and a form to fix it.
/// The answer is Basil's real one: the native runtime on GLM-5V-Turbo read
/// www.yuigui.com/demo/meal-salmon.jpg (runtime/scripts/live.ts, 2026-09-27, after the soul's no-`end` line), kept
/// verbatim but for apostrophes (a launch argument can't carry them). Demo account, no network.
/// `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots; `TEST_RUNNER_YUI_TEST_PHOTO=<jpg>` is the meal.
final class MealPhotoTests: XCTestCase {
    static let basilReadsSalmon = [
        "```yui",
        "say \"That’s a beautiful grilled salmon steak on greens with avocado, cherry tomatoes, lemon and dill. There’s a creamy-looking sauce in that little spoon and a balsamic-style drizzle too.\"",
        "",
        "stat@kcal1 550kcal Calories sub=\"a guess\"",
        "stat@protein1 34g Protein",
        "stat@carbs1 8g Carbs",
        "stat@fat1 38g Fat",
        "",
        "form@fix1 \"Fix it before I save\" portion:Half|\"As shown\"|Bigger|Double \"Anything I missed? (sauce type, cooking method...)\":text submit=Save",
        "```",
        "",
        "I’m pretty confident on the salmon and veggies. A bit less sure on the sauce in the spoon — looks like maybe a yogurt-dill sauce or tartar? — and how much oil went into grilling. Let me know if any of this is off!",
    ].joined(separator: "\\n")

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "dark" }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(appearance).png"))
    }

    func testBasilReadsAMeal() throws {
        let photo = try XCTUnwrap(ProcessInfo.processInfo.environment["YUI_TEST_PHOTO"], "set TEST_RUNNER_YUI_TEST_PHOTO to a meal photo")
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoShared", "-yuiAgent", "basil", "-appearance", appearance,
                               "-yuiComposerPhoto", photo, "-yuiDemoReply", Self.basilReadsSalmon, "-yuiDemoReplyAfter", "3"]
        app.launch()
        let attachment = app.descendants(matching: .any)["attachment"].firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 20), "the photo never reached the composer")
        let field = app.descendants(matching: .any)["composer"].firstMatch
        field.tap()
        field.typeText("Lunch")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["bubble-photo"].firstMatch.waitForExistence(timeout: 5), "the photo never reached the thread")
        shot("meal-01-sent")
        let sure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "less sure")).firstMatch
        XCTAssertTrue(sure.waitForExistence(timeout: 20), "no line on how sure Basil is")
        for tile in ["Calories", "Protein", "Carbs", "Fat", "Fix it before I save"] {
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", tile)).firstMatch.exists, "no \(tile)")
        }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "end:")).firstMatch.exists, "a parse error shows")
        // Let the keyboard go with a pull on the thread, as a person does; it goes back to the newest message.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.9)))
        sleep(3)
        shot("meal-03-fix")
        // Back up to the tiles: drag from the left margin (a card would scroll itself).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.62)))
        sleep(3)
        shot("meal-02-estimate")
    }
}
