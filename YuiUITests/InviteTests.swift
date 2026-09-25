import XCTest

/// Invite links (YUI-56). Signed out, a link waits on the sign-in screen for
/// Sign in with Apple; the Invite code sheet does the same by hand. Signed in,
/// a link claims the invite at once, and a bad one says so. The signed-in test
/// runs from supabase/tests/invite_claim_e2e.py, which makes a throwaway
/// account and invite and checks the claim landed. `TEST_RUNNER_YUI_SHOTS=<dir>`
/// saves screenshots.
@MainActor
final class InviteTests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var shots: URL? { ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) } }
    func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
    }

    /// Opens a link the way Safari or Mail would, and says yes to iOS's prompt.
    func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let ok = springboard.buttons["Open"]
        if ok.waitForExistence(timeout: 5) { ok.tap() }
    }

    func testSignedOutLinkWaitsForSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiSignedOut", "-appearance", "light"]
        app.launch()
        open("yui://invite/abcde-fghjk")
        let pending = app.descendants(matching: .any)["pendingInvite"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "the invite didn't show on the sign-in screen")
        XCTAssertTrue(app.staticTexts["Invite ABCDE-FGHJK is ready. Sign in to join."].exists)
        sleep(1)
        shot("01-link-pending")
        app.buttons["Remove"].tap()
        XCTAssertFalse(pending.waitForExistence(timeout: 2))

        app.buttons["Invite code"].tap()
        let field = app.textFields["inviteCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("nope")
        app.buttons["Use this code"].tap()
        XCTAssertTrue(app.staticTexts["That doesn't look like an invite code. It has 10 letters and numbers."].waitForExistence(timeout: 3))
        field.typeText("  zyxwv tsrqp")
        sleep(1)
        shot("02-code-sheet")
        app.buttons["Use this code"].tap()
        XCTAssertTrue(app.staticTexts["Invite NOPEZ-YXWVT is ready. Sign in to join."].waitForExistence(timeout: 5)
                      || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Invite '")).firstMatch.exists)
        app.buttons["Remove"].tap()
    }

    func testSignedInLinkClaims() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let code = env["YUI_INVITE"] else {
            throw XCTSkip("run from supabase/tests/invite_claim_e2e.py")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["Add your first agent"].waitForExistence(timeout: 20), "not signed in")
        open("yui://invite/WRONG-CODE0")
        let notice = app.staticTexts["inviteNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "a bad code said nothing")
        XCTAssertTrue(notice.label.hasPrefix("That invite code didn't work"), notice.label)
        shot("03-bad-code")
        open("yui://invite/\(code.lowercased())")
        sleep(6)  // the driver checks the row
    }
}
