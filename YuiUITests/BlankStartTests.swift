import XCTest

/// Start blank (YUI-138, NATIVE-1): Add agent offers it under the crew; a tap makes a new empty agent
/// whose first screen is its setup flow: name, how it talks, look, favorite screens, model, each with
/// Not sure and Skip, one Send. The answers go to the agent as one {plan} (its runtime turns them into
/// the profile: runtime/tests/setup.test.ts) and it greets as itself. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class BlankStartTests: XCTestCase {
    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    /// runtime/src/setup.ts applySetup's hello for Nova in a short voice.
    static let hello = "say Nova. Ready.\\nchoose What should I help with? Cooking|Money|Writing"
    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "blank-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "blank-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-blank-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiAgents", "-yuiAddAgent", "-appearance", look,
                               "-yuiDemoReply", Self.hello, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. Add agent shows Start blank under the crew.
        let blank = app.descendants(matching: .any)["crew-blank"]
        _ = app.descendants(matching: .any)["crew-arnold"].waitForExistence(timeout: 20)
        if !blank.exists { shot("0-add-without-blank") }
        XCTAssertTrue(blank.waitForExistence(timeout: 5), "Add agent has no Start blank")
        XCTAssertEqual(blank.label.contains("Start blank"), true)
        sleep(1)
        shot("1-add")

        // 2. Tap: the new agent opens on its first message, the setup flow.
        blank.tap()
        XCTAssertTrue(text(app, "I'm new here", timeout: 20), "the blank agent's first message did not play")
        sleep(1)
        shot("2-hello")
        // 3. One question a screen, Not sure and Skip beside the real answers.
        XCTAssertTrue(text(app, "Step 1 of 5", timeout: 15), "the setup is not a five step flow")
        XCTAssertTrue(text(app, "What should I be called?", timeout: 5))
        for a in ["Nova", "Not sure", "Skip"] { XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)") }
        sleep(1)
        shot("3-name")
        b(app, "Nova").tap()
        XCTAssertTrue(text(app, "How should I talk?", timeout: 8), "a tap did not move on to the voice")
        for a in ["Not sure", "Skip"] { XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a) on the voice") }
        b(app, "Short").tap()
        XCTAssertTrue(text(app, "What should I look like?", timeout: 8))
        shot("4-look")
        b(app, "Butter").tap()
        XCTAssertTrue(text(app, "Which screens should I reach for?", timeout: 8))
        b(app, "Lists").tap()
        shot("5-screens")
        b(app, "Next").tap()
        XCTAssertTrue(text(app, "Which model should I run on?", timeout: 8))
        b(app, "GLM 5.2").tap()
        sleep(1)
        shot("6-review")
        let make = b(app, "Make me")
        XCTAssertTrue(make.waitForExistence(timeout: 8), "no Make me on the review")
        make.tap()

        // 4. The agent greets as itself, and the answers went as one {plan} keyed by the question ids.
        XCTAssertTrue(text(app, "Nova. Ready.", timeout: 20), "the agent never greeted")
        sleep(1)
        shot("7-greeting")
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["name"] as? String, "Nova")
        XCTAssertEqual(p["voice"] as? String, "Short")
        XCTAssertEqual(p["look"] as? String, "Butter")
        XCTAssertEqual(p["screens"] as? [String], ["Lists"])
        XCTAssertEqual(p["model"] as? String, "GLM 5.2")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
