import XCTest

/// Reactions on the phone (YUI-49), against the live relay and a host whose
/// agent is a real model. Driven by `supabase/tests/reactions_e2e.py --sim
/// <udid>`, which runs the host and answers the handshake file below.
///
///   1. Ask; the agent proposes a plan.
///   2. Hold the proposal: the bar opens. Tap 👍: the badge lands on the bubble.
///   3. The agent gets the reaction as a turn and builds the plan.
///   4. Reopen (dark): the 👍 is still on the proposal, read back from the server.
///
/// Every launch needs its own FRESH refresh token (TEST_RUNNER_YUI_RTS, two).
final class ReactionTests: XCTestCase {
    func testThumbsUpBuildsIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/reactions_e2e.py --sim <udid>")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: shots.appending(path: "\(name).png"))
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func launch(_ n: Int, _ appearance: String) -> XCUIElement {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            let field = app.descendants(matching: .any).matching(
                NSPredicate(format: "placeholderValue == %@ OR label == %@", "Say something nice", "Say something nice")).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            return field
        }
        let proposal = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Want me to set up Saturday")).firstMatch

        // 1. Ask; the agent proposes.
        let field = launch(0, "light")
        field.tap()
        field.typeText("Saturday workout?")
        app.buttons["Send"].tap()
        XCTAssertTrue(proposal.waitForExistence(timeout: 90), "no proposal from the agent")
        app.swipeDown()  // keyboard away
        sleep(1)

        // 2. Hold it: the bar. Tap 👍.
        proposal.press(forDuration: 0.8)
        let thumbs = app.buttons["react-build it"]
        XCTAssertTrue(thumbs.waitForExistence(timeout: 5), "no reaction bar after a long press")
        XCTAssertTrue(app.buttons["react-priority"].exists && app.buttons["react-not sure"].exists)
        sleep(1)
        shot("05-e2e-bar-light")
        thumbs.tap()
        func reacted(_ secs: TimeInterval) -> Bool {
            let end = Date.now.addingTimeInterval(secs)
            repeat {
                if (proposal.value as? String)?.contains("Reacted 👍") == true { return true }
                usleep(300_000)
            } while Date.now < end
            return false
        }
        XCTAssertTrue(reacted(5), "no 👍 on the bubble after the tap")
        XCTAssertFalse(thumbs.exists, "the bar stayed open")
        shot("06-e2e-reacted-light")

        // 3. The agent answers the reaction (the driver says when it's in the thread).
        try? Data().write(to: shots.appending(path: "need-reply"))
        let done = shots.appending(path: "reply-ok")
        let end = Date.now.addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the agent never answered the 👍")
        sleep(4)
        app.swipeUp()
        sleep(1)
        shot("07-e2e-agent-built-it-light")
        app.terminate()

        // 4. Reopen in dark: the badge comes back from the server.
        _ = launch(1, "dark")
        XCTAssertTrue(proposal.waitForExistence(timeout: 20))
        XCTAssertTrue(reacted(10), "the 👍 did not come back after reopening")
        // The plan's screens push the proposal up under the bar: scroll back to it.
        for _ in 0..<3 where !proposal.isHittable || proposal.frame.minY < 140 { app.scrollViews.firstMatch.swipeDown() }
        sleep(1)
        shot("08-e2e-reopened-dark")
        proposal.press(forDuration: 0.8)
        XCTAssertTrue(thumbs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["react-remove"].exists, "a reacted bubble offers Remove")
        sleep(1)
        shot("09-e2e-bar-dark")
        // Close by tapping the dimmed thread, clear of the bar and the menu.
        XCTAssertTrue(app.descendants(matching: .any)["reaction-dismiss"].firstMatch.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)).tap()
        sleep(1)
        XCTAssertFalse(thumbs.exists, "the bar stayed open")
        XCTAssertEqual(proposal.value as? String, "Reacted 👍, build it", "closing the bar changed the reaction")
    }
}

/// The hold menu fits any message (YUI-78, TestFlight feedback AFduDX-JwEKyTFAt4pnYIPY:
/// "the copy button and the emojis are competing"). The reaction bar is always above
/// the held message and the menu below it, both inside the window, clear of the
/// header and of each other: for a checklist taller than the screen (drawn as a
/// shortened preview), a message at the top, one at the bottom and a card, with and
/// without the Remove row, at default and AX3 type. Tap outside closes; Select text
/// has every word. Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class HoldMenuLayoutTests: XCTestCase {
    func testLight() throws { try run(appearance: "light") }

    func testDark() throws { try run(appearance: "dark") }

    func testAX3() throws { try run(appearance: "light", type: "UICTContentSizeCategoryAccessibilityXL", tag: "ax3") }

    private func run(appearance: String, type: String? = nil, tag: String? = nil) throws {
        let app = XCUIApplication()
        let name = tag.map { "\(appearance)-\($0)" } ?? appearance
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ s: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "hold-\(s)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "hold-\(s)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        func text(_ prefix: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        let bar = el("reaction-bar"), menu = el("reaction-menu"), preview = el("reaction-preview")

        /// Holds `target`, checks the layout, and returns with the menu open.
        func hold(_ target: XCUIElement, _ what: String, reacts: Bool = true, remove: Bool = false,
                  cut: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) {
            target.press(forDuration: 0.8)
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "\(what): no hold menu", file: file, line: line)
            sleep(1)  // the spring settles
            let window = app.windows.firstMatch.frame
            let header = app.navigationBars.firstMatch.frame.maxY
            let p = preview.frame, m = menu.frame
            XCTAssertTrue(window.contains(m), "\(what): menu \(m) leaves the window \(window)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(p.minY, header - 0.5, "\(what): preview under the header", file: file, line: line)
            XCTAssertLessThanOrEqual(p.maxY, m.minY + 0.5, "\(what): menu over the preview", file: file, line: line)
            XCTAssertEqual(app.buttons["react-remove"].exists, remove, "\(what): Remove row", file: file, line: line)
            for id in ["react-reply", "react-copy", "react-select", "react-share"] {
                XCTAssertTrue(app.buttons[id].isHittable, "\(what): \(id) not tappable", file: file, line: line)
            }
            if let cut {
                XCTAssertEqual(preview.label.hasSuffix("shortened"), cut, "\(what): \(preview.label)", file: file, line: line)
            }
            if reacts {
                let b = bar.frame
                XCTAssertTrue(window.contains(b), "\(what): bar \(b) leaves the window", file: file, line: line)
                XCTAssertGreaterThanOrEqual(b.minY, header - 0.5, "\(what): bar under the header", file: file, line: line)
                XCTAssertLessThanOrEqual(b.maxY, p.minY + 0.5, "\(what): bar over the preview", file: file, line: line)
                XCTAssertFalse(b.intersects(m), "\(what): bar \(b) and menu \(m) overlap", file: file, line: line)
                for r in ["love it", "build it", "not sure", "priority"] {
                    XCTAssertTrue(app.buttons["react-\(r)"].isHittable, "\(what): \(r) not tappable", file: file, line: line)
                }
            } else {
                XCTAssertFalse(bar.exists, "\(what): a bar on the person's own message", file: file, line: line)
            }
        }
        /// Closes by tapping the dimmed thread beside the preview.
        func tapOutside(_ what: String) {
            let p = preview.frame, w = app.windows.firstMatch.frame
            let x = p.minX > 30 ? 12 : w.width - 12
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: p.midY)).tap()
            XCTAssertTrue(menu.waitForNonExistence(timeout: 3), "\(what): tap outside did not close")
        }

        /// Scrolls until `e` is fully in the thread, clear of the header and the composer.
        func reveal(_ e: XCUIElement, down: Bool) {
            for _ in 0..<8 {
                let header = app.navigationBars.firstMatch.frame.maxY
                let f = e.frame
                if e.exists, e.isHittable, f.minY > header + 8, f.maxY < app.windows.firstMatch.frame.height - 140 { return }
                if down { app.swipeDown() } else { app.swipeUp() }
                sleep(1)
            }
        }

        var args = ["-yuiDemoAccount", "-yuiDemoHold", "-appearance", appearance]
        if let type { args += ["-UIPreferredContentSizeCategoryName", type] }
        app.launchArguments = args
        app.launch()

        // 1. The checklist taller than the screen: a shortened preview, bar and menu clear.
        let list = text("Before build 95")
        XCTAssertTrue(list.waitForExistence(timeout: 15), "no checklist")
        for _ in 0..<4 where !list.isHittable { app.swipeDown() }
        hold(list, "long", cut: true)
        shot("long")
        // React; held again it has the Remove row, and still fits.
        app.buttons["react-priority"].tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 3), "the bar stayed open after a reaction")
        hold(list, "long + Remove", remove: true, cut: true)
        shot("long-remove")
        // Tapping the preview closes too.
        preview.tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 3), "tapping the preview did not close")

        // Select text still has every word, not the preview's.
        hold(list, "long again", remove: true)
        app.buttons["react-select"].tap()
        let words = app.textViews["select-text"]
        XCTAssertTrue(words.waitForExistence(timeout: 5))
        XCTAssertTrue((words.value as? String)?.contains("Progress") == true, "Select text lost the end of the message")
        app.navigationBars["Select text"].buttons["Done"].tap()
        XCTAssertTrue(words.waitForNonExistence(timeout: 3))
        sleep(1)

        // 2. The first message, at the very top of the thread.
        let first = text("Morning! Ready")
        reveal(first, down: true)
        hold(first, "top", cut: false)
        shot("top")
        tapOutside("top")

        // 3. The person's own message: the menu alone.
        hold(app.staticTexts["What's left before the build?"], "mine", reacts: false)
        tapOutside("mine")

        // 4. The card.
        let card = text("Here's everything I can draw")
        reveal(card, down: false)
        hold(card, "card")
        shot("card")
        tapOutside("card")

        // 5. The last message, at the bottom above the composer.
        let last = text("Last one: the hold menu")
        reveal(last, down: false)
        hold(last, "bottom", cut: false)
        shot("bottom")
        tapOutside("bottom")
    }
}
