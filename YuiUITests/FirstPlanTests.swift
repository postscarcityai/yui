import XCTest

/// A first plan in every agent, Arnold first (YUI-217, PROP-4). A new person opens Arnold: his
/// hello plays, the questions come last (goal, days, time, gear, how much they have lifted), one
/// Send. The runtime answers with the built week and This week is drawn again from it: the split
/// is saved, "0 of 3" and the days are the ones the answers made. Skip and "Not sure" are there.
/// The reply is runtime/src/workouts.ts's, verbatim. Demo account, no network.
/// `YUI_SHOTS=<dir>` saves screenshots.
final class FirstPlanTests: XCTestCase {
    /// runtime: the Send of Lift heavy, 3 days, 45 min, dumbbells, some experience (applyFirst + screenLines).
    static let built = #"""
Your week is built: 3 days, about 45 minutes, dumbbells. The last set of each lift stops one rep short. Ask me to push it later. It's a starting point. Tap any day to change it.
```yui
>2 clear
>2
stat@week-done "0 of 3" "Workouts this week" sub="Next: Mon Full body"
list@days title="This week" "Mon Full body" "Wed Full body" "Fri Full body" check=off
choose@edit-day "Change a day" Mon|Tue|Wed|Thu|Fri|Sat|Sun body="Tap a day to change what it trains."
card@split "Your split" "3 training days a week." cta="Rebuild my split"
save this week
>3 clear
>3
card@today "Today's workout" "Full body. About 45 minutes." sub="Mon" cta="Start"
list@sets title="Full body" "Goblet squat 3 x 8 at 20 lb" "Dumbbell bench press 3 x 8" "Dumbbell row 3 x 8 at 20 lb" "Romanian deadlift 3 x 8 at 45 lb" "Plank 3 x 30s" +check
save today
>4 clear
>4
stat@streak "0 weeks" "Streak" sub="Finish a workout and this starts"
stat@best "None yet" "Best set" sub="Your heaviest set shows here"
card@lifts "Your lifts" "Every lift you log gets its own chart here."
save progress
```
"""#

    func testLight() throws { try run("light") }
    func testDark() throws { try run("dark") }

    private var appearance = "light"
    private let tmp = FileManager.default.temporaryDirectory

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "firstplan-\(appearance)-\(name).png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "firstplan-\(appearance)-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func b(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func text(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func run(_ look: String) throws {
        appearance = look
        let log = tmp.appending(path: "yui-firstplan-events-\(look).jsonl").path
        try? FileManager.default.removeItem(atPath: log)
        let replies = tmp.appending(path: "yui-firstplan-replies.json")
        try JSONSerialization.data(withJSONObject: [Self.built]).write(to: replies)
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoFirstLaunch", "-yuiStageFirst", "YES", "-yuiAgent", "arnold", "-appearance", look,
                               "-yuiDemoReplyFile", replies.path, "-yuiDemoReplyTaps", "-yuiDemoReplyAfter", "0.6", "-yuiEventLog", log]
        app.launch()

        // 1. The first open plays his hello, not a blank screen, and the questions come after it.
        XCTAssertTrue(text(app, "Arnold here.", timeout: 20), "Arnold's hello did not play")
        XCTAssertTrue(text(app, "Five taps", timeout: 3), "the hello does not promise the five taps")
        sleep(1)
        shot("1-hello")
        for _ in 0..<4 where !text(app, "What are we training for?", timeout: 1) {
            if app.buttons["stage-next"].exists { app.buttons["stage-next"].tap() }
        }
        XCTAssertTrue(text(app, "What are we training for?", timeout: 8), "the intake's questions never came")

        // 2. One screen of questions, one Send. Not sure sits beside the real answers; Send waits for an answer.
        let send = app.buttons["stage-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no one Send under the questions")
        XCTAssertEqual(send.label, "Build my week")
        XCTAssertFalse(send.isEnabled, "Send before any answer")
        for a in ["Lift heavy", "Not sure"] {
            XCTAssertTrue(b(app, a).waitForExistence(timeout: 3), "no \(a)")
        }
        for a in ["Lift heavy", "3", "45 min", "Dumbbells", "Some experience"] {
            let o = b(app, a)
            XCTAssertTrue(o.waitForExistence(timeout: 3), "no \(a)")
            if !o.isHittable { app.swipeUp() }
            b(app, a).tap()
            if a == "Dumbbells" { shot("2-questions") }
        }
        if !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isEnabled, "Send still off with every question answered")
        shot("3-send")
        send.tap()

        // 3. Arnold answers with the week, and it is what the answers asked for.
        XCTAssertTrue(text(app, "Your week is built: 3 days", timeout: 20), "the week was never built")
        sleep(1)
        shot("4-built")
        let events = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let sent = events.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0["plan"] as? [String: Any] }.last
        let p = try XCTUnwrap(sent, "no {plan} event: \(events)")
        XCTAssertEqual(p["goal"] as? String, "Lift heavy")
        XCTAssertEqual(p["days"] as? String, "3")
        XCTAssertEqual(p["time"] as? String, "45 min")
        XCTAssertEqual(p["gear"] as? [String], ["Dumbbells"])
        XCTAssertEqual(p["level"] as? String, "Some experience")

        // 4. The split is saved: This week is drawn again from it, and Today has its first session.
        if app.buttons["Close full screen"].exists { app.buttons["Close full screen"].tap() }
        app.goToScreen(2)
        let week = app.descendants(matching: .any)["stage-screen-2"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "no This week page")
        XCTAssertTrue(week.staticTexts["0 of 3"].waitForExistence(timeout: 5), "This week does not count the three training days")
        XCTAssertTrue(text(app, "Fri Full body", timeout: 5), "the split's days are not on This week")
        XCTAssertFalse(text(app, "Easy cardio", timeout: 1), "the starter week is still there")
        shot("5-this-week")
        app.goToScreen(3)
        XCTAssertTrue(text(app, "Dumbbell bench press", timeout: 5), "Today does not hold the first session")
        shot("6-today")
    }

    override func setUp() async throws { continueAfterFailure = false }
}
