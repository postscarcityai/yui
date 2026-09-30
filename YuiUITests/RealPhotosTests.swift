import UIKit
import XCTest

/// t_82dc3a4b: on a REAL account, 11 photos offered, 10 kept (the 11th dropped; its flash is ComposerAttachTests), then one send
/// carries all 10 and Yui's reply shows it saw them. Driven by scripts/open_real_account.py
/// (--only RealPhotosTests); skips without its env.
final class RealPhotosTests: XCTestCase {
    private var shots = URL(fileURLWithPath: "/tmp")
    private var tag = "dark"

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(tag)-\(name).png"))
    }

    /// Photo n: a big number on its own colour, 3000 x 2000 like a phone shot.
    private func photos(_ n: Int) throws -> String {
        let hues: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                               .systemIndigo, .systemPurple, .systemPink, .systemBrown, .systemGray]
        var paths: [String] = []
        for i in 1...n {
            let url = FileManager.default.temporaryDirectory.appending(path: "real-photo-\(i).jpg")
            let size = CGSize(width: 3000, height: 2000)
            let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { ctx in
                hues[(i - 1) % hues.count].setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                let s = NSAttributedString(string: "\(i)", attributes: [.font: UIFont.boldSystemFont(ofSize: 1200), .foregroundColor: UIColor.white])
                s.draw(at: CGPoint(x: (size.width - s.size().width) / 2, y: (size.height - s.size().height) / 2))
            }
            try data.write(to: url)
            paths.append(url.path)
        }
        return paths.joined(separator: "|")
    }

    func testTenPhotosInOneSendOnARealAccount() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rt = env["YUI_RT"], let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else { throw XCTSkip("driver only") }
        shots = URL(fileURLWithPath: dir)
        tag = env["YUI_APPEARANCE"] ?? "dark"
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        // 11 files: the composer keeps 10 and flashes for the 11th.
        app.launchArguments = ["-yuiRefreshToken", rt, "-yuiUserID", user, "-appearance", tag, "-yuiComposerPhoto", try photos(11)]
        app.launch()
        XCTAssertTrue(any("crew-pick-title").waitForExistence(timeout: 60), "no picker")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }
        any("crew-pick-basil").tap()
        any("crew-start").tap()
        XCTAssertTrue(text("Your crew is here").waitForExistence(timeout: 60), "Yui's hello never came")
        sleep(2)

        let strip = app.buttons.matching(identifier: "Remove photo").allElementsBoundByIndex
        XCTAssertTrue(app.descendants(matching: .any)["attachment"].firstMatch.waitForExistence(timeout: 30), "no photos in the composer")
        shot("1-ten-in-composer")
        let kept = Set(strip.map { "\($0.frame)" }).count
        XCTAssertEqual(kept, 10, "the composer holds \(kept), not 10")
        XCTAssertFalse(app.buttons["attach"].isEnabled, "+ still enabled with 10 attached")

        let field = any("composer").firstMatch
        field.tap()
        field.typeText("Say the big number on each photo, in order, comma separated. Nothing else.")
        app.buttons["Send"].tap()
        XCTAssertTrue(any("bubble-photo").firstMatch.waitForExistence(timeout: 120), "the photos never reached the thread")
        shot("2-sent")
        // Yui's answer: a reply that names the numbers.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '9' AND label CONTAINS '10' AND label CONTAINS ','")).firstMatch
        var saw = false
        for _ in 0..<50 where !saw { saw = reply.exists; if !saw { sleep(3) } }
        sleep(2)
        shot("3-reply")
        XCTAssertTrue(saw, "no reply naming 10")
        print("reply: \(reply.label)")
    }
}
