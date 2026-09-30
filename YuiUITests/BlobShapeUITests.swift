import XCTest

/// The shader blob (YUI-232, yuigui spec/SHADER.md): the vector mark is gone and the shader
/// behind the stage draws the agent. One turn walks the doing words through each shape:
/// thinking (a cloud), reading (a football), running (a rounded square), searching (a drop),
/// then the reply's done beat. Dark first, then light. Screenshots go to `YUI_SHOTS` when set,
/// and always into the result bundle.
final class BlobShapeUITests: XCTestCase {
    /// Unquoted: a launch argument that starts with a quote is read as a plist string.
    static let doing = "Pondering 1/4|Reading your calendar 2/4|Running the tests 3/4|Searching the web 4/4"
    static let reply = "say \"Tuesday at 10 is free.\""

    func testEveryShapeDark() throws { try walk("dark") }

    func testEveryShapeLight() throws { try walk("light") }

    private func walk(_ appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", Self.reply, "-yuiDemoDoing", Self.doing,
                               "-yuiDemoPickupAfter", "0.6", "-yuiDemoReplyAfter", "30"]
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 15), "no stage")
        XCTAssertTrue(app.descendants(matching: .any)["stage-visual"].waitForExistence(timeout: 5), "the shader draws the agent")
        shot("0-idle", appearance)
        app.buttons["stage-type"].tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("When am I free this week?")
        app.buttons["stage-send-text"].tap()
        let working = app.descendants(matching: .any)["stage-working"]
        XCTAssertTrue(working.waitForExistence(timeout: 5), "no working state after send")
        for (words, name) in [("Pondering", "1-thinking"), ("Reading your calendar", "2-reading"),
                              ("Running the tests", "3-running"), ("Searching the web", "4-searching")] {
            let got = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", words), object: working)
            XCTAssertEqual(XCTWaiter.wait(for: [got], timeout: 12), .completed, "no step \(words): \(working.label)")
            // Let the morph settle into the shape.
            Thread.sleep(forTimeInterval: 1.6)
            shot(name, appearance)
        }
        let line = app.staticTexts.matching(NSPredicate(format: "identifier == 'stage-line' AND label BEGINSWITH 'Tuesday at 10'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the reply never played")
        shot("5-reply", appearance)
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "app-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "blob-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }
}
