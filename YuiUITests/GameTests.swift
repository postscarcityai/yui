import XCTest

/// Game presets (YUI-59): tic-tac-toe against the agent (each tap is a move
/// event, the agent answers with `~game o=...`), snake and memory run on the
/// phone and send one event at the end. The demo account's stand-in agent
/// (`-yuiDemoGame`) answers moves the way a real one would. Screenshots go to
/// `YUI_SHOTS` when set.
final class GameTests: XCTestCase {
    private var app: XCUIApplication!
    private var log = ""
    private var tag = ""

    private func launch(_ tag: String, appearance: String, lines: [String], extra: [String] = []) {
        self.tag = tag
        log = FileManager.default.temporaryDirectory.appending(path: "yui59-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log, "-yuiDemoGame", "YES"] + extra
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func events() -> [[String: Any]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func cell(_ n: Int) -> XCUIElement { app.buttons["game-cell-\(n)"] }
    private func status() -> String { app.staticTexts["game-status"].label }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return }; usleep(150_000) }
        XCTFail("timed out waiting for \(what)")
    }

    private func ticTacToe(_ appearance: String) {
        launch("ttt-\(appearance)", appearance: appearance, lines: [#"say Your move. You are X."#, #"game tictactoe "Beat me""#])
        XCTAssertTrue(cell(5).waitForExistence(timeout: 20), "the board never drew")
        sleep(1)
        XCTAssertEqual(status(), "Your turn")
        shot("1-start")

        // The first move: one event with the board, then the agent's patch lands an O.
        cell(1).tap()
        waitFor("the agent's O") { (1...9).contains { cell($0).label.hasSuffix(", O") } }
        let first = events().first { $0["preset"] as? String == "game" }
        XCTAssertEqual(first?["kind"] as? String, "tictactoe")
        XCTAssertEqual(first?["move"] as? Int, 1)
        XCTAssertEqual(first?["x"] as? [Int], [1])
        XCTAssertEqual(first?["o"] as? [Int], [])
        waitFor("my turn again") { status() == "Your turn" }
        shot("2-answered")

        // Play on until the game ends: always the first free cell.
        var guardCount = 0
        while !app.buttons["game-again"].exists, guardCount < 6 {
            guardCount += 1
            guard let free = (1...9).first(where: { cell($0).label.hasSuffix("empty") }) else { break }
            let before = events().count
            cell(free).tap()
            waitFor("the move to go out") { events().count > before }
            if events().last?["winner"] != nil { break }
            waitFor("the agent to answer or the game to end") { status() == "Your turn" || app.buttons["game-again"].exists }
        }
        XCTAssertTrue(app.buttons["game-again"].waitForExistence(timeout: 5), "the game never ended")
        let result = status()
        XCTAssertTrue(["You win!", "The agent wins.", "Draw."].contains(result), "status: \(result)")
        shot("3-over")

        // Play again clears the board on the phone and tells the agent.
        app.buttons["game-again"].tap()
        waitFor("an empty board") { (1...9).allSatisfy { cell($0).label.hasSuffix("empty") } }
        XCTAssertEqual(events().last?["again"] as? Bool, true)
        XCTAssertEqual(status(), "Your turn")
    }

    func testTicTacToeLight() { ticTacToe("light") }
    func testTicTacToeDark() { ticTacToe("dark") }

    func testSnakeScoresComeBack() {
        launch("snake", appearance: "dark", lines: [#"game snake "Beat 3" speed=5 size=10 best=3"#])
        let start = app.buttons["snake-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "no Start button")
        sleep(1)
        XCTAssertEqual(app.staticTexts["game-best"].label, "Best 3")
        shot("1-ready")
        start.tap()
        // Heading right on a 10-cell board at speed 5: it eats the first food and hits the wall.
        XCTAssertTrue(app.staticTexts["snake-over"].waitForExistence(timeout: 10), "no game over")
        let over = events().last { $0["preset"] as? String == "game" }
        XCTAssertEqual(over?["kind"] as? String, "snake")
        XCTAssertEqual(over?["over"] as? Bool, true)
        XCTAssertEqual(over?["score"] as? Int, 1)
        shot("2-over")
        // Play again starts a new game; steering with the pad works.
        app.buttons["snake-start"].tap()
        app.buttons["snake-up"].tap()
        XCTAssertTrue(app.staticTexts["snake-over"].waitForExistence(timeout: 10))
        shot("3-again")
    }

    private func memory(_ appearance: String) {
        launch("memory-\(appearance)", appearance: appearance,
               lines: [#"game memory "Spanish animals" pairs=3 items=perro|gato|pez"#], extra: ["-yuiGameSeed", "YES"])
        let first = app.buttons["memory-card-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no cards")
        sleep(1)
        XCTAssertEqual(first.label, "Hidden card")
        shot("1-deal")
        // Seeded deal: card k pairs with k+3. One miss, then the three pairs.
        first.tap(); app.buttons["memory-card-1"].tap()
        XCTAssertEqual(app.buttons["memory-card-1"].label, "gato")
        waitFor("the miss to turn back") { app.buttons["memory-card-0"].label == "Hidden card" }
        for k in 0..<3 {
            app.buttons["memory-card-\(k)"].tap(); app.buttons["memory-card-\(k + 3)"].tap()
            usleep(600_000)
        }
        XCTAssertTrue(app.buttons["game-again"].waitForExistence(timeout: 5), "not finished")
        let over = events().last { $0["preset"] as? String == "game" }
        XCTAssertEqual(over?["kind"] as? String, "memory")
        XCTAssertEqual(over?["moves"] as? Int, 4)
        XCTAssertNotNil(over?["seconds"] as? Int)
        shot("2-done")
    }

    func testMemoryLight() { memory("light") }
    func testMemoryDark() { memory("dark") }

    /// An unknown kind says so instead of breaking; a game saved to the shelf comes back.
    func testUnknownKindAndShelf() {
        launch("unknown", appearance: "light",
               lines: [#"game chess "Pawn to e4" +inline"#, "game@s snake +inline", "save arcade"])
        XCTAssertTrue(app.descendants(matching: .any)["game-unknown"].waitForExistence(timeout: 20), "no unknown-kind note")
        XCTAssertTrue(app.buttons["snake-start"].waitForExistence(timeout: 5), "the inline snake is missing")
        let shelf = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'arcade'")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 5), "arcade is not on the shelf")
        shot("1-inline")
        shelf.tap()
        XCTAssertTrue(app.buttons["snake-start"].waitForExistence(timeout: 5), "the shelf did not bring the game back")
        shot("2-shelf")
    }
}
