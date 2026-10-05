import XCTest

/// Several chats with one agent (YUI-169, spec yuigui/spec/CHATS.md). The drawer's Home starts with
/// New chat, then the chats (newest activity first, the last line said, a coral dot for an unread
/// reply, a soft coral fill on the open one), then Next up and the pinned screens. Rename in place,
/// swipe left or hold a row, Delete asks first, an agent's only chat is cleared instead. New chat
/// is empty and nothing is saved until you say something. Demo account, no network, chats from
/// `-yuiChats`. Shots go to `YUI_SHOTS` as app-<name>-<dark|light>.png.
final class ChatsTests: XCTestCase {
    static let reply = [
        "say Five dinners, one list.",
        #"choose@start "Where to start?" Plan|Log"#,
        ">2",
        #"card "Calories" sub="1,420 of 2,100""#,
        "save calories",
        ">3",
        #"card "Dinners" sub="5 this week""#,
        "save dinners",
    ].joined(separator: "\\n")

    func testDark() throws { try run("dark") }
    func testLight() throws { try run("light") }

    private func chatsFile() throws -> URL {
        func ago(_ s: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-s)) }
        let rows: [[String: Any]] = [
            ["id": "c3", "title": "Tuesday's groceries", "is_first": false, "last_at": ago(20 * 60), "seen_at": ago(3600),
             "last_sender": "agent", "last_body": "Five dinners, one list. Tick what you have.", "last_message_at": ago(20 * 60), "unread": true],
            ["id": "c2", "title": "Protein on rest days", "is_first": false, "last_at": ago(2 * 3600), "seen_at": ago(2 * 3600),
             "last_sender": "agent", "last_body": "Same as training days: about 140 g for you.", "last_message_at": ago(2 * 3600), "unread": false],
            ["id": "c1", "title": NSNull(), "is_first": true, "last_at": ago(3 * 86_400), "seen_at": ago(3 * 86_400),
             "last_sender": "agent", "last_body": "Logged. 390 calories, 20 g protein.", "last_message_at": ago(3 * 86_400), "unread": false],
        ]
        let file = FileManager.default.temporaryDirectory.appending(path: "yui-chats.json")
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        return file
    }

    private func run(_ appearance: String) throws {
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "app-\(name)-\(appearance).png"))
            }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "app-\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoShared", "-yuiAgent", "basil", "-appearance", appearance,
                               "-yuiChats", try chatsFile().path, "-yuiThemeDemo", Self.reply]
        app.launch()

        // The top bar names no chat (the agent chip and its dropdown went, feedback AJw_G3S2):
        // which chat is open is the drawer's to say, checked there.
        XCTAssertTrue(app.buttons["record-new-chat"].waitForExistence(timeout: 20), "no New chat button top right")
        // The reply lands and its screens come forward: a drag right pages back to the chat.
        XCTAssertTrue(app.descendants(matching: .any)["page-3"].staticTexts["Dinners"].waitForExistence(timeout: 25),
                      "the demo reply never landed")
        sleep(1)
        let menu = app.buttons["Agent menu"]
        for _ in 0..<3 where !(menu.exists && menu.isHittable) {
            app.swipeRight()
            sleep(2)
        }
        XCTAssertTrue(menu.exists && menu.isHittable, "did not page back to the chat")
        sleep(1)

        // 1. The drawer: three chats, Next up, pinned screens. New chat is the main screen's button, not here.
        menu.tap()
        let bar = app.buttons["drawer-agent-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no drawer")
        XCTAssertFalse(app.buttons["drawer-new-chat"].exists, "the drawer still has a New chat button")
        let rows = ["c3", "c2", "c1"].map { app.buttons["drawer-chat-open-\($0)"] }
        for (i, r) in rows.enumerated() { XCTAssertTrue(r.waitForExistence(timeout: 5), "chat \(i) is not in the list") }
        XCTAssertTrue(rows[0].isSelected, "the chat you are in, the newest one, is not the marked one")
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY, "newest activity first")
        XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY)
        XCTAssertTrue(rows[0].label.contains("Tuesday's groceries") && rows[0].label.contains("Five dinners, one list"), rows[0].label)
        XCTAssertTrue(rows[0].label.contains("New reply"), "no dot on the unread chat: \(rows[0].label)")
        XCTAssertFalse(rows[1].label.contains("New reply"))
        XCTAssertTrue(rows[2].label.hasPrefix("Hi Basil"), "the first chat is called Hi Basil: \(rows[2].label)")
        XCTAssertTrue(rows[2].label.contains("3d"), rows[2].label)
        let next = app.buttons["drawer-next-up"]
        XCTAssertTrue(next.exists, "no Next up")
        XCTAssertGreaterThan(next.frame.minY, rows[2].frame.maxY - 1, "Next up sits under the chats")
        let pin = app.buttons["drawer-pin-calories"]
        XCTAssertTrue(pin.exists, "no pinned screen")
        XCTAssertGreaterThan(pin.frame.minY, next.frame.maxY - 1, "pinned screens come last")
        XCTAssertEqual(pin.frame.minY, app.buttons["drawer-pin-dinners"].frame.minY, accuracy: 2, "one row, sideways")
        sleep(1)
        shot("drawer")

        // 2. Swipe a row left: Rename and Delete behind it. The drawer stays open.
        rows[2].swipeLeft()
        XCTAssertTrue(app.buttons["chat-delete-c1"].waitForExistence(timeout: 3), "no Delete behind the row")
        XCTAssertTrue(app.buttons["chat-rename-c1"].exists)
        XCTAssertTrue(bar.exists, "the swipe closed the drawer")
        sleep(1)
        shot("swipe")
        rows[2].swipeRight()

        // 3. Hold a row, Rename: the title is edited in place.
        rows[1].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3), "no Rename in the hold menu")
        XCTAssertTrue(app.buttons["Delete"].exists, "no Delete in the hold menu")
        app.buttons["Rename"].tap()
        let field = app.textFields["chat-rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the title is not editable in place")
        if (field.value as? String) != "Protein on rest days" { XCTFail("the field starts empty: \(String(describing: field.value))") }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Protein on rest days".count))
        field.typeText("Rest day protein")
        sleep(1)
        shot("rename")
        field.typeText("\n")
        XCTAssertTrue(app.buttons["drawer-chat-open-c2"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["drawer-chat-open-c2"].label.hasPrefix("Rest day protein"), app.buttons["drawer-chat-open-c2"].label)

        // 4. Delete asks first. Keep it changes nothing; Delete removes the chat.
        app.buttons["drawer-chat-open-c2"].press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Delete \"Rest day protein\"?"].waitForExistence(timeout: 3), "the sheet does not ask")
        XCTAssertTrue(app.staticTexts["Its messages go. Basil still remembers what it learned."].exists)
        XCTAssertTrue(app.buttons["chat-sheet-keep"].exists)
        sleep(1)
        shot("delete-sheet")
        app.buttons["chat-sheet-keep"].tap()
        XCTAssertTrue(app.buttons["drawer-chat-open-c2"].waitForExistence(timeout: 3), "Keep it deleted the chat")
        app.buttons["drawer-chat-open-c2"].press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["chat-sheet-delete"].waitForExistence(timeout: 3))
        app.buttons["chat-sheet-delete"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["drawer-chat-open-c2"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "Delete did not remove the chat")
        XCTAssertTrue(app.buttons["drawer-chat-open-c3"].exists && app.buttons["drawer-chat-open-c1"].exists)

        // 5. The open chat can be deleted: the next newest opens.
        app.buttons["drawer-chat-open-c3"].press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Delete \"Tuesday's groceries\"?"].waitForExistence(timeout: 3))
        app.buttons["chat-sheet-delete"].tap()
        let openGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["drawer-chat-open-c3"])
        XCTAssertEqual(XCTWaiter.wait(for: [openGone], timeout: 5), .completed, "the open chat stayed")
        XCTAssertTrue(app.buttons["drawer-chat-open-c1"].isSelected, "the next newest did not open")

        // 6. The only chat is cleared, not deleted.
        app.buttons["drawer-chat-open-c1"].press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Clear this chat?"].waitForExistence(timeout: 3), "the only chat says Delete, not Clear")
        XCTAssertEqual(app.buttons["chat-sheet-delete"].label, "Clear")
        sleep(1)
        shot("clear-sheet")
        app.buttons["chat-sheet-keep"].tap()
        XCTAssertTrue(app.buttons["drawer-chat-open-c1"].exists)

        // 7. New chat, from the main screen: empty, not in the list, the same one when tapped twice.
        app.buttons["drawer-close"].tap()
        XCTAssertTrue(app.buttons["record-new-chat"].waitForExistence(timeout: 5), "no New chat button top right")
        app.buttons["record-new-chat"].tap()
        XCTAssertTrue(app.staticTexts["Say hi to Basil!"].waitForExistence(timeout: 5), "the empty chat is not today's empty screen")
        sleep(1)
        shot("new-chat")
        app.buttons["record-new-chat"].tap()
        sleep(1)
        menu.tap()
        XCTAssertTrue(app.buttons["drawer-chat-open-c1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "drawer-chat-open-")).count, 1,
                       "an empty chat is in the list")
        app.buttons["drawer-close"].tap()

        // 8. Say something in it: it is saved and comes to the top.
        let input = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("What should I eat before a run")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["What should I eat before a run"].waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "drawer-chat-open-")).count, 2,
                       "the chat was not saved once something was said")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                       "drawer-chat-open-", "New chat")).firstMatch.exists,
                      "the title comes from the server, not the phone")
        sleep(1)
        shot("after-new")
    }
}
