import XCTest

/// Live media round trip (YUI-21): an agent's generated picture arrives as a
/// signed yui-media link and renders, then the person answers its `camera`
/// with a photo (the library, since the simulator has no camera) and the
/// photo goes up to yui-media for the agent. `hermes-plugin/tests/media_e2e.py`
/// drives it: it makes a throwaway account, plays the agent through the real
/// adapter, runs this test, checks the agent got the file, deletes the account.
///
///   TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> TEST_RUNNER_YUI_SHOTS=/tmp/shots \
///     xcodebuild test -scheme Yui -destination '...' -only-testing:YuiUITests/MediaTests
final class MediaTests: XCTestCase {
    func testPictureInPhotoOut() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"] else {
            throw XCTSkip("set TEST_RUNNER_YUI_RT and TEST_RUNNER_YUI_USER to run against the live backend")
        }
        let shots = env["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let app = XCUIApplication()
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", "light"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        // The agent's picture: rendered from the signed link, not a placeholder.
        let picture = app.images[env["YUI_ALT"] ?? "Frame 1"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 60), "the agent's picture never rendered")
        XCTAssertFalse(app.staticTexts["Picture unavailable"].exists, "the signed link did not load")
        sleep(3)
        shot("01-agent-picture")
        // The driver sends the `camera` next (it opens on the stage, over the picture).
        if let shots { try? Data("picture".utf8).write(to: shots.appending(path: "picture")) }

        // The camera card sits on the stage; its library button picks a photo.
        let library = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Choose a photo", "Library")).firstMatch
        if !library.waitForExistence(timeout: 30) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open ")).firstMatch.tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 20), "no camera card")
        shot("02-camera-card")
        library.tap()

        // The picker's grid: photos are labelled "Photo, <date>". The banner's Photos icon is not one.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        let found = photo.waitForExistence(timeout: 20)
        sleep(1)
        shot("03-picker")
        if found {
            photo.tap()
        } else {  // first grid cell, under the privacy banner
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.42)).tap()
        }

        let sent = app.staticTexts["Photo sent"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the photo never finished sending")
        sleep(1)
        shot("04-photo-sent")
        if let shots { try? Data("sent".utf8).write(to: shots.appending(path: "sent")) }

        // The agent answers once it has looked at the photo.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "got your photo")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "the agent never answered the photo")
        sleep(1)
        shot("05-agent-answered")
    }
}
