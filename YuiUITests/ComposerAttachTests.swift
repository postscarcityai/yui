import UIKit
import XCTest

/// The composer's + menu, a photo sent in the thread, and hold to talk
/// (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q). Demo account, no network.
/// `TEST_RUNNER_YUI_SHOTS=<dir>` saves screenshots; `TEST_RUNNER_YUI_TEST_PHOTO=<jpg>` picks the photo.
final class ComposerAttachTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-appearance", appearance] + extra
        app.launch()
        return app
    }

    /// `TEST_RUNNER_YUI_APPEARANCE=light` for the light screenshots.
    private var appearance: String { ProcessInfo.processInfo.environment["YUI_APPEARANCE"] ?? "dark" }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(appearance).png"))
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
        // A person lets the keyboard go with a pull on the thread into the keyboard.
        // The pull scrolls the thread too; a thread that sat on the newest message goes back to it.
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            sleep(2)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the pull did not let the keyboard go")
        XCTAssertTrue(sent.isHittable, "the sent photo is hidden")
        // The thread rests on the newest message: the caption clears the page pill (YUI-74).
        let caption = app.staticTexts["Lunch, what do you think?"]
        let tabs = app.descendants(matching: .any)["page-tabs"].firstMatch
        let floor = tabs.exists ? tabs.frame.minY : app.descendants(matching: .any)["composer"].firstMatch.frame.minY
        XCTAssertLessThanOrEqual(caption.frame.maxY, floor + 1, "the caption sits under the page pill: \(caption.frame) vs \(floor)")
        XCTAssertLessThanOrEqual(sent.frame.maxY, floor + 1, "the photo sits under the page pill")
        shot("03-photo-sent")
        // Scrolled up on purpose, the thread stays put (YUI-74).
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        sleep(2)
        XCTAssertGreaterThan(caption.frame.minY, floor, "a thread scrolled up jumped back to the bottom")
    }

    func testHoldToTalkListens() {
        let app = launch(["-yuiPTTDemo", "Book me a haircut Friday at four"])
        let listening = app.descendants(matching: .any)["listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 20), "no listening state")
        XCTAssertFalse(app.buttons["attach"].exists, "the + stays up while listening")
        sleep(1)
        shot("04-push-to-talk")
    }

    /// TestFlight feedback AFxu7cyMxK1BmzLnKcwsPzw: let go sends, with a waveform while it listens.
    /// `-yuiPTTFake` stands in for the mic; the hold and the let-go are the real gesture.
    func testLetGoSends() {
        let words = "Book me a haircut Friday at four"
        let app = launch(["-yuiPTTFake", words])
        let talk = app.descendants(matching: .any)["talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 20))
        talk.press(forDuration: 1.5)
        XCTAssertTrue(app.staticTexts[words].waitForExistence(timeout: 5), "let go did not send the words")
        XCTAssertFalse(app.descendants(matching: .any)["listening"].exists, "still listening after let go")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a voice send brought the keyboard up")
        sleep(1)
        shot("06-talk-sent")
    }

    /// Slide left to the trash and let go: nothing is sent.
    func testSlideLeftCancels() {
        let words = "Never mind this one"
        let app = launch(["-yuiPTTFake", words])
        let talk = app.descendants(matching: .any)["talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 20))
        let from = talk.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 1.0, thenDragTo: from.withOffset(CGVector(dx: -200, dy: 0)))
        sleep(2)
        XCTAssertFalse(app.staticTexts[words].exists, "a cancelled recording was sent")
        XCTAssertFalse(app.descendants(matching: .any)["listening"].exists, "still listening after cancel")
        XCTAssertTrue(talk.exists, "the mic did not come back")
        shot("07-talk-cancelled")
    }

    func testSlideToTrashArmsCancel() {
        let app = launch(["-yuiPTTDemo", "Book me a haircut Friday at four", "-yuiPTTDemoCancel"])
        XCTAssertTrue(app.descendants(matching: .any)["listening"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["talk-trash-armed"].firstMatch.exists, "the trash is not armed")
        sleep(1)
        shot("05-talk-cancel-armed")
    }

    func testReduceMotionShowsALevelBar() {
        let app = launch(["-yuiPTTDemo", "Book me a haircut Friday at four", "-yuiReduceMotion"])
        XCTAssertTrue(app.descendants(matching: .any)["listening"].firstMatch.waitForExistence(timeout: 20))
        sleep(1)
        shot("08-talk-reduce-motion")
    }

    func testTapOnMicExplainsHold() {
        let app = launch()
        let talk = app.descendants(matching: .any)["talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 20))
        talk.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer-note"].waitForExistence(timeout: 3), "a tap on the mic says nothing")
    }
}
