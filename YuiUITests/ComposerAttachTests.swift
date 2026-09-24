import UIKit
import XCTest

/// The composer's + menu, a photo sent in the thread, and hold to talk
/// (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q). Demo account, no network.
/// `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots; `TEST_RUNNER_YUI_TEST_PHOTO=<jpg>` picks the photo.
final class ComposerAttachTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", "dark"] + extra
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    /// A photo on disk the app can read.
    private func photo() throws -> String {
        if let p = ProcessInfo.processInfo.environment["YUI_TEST_PHOTO"], FileManager.default.fileExists(atPath: p) { return p }
        let url = FileManager.default.temporaryDirectory.appending(path: "composer-\(UUID().uuidString).jpg")
        let data = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 900)).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
            UIColor.systemPink.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 200, y: 200, width: 500, height: 500))
        }
        try data.write(to: url)
        return url.path
    }

    func testPlusMenuOffersPhotos() {
        let app = launch()
        let attach = app.buttons["attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 20), "no + in the composer")
        XCTAssertTrue(app.descendants(matching: .any)["talk"].exists, "an empty composer shows the mic")
        XCTAssertFalse(app.buttons["Send"].exists, "Send shows with nothing to send")
        attach.tap()
        XCTAssertTrue(app.buttons["Photo library"].waitForExistence(timeout: 5), "the + menu has no photo library")
        sleep(1)
        shot("01-plus-menu")
    }

    func testPhotoSendsIntoTheThread() throws {
        let app = launch(["-yuiComposerPhoto", try photo()])
        let attachment = app.descendants(matching: .any)["attachment"].firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 20), "the photo never reached the composer")
        XCTAssertTrue(app.buttons["Send"].isEnabled, "a photo alone can't be sent")
        let field = app.descendants(matching: .any)["composer"].firstMatch
        field.tap()
        field.typeText("Lunch, what do you think?")
        shot("02-photo-in-composer")
        app.buttons["Send"].tap()
        let sent = app.descendants(matching: .any)["bubble-photo"].firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the photo never reached the thread")
        XCTAssertTrue(app.staticTexts["Lunch, what do you think?"].exists, "the caption is missing")
        XCTAssertFalse(attachment.exists, "the photo stayed in the composer")
        let left = (field.value as? String) ?? ""
        XCTAssertTrue(left.isEmpty || left == "Say something nice", "the caption stayed in the composer: \(left)")
        sleep(2)
        // The thread lets the keyboard go on an interactive drag, so pull it down past the bottom.
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            sleep(1)
        }
        XCTAssertTrue(sent.isHittable, "the sent photo is hidden")
        shot("03-photo-sent")
    }

    func testHoldToTalkListens() {
        let app = launch(["-yuiPTTDemo", "Book me a haircut Friday at four"])
        let listening = app.descendants(matching: .any)["listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 20), "no listening state")
        XCTAssertFalse(app.buttons["attach"].exists, "the + stays up while listening")
        sleep(1)
        shot("04-push-to-talk")
    }

    func testTapOnMicExplainsHold() {
        let app = launch()
        let talk = app.descendants(matching: .any)["talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 20))
        talk.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer-note"].waitForExistence(timeout: 3), "a tap on the mic says nothing")
    }
}
