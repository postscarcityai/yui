import XCTest

/// The first-run path on the live backend, for the video (YUI-160): a brand-new person signs in,
/// Yui talks first with the crew there, a tap gets her answer, Arnold answers with a screen, and
/// Basil reads a meal photo. Driven by supabase/tests/native_first_run_video.py, which makes a
/// throwaway account, records the simulator, writes `replied-<agent>` to YUI_SHOTS as each answer
/// lands in the database, and deletes the account after.
final class NativeFirstRunVideoTests: XCTestCase {
    func testFirstRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let rt2 = env["YUI_RT2"], let user = env["YUI_USER"],
              let dir = env["YUI_SHOTS"], let photo = env["YUI_TEST_PHOTO"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT, _RT2, _USER, _SHOTS and _TEST_PHOTO")
        }
        let shots = URL(fileURLWithPath: dir)
        let look = env["YUI_APPEARANCE"] ?? "light"
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func answer(_ agent: String) -> String {
            let file = shots.appending(path: "replied-\(agent)")
            let end = Date().addingTimeInterval(150)
            while Date() < end && !FileManager.default.fileExists(atPath: file.path) { sleep(1) }
            return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        func talkTo(_ name: String) {
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10), "no agent picker")
            picker.tap()
            let row = app.buttons[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) is not in the picker")
            sleep(1)
            row.tap()
            sleep(2)
        }
        func say(_ words: String) {
            let field = app.descendants(matching: .any)["composer"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
            field.tap()
            field.typeText(words)
            app.buttons["Send"].tap()
        }
        func letKeyboardGo() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.9)))
            sleep(2)
        }

        // 1. First launch: Yui talks first. No pairing anywhere.
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", look]
        app.launch()
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 45), "Yui's first message is not on screen")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertFalse(text("Pairing code").exists, "a pairing step shows")
        sleep(3)
        shot("01-yui-first")

        // 2. The crew is there: the picker lists them. Close it and tap Yui's first choice.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to")).firstMatch
        picker.tap()
        XCTAssertTrue(app.buttons["Basil"].waitForExistence(timeout: 5), "the crew is not in the picker")
        sleep(2)
        shot("02-crew")
        app.buttons["Yui"].firstMatch.tap()
        sleep(1)
        let getFit = app.buttons["Get fit"].firstMatch
        XCTAssertTrue(getFit.waitForExistence(timeout: 10), "Yui's first choice is missing")
        getFit.tap()
        let yui = answer("yui")
        XCTAssertFalse(yui.isEmpty, "Yui never answered")
        XCTAssertTrue(text(yui).waitForExistence(timeout: 30), "Yui's answer is not on screen: \(yui)")
        sleep(3)
        shot("03-yui-answers")

        // 3. A full turn with a screen: Arnold builds a workout.
        talkTo("Arnold")
        say("Give me a 15 minute workout I can do at home today")
        let arnold = answer("arnold")
        XCTAssertFalse(arnold.isEmpty, "Arnold never answered")
        XCTAssertTrue(text(arnold).waitForExistence(timeout: 30), "Arnold's answer is not on screen: \(arnold)")
        letKeyboardGo()
        sleep(3)
        shot("04-arnold-screen")

        // 4. A photo turn: Basil reads a meal. A second session puts the photo in the composer.
        app.terminate()
        app.launchArguments = ["-yuiRefreshToken", rt2, "-yuiUserID", user, "-appearance", look, "-yuiComposerPhoto", photo]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["attachment"].firstMatch.waitForExistence(timeout: 30),
                      "the photo never reached the composer")
        talkTo("Basil")
        say("Lunch")
        XCTAssertTrue(app.descendants(matching: .any)["bubble-photo"].firstMatch.waitForExistence(timeout: 20),
                      "the photo never reached the thread")
        let basil = answer("basil")
        XCTAssertFalse(basil.isEmpty, "Basil never answered")
        XCTAssertTrue(text("Calories").waitForExistence(timeout: 30), "Basil's meal tiles are not on screen")
        letKeyboardGo()
        sleep(3)
        shot("05-basil-meal")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.62)))
        sleep(3)
        shot("06-basil-tiles")
    }
}
