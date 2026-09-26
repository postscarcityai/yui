import XCTest

/// YUI-99. Chris on build 96: "when I hold the backspace button it goes very slow,
/// and if I hit space twice, it is slow to create the period." On a 241-message
/// thread with cards in it, type a sentence, delete it all at key-repeat speed,
/// then double-space for the period. The field must keep every key and end where
/// the keys say. Demo account, no network.
///
/// With `-yuiBodyLog` and Speed on, the app logs each ChatView body run and each
/// keystroke_render time; `scripts/typing_speed.sh` streams that log around this
/// test and prints the p95 and how often the chat re-evaluated per key.
/// Screenshots go to `YUI_SHOTS` when set.
final class TypingSpeedTests: XCTestCase {
    static let sentence = "The quick brown fox jumps over the lazy dog again"

    func testTypingKeepsUpOnALongThread() throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "typing-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "typing-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }

        // TYPING_THREAD (TEST_RUNNER_TYPING_THREAD from xcodebuild): another odd length,
        // e.g. 1 for the control run the numbers are compared with.
        let n = ProcessInfo.processInfo.environment["TYPING_THREAD"] ?? "241"
        let newest = "Message \(n)"
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiLongThread", n, "-yuiLongThreadCards",
                               "-yuiSpeed", "YES", "-yuiBodyLog", "-appearance", "light"]
        app.launch()

        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        XCTAssertTrue(app.staticTexts[newest].waitForExistence(timeout: 10), "the long thread did not load")
        sleep(1)
        field.tap()
        sleep(1)

        // Type, one key at a time the way a thumb does.
        field.typeText(Self.sentence)
        XCTAssertEqual(field.value as? String, Self.sentence, "typing dropped or reordered keys")
        shot("1-typed")

        // Hold backspace: every character goes, as fast as the keys come.
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.sentence.count)
        field.typeText(deletes)
        let left = field.value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == field.placeholderValue, "backspace left \"\(left)\" behind")

        // Double space: the keyboard's period.
        field.typeText("See you soon  ")
        let after = field.value as? String ?? ""
        XCTAssertTrue(after.hasPrefix("See you soon"), "the words after the delete run are wrong: \"\(after)\"")
        print("typing-speed double-space result: \"\(after)\"")
        shot("2-double-space")

        // The chat is still where it was: at the newest message, nothing jumped.
        XCTAssertTrue(app.staticTexts[newest].isHittable, "typing moved the thread off its newest message")
    }
}
