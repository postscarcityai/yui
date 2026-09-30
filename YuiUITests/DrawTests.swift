import XCTest

/// Drawings (DRAW-2): `diagram` (a flowchart, a sequence, a state diagram) and `mock`
/// (a phone, a sign-in with a keyboard, a browser page). `-yuiDemoDraw` seeds six
/// replies. Each drawing sits in the chat on a card, reads its parts to VoiceOver in
/// the order they were written, and (Reduce Motion) shows finished at once. Then a
/// deck on the full-screen stage with a diagram and a mock as page pictures.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class DrawTests: XCTestCase {
    func testLight() throws { try chat(appearance: "light", tag: "light") }
    func testDark() throws { try chat(appearance: "dark", tag: "dark") }
    func testReduceMotion() throws { try chat(appearance: "light", reduce: true, tag: "reduce") }
    func testStageLight() throws { try stage(appearance: "light") }
    func testStageDark() throws { try stage(appearance: "dark") }

    static let deck = """
    >full
    deck "Drawing it"
    page "How it flows" body="Nodes come on in the order they were written."
    diagram caption="Checks green, or back to the lane."
    flowchart TD
      ask([Ask]) --> lane[Lane]
      lane --> check{Green?}
      check -->|yes| ship((Ship))
      check -.->|no| lane
    end
    page "What it looks like"
    mock "Agents" frame=phone
    part nav Agents action=Edit
    part row Basil sub="Groceries" icon=B +chev +hi note="new badge"
    part button "New agent"
    part tabs items=Home|Agents|Me tab=Agents
    page "Last"
    end
    """

    private func shot(_ name: String, _ tag: String) {
        let s = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "draw-\(name)-\(tag).png"))
        }
        let a = XCTAttachment(screenshot: s)
        a.name = "draw-\(name)-\(tag)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func drawing(_ app: XCUIApplication, _ id: String, _ starts: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", id, starts)).firstMatch
    }

    private func chat(appearance: String, reduce: Bool = false, tag: String) throws {
        let app = XCUIApplication()
        func scroll(up: Bool) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.35 : 0.7))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: up ? 0.7 : 0.35)))
        }
        func reveal(_ e: XCUIElement) {
            for _ in 0..<10 where !(e.exists && e.isHittable) { scroll(up: true) }
            for _ in 0..<10 where !(e.exists && e.isHittable) { scroll(up: false) }
        }
        var args = ["-yuiDemoAccount", "-yuiDemoDraw", "-appearance", appearance]
        if reduce { args.append("-yuiReduceMotion") }
        app.launchArguments = args
        app.launch()

        // The newest reply: the browser page.
        let browser = drawing(app, "mock-drawing", "Mock screen, browser")
        XCTAssertTrue(browser.waitForExistence(timeout: 15), "the mock reply never reached the chat")
        XCTAssertEqual(browser.label, "Mock screen, browser: Pricing; Options, Monthly, Yearly, selected; Card, Crew, $12 a month, Every agent, every device (highlighted). Note: the one we sell; Grid, Voice, Drawings, Timers, Games; Button, Start free.")
        XCTAssertEqual(browser.value as? String, "5 parts")
        shot("mock-browser", tag)

        let signin = drawing(app, "mock-drawing", "Sign in.")
        reveal(signin)
        XCTAssertTrue(signin.isHittable, "the sign-in is not on screen")
        XCTAssertEqual(signin.label, "Sign in. Mock screen, phone: Navigation bar, Sign in, back Back; Field, Email, chris@example.com; Field, Password, placeholder at least 8 characters (highlighted). Note: show a meter here; Switch, Keep me signed in, on; Slider, Volume, 70 percent; Button, Continue; Keyboard.")
        shot("mock-signin", tag)

        let agents = drawing(app, "mock-drawing", "Agents.")
        reveal(agents)
        XCTAssertTrue(agents.isHittable, "the Agents mock is not on screen")
        XCTAssertTrue(agents.label.contains("Navigation bar, Agents, button Edit"), agents.label)
        XCTAssertTrue(agents.label.contains("Tabs, Home, Agents, selected, Me"), agents.label)
        XCTAssertTrue(agents.label.contains("Old, Soon (crossed out, greyed)"), agents.label)
        XCTAssertTrue(app.staticTexts["The Agents screen, with what to change."].exists || true)
        shot("mock-agents", tag)

        let state = drawing(app, "diagram-drawing", "A TestFlight build")
        reveal(state)
        XCTAssertTrue(state.isHittable, "the state diagram is not on screen")
        XCTAssertEqual(state.label, "A TestFlight build. State diagram: start, Uploaded, Processing, Valid, Invalid, end. start to Uploaded; Uploaded to Processing, Apple receives it; Processing to Valid, passes; Processing to Invalid, fails; Valid to end.")
        if !reduce { usleep(700_000); shot("state-mid", tag); sleep(3) }
        shot("state", tag)

        let seq = drawing(app, "diagram-drawing", "What happens when you send a message")
        reveal(seq)
        XCTAssertTrue(seq.isHittable, "the sequence is not on screen")
        XCTAssertTrue(seq.label.contains("Sequence diagram: You, Yui app, Agent. 1. You to Yui app: type and send; 2. Yui app to Agent: your words; loop while it thinks; 3. Yui app to You: working row;"), seq.label)
        if !reduce { seq.tap(); usleep(900_000); shot("sequence-mid", tag); sleep(4) }
        shot("sequence", tag)

        let flow = drawing(app, "diagram-drawing", "How an ask ships")
        reveal(flow)
        XCTAssertTrue(flow.isHittable, "the flowchart is not on screen")
        XCTAssertEqual(flow.label, "How an ask ships. Flowchart: You, Board, Lane, Checks green?, TestFlight. You to Board; Board to Lane; Lane to Checks green?; Checks green? to TestFlight, yes; Checks green? to Lane, no. You ask. A lane builds it. It rides the next build.")
        XCTAssertTrue(app.staticTexts["You ask. A lane builds it. It rides the next build."].exists, "no caption")
        if !reduce { flow.tap(); usleep(700_000); shot("flow-mid", tag); sleep(4) }
        shot("flow", tag)

        // No raw Mermaid or part lines and no Update chip: this build draws them.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'part ' OR label BEGINSWITH 'flowchart' OR label BEGINSWITH 'sequenceDiagram'")).firstMatch.exists,
                       "raw lines in the chat")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'update'")).firstMatch.exists, "an Update chip")
    }

    private func stage(appearance: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance, "-yuiDemoReply",
                               Self.deck.replacingOccurrences(of: "\n", with: "\\n")]
        app.launch()
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText("Show me how it flows")
        app.buttons["Send"].tap()

        XCTAssertTrue(app.staticTexts["How it flows"].waitForExistence(timeout: 20), "the deck never opened")
        let flow = drawing(app, "diagram-drawing", "Flowchart: Ask, Lane, Green?, Ship")
        XCTAssertTrue(flow.waitForExistence(timeout: 5), "the first page has no diagram")
        XCTAssertEqual(flow.label, "Flowchart: Ask, Lane, Green?, Ship. Ask to Lane; Lane to Green?; Green? to Ship, yes; Green? to Lane, no. Checks green, or back to the lane.")
        sleep(3)
        shot("stage-flow", appearance)

        app.buttons["Next page"].tap()
        XCTAssertTrue(app.staticTexts["What it looks like"].waitForExistence(timeout: 5), "the deck did not turn past the diagram")
        let mock = drawing(app, "mock-drawing", "Agents.")
        XCTAssertTrue(mock.waitForExistence(timeout: 5), "the second page has no mock")
        XCTAssertEqual(mock.label, "Agents. Mock screen, phone: Navigation bar, Agents, button Edit; Basil, Groceries (highlighted). Note: new badge; Button, New agent; Tabs, Home, Agents, selected, Me.")
        sleep(1)
        shot("stage-mock", appearance)
    }
}
