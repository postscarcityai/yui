import XCTest

/// Hold a card that has an ask under it > Reply must not crash (t_2aba089a).
final class ReplyCardAskCrashTests: XCTestCase {
    func testReplyToCardWithAsk() throws {
        let rows: [[String: Any]] = [
            ["id": "a0", "sender": "agent", "kind": "text", "created_at": "2026-09-25T10:00:00+00:00",
             "body": "```yui\ncard \"Saturday plan\" body=\"Squats 5x5 at 185, then a 20 minute tabata\" cta=Start\nask \"Ready at 9?\" \"Yes\"|\"Later\"\n```"],
        ]
        let f = FileManager.default.temporaryDirectory.appending(path: "yui-reply-crash.json")
        try JSONSerialization.data(withJSONObject: rows).write(to: f)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiLongThread", "12", "-yuiThreadRows", f.path]
        app.launch()
        let card = app.staticTexts["Saturday plan"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        for target in ["Saturday plan", "Squats 5x5 at 185, then a 20 minute tabata", "Ready at 9?"] {
            let e = app.staticTexts[target].firstMatch
            XCTAssertTrue(e.waitForExistence(timeout: 5), target)
            e.press(forDuration: 0.8)
            let reply = app.buttons["react-reply"]
            XCTAssertTrue(reply.waitForExistence(timeout: 5), "no menu on \(target)")
            reply.tap()
            let bar = app.descendants(matching: .any)["reply-bar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 4), "no reply bar (crash?) on \(target)")
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "crashed on \(target)")
            print("BAR[\(target)]: \(bar.label)")
            app.buttons["reply-cancel"].tap()
            XCTAssertTrue(bar.waitForNonExistence(timeout: 4))
        }
    }
}
