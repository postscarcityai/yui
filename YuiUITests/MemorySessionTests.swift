import XCTest

/// YUI-100. Chris, Sep 25: "I think there must be memory leakage all over the place."
/// A scripted session on the demo account: five agents, each with a 500-row thread
/// (text, markdown, galleries, decks, games) and screens 2 to 12. One warm-up round,
/// then the same round again and again: switch agents, scroll far up and back, visit
/// every screen, open a card full screen and close it. Then idle.
///
/// With `-yuiMemEvery 1` the app logs its footprint every second. `scripts/memory.sh`
/// streams that log, cuts it at the `MEM` marks printed here, runs `leaks` on the app
/// at the start and end checkpoints and fails when the session ends too far above
/// where it started. MEM_ROWS (TEST_RUNNER_MEM_ROWS) is the rows file the script
/// writes; MEM_DIR is where the checkpoints meet the script.
final class MemorySessionTests: XCTestCase {
    func testTheSessionGivesItsMemoryBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rows = env["MEM_ROWS"] else { throw XCTSkip("run through scripts/memory.sh") }
        let dir = env["MEM_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let cycles = Int(env["MEM_CYCLES"] ?? "") ?? 3
        let idle = UInt32(env["MEM_IDLE"] ?? "") ?? 60

        func mark(_ phase: String) {
            print("MEM \(phase) \(String(format: "%.3f", Date().timeIntervalSince1970))")
        }
        /// The script runs `leaks` on the app here; the app sits still meanwhile.
        func checkpoint(_ name: String) {
            mark(name)
            guard let dir else { sleep(3); return }
            let done = dir.appending(path: "\(name).done")
            FileManager.default.createFile(atPath: dir.appending(path: "\(name).go").path, contents: nil)
            let end = Date().addingTimeInterval(180)
            while Date() < end, !FileManager.default.fileExists(atPath: done.path) { sleep(1) }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiThreadRows", rows, "-yuiSpeed", "YES",
                               "-yuiMemEvery", "1", "-yuiDemoReply", "say Got it.", "-yuiReduceMotion",
                               "-appearance", "light"]
        app.launch()
        let newest = app.staticTexts["The newest answer, at the bottom of a long thread."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "the long thread did not load")
        sleep(3)
        mark("launch")

        // Drags from the left margin: over a card they would scroll the card.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.25))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.8))
        let menu = app.buttons["Agent menu"]
        let bar = app.buttons["drawer-agent-bar"]

        func open(_ agent: String) {
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "no agent menu")
            menu.tap()
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "the drawer did not open")
            bar.tap()
            let row = app.buttons["switch-\(agent)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(agent) in the switcher")
            row.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 10), "\(agent)'s thread did not open")
        }

        func round() {
            for agent in ["Coach", "Wizard", "Counsel", "Nova", "Yui"] {
                open(agent)
                // Far up through the galleries and decks, then back.
                for _ in 0..<8 { top.press(forDuration: 0.01, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0) }
                let jump = app.buttons["Jump to newest"]
                if jump.waitForExistence(timeout: 3) { jump.tap() }
                XCTAssertTrue(newest.waitForExistence(timeout: 5), "the arrow did not bring the newest message back")
                // Every screen, 2 to 12, then back to the chat.
                for n in 2...12 {
                    let tab = app.buttons["page-tab-\(n)"]
                    if tab.waitForExistence(timeout: 2) { tab.tap() } else { XCTFail("no screen \(n) tab for \(agent)") }
                }
                app.buttons["page-tab-1"].tap()
                // A card full screen, and closed.
                let pill = app.buttons["Open Tabata full screen"].firstMatch
                for _ in 0..<3 where !pill.isHittable { top.press(forDuration: 0.01, thenDragTo: bottom) }
                if pill.waitForExistence(timeout: 3), pill.isHittable {
                    pill.tap()
                    let close = app.buttons["Close full screen"]
                    if close.waitForExistence(timeout: 5) { close.tap() }
                }
            }
        }

        round()
        checkpoint("start")
        for i in 1...cycles {
            round()
            mark("round\(i)")
        }
        sleep(idle)
        checkpoint("end")
    }
}
