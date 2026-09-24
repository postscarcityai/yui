import XCTest

/// Full-screen media always has a way out (TestFlight feedback, 2026-09-24:
/// "the X button doesn't work, I can't get out of the screen"). Every viewer
/// closes on its X and on a swipe down, and compare opens full screen too.
final class MediaViewerTests: XCTestCase {
    private var app: XCUIApplication!
    private var tag = ""

    private func launch(_ tag: String, _ lines: [String]) {
        self.tag = tag
        let log = FileManager.default.temporaryDirectory.appending(path: "yui-viewer-\(tag).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", "light",
                               "-yuiThemeDemo", lines.joined(separator: "\\n"), "-yuiEventLog", log]
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(tag)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "\(tag)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    /// The viewer's X: there while the viewer is up, gone once it closed.
    private var viewer: XCUIElement { app.buttons["Close"] }

    private func gone(_ e: XCUIElement, _ timeout: TimeInterval = 4) -> Bool {
        let x = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter.wait(for: [x], timeout: timeout) == .completed
    }

    private let gallery = #"gallery "Hello" /demo/g1.jpg|"On the wheel" /demo/g2.jpg /demo/g3.jpg layout=row"#
    private let compare = #"compare /demo/before_room.jpg /demo/after_room.jpg "Living room" labels=Old|New"#

    /// Tap a tile, then the X: the viewer goes, the chat is back.
    func testGalleryCloseButton() throws {
        launch("gallery-x", [gallery])
        let tile = app.otherElements["On the wheel"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the gallery never arrived")
        sleep(2)
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4), "the viewer never opened")
        sleep(2) // the chat keeps rendering behind the viewer (echo, typing, presence)
        shot("1-open")
        app.buttons["Close"].tap()
        XCTAssertTrue(gone(viewer), "the X did not close the viewer")
        shot("2-closed")
        // And again: a second open must close too.
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4))
        app.buttons["Close"].tap()
        XCTAssertTrue(gone(viewer), "the X did not close the viewer the second time")
    }

    /// The same, with a running timer re-rendering the chat every second behind
    /// the viewer (a live thread re-renders on every poll the same way).
    func testGalleryCloseButtonWhileChatTicks() throws {
        launch("gallery-tick", ["timer@hiit 20/10x8 Tabata +auto", gallery])
        let stageX = app.buttons["Close full screen"]
        XCTAssertTrue(stageX.waitForExistence(timeout: 20), "the timer never took the stage")
        sleep(2)
        stageX.tap()
        let tile = app.otherElements["On the wheel"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the gallery never arrived")
        sleep(1)
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4), "the viewer never opened")
        sleep(3)
        shot("1-open")
        viewer.tap()
        XCTAssertTrue(gone(viewer), "the X did not close the viewer while the chat ticks")
        shot("2-closed")
    }

    /// Off to another app and back with the viewer up (the feedback screenshot
    /// has "◀ Instagram"): the X still closes it.
    func testGalleryCloseAfterAppSwitch() throws {
        launch("gallery-switch", ["timer@hiit 20/10x8 Tabata +auto", gallery])
        let stageX = app.buttons["Close full screen"]
        XCTAssertTrue(stageX.waitForExistence(timeout: 20), "the timer never took the stage")
        sleep(2)
        stageX.tap()
        let tile = app.otherElements["On the wheel"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the gallery never arrived")
        sleep(1)
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4), "the viewer never opened")
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(4)
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").activate()
        sleep(3)
        app.activate()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "the viewer did not survive the switch")
        sleep(2)
        shot("1-back")
        viewer.tap()
        XCTAssertTrue(gone(viewer), "the X did not close the viewer after an app switch")
        shot("2-closed")
    }

    /// A thumb is not a pointer: a tap 14pt off the X's center still lands (a
    /// 44pt target, Apple's minimum). The glyph-sized X missed these on a phone.
    func testGalleryCloseButtonTargetSize() throws {
        launch("gallery-target", [gallery])
        let tile = app.otherElements["On the wheel"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the gallery never arrived")
        sleep(2)
        for (dx, dy) in [(-14.0, 14.0), (14.0, -14.0), (-14.0, -14.0)] {
            tile.tap()
            XCTAssertTrue(viewer.waitForExistence(timeout: 4), "the viewer never opened")
            sleep(1)
            let f = viewer.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX + dx, dy: f.midY + dy)).tap()
            XCTAssertTrue(gone(viewer), "a tap \(dx),\(dy) off the X's center did not close the viewer (X frame \(f))")
            if viewer.exists { break }
        }
    }

    /// Swipe down anywhere on the picture closes it too.
    func testGallerySwipeDown() throws {
        launch("gallery-swipe", [gallery])
        let tile = app.otherElements["On the wheel"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the gallery never arrived")
        sleep(2)
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4), "the viewer never opened")
        sleep(1)
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        mid.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(gone(viewer), "a swipe down did not close the viewer")
    }

    /// Compare has a full-screen button; full screen closes on X and on a swipe down.
    func testCompareFullScreen() throws {
        launch("compare", [compare])
        let full = app.buttons["Compare full screen"]
        XCTAssertTrue(full.waitForExistence(timeout: 20), "compare has no full-screen button")
        sleep(2)
        full.tap()
        let viewer = app.otherElements["Compare viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 4), "compare never went full screen")
        sleep(2)
        shot("1-full")
        app.buttons["Side by side"].firstMatch.tap()
        sleep(1)
        shot("2-full-side")
        app.buttons["Close"].tap()
        XCTAssertTrue(gone(viewer), "the X did not close the compare viewer")
        full.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 4))
        sleep(1)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(gone(viewer), "a swipe down did not close the compare viewer")
        shot("3-closed")
    }
}
