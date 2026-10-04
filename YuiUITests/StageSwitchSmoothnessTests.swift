import XCTest

/// Chris, TestFlight ANRhjGE0nCBvjnHKIE2SNls: "when I switch between the screens, it feels a little
/// laggy." On the stage (Home, Screen 2, Screen 3 as pills), switch screens: a drag across (the app
/// plays its own, `-yuiAutoSwitch`) and a tap on a pill. Every drag frame used to run the whole
/// stage's body, the turn included, and both pages again with their rows; now it only moves the pages.
///
/// Run through `SMOOTH_TEST=StageSwitchSmoothnessTests scripts/smoothness.sh <udid>`: the table
/// prints hitches and how often the stage's body (and the screens') ran per step.
final class StageSwitchSmoothnessTests: XCTestCase {
    func testSwitchingScreensOnTheStage() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rows = env["SMOOTH_ROWS"] else { throw XCTSkip("run through scripts/smoothness.sh") }
        let shots = env["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        let appearance = env["SMOOTH_APPEARANCE"] ?? "light"
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "switch-\(appearance)-\(name).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "switch-\(appearance)-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        func mark(_ phase: String, _ edge: String) {
            print("SMOOTH \(phase) \(edge) \(String(format: "%.3f", Date().timeIntervalSince1970))")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-yuiStageFirst", "YES", "-yuiDemoAccount", "-yuiDemoAgents", "-yuiThreadRows", rows,
                               "-yuiSpeed", "YES", "-yuiBodyLog", "-appearance", appearance, "-yuiAgent", "yui", "-yuiAutoSwitch"]
        // SMOOTH_NOVISUAL=1 turns the agent's shader off, to tell its frames from the switch's.
        if env["SMOOTH_NOVISUAL"] == "1" { app.launchArguments += ["-yuiVisualOff-yui", "YES"] }
        mark("launch", "begin")
        app.launch()
        XCTAssertTrue(app.buttons["stage-type"].waitForExistence(timeout: 30), "no stage")
        waitScreens(app, 3, "the thread has no screen 3")
        sleep(2)
        mark("launch", "end")
        shot("1-home")

        // Nothing moving: the stage's own frames, for the other steps to be read against.
        mark("idle", "begin")
        sleep(8)
        mark("idle", "end")

        // The app drags its own screens (-yuiAutoSwitch, 8 s after the screens are there): 24 switches, a second
        // apart, with nothing from the test in the way. No element query runs while it is timed: an
        // accessibility snapshot blocks the app's main thread for 40 to 60 ms and reads as a hitch.
        mark("auto", "begin")
        sleep(40)
        mark("auto", "end")
        shot("2-after-auto")

        // Pills: tap across and back. (Each tap resolves its button first, which costs the app a
        // snapshot, so this step reads high on any build.)
        mark("pill", "begin")
        for n in [2, 3, 2, 1, 3, 1] {
            app.buttons["screen-pill-\(n)"].tap()
            sleep(1)
        }
        mark("pill", "end")
        waitScreen(app, 1, "the pills did not end on Home")
        shot("3-after-flicks")
    }
}
