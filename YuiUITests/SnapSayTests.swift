import UIKit
import XCTest

/// Hold to snap and say (YUI-166): + > Snap and say opens the camera; pressing takes the
/// photo, holding listens, letting go sends the photo and the words as one message, and
/// sliding to the trash throws both away. Demo account (the starter crew), Basil, no network. `-yuiSnapFake`
/// stands in for the camera and `-yuiPTTFake` for the mic. Screenshots go to `YUI_SHOTS`
/// when set, and always into the result bundle.
final class SnapSayTests: XCTestCase {
    static let words = "Two eggs in a lot of butter"
    /// Basil reads the butter, not only the picture (no apostrophes: launch args are plists).
    static let reply = [
        "say \"Two eggs, and the butter counts. About a tablespoon is 100 kcal on its own.\"",
        "card \"Breakfast\" body=\"About 250 kcal. 13 g protein, 21 g fat, most of it the butter.\"",
    ].joined(separator: "\\n")

    /// Hold, talk, let go: the photo and the words reach Basil together and he answers with the butter.
    func testHoldSendsThePhotoAndTheWords() throws {
        let app = try launch("light")
        let snap = try openSnap(app)
        shot("1-camera", "light")
        snap.press(forDuration: 2.5)
        XCTAssertTrue(waitGone(snap), "let go did not send")
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 8), "the stage is not on the sent message")
        XCTAssertTrue(you.label.localizedCaseInsensitiveContains("butter"), "the words did not ride with the photo: \(you.label)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'butter counts'")).firstMatch
            .waitForExistence(timeout: 15), "Basil's answer never played")
        sleep(1)
        shot("3-answered", "light")
        // One message: the photo with the words as its caption.
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["bubble-photo"].firstMatch.waitForExistence(timeout: 5), "no photo in the record")
        XCTAssertTrue(app.staticTexts[Self.words].exists, "the words are not on the photo's message")
        sleep(1)
        shot("4-record", "light")
    }

    /// Slide to the trash while holding: nothing is sent and the camera stays up for another go.
    func testSlideToTheTrashThrowsItAway() throws {
        let app = try launch("dark")
        let snap = try openSnap(app)
        let start = snap.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let trash = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: snap.frame.midY - app.frame.midY))
        start.press(forDuration: 1.5, thenDragTo: trash)
        sleep(1)
        XCTAssertTrue(snap.exists, "the trash closed the camera")
        XCTAssertFalse(app.images["snap-shot"].exists, "the thrown-away photo is still up")
        XCTAssertFalse(app.descendants(matching: .any)["stage-you"].exists, "the trash sent something")
        app.buttons["snap-close"].tap()
        XCTAssertTrue(waitGone(snap), "close did not close")
        app.buttons["stage-record"].tap()
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["bubble-photo"].exists, "a photo went out after the trash")
    }

    /// The holding state, for the eye: the photo frozen, the words big, the waveform, the trash.
    func testHoldingLooksRight() throws {
        for appearance in ["light", "dark"] {
            let app = try launch(appearance, ["-yuiSnapDemo", Self.words])
            _ = try openSnap(app)
            XCTAssertTrue(app.staticTexts[Self.words].waitForExistence(timeout: 5), "the words are not over the photo")
            sleep(1)
            shot("2-holding", appearance)
            app.terminate()
        }
    }

    // MARK: Helpers

    private func openSnap(_ app: XCUIApplication) throws -> XCUIElement {
        let attach = app.buttons["stage-attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 15), "no + on the stage")
        attach.tap()
        let item = app.buttons["Snap and say"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Snap and say in +")
        item.tap()
        let snap = app.descendants(matching: .any)["snap-button"].firstMatch
        XCTAssertTrue(snap.waitForExistence(timeout: 5), "the camera did not open")
        return snap
    }

    private func launch(_ appearance: String, _ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiAgent", "basil",
                               "-appearance", appearance, "-yuiDemoReply", Self.reply,
                               "-yuiDemoPickupAfter", "0.3", "-yuiDemoReplyAfter", "1.5",
                               "-yuiSnapFake", try photo(), "-yuiPTTFake", Self.words] + extra
        app.launch()
        return app
    }

    /// `YUI_SNAP_PHOTO` (a real plate, for the site's shots), else a drawn one.
    private func photo() throws -> String {
        if let path = ProcessInfo.processInfo.environment["YUI_SNAP_PHOTO"], FileManager.default.fileExists(atPath: path) {
            return path
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString).jpg")
        let size = CGSize(width: 900, height: 1600)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor(red: 0.35, green: 0.25, blue: 0.2, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 100, y: 450, width: 700, height: 700))
            UIColor.systemYellow.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 280, y: 640, width: 150, height: 150))
            ctx.cgContext.fillEllipse(in: CGRect(x: 470, y: 720, width: 150, height: 150))
        }
        try data.write(to: url)
        return url.path
    }

    private func waitGone(_ e: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)],
                         timeout: 8) == .completed
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "snap-say-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "snap-say-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
