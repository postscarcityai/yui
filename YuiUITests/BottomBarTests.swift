import UIKit
import XCTest

/// The bottom bar (YUI-121): mic bottom right at 58, T and + beside it at 40. Tap the
/// mic and talk (a pause sends), hold it and let go (sends), T opens the whole field and
/// a tap away folds it, + adds pictures that go with the message. The same bar sits over
/// the stage and over the chat record. Demo account, no network; `-yuiPTTFake` stands in
/// for the mic. Screenshots go to `YUI_SHOTS` when set, and always into the result bundle.
final class BottomBarTests: XCTestCase {
    static let reply = "say \"On it. Friday at four.\""

    func testTheBarLight() throws { try bar("light") }
    func testTheBarDark() throws { try bar("dark") }

    /// Order, sizes, T out and folded back, + menu, and the same bar in the record.
    private func bar(_ appearance: String) throws {
        let app = launch(appearance)
        let mic = app.buttons["stage-mic"], type = app.buttons["stage-type"], attach = app.buttons["stage-attach"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15), "no mic on the stage")
        XCTAssertEqual(mic.frame.width, 58, accuracy: 1, "mic size")
        XCTAssertLessThan(attach.frame.minX, type.frame.minX, "+ is not left of T")
        XCTAssertLessThan(type.frame.minX, mic.frame.minX, "the mic is not bottom right")
        XCTAssertGreaterThan(mic.frame.maxX, app.frame.width - 40, "the mic is not in the corner")
        shot("1-stage-bar", appearance)

        // + does what + does: photos, the camera where there is one, files.
        attach.tap()
        XCTAssertTrue(app.buttons["Photo library"].waitForExistence(timeout: 5), "no Photo library in +")
        XCTAssertTrue(app.buttons["Files"].exists, "no Files in +")
        sleep(1)
        shot("2-plus-menu", appearance)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).tap()
        sleep(1)

        // T: the whole field slides up with the keyboard; a tap away folds it back.
        type.tap()
        let field = app.textFields["stage-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "T did not open the field")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard with the field")
        field.typeText("Half a thought")
        shot("3-stage-typing", appearance)
        app.descendants(matching: .any)["stage-tap-away"].firstMatch.tap()
        XCTAssertTrue(type.waitForExistence(timeout: 5), "a tap away did not fold the field")
        XCTAssertFalse(field.exists, "the field stayed out")
        // The words wait for the next T.
        type.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Half a thought", "the words were lost on the fold")
        app.buttons["stage-back-to-mic"].tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))

        // The record has the same bar, same place, same size.
        app.buttons["stage-record"].tap()
        let rmic = app.buttons["record-mic"], rtype = app.buttons["record-type"]
        XCTAssertTrue(rmic.waitForExistence(timeout: 5), "no mic in the record")
        XCTAssertEqual(rmic.frame.width, 58, accuracy: 1, "record mic size")
        XCTAssertTrue(app.buttons["record-attach"].exists, "no + in the record")
        XCTAssertLessThan(rtype.frame.minX, rmic.frame.minX, "the record's mic is not bottom right")
        XCTAssertFalse(app.descendants(matching: .any)["composer"].firstMatch.exists, "the record shows the old field at rest")
        sleep(1)
        shot("4-record-bar", appearance)
        rtype.tap()
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "T in the record did not open the field")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard in the record")
        shot("5-record-typing", appearance)
        // A tap on the thread lets it go and folds back to the bar.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(rtype.waitForExistence(timeout: 5), "a tap on the thread did not fold the field")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stayed up")
    }

    /// Tap the mic and talk: the words stream in, a pause sends, the stage answers.
    func testTapTalks() {
        let words = "Book me a haircut Friday at four"
        let app = launch("light", ["-yuiPTTFake", words])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.tap()
        let listening = app.descendants(matching: .any)["stage-listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 3), "a tap did not open the mic")
        XCTAssertFalse(app.buttons["stage-type"].exists, "T stays up while talking")
        shot("6-talking", "light")
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 8), "a pause did not send the words")
        XCTAssertTrue(you.label.contains("haircut"), "the stage is on something else: \(you.label)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On it'")).firstMatch
            .waitForExistence(timeout: 15), "the answer never played")
        shot("7-talk-answered", "light")
    }

    /// Hold the mic, talk, let go: it sends. The words show big while held.
    func testHoldToTalk() {
        let words = "Is my morning free tomorrow"
        let app = launch("dark", ["-yuiPTTFake", words])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.press(forDuration: 1.5)
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 5), "let go did not send the words")
        XCTAssertTrue(you.label.contains("morning"), "sent something else: \(you.label)")
        XCTAssertFalse(app.descendants(matching: .any)["stage-listening"].exists, "still listening after let go")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a voice send brought the keyboard up")
    }

    /// Hold, then slide left and let go: the words are thrown away, nothing is sent (YUI-201).
    func testSlideLeftCancels() {
        let words = "Never mind this one"
        let app = launch("light", ["-yuiPTTFake", words])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        let from = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // All the way to the trash, which sits flush left (YUI-251): the reach is the bar's width less the
        // insets and a mic, 272 points on this phone. The 200 this test used to drag stopped short of it.
        from.press(forDuration: 1.0, thenDragTo: from.withOffset(CGVector(dx: -300, dy: 0)))
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any)["stage-you"].exists, "a cancelled recording was sent")
        XCTAssertFalse(app.descendants(matching: .any)["stage-listening"].exists, "still listening after cancel")
        XCTAssertTrue(app.buttons["stage-mic"].exists, "the mic did not come back")
    }

    /// Hold, then slide up onto the lock and let go: the mic stays open hands-free, and a pause sends (YUI-201).
    func testSlideUpLocksTheRecording() {
        let words = "Is my morning free tomorrow"
        let app = launch("light", ["-yuiPTTFake", words])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        let from = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.5, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -130)))
        // Let go on the lock did not send by itself: it is still listening, then the pause sends.
        XCTAssertTrue(app.descendants(matching: .any)["stage-listening"].firstMatch.waitForExistence(timeout: 2),
                      "let go on the lock stopped the recording")
        let you = app.descendants(matching: .any)["stage-you"].firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 8), "a locked recording never sent on the pause")
        XCTAssertTrue(you.label.contains("morning"), "sent something else: \(you.label)")
    }

    /// A plain tap still toggles recording (YUI-201).
    func testTapStillToggles() {
        let app = launch("light", ["-yuiPTTFake", "Hello there"])
        let mic = app.buttons["stage-mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 15))
        mic.tap()
        XCTAssertTrue(app.descendants(matching: .any)["stage-listening"].firstMatch.waitForExistence(timeout: 3), "a tap did not record")
    }

    /// The lock sits over the mic while it is held, and the stray orb is gone (YUI-201).
    func testLockShowsAndNoStrayBubble() {
        let app = launch("dark", ["-yuiPTTDemo", "Book me a haircut Friday at four"])
        XCTAssertTrue(app.descendants(matching: .any)["stage-listening"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["stage-lock"].firstMatch.exists, "no lock over the mic")
        sleep(1)
        shot("10-lock-waiting", "dark")
    }

    func testLockArmedWhenSlidUp() {
        let app = launch("dark", ["-yuiPTTDemo", "Book me a haircut Friday at four", "-yuiPTTDemoLock"])
        XCTAssertTrue(app.descendants(matching: .any)["stage-lock-armed"].firstMatch.waitForExistence(timeout: 20), "the lock did not arm")
        sleep(1)
        shot("11-lock-armed", "dark")
    }

    /// While typing, two pictures sit above the field and go with the message.
    func testTwoPicturesGoWithTheMessage() throws {
        let app = launch("light", ["-yuiComposerPhoto", try photo(.systemOrange) + "|" + photo(.systemTeal)])
        let type = app.buttons["stage-type"]
        XCTAssertTrue(type.waitForExistence(timeout: 15))
        type.tap()
        let chips = app.images.matching(identifier: "stage-photo")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 10), "the pictures are not above the field")
        XCTAssertEqual(chips.count, 2, "two pictures should sit above the field")
        let field = app.textFields["stage-field"]
        field.tap()
        field.typeText("Which one for the poster")
        shot("8-two-pictures", "light")
        app.buttons["stage-send-text"].tap()
        XCTAssertTrue(waitGone(chips.firstMatch), "the pictures stayed after Send")
        // They went with the words: the record has the message with its pictures.
        if app.buttons["stage-back-to-mic"].exists { app.buttons["stage-back-to-mic"].tap() }
        app.buttons["stage-record"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["bubble-photo"].firstMatch.waitForExistence(timeout: 5), "no pictures in the record")
        XCTAssertTrue(app.staticTexts["Which one for the poster"].exists, "the caption is missing")
        sleep(1)
        shot("9-sent-pictures", "light")
    }

    // MARK: Helpers

    private func launch(_ appearance: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "yui",
                               "-appearance", appearance, "-yuiDemoReply", Self.reply,
                               "-yuiDemoPickupAfter", "0.3", "-yuiDemoReplyAfter", "1.5"] + extra
        app.launch()
        return app
    }

    private func photo(_ color: UIColor) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "bar-\(UUID().uuidString).jpg")
        let data = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).jpegData(withCompressionQuality: 0.9) { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            UIColor.white.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 150, y: 150, width: 300, height: 300))
        }
        try data.write(to: url)
        return url.path
    }

    private func waitGone(_ e: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)],
                         timeout: 5) == .completed
    }

    private func shot(_ name: String, _ appearance: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "bottom-bar-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "bottom-bar-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
