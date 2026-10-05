import XCTest

/// Voice first (t_3df48502): the naming and search fields can be said. A mic sits in the add-agent
/// name, the agent's rename, past-chats search, the chat title, "Find an agent" and the stage
/// caption field. Saying fills the field; nothing saves or searches until the person confirms as
/// before. Demo account, no network; `-yuiPTTFake` stands in for the mic. Shots go to `YUI_SHOTS`
/// as naming-<name>-<dark|light>.png and into the result bundle.
final class NamingMicTests: XCTestCase {
    func testNamingMicsDark() throws { try run("dark") }
    func testNamingMicsLight() throws { try run("light") }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "naming-\(name)-\(appearance).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "naming-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ appearance: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-appearance", appearance, "-yuiPTTFake", "Nova Prime"] + extra
        app.launch()
        return app
    }

    /// Tap to listen, tap to stop: the fake words land in the field.
    private func say(_ mic: XCUIElement, into field: XCUIElement, _ words: String, _ what: String) {
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "no mic on \(what)")
        mic.tap()
        mic.tap()
        let said = NSPredicate(format: "value CONTAINS %@", words)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: said, object: field)], timeout: 6), .completed,
                       "the words never reached \(what): \(String(describing: field.value))")
    }

    private func chatsFile() throws -> URL {
        func ago(_ s: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-s)) }
        let rows: [[String: Any]] = (1...12).map { i in
            ["id": "c\(i)", "title": "Chat number \(i)", "is_first": false, "last_at": ago(Double(i) * 600), "seen_at": ago(Double(i) * 600),
             "last_sender": "agent", "last_body": "Line \(i).", "last_message_at": ago(Double(i) * 600), "unread": false]
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "yui-naming-chats.json")
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        return file
    }

    private func run(_ appearance: String) throws {
        // 1. Add agent: the name field.
        var app = launch(appearance, ["-yuiAgents", "-yuiAddAgent"])
        say(app.buttons["agent-name-mic"], into: app.textFields["Name, like Nova"], "Nova Prime", "the add-agent name")
        XCTAssertFalse(app.buttons["pair-copy"].exists, "saying a name must not create the agent")
        shot("1-add-agent", appearance)
        app.terminate()

        // 2. Past chats: search and chat title (the drawer, 12 chats so search shows).
        app = launch(appearance, ["-yuiAgent", "yui", "-yuiChats", try chatsFile().path, "-yuiDrawer"])
        let search = app.textFields["drawer-chat-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "no chat search in the drawer")
        say(app.buttons["drawer-chat-search-mic"], into: search, "Nova Prime", "the chat search")
        shot("2-chat-search", appearance)
        app.buttons["Clear search"].firstMatch.tap()
        let row = app.buttons["drawer-chat-open-c2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no chat row")
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3), "no Rename in the hold menu")
        app.buttons["Rename"].tap()
        let title = app.textFields["chat-rename-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), "the title is not editable in place")
        shot("3-chat-title", appearance)
        XCTAssertTrue(app.buttons["chat-rename-mic"].waitForExistence(timeout: 5), "no mic on the chat title")
        app.terminate()

        // 4. The agent's own rename.
        app = launch(appearance, ["-yuiAgents"])
        let coach = app.buttons["Edit Coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 15), "no Edit Coach in the list")
        coach.tap()
        let mic = app.buttons["agent-rename-mic"]
        for _ in 0..<4 where !mic.exists { app.swipeUp() }
        say(mic, into: app.textFields["Name"], "Nova Prime", "the agent rename")
        shot("5-agent-rename", appearance)
        app.terminate()

        // 5. The stage caption field, under T.
        app = launch(appearance, ["-yuiStageFirst", "YES", "-yuiAgent", "yui"])
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 20), "no stage")
        app.buttons["stage-type"].tap()
        say(app.buttons["stage-caption-mic"], into: app.textFields["stage-field"], "Nova Prime", "the stage caption field")
        shot("6-stage-caption", appearance)

        // 3. Find an agent, in the agent list the drawer opens.
        // More than six agents, or the switcher has no search.
        app = launch(appearance, ["-yuiDemoFirstLaunch", "-yuiAgent", "yui", "-yuiDrawer"])
        XCTAssertTrue(app.buttons["drawer-agent-bar"].waitForExistence(timeout: 20), "no drawer")
        app.buttons["drawer-agent-bar"].tap()
        say(app.buttons["agent-find-mic"], into: app.textFields["Find an agent"], "Nova Prime", "Find an agent")
        shot("4-find-agent", appearance)
        app.terminate()
    }
}