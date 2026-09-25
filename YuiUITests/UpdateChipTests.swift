import XCTest

/// Presets from a newer Yui (beta feedback ANJPrtB7CHynwGR5mqNVPSM: build 96 got a
/// `sketch` and drew every line as a red "unknown preset" with the raw Yui Lines under
/// it). `-yuiDemoUnknown` seeds a reply with a card this build draws, then four lines
/// in presets it doesn't know. The card draws; the rest is ONE "Update Yui to see this"
/// chip and no raw line or "unknown preset" shows.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class UpdateChipTests: XCTestCase {
    func testLight() throws { try run(appearance: "light") }

    func testDark() throws { try run(appearance: "dark") }

    private func run(appearance: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(appearance).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }
        func text(containing s: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }

        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoUnknown", "-appearance", appearance]
        app.launch()

        XCTAssertTrue(text(containing: "Not yet + You decide").waitForExistence(timeout: 15), "the card is not drawn")
        let chips = app.buttons.matching(identifier: "update-chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 5), "no Update chip")
        XCTAssertEqual(chips.count, 1, "the newer lines should fold into one chip")
        XCTAssertEqual(chips.firstMatch.label, "Update Yui to see this")
        XCTAssertTrue(chips.firstMatch.isHittable, "the chip is not on screen")
        XCTAssertFalse(text(containing: "unknown preset").exists, "an unknown preset error is showing")
        XCTAssertFalse(text(containing: "hologram").exists, "raw Yui Lines are showing")
        XCTAssertFalse(text(containing: "beam \"").exists, "raw Yui Lines are showing")
        sleep(1)
        shot("update-chip")
    }
}
