import XCTest

/// YUI-96 (YUI-43 step 2, spec yuigui/spec/RESTYLE.md): an agent offers Yui a new
/// look with `theme app autumn`. The card shows Now beside autumn, light or dark;
/// nothing changes before the tap. Use autumn restyles the chrome and leaves
/// Undo; Undo puts the old look back. An older offer retires. Settings > Look
/// has Back to Yui's look, and an agent's thread keeps its own look unless the
/// switch is off. Demo account, no backend.
final class RestyleTests: XCTestCase {
    private var shots: URL? { ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) } }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ args: [String], _ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-appearance", appearance, "-yuiReduceMotion"] + args
        app.launch()
        return app
    }

    func testPreviewApplyUndo() throws {
        for appearance in ["light", "dark"] { try previewApplyUndo(appearance) }
    }

    private func previewApplyUndo(_ appearance: String) throws {
        let app = launch(["-yuiDemoRestyle"], appearance)
        let apply = app.buttons["restyle-apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 15), "no preview card")
        XCTAssertEqual(apply.label, "Use autumn")
        XCTAssertTrue(app.buttons["restyle-keep"].exists)
        // One live card: the ocean offer above it retired.
        XCTAssertTrue(app.staticTexts["A newer look was offered below."].exists, "the older card did not retire")
        XCTAssertEqual(app.buttons.matching(identifier: "restyle-apply").count, 1)
        // Autumn's accent is moved by the guard in both modes, and the card says so.
        XCTAssertTrue(app.staticTexts["restyle-guard"].exists, "no guard note")
        sleep(1)
        shot("restyle-preview-\(appearance)")

        // The Light / Dark switch flips both small phones.
        let other = appearance == "light" ? "dark" : "light"
        app.buttons["restyle-\(other)"].tap()
        XCTAssertTrue(app.buttons["restyle-\(other)"].isSelected)
        sleep(1)
        shot("restyle-preview-\(appearance)-showing-\(other)")

        apply.tap()
        let undo = app.buttons["restyle-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo after apply")
        XCTAssertTrue(app.staticTexts["Yui is autumn now."].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Yui is autumn now.'")).count > 0)
        XCTAssertFalse(app.buttons["restyle-apply"].exists, "the card kept its buttons")
        sleep(1)
        shot("restyle-applied-\(appearance)")

        undo.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Put back the look from before.'")).firstMatch
            .waitForExistence(timeout: 5), "Undo did not put the look back")
        XCTAssertFalse(app.buttons["restyle-undo"].exists)
        sleep(1)
        shot("restyle-undo-\(appearance)")
        app.terminate()
    }

    func testKeepMine() throws {
        let app = launch(["-yuiDemoRestyle"], "light")
        XCTAssertTrue(app.buttons["restyle-keep"].waitForExistence(timeout: 15))
        app.buttons["restyle-keep"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Kept your look.'")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["restyle-apply"].exists)
        app.terminate()
    }

    func testSettingsBackToYuisLook() throws {
        for appearance in ["light", "dark"] {
            let app = launch(["-yuiDemo", "-yuiAppLookDemo", "autumn", "-yuiSettings", "-yuiSettingsLarge"], appearance)
            let reset = app.buttons["look-reset"]
            XCTAssertTrue(reset.waitForExistence(timeout: 15), "no Back to Yui's look")
            let name = app.descendants(matching: .any).matching(identifier: "look-name").firstMatch
            XCTAssertEqual(name.label, "Yui's look, Autumn", "Settings does not name the look")
            sleep(1)
            shot("restyle-settings-\(appearance)")
            reset.tap()
            XCTAssertTrue(app.descendants(matching: .any)["Yui's look, Yui's own"].waitForExistence(timeout: 5))
            XCTAssertFalse(reset.exists, "Back to Yui's look stays after the reset")
            sleep(1)
            shot("restyle-reset-\(appearance)")
            app.terminate()
        }
    }

    /// An agent's thread keeps its own look under an app look; the switch off, it wears the app's.
    func testAgentThreadsKeepTheirLooks() throws {
        let app = launch(["-yuiDemoAgents", "-yuiAgent", "wizard", "-yuiAppLookDemo", "autumn"], "light")
        XCTAssertTrue(app.buttons["Talking to Wizard, online"].waitForExistence(timeout: 15))
        sleep(1)
        shot("restyle-agent-keeps-look-light")
        app.terminate()

        let off = launch(["-yuiDemoAgents", "-yuiAgent", "wizard", "-yuiAppLookDemo", "autumn",
                          "-yuiAgentsOwnLooks", "NO"], "light")
        XCTAssertTrue(off.buttons["Talking to Wizard, online"].waitForExistence(timeout: 15))
        sleep(1)
        shot("restyle-agents-wear-app-look-light")
        off.terminate()
    }
}
