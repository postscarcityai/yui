import XCTest

/// Talk about this over the live relay (YUI-69). Driven by
/// `supabase/tests/talk_e2e.py --sim <udid>`: a throwaway owner whose agent,
/// Scout, runs on a throwaway host served by the plugin's own talk and controls
/// code, with a scripted agent. Light: each round trip with a shot before and
/// after (SOUL.md gets a line, one Keep it as is, a conflict from a terminal
/// edit then Ask again, a memory forgotten, a schedule moved, a token-shaped
/// memory refused). Dark: the chip and the thread. The driver checks the host.
final class TalkLiveTests: XCTestCase {
    func testRoundTrips() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), rts.count >= 2,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/talk_e2e.py --sim <udid>")
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
        func handshake(_ ask: String) {
            try? Data().write(to: shots.appending(path: "need-\(ask)"))
            let done = shots.appending(path: "\(ask)-ok")
            let end = Date.now.addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
        }
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        func count(_ s: String) -> Int {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).count
        }
        func waitCount(_ s: String, _ n: Int, _ why: String, timeout: TimeInterval = 30) {
            let end = Date.now.addingTimeInterval(timeout)
            while count(s) < n, Date.now < end { sleep(1) }
            XCTAssertGreaterThanOrEqual(count(s), n, why)
        }
        func launch(_ n: Int, _ appearance: String) {
            app.launchArguments = ["-yuiRefreshToken", rts[n], "-yuiUserID", user, "-appearance", appearance]
            app.launch()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 6) { allow.tap() }
            XCTAssertTrue(app.buttons["Agent menu"].waitForExistence(timeout: 30), "the chat did not open")
        }
        func openItem(_ area: String, _ row: String? = nil) {
            app.buttons["Agent menu"].tap()
            let tab = app.buttons["drawer-tab-controls"]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Controls tab")
            tab.tap()
            let areaRow = app.buttons["controls-\(area)"]
            XCTAssertTrue(areaRow.waitForExistence(timeout: 20), "the host's report never arrived")
            let live = NSPredicate(format: "isEnabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: live, object: areaRow)], timeout: 60),
                           .completed, "the host never read online")
            areaRow.tap()
            if let row {
                XCTAssertTrue(text(row).waitForExistence(timeout: 15), "\(row) did not come from the host")
                text(row).tap()
            }
            XCTAssertTrue(app.buttons["controls-talk-about"].waitForExistence(timeout: 15), "no Talk about this on \(area)")
        }
        func talk(_ words: String) {
            app.buttons["controls-talk-about"].tap()
            XCTAssertTrue(app.buttons["about-chip"].waitForExistence(timeout: 8), "no chip")
            let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
            field.typeText(words)
            app.buttons["Send"].tap()
        }
        func keyboardDown() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))  // a drag, not a tap: a tap could open a card
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            sleep(1)
        }
        /// The newest button with this label: older proposals keep theirs.
        func tapNewest(_ label: String) {
            let all = app.buttons.matching(NSPredicate(format: "label == %@", label))
            XCTAssertGreaterThan(all.count, 0, "no \(label) button")
            let b = all.element(boundBy: all.count - 1)
            if !b.isHittable { app.swipeUp() }
            b.tap()
        }

        launch(0, "light")

        // 1. SOUL.md gets a new line.
        openItem("soul")
        XCTAssertTrue(text("trail-running coach").waitForExistence(timeout: 10))
        sleep(1)
        shot("L01-soul-before")
        talk("Less playful when I'm working. Keep the warmth.")
        waitCount("Apply this change?", 1, "no proposal for SOUL.md")
        keyboardDown()
        shot("L02-soul-proposal")
        tapNewest("Apply")
        waitCount("Personality updated", 1, "no receipt for SOUL.md")
        sleep(1)
        XCTAssertFalse(app.buttons["about-chip"].exists, "the chip stayed after its proposal was applied")
        shot("L03-soul-applied")
        handshake("host-after-soul")

        // 2. Keep it as is.
        let applied = count("Personality updated")
        openItem("soul")
        talk("Make the sentences even shorter.")
        waitCount("Apply this change?", 2, "no second proposal")
        keyboardDown()
        tapNewest("Keep it as is")
        sleep(3)
        XCTAssertEqual(count("Personality updated"), applied, "Keep it as is wrote something")
        XCTAssertTrue(app.buttons["about-chip"].exists, "the chip left on Keep it as is")
        shot("L04-kept")

        // 3. A terminal edit mid-proposal: the conflict card, then Ask again.
        app.buttons["about-chip-remove"].tap()
        openItem("soul")
        talk("End every answer with a question.")
        waitCount("Apply this change?", 3, "no third proposal")
        keyboardDown()
        handshake("edit")
        tapNewest("Apply")
        XCTAssertTrue(text("changed on your Mac since this was proposed").waitForExistence(timeout: 20), "no conflict card")
        sleep(1)
        shot("L05-conflict")
        tapNewest("Ask again")
        waitCount("Apply this change?", 4, "Ask again brought no new proposal")
        sleep(1)
        shot("L06-asked-again")
        tapNewest("Apply")
        waitCount("Personality updated", applied + 1, "the second proposal did not apply")
        sleep(1)
        shot("L07-again-applied")
        handshake("host-after-conflict")

        // 4. A memory talked out of date and forgotten.
        openItem("memory", "Knee felt tight")
        sleep(1)
        shot("L08-memory-before")
        talk("That's out of date, the knee is fine now.")
        waitCount("Forget this?", 1, "no proposal to forget the memory")
        keyboardDown()
        shot("L09-memory-proposal")
        tapNewest("Forget")
        waitCount("Memory forgotten", 1, "no receipt for the memory")
        sleep(1)
        shot("L10-memory-forgotten")

        // 5. A schedule talked to a new time.
        openItem("schedules", "morning brief")
        sleep(1)
        shot("L11-schedule-before")
        talk("Move it to 7:30.")
        waitCount("Apply this change?", 5, "no proposal for the schedule")
        keyboardDown()
        shot("L12-schedule-proposal")
        tapNewest("Apply")
        waitCount("Schedule updated", 1, "no receipt for the schedule")
        sleep(1)
        shot("L13-schedule-applied")

        // 6. A memory with a key in it: talked about, never changed.
        openItem("memory", "hidden on your Mac")  // the key's line is hidden, even in the list
        talk("Rotate this token.")
        XCTAssertTrue(text("can only be changed on your Mac").waitForExistence(timeout: 20), "the agent did not say it can't")
        keyboardDown()
        shot("L14-secret-refused")

        // Dark: the chip, and the thread.
        launch(1, "dark")
        openItem("soul")
        app.buttons["controls-talk-about"].tap()
        XCTAssertTrue(app.buttons["about-chip"].waitForExistence(timeout: 8))
        keyboardDown()
        app.swipeDown()
        sleep(1)
        shot("D01-thread-chip")
    }
}
