import XCTest

/// Add agent, the pairing sheet, against the live relay (YUI-192). Driven by
/// `supabase/tests/pairing_sheet_e2e.py --sim <udid>`: a throwaway account and
/// a throwaway computer.
///
///   1. Light: Get a pairing code. The driver pairs the code from "the computer":
///      the sheet flips to One step left.
///   2. Three seconds of nothing: "Still nothing" and Try again (a minute in the app).
///   3. The driver starts the gateway (a real Yui adapter): the sheet flips to
///      connected within seconds, on its own, and Done closes it.
///
/// Feedback ADYHHk9t... "This screen hangs. The restart happened. I'm still waiting."
final class PairingSheetTests: XCTestCase {
    func testWaitingThenListening() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rts = env["YUI_RTS"]?.split(separator: ",").map(String.init), !rts.isEmpty,
              let user = env["YUI_USER"], let dir = env["YUI_SHOTS"] else {
            throw XCTSkip("run through supabase/tests/pairing_sheet_e2e.py --sim <udid>")
        }
        let shots = URL(fileURLWithPath: dir)
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: shots.appending(path: "\(name).png"))
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name
            a.lifetime = .keepAlways
            add(a)
        }
        func handshake(_ ask: String, timeout: TimeInterval = 120) {
            try? Data().write(to: shots.appending(path: "need-\(ask)"))
            let done = shots.appending(path: "\(ask)-ok")
            let end = Date.now.addingTimeInterval(timeout)
            while !FileManager.default.fileExists(atPath: done.path), Date.now < end { sleep(1) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "driver never did \(ask)")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        func text(_ s: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        let appearance = env["YUI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-yuiRefreshToken", rts[0], "-yuiUserID", user, "-appearance", appearance,
                               "-yuiAgents", "-yuiAddAgent", "-yuiGatewayGiveUp"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }

        let get = app.buttons["Get a pairing code"]
        XCTAssertTrue(get.waitForExistence(timeout: 30), "no Add agent sheet")
        get.tap()
        let code = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Pairing code")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 30), "no pairing code")
        let digits = code.label.replacingOccurrences(of: "Pairing code", with: "").filter(\.isNumber)
        try? digits.data(using: .utf8)?.write(to: shots.appending(path: "code"))
        shot("01-code-\(appearance)")

        handshake("pair")
        XCTAssertTrue(text("One step left").waitForExistence(timeout: 30), "the sheet never saw the computer pair")
        XCTAssertTrue(text("Waiting for its gateway").exists)
        sleep(1)
        shot("02-waiting-\(appearance)")

        // Nothing comes for a while (the test shortens a minute to 3 s): say so, with a way to try again.
        XCTAssertTrue(text("Still nothing from its gateway").waitForExistence(timeout: 20), "an endless spinner")
        shot("02b-gave-up-\(appearance)")
        app.buttons["Try again"].tap()
        XCTAssertTrue(text("Waiting for its gateway").waitForExistence(timeout: 5), "Try again did not wait again")

        // The gateway starts. The sheet must notice on its own, quickly.
        handshake("wake")
        let started = Date.now
        let connected = text("is connected!")
        XCTAssertTrue(connected.waitForExistence(timeout: 30), "the sheet is still waiting 30 s after the gateway answered")
        try? "\(Date.now.timeIntervalSince(started))".data(using: .utf8)?.write(to: shots.appending(path: "seconds"))
        XCTAssertFalse(text("Waiting for its gateway").exists)
        sleep(1)
        shot("03-listening-\(appearance)")
        app.buttons["Done"].tap()
        XCTAssertTrue(get.waitForNonExistence(timeout: 10))
    }
}
