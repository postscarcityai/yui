import XCTest

/// Chris's TestFlight feedback on build 33: "I'm going to want a wider variety of
/// colors." The Add agent sheet showed Own + six warm looks in a sideways row, the
/// rest hidden past the edge. Every look is on screen now, sorted by hue, with
/// cool and neutral colors among them. Demo account, no backend.
final class LookPickerTests: XCTestCase {
    func testEveryLookIsOnScreen() throws {
        for appearance in ["dark", "light"] {
            try pick(appearance)
        }
    }

    private func pick(_ appearance: String) throws {
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgents", "-yuiAddAgent", "-appearance", appearance]
        app.launch()

        let own = app.buttons["Own look"]
        XCTAssertTrue(own.waitForExistence(timeout: 15), "add agent did not open")
        sleep(1)
        shot("look-picker-\(appearance)")

        // A spread of hues, not just warm ones, all tappable without a sideways scroll.
        for look in ["Cherry", "Lemon", "Lime", "Forest", "Teal", "Ocean", "Midnight", "Grape", "Slate", "Mono", "Counsel"] {
            let chip = app.buttons["\(look) look"]
            XCTAssertTrue(chip.exists, "\(look) is not a look")
            XCTAssertTrue(chip.isHittable, "\(look) is off screen")
        }

        app.buttons["Teal look"].tap()
        XCTAssertTrue(app.buttons["Teal look"].isSelected, "tapping Teal did not pick it")
        XCTAssertFalse(own.isSelected)
        sleep(1)
        shot("look-picker-\(appearance)-teal")
        app.terminate()
    }
}
