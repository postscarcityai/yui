import XCTest

/// Shared agents in the app (YUI-97), on the demo account (no network).
///
///   1. An invited client's list: "Hi Maya. Sam set these up for you.", the plain
///      line under it, no Add agent, a paused agent reads "Paused by its owner".
///   2. A shared agent's settings say "Shared by Sam": mute only, no rename or remove.
///   3. A revoke while its thread is open closes it with one quiet line, and the
///      list says "Basil is no longer shared with you."
///   4. The owner's side: "Safe to share", or "Not safe to share: <rule>".
///
/// YUI_SHOTS=<dir> (TEST_RUNNER_YUI_SHOTS) saves the screenshots there too.
@MainActor
final class SharedClientTests: XCTestCase {
    private let app = XCUIApplication()

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func launch(_ args: [String], _ appearance: String) {
        app.launchArguments = ["-yuiDemoAccount", "-appearance", appearance] + args
        app.launch()
    }

    func testAnInvitedClientsList() {
        for look in ["light", "dark"] {
            launch(["-yuiDemoShared", "-yuiAgents"], look)
            XCTAssertTrue(text("Hi Maya. Sam set these up for you.").waitForExistence(timeout: 10), "no greeting (\(look))")
            XCTAssertTrue(text("These agents run on Sam's computer, which keeps your conversations.").exists, "no plain line")
            XCTAssertTrue(text("Paused by its owner").exists, "Scout is not paused")
            XCTAssertFalse(app.buttons["Add agent"].exists, "an invited account shows Add agent")
            sleep(1)
            shot("yui97-01-client-list-\(look)")

            app.buttons["Edit Basil"].tap()
            XCTAssertTrue(text("Shared by Sam").waitForExistence(timeout: 5), "no Shared by line (\(look))")
            XCTAssertTrue(app.switches.firstMatch.exists, "no notifications switch")
            XCTAssertFalse(text("Remove Basil").exists, "a client can remove a shared agent")
            XCTAssertFalse(app.textFields["Name"].exists, "a client can rename a shared agent")
            XCTAssertFalse(text("Make default").exists)
            sleep(1)
            shot("yui97-02-shared-by-\(look)")
            app.terminate()
        }
    }

    func testARevokeClosesTheOpenThread() {
        launch(["-yuiDemoShared", "-yuiAgent", "basil", "-yuiDemoRevoke", "4"], "light")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to Basil")).firstMatch
            .waitForExistence(timeout: 10), "Basil's thread is not open")
        let note = app.descendants(matching: .any)["agentNotice"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "no quiet line when the open thread was revoked")
        XCTAssertEqual(note.label, "Basil is no longer shared with you.")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to Basil")).firstMatch.exists,
                       "the revoked thread is still open")
        shot("yui97-03-revoked-notice")
        // The line sits over the nav bar for a moment: let it go first.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: note)
        wait(for: [gone], timeout: 10)
        // The thread fell back to Penny. Drawer, then its agent bar: the switcher.
        let penny = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Talking to Penny")).firstMatch
        XCTAssertTrue(penny.waitForExistence(timeout: 5), "the chat did not fall back to Penny")
        penny.tap()
        let bar = app.descendants(matching: .any)["drawer-agent-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["switch-unshared"].waitForExistence(timeout: 5), "the switcher has no quiet line")
        XCTAssertFalse(app.descendants(matching: .any)["switch-Basil"].exists, "Basil is still in the switcher")
        XCTAssertFalse(app.descendants(matching: .any)["switch-add"].exists, "an invited account can add agents")
        sleep(1)
        shot("yui97-04-revoked-list")
    }

    func testTheOwnerSeesWhatIsSafeToShare() {
        launch(["-yuiDemoAgents", "-yuiAgents"], "light")
        XCTAssertTrue(app.buttons["Edit Coach"].waitForExistence(timeout: 10))
        app.buttons["Edit Coach"].tap()
        XCTAssertTrue(text("Safe to share").waitForExistence(timeout: 5), "Coach does not say Safe to share")
        sleep(1)
        shot("yui97-05-safe-to-share")
        app.buttons["Cancel"].tap()
        app.buttons["Edit Wizard"].tap()
        XCTAssertTrue(text("Not safe to share: it has a shell on your computer").waitForExistence(timeout: 5),
                      "Wizard does not say why it is not safe")
        sleep(1)
        shot("yui97-06-not-safe")
    }
}
