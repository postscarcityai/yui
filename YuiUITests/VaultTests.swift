import XCTest

/// The key vault (YUI-34 step 2). Demo account, no network, no Face ID (`-yuiVaultNoAuth`), fake keys.
/// Settings > Keys: add a key, the row that follows, no reveal. Key-shaped text held in the composer and in forms,
/// one test per provider shape. The host's ask as the app's own sheet, and Controls > Keys with Revoke.
/// Screenshots go to `YUI_SHOTS`.
final class VaultUITests: XCTestCase {
    static let keys: [(String, String)] = [
        ("fal", "3f9a1c2e-7b4d-4e6a-9c1d-2a8b5e7f0c13:9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a"),
        ("replicate", "r8_Zx3Kq9LmN2pR7sT4vW6yB8cD1eF5gH0jAb"),
        ("elevenlabs", "sk_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f"),
        ("anthropic", "sk-ant-api03-Qx7Lm2Pn9Rs4Tv6Wy8Zb1Cd3Ef5Gh0Jk"),
        ("openai", "sk-proj-Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv"),
    ]

    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "light" }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "vault-\(name)-\(appearance)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "vault-\(name)-\(appearance).png"))
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiDemoNative", "-yuiVaultNoAuth", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, _ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func scrollTo(_ el: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(el.exists && el.isHittable) { app.swipeUp() }
    }

    private func typeInComposer(_ app: XCUIApplication, _ words: String) {
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        field.tap()
        field.typeText(words)
    }

    // MARK: Settings > Keys

    func testAddAKeyThenTheRowShowsLastFourAndNeverTheKey() {
        let app = launch(["-yuiSettings", "-yuiSettingsLarge"])
        let add = app.buttons["vault-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "no Add a key in Settings")
        scrollTo(add, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["vault-empty"].exists, "no empty line")
        add.tap()
        let field = app.secureTextFields["vault-key-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the key field is not a secure field")
        XCTAssertTrue(app.buttons["vault-get-key"].exists || app.links["vault-get-key"].exists
                      || app.descendants(matching: .any)["vault-get-key"].exists, "no Get a key")
        XCTAssertFalse(app.buttons["vault-save"].isEnabled, "Save works with no key")
        shot("1-add")

        // Wrong shape for the provider chosen (fal is first): refused in words.
        field.tap()
        field.typeText(Self.keys[1].1)
        app.buttons["vault-save"].tap()
        let err = app.staticTexts["vault-error"]
        XCTAssertTrue(err.waitForExistence(timeout: 5), "no shape error")
        XCTAssertEqual(err.label, "That doesn't look like a fal key.")

        // The right one.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.keys[1].1.count + 2))
        field.typeText(Self.keys[0].1)
        app.buttons["vault-save"].tap()

        let row = app.descendants(matching: .any)["vault-key-5b4a"]
        _ = row.waitForExistence(timeout: 10); shot("2-after-save")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the saved key is not in the list")
        for part in ["Personal fal", "fal, ends in 5b4a", "Not used yet", "$0 of $10 this month", "On this iPhone only"] {
            XCTAssertTrue(row.label.contains(part), "the row misses \(part): \(row.label)")
        }
        XCTAssertFalse(text(app, Self.keys[0].1).exists, "the key shows after it is saved")
        XCTAssertFalse(text(app, "3f9a1c2e").exists, "part of the key shows")
        shot("2-list")

        // A key's page: no reveal, no copy; iCloud is a switch, off.
        row.tap()
        XCTAssertTrue(app.buttons["vault-remove"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vault-replace"].exists)
        XCTAssertFalse(app.buttons["Show"].exists || app.buttons["Reveal"].exists || app.buttons["Copy"].exists, "a reveal or copy")
        let lives = app.staticTexts["vault-lives"]
        XCTAssertEqual(lives.label, "On this iPhone only")
        let icloud = app.switches["vault-icloud"]
        XCTAssertTrue(icloud.exists)
        XCTAssertEqual(icloud.value as? String, "0", "iCloud is on by default")
        icloud.tap()
        for _ in 0..<25 where lives.label != "On this iPhone and your iCloud Keychain" { usleep(200_000) }
        XCTAssertEqual(lives.label, "On this iPhone and your iCloud Keychain")
        shot("3-key")

        // Remove: asks, says the key still works at the provider.
        app.buttons["vault-remove"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'still works at fal'")).firstMatch.exists)
        XCTAssertTrue(app.alerts.firstMatch.buttons["Revoke it at fal"].exists)
        app.alerts.firstMatch.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["vault-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["vault-key-5b4a"].exists, "the key is still listed after Remove")
    }

    func testTheListShowsSpendAgainstTheCapAndTheModelKeyRow() {
        let app = launch(["-yuiSettings", "-yuiSettingsLarge", "-yuiDemoVault"])
        let row = app.descendants(matching: .any)["vault-key-cdef"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded key is not listed")
        scrollTo(row, in: app)
        XCTAssertTrue(row.label.contains("$8 of $10 this month"), row.label)
        shot("4-spend")
    }

    // MARK: Key-shaped sends

    func testEachProviderShapeIsHeldInTheComposerWithNoSendAnyway() {
        for (provider, key) in Self.keys {
            let app = launch()
            typeInComposer(app, "here is my \(provider) key \(key)")
            app.buttons["Send"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["key-hold"].waitForExistence(timeout: 5), "\(provider): the send was not held")
            XCTAssertEqual(app.staticTexts["key-hold-text"].label, "That looks like a key. Keys go in Settings > Keys, where agents can't read them.")
            XCTAssertTrue(app.buttons["key-hold-move"].exists, "\(provider): no Move it to Keys")
            XCTAssertFalse(app.buttons["key-hold-send"].exists, "\(provider): a known shape has a Send anyway")
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", key)).count, 0,
                           "\(provider): the key was sent into the thread")
            if provider == "fal" { shot("5-held") }
            app.terminate()
        }
    }

    func testAMereLookalikeMaySendAnywayAndMoveOpensTheAddSheet() {
        let app = launch()
        let token = "Zk3Jq8Vn2Lp7Xw5Ty9Bm4Rc6Hd1Fs0Ga8Ue"
        typeInComposer(app, "the token is \(token)")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["key-hold-send"].waitForExistence(timeout: 5), "no Send anyway for a lookalike")
        app.buttons["key-hold-move"].tap()
        XCTAssertTrue(app.secureTextFields["vault-key-field"].waitForExistence(timeout: 10), "Move it to Keys did not open the add sheet")
        app.buttons["vault-cancel"].tap()
        XCTAssertTrue(app.buttons["key-hold-send"].waitForExistence(timeout: 5))
        app.buttons["key-hold-send"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["key-hold"].waitForExistence(timeout: 2), "the hold stays after Send anyway")
        XCTAssertTrue(text(app, token).waitForExistence(timeout: 5), "Send anyway did not send")
    }

    func testEditingTheKeyOutClearsTheHold() {
        let app = launch()
        typeInComposer(app, "sk-ant-api03-Qx7Lm2Pn9Rs4Tv6Wy8Zb1Cd3Ef5Gh0Jk")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["key-hold"].waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["composer"].firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 44))
        XCTAssertFalse(app.descendants(matching: .any)["key-hold"].waitForExistence(timeout: 2), "the hold outlives the key")
    }

    // MARK: Key-shaped text in a form

    func testAKeyTypedIntoAFormIsHeldForEachShape() {
        let reply = "say \"Fill this in.\"\\nform \"Your details\" note:text\\nend"
        for (provider, key) in Self.keys {
            let app = launch(["-yuiDemoReply", reply])
            typeInComposer(app, "start")
            app.buttons["Send"].tap()
            let note = app.textFields["Note"]
            XCTAssertTrue(note.waitForExistence(timeout: 20), "no form")
            note.tap()
            note.typeText(key)
            XCTAssertTrue(app.descendants(matching: .any)["key-hold"].waitForExistence(timeout: 5), "\(provider): the form was not held")
            XCTAssertFalse(app.buttons["Submit"].isEnabled, "\(provider): Submit works with a key in the form")
            XCTAssertFalse(app.buttons["key-hold-send"].exists, "\(provider): Send anyway on a known shape")
            if provider == "fal" { shot("6-form-held") }
            app.terminate()
        }
    }

    // MARK: The ask

    func testAskAllowGrantsAndTheDrawerShowsItWithRevoke() {
        let app = launch(["-yuiDemoVault", "-yuiDemoAgents", "-yuiDemoControls", "-yuiAgent", "coach",
                          "-yuiDemoKeyAsk", "fal|Draw your agent avatars|5|about 4 images a week"])
        let title = app.staticTexts["key-ask-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 25), "the ask sheet never came")
        XCTAssertEqual(title.label, "Coach wants to use your fal key")
        XCTAssertEqual(app.staticTexts["key-ask-for"].label, "Draw your agent avatars")
        XCTAssertEqual(app.staticTexts["key-ask-cap"].label, "Suggested cap: $5 a month")
        for b in ["key-ask-allow", "key-ask-once", "key-ask-deny"] { XCTAssertTrue(app.buttons[b].exists, b) }
        shot("7-ask")
        app.buttons["key-ask-allow"].tap()
        let line = text(app, "[yui] Key access: fal allowed for \"Draw your agent avatars\", cap $5 a month, handle vk_fal_")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the agent's line is missing")
        XCTAssertFalse(app.descendants(matching: .any)["key-ask"].exists, "the sheet stays after Allow")

        // The drawer: Controls > Keys.
        app.buttons["Agent menu"].firstMatch.tap()
        let tab = app.buttons["drawer-tab-controls"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let keys = app.buttons["controls-keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 5), "no Keys row in Controls")
        keys.tap()
        let spend = app.staticTexts["agent-key-spend"]
        XCTAssertTrue(spend.waitForExistence(timeout: 10), "the grant is not listed")
        XCTAssertEqual(spend.label, "$0 of $5 this month")
        XCTAssertTrue(text(app, "Draw your agent avatars").exists)
        shot("8-drawer-keys")
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vault-revoke-'")).firstMatch
        XCTAssertTrue(revoke.exists)
        revoke.tap()
        XCTAssertTrue(app.staticTexts["agent-keys-empty"].waitForExistence(timeout: 10), "the grant is still there after Revoke")
    }

    func testAskNoKeyOffersAddAndDontAllowAnswersNo() {
        let app = launch(["-yuiDemoAgents", "-yuiAgent", "coach", "-yuiDemoKeyAsk", "replicate|Make a header image"])
        XCTAssertTrue(app.staticTexts["key-ask-title"].waitForExistence(timeout: 25), "the ask sheet never came")
        XCTAssertEqual(app.staticTexts["key-ask-title"].label, "Coach wants to use your Replicate key")
        XCTAssertTrue(app.staticTexts["key-ask-nokey"].exists)
        XCTAssertFalse(app.buttons["key-ask-allow"].exists, "Allow with no key")
        shot("9-ask-nokey")
        app.buttons["key-ask-add"].tap()
        XCTAssertTrue(app.secureTextFields["vault-key-field"].waitForExistence(timeout: 10), "Add a Replicate key did not open the add sheet")
        app.buttons["vault-cancel"].tap()
        XCTAssertTrue(app.buttons["key-ask-deny"].waitForExistence(timeout: 5))
        app.buttons["key-ask-deny"].tap()
        XCTAssertTrue(text(app, "[yui] Key access: replicate not allowed.").waitForExistence(timeout: 10), "the agent's no line is missing")
    }
}
